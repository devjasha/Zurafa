use serde_json::{json, Value};
use std::{
    env,
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process,
};

const PROTOCOL: u32 = 2;

fn socket_path(explicit: Option<String>) -> PathBuf {
    explicit
        .or_else(|| env::var("ZURAFA_SOCKET").ok())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
            home.join("Library/Application Support/Zurafa/daemon.sock")
        })
}

struct Client {
    stream: UnixStream,
    next_id: u64,
}
impl Client {
    fn connect(socket: Option<String>) -> Result<Self, String> {
        let path = socket_path(socket);
        let mut client = Self {
            stream: UnixStream::connect(&path)
                .map_err(|e| format!("could not reach daemon at {}: {e}", path.display()))?,
            next_id: 1,
        };
        let reply = client.request(json!({"type":"hello","protocol":PROTOCOL}))?;
        if reply["type"] != "hello_ok" {
            return Err(reply["message"]
                .as_str()
                .unwrap_or("hello failed")
                .to_owned());
        }
        Ok(client)
    }
    fn request(&mut self, mut v: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        v["id"] = json!(id);
        write_frame(&mut self.stream, v.to_string().as_bytes()).map_err(|e| e.to_string())?;
        loop {
            let reply: Value =
                serde_json::from_slice(&read_frame(&mut self.stream).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            if reply["id"] == id {
                if reply["type"] == "error" {
                    return Err(reply["message"]
                        .as_str()
                        .unwrap_or("request failed")
                        .to_owned());
                }
                return Ok(reply);
            }
        }
    }
    fn snapshot(&mut self) -> Result<Value, String> {
        Ok(self.request(json!({"type":"events.snapshot"}))?["snapshot"].clone())
    }
}

fn read_frame(r: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let mut len = [0; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    let mut body = vec![0; len];
    r.read_exact(&mut body)?;
    Ok(body)
}
fn write_frame(w: &mut impl Write, body: &[u8]) -> std::io::Result<()> {
    w.write_all(&(body.len() as u32).to_be_bytes())?;
    w.write_all(body)
}

#[derive(Default)]
struct Global {
    json: bool,
    socket: Option<String>,
}

fn main() {
    let (global, args) = parse_global(env::args().skip(1).collect());
    let result = run(global, args);
    if let Err((code, message)) = result {
        eprintln!("Error: {message}");
        process::exit(code);
    }
}

fn parse_global(args: Vec<String>) -> (Global, Vec<String>) {
    let mut global = Global::default();
    let mut rest = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => global.json = true,
            "--socket" if i + 1 < args.len() => {
                i += 1;
                global.socket = Some(args[i].clone());
            }
            _ => rest.push(args[i].clone()),
        }
        i += 1;
    }
    (global, rest)
}

fn run(global: Global, args: Vec<String>) -> Result<(), (i32, String)> {
    if args.is_empty() || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
        print_help();
        return Ok(());
    }
    let mut client = Client::connect(global.socket).map_err(|e| (4, e))?;
    match args[0].as_str() {
        "ls" | "sessions" => cmd_ls(&mut client, global.json),
        "session" if args.get(1).is_some_and(|s| s == "inspect") => {
            cmd_session_inspect(&mut client, &args[2..], global.json)
        }
        "pane" | "block" if args.get(1).is_some_and(|s| s == "inspect") => {
            cmd_pane_inspect(&mut client, &args[2..], global.json)
        }
        "tab" if args.get(1).is_some_and(|s| s == "new") => cmd_tab(&mut client, &args[2..]),
        "split" => cmd_split(&mut client, &args[1..]),
        other => Err((2, format!("unknown command {other:?}; run `zurafa help`"))),
    }
}

fn cmd_ls(client: &mut Client, as_json: bool) -> Result<(), (i32, String)> {
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"sessions": snapshot["sessions"]})).unwrap()
        );
        return Ok(());
    }
    println!(
        "{:<12}  {:<24}  {:>4}  {:>5}  ACTIVE",
        "SESSION", "LABEL", "TABS", "PANES"
    );
    for session in sessions(&snapshot) {
        let id = strv(&session["session_id"]);
        let label = strv(&session["label"]);
        let tabs = session["windows"].as_array().map_or(0, Vec::len);
        let panes = session["blocks"].as_object().map_or(0, |m| m.len());
        println!(
            "{:<12}  {:<24}  {:>4}  {:>5}  {}",
            short(&id),
            truncate(&label, 24),
            tabs,
            panes,
            strv(&session["active_window"])
        );
    }
    Ok(())
}

fn cmd_session_inspect(
    client: &mut Client,
    args: &[String],
    as_json: bool,
) -> Result<(), (i32, String)> {
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let target = option_value(args, &["-s", "--session"])
        .or_else(|| first_positional(args))
        .or_else(|| env::var("ZURAFA_SESSION").ok())
        .unwrap_or_else(|| "default".into());
    let session = resolve_session(&snapshot, &target)?;
    if as_json {
        println!("{}", serde_json::to_string_pretty(&session).unwrap());
        return Ok(());
    }
    print_session(&session);
    Ok(())
}

fn cmd_pane_inspect(
    client: &mut Client,
    args: &[String],
    as_json: bool,
) -> Result<(), (i32, String)> {
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let session_target = option_value(args, &["-s", "--session"])
        .or_else(|| env::var("ZURAFA_SESSION").ok())
        .unwrap_or_else(|| "default".into());
    let pane_target = option_value(args, &["-b", "--pane", "--block"])
        .or_else(|| first_positional(args))
        .or_else(|| env::var("ZURAFA_PANE").ok())
        .or_else(|| env::var("ZURAFA_BLOCK").ok())
        .ok_or((2, "pane target required outside a Zurafa pane".into()))?;
    let session = resolve_session(&snapshot, &session_target)?;
    let (id, pane) = resolve_pane(&session, &pane_target)?;
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"pane_id": id, "pane": pane})).unwrap()
        );
        return Ok(());
    }
    println!("Pane: {}", id);
    println!("Running: {}", pane["running"].as_bool().unwrap_or(false));
    if !pane["title"].is_null() {
        println!("Title: {}", strv(&pane["title"]));
    }
    if !pane["pwd"].is_null() {
        println!("PWD: {}", strv(&pane["pwd"]));
    }
    if !pane["exit_code"].is_null() {
        println!("Exit code: {}", pane["exit_code"]);
    }
    Ok(())
}

fn cmd_tab(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let session = option_value(args, &["-s", "--session"])
        .or_else(|| env::var("ZURAFA_SESSION").ok())
        .unwrap_or_else(|| "default".into());
    let label = option_value(args, &["-l", "--label"]).unwrap_or_else(|| "Terminal".into());
    let cwd = option_value(args, &["--cwd"]);
    let command = command_after_double_dash(args);
    let reply = client.request(json!({"type":"layout.tab","session":session,"label":label,"cols":80,"rows":24,"cwd":cwd,"command":command})).map_err(|e| (1, e))?;
    println!("created pane {}", strv(&reply["terminal"]));
    Ok(())
}

fn cmd_split(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let session_target = option_value(args, &["-s", "--session"])
        .or_else(|| env::var("ZURAFA_SESSION").ok())
        .unwrap_or_else(|| "default".into());
    let pane_target = option_value(args, &["-b", "--pane", "--block"])
        .or_else(|| env::var("ZURAFA_PANE").ok())
        .or_else(|| env::var("ZURAFA_BLOCK").ok())
        .ok_or((2, "--pane is required outside a Zurafa pane".into()))?;
    let session = resolve_session(&snapshot, &session_target)?;
    let (pane, _) = resolve_pane(&session, &pane_target)?;
    let axis = option_value(args, &["--axis"]).unwrap_or_else(|| "horizontal".into());
    if axis != "horizontal" && axis != "vertical" {
        return Err((2, "--axis must be horizontal or vertical".into()));
    }
    let cwd = option_value(args, &["--cwd"]);
    let command = command_after_double_dash(args);
    let reply = client.request(json!({"type":"layout.split","session":strv(&session["session_id"]),"block":pane,"axis":axis,"cols":80,"rows":24,"cwd":cwd,"command":command})).map_err(|e| (1, e))?;
    println!("created pane {}", strv(&reply["terminal"]));
    Ok(())
}

fn print_session(session: &Value) {
    println!(
        "Session: {} ({})",
        strv(&session["label"]),
        strv(&session["session_id"])
    );
    println!("Revision: {}", session["revision"]);
    if let Some(windows) = session["windows"].as_array() {
        for (i, w) in windows.iter().enumerate() {
            let active = if session["active_window"] == w["window_id"] {
                " *"
            } else {
                ""
            };
            println!(
                "  Tab {}: {} ({}){}",
                i + 1,
                strv(&w["label"]),
                strv(&w["window_id"]),
                active
            );
            println!("    selected pane: {}", strv(&w["selected_block"]));
        }
    }
}

fn resolve_session(snapshot: &Value, target: &str) -> Result<Value, (i32, String)> {
    let matches = sessions(snapshot)
        .into_iter()
        .enumerate()
        .filter(|(i, s)| {
            target_matches(
                target,
                *i + 1,
                &strv(&s["session_id"]),
                Some(&strv(&s["label"])),
            )
        })
        .map(|(_, s)| s)
        .collect::<Vec<_>>();
    one(matches, "session", target)
}
fn resolve_pane(session: &Value, target: &str) -> Result<(String, Value), (i32, String)> {
    let blocks = session["blocks"]
        .as_object()
        .ok_or((1, "snapshot has no pane map".into()))?;
    let matches = blocks
        .iter()
        .enumerate()
        .filter(|(i, (id, _))| target_matches(target, *i + 1, id, None))
        .map(|(_, (id, b))| (id.clone(), b.clone()))
        .collect::<Vec<_>>();
    one(matches, "pane", target)
}
fn one<T>(matches: Vec<T>, kind: &str, target: &str) -> Result<T, (i32, String)> {
    match matches.len() {
        1 => Ok(matches.into_iter().next().unwrap()),
        0 => Err((3, format!("{kind} target {target:?} was not found"))),
        _ => Err((3, format!("{kind} target {target:?} is ambiguous"))),
    }
}
fn target_matches(target: &str, position: usize, id: &str, label: Option<&str>) -> bool {
    target == id
        || label.is_some_and(|l| l.eq_ignore_ascii_case(target))
        || target.parse::<usize>().ok() == Some(position)
        || (target.len() >= 4 && id.ends_with(target))
}
fn sessions(snapshot: &Value) -> Vec<Value> {
    snapshot["sessions"]
        .as_object()
        .map(|m| m.values().cloned().collect())
        .unwrap_or_default()
}
fn strv(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_owned()
}
fn short(id: &str) -> String {
    if id.len() > 12 {
        format!("…{}", &id[id.len() - 11..])
    } else {
        id.to_owned()
    }
}
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        s.chars().take(max - 1).collect::<String>() + "…"
    } else {
        s.to_owned()
    }
}
fn option_value(args: &[String], names: &[&str]) -> Option<String> {
    args.windows(2)
        .find(|w| names.contains(&w[0].as_str()))
        .map(|w| w[1].clone())
}
fn first_positional(args: &[String]) -> Option<String> {
    let valued = [
        "-s",
        "--session",
        "-b",
        "--pane",
        "--block",
        "-l",
        "--label",
        "--cwd",
        "--axis",
    ];
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--" {
            return None;
        }
        if valued.contains(&args[i].as_str()) {
            i += 2;
        } else if args[i].starts_with('-') {
            i += 1;
        } else {
            return Some(args[i].clone());
        }
    }
    None
}
fn command_after_double_dash(args: &[String]) -> Option<Vec<String>> {
    args.iter()
        .position(|a| a == "--")
        .map(|i| args[i + 1..].to_vec())
        .filter(|v| !v.is_empty())
}

fn print_help() {
    println!("zurafa is the command-line interface to Zurafa.\n\nUSAGE:\n  zurafa [--socket PATH] [--json] <command>\n\nCOMMANDS:\n  ls                         List sessions\n  session inspect [TARGET]   Show session details\n  pane inspect [TARGET]      Show pane details\n  tab new [OPTIONS] [-- CMD] Create a tab\n  split [OPTIONS] [-- CMD]   Split a pane\n\nTARGETS:\n  Targets match a full ID, case-insensitive label, one-based position, or ID suffix.\n\nENVIRONMENT:\n  ZURAFA_SOCKET, ZURAFA_SESSION, and ZURAFA_PANE provide defaults inside Zurafa terminals.");
}
