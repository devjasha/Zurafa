use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    env,
    io::{ErrorKind, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process,
    time::{Duration, Instant},
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
    fn send(&mut self, v: Value) -> Result<(), String> {
        write_frame(&mut self.stream, v.to_string().as_bytes()).map_err(|e| e.to_string())
    }
    /// The next subscribed event, or None once `deadline` passes.
    fn event(&mut self, deadline: Option<Instant>) -> Result<Option<Value>, String> {
        loop {
            let left = match deadline {
                Some(d) => match d.checked_duration_since(Instant::now()) {
                    Some(left) if !left.is_zero() => Some(left),
                    _ => return Ok(None),
                },
                None => None,
            };
            self.stream
                .set_read_timeout(left)
                .map_err(|e| e.to_string())?;
            let frame = match read_frame(&mut self.stream) {
                Ok(frame) => frame,
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                    return Ok(None)
                }
                Err(e) => return Err(format!("lost the daemon: {e}")),
            };
            let v: Value = serde_json::from_slice(&frame).map_err(|e| e.to_string())?;
            match v["type"].as_str() {
                Some("events.event") => return Ok(Some(v["event"].clone())),
                Some("events.gap") => return Err("missed events; run the command again".into()),
                _ => {}
            }
        }
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
    if args[0] == "report" {
        return cmd_report(&args[1..]);
    }
    if args[0] == "setup" {
        return cmd_setup(&args[1..]);
    }
    if args[0] == "mcp" {
        return cmd_mcp(global.socket);
    }
    if args[0] == "worktree" {
        return cmd_worktree(global.socket, &args[1..]);
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
        "preview" => cmd_preview(&mut client, &args[1..]),
        "send" => cmd_send(&mut client, &args[1..]),
        "key" => cmd_key(&mut client, &args[1..]),
        "read" => cmd_read(&mut client, &args[1..]),
        "wait" => cmd_wait(&mut client, &args[1..]),
        "prompt" => cmd_prompt(&mut client, &args[1..]),
        "events" => cmd_events(&mut client, &args[1..], global.json),
        "spawn" => cmd_spawn(&mut client, &args[1..]),
        "panes" => cmd_panes(&mut client, global.json),
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

fn cmd_preview(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let file = first_positional(args).ok_or((2, "file path required".into()))?;
    let path = std::fs::canonicalize(&file).map_err(|e| (2, format!("{file}: {e}")))?;
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let session_target = option_value(args, &["-s", "--session"])
        .or_else(|| env::var("ZURAFA_SESSION").ok())
        .unwrap_or_else(|| "default".into());
    let session = resolve_session(&snapshot, &session_target)?;
    // Callers outside Zurafa have no ZURAFA_PANE, so fall back to the focused pane of the active tab.
    let pane_target = option_value(args, &["-b", "--pane", "--block"])
        .or_else(|| env::var("ZURAFA_PANE").ok())
        .or_else(|| env::var("ZURAFA_BLOCK").ok())
        .or_else(|| {
            session["windows"]
                .as_array()?
                .iter()
                .find(|w| w["window_id"] == session["active_window"])
                .map(|w| strv(&w["selected_block"]))
        })
        .ok_or((3, "session has no open pane".into()))?;
    let (pane, _) = resolve_pane(&session, &pane_target)?;
    client
        .request(json!({"type":"layout.preview","session":strv(&session["session_id"]),"block":pane,"path":path.to_string_lossy()}))
        .map_err(|e| (1, e))?;
    Ok(())
}

/// A pane named by a target: a pane, or a session for its active tab's selected pane.
/// Without `-s`, it searches every session. Returns the session id and the pane id.
fn target_pane(
    snapshot: &Value,
    args: &[String],
    target: Option<String>,
) -> Result<(String, String), (i32, String)> {
    let target = target
        .or_else(|| option_value(args, &["-b", "--pane", "--block"]))
        .or_else(|| env::var("ZURAFA_PANE").ok())
        .ok_or((2, "pane target required outside a Zurafa pane".into()))?;
    let scope = match option_value(args, &["-s", "--session"]) {
        Some(s) => vec![resolve_session(snapshot, &s)?],
        None => sessions(snapshot),
    };
    let panes = scope
        .iter()
        .filter_map(|session| {
            resolve_pane(session, &target)
                .ok()
                .map(|(id, _)| (strv(&session["session_id"]), id))
        })
        .collect::<Vec<_>>();
    if !panes.is_empty() {
        return one(panes, "pane", &target);
    }
    let session = resolve_session(snapshot, &target).map_err(|(code, e)| match code {
        3 if e.ends_with("was not found") => (3, format!("no pane or session matches {target:?}")),
        _ => (code, e),
    })?;
    let pane = session["windows"]
        .as_array()
        .and_then(|ws| {
            ws.iter()
                .find(|w| w["window_id"] == session["active_window"])
        })
        .map(|w| strv(&w["selected_block"]))
        .ok_or((3, format!("session {target:?} has no open pane")))?;
    Ok((strv(&session["session_id"]), pane))
}

/// Positional arguments before `--`, skipping options and their values.
fn positionals(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() && args[i] != "--" {
        if VALUED.contains(&args[i].as_str()) {
            i += 2;
            continue;
        }
        if !args[i].starts_with('-') || args[i] == "-" {
            out.push(args[i].clone());
        }
        i += 1;
    }
    out
}

fn input(client: &mut Client, pane: &str, bytes: &[u8]) -> Result<(), (i32, String)> {
    client
        .send(json!({"type":"input","terminal":pane,"data":B64.encode(bytes)}))
        .map_err(|e| (1, e))
}

fn cmd_send(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let [target, text] = pos.as_slice() else {
        return Err((2, "usage: zurafa send TARGET TEXT [--enter] [-e]".into()));
    };
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let (_, pane) = target_pane(&snapshot, args, Some(target.clone()))?;
    let mut bytes = if has_flag(args, &["-e", "--escapes"]) {
        unescape(text).map_err(|e| (2, e))?
    } else {
        text.as_bytes().to_vec()
    };
    if has_flag(args, &["--enter"]) {
        bytes.push(b'\r');
    }
    input(client, &pane, &bytes)
}

fn cmd_key(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let Some((target, keys)) = pos.split_first().filter(|(_, k)| !k.is_empty()) else {
        return Err((2, "usage: zurafa key TARGET KEY...".into()));
    };
    let mut bytes = Vec::new();
    for key in keys {
        bytes.extend(key_bytes(key).ok_or((2, format!("unknown key {key:?}")))?);
    }
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let (_, pane) = target_pane(&snapshot, args, Some(target.clone()))?;
    input(client, &pane, &bytes)
}

fn key_bytes(key: &str) -> Option<Vec<u8>> {
    let lower = key.to_ascii_lowercase();
    if let Some(c) = lower.strip_prefix("ctrl+").filter(|c| c.len() == 1) {
        let c = c.as_bytes()[0];
        return c.is_ascii_lowercase().then(|| vec![c & 0x1f]);
    }
    let seq: &[u8] = match lower.as_str() {
        "enter" | "return" => b"\r",
        "tab" => b"\t",
        "escape" | "esc" => b"\x1b",
        "backspace" => b"\x7f",
        "space" => b" ",
        "up" => b"\x1b[A",
        "down" => b"\x1b[B",
        "right" => b"\x1b[C",
        "left" => b"\x1b[D",
        _ => return None,
    };
    Some(seq.to_vec())
}

/// Interprets \n \r \t \e \\ and \xHH.
fn unescape(text: &str) -> Result<Vec<u8>, String> {
    let (mut out, mut chars) = (Vec::new(), text.chars());
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.extend(c.to_string().as_bytes());
            continue;
        }
        match chars.next() {
            Some('n') => out.push(b'\n'),
            Some('r') => out.push(b'\r'),
            Some('t') => out.push(b'\t'),
            Some('e') => out.push(0x1b),
            Some('\\') => out.push(b'\\'),
            Some('x') => {
                let hex: String = chars.by_ref().take(2).collect();
                out.push(u8::from_str_radix(&hex, 16).map_err(|_| format!("bad escape \\x{hex}"))?);
            }
            other => {
                return Err(format!(
                    "bad escape \\{}",
                    other.map(String::from).unwrap_or_default()
                ))
            }
        }
    }
    Ok(out)
}

/// The pane's screen as text, with up to `lines` lines including scrollback.
fn screen(client: &mut Client, pane: &str, lines: Option<usize>) -> Result<String, (i32, String)> {
    let reply = client
        .request(json!({"type":"attach","terminal":pane}))
        .map_err(|e| (1, e))?;
    let data = B64
        .decode(strv(&reply["data"]))
        .map_err(|e| (1, e.to_string()))?;
    let (cols, rows) = (
        reply["cols"].as_u64().unwrap_or(80) as u16,
        reply["rows"].as_u64().unwrap_or(24) as u16,
    );
    let mut parser = vt100::Parser::new(rows, cols, 10_000);
    parser.process(&data);
    Ok(screen_lines(&mut parser, lines).join("\n"))
}

fn screen_lines(parser: &mut vt100::Parser, lines: Option<usize>) -> Vec<String> {
    let cols = parser.screen().size().1;
    let mut out = Vec::new();
    if lines.is_some() {
        // Scrolled back by n rows, the top row is the nth-newest scrollback line.
        parser.screen_mut().set_scrollback(usize::MAX);
        for n in (1..=parser.screen().scrollback()).rev() {
            parser.screen_mut().set_scrollback(n);
            out.extend(parser.screen().rows(0, cols).take(1));
        }
        parser.screen_mut().set_scrollback(0);
    }
    out.extend(parser.screen().rows(0, cols));
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    let keep = lines.unwrap_or(out.len()).min(out.len());
    out.split_off(out.len() - keep)
}

fn cmd_read(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let lines = option_value(args, &["-n", "--lines"])
        .map(|n| {
            n.parse::<usize>()
                .map_err(|_| (2, "-n takes a number of lines".to_owned()))
        })
        .transpose()?;
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let (_, pane) = target_pane(&snapshot, args, positionals(args).into_iter().next())?;
    println!("{}", screen(client, &pane, lines)?);
    Ok(())
}

const STATES: [&str; 6] = ["idle", "working", "blocked", "done", "error", "exited"];

/// A pane's status, as the app shows it: the record that most needs you wins.
fn pane_state(records: &BTreeMap<String, String>, running: bool) -> &'static str {
    if !running {
        return "exited";
    }
    ["blocked", "error", "working", "done"]
        .into_iter()
        .find(|s| records.values().any(|r| r == s))
        .unwrap_or("idle")
}

/// Watches one pane's status records and whether it still runs.
struct Watch {
    pane: String,
    records: BTreeMap<String, String>,
    running: bool,
}
impl Watch {
    fn start(client: &mut Client, session: &str, pane: &str) -> Result<Self, (i32, String)> {
        let reply = client
            .request(
                json!({"type":"events.subscribe","subscription":"wait","filter":{"block":pane}}),
            )
            .map_err(|e| (1, e))?;
        let block = &reply["snapshot"]["sessions"][session]["blocks"][pane];
        let records = block["statuses"]["records"]
            .as_object()
            .map(|m| {
                m.iter()
                    .map(|(k, r)| (k.clone(), strv(&r["state"])))
                    .collect()
            })
            .unwrap_or_default();
        Ok(Self {
            pane: pane.to_owned(),
            records,
            running: block["running"].as_bool().unwrap_or(false),
        })
    }
    fn state(&self) -> &'static str {
        pane_state(&self.records, self.running)
    }
    fn apply(&mut self, event: &Value) {
        if strv(&event["block_id"]) != self.pane {
            return;
        }
        let payload = &event["payload"];
        match event["name"].as_str() {
            Some("program_status_changed") => {
                self.records
                    .insert(strv(&payload["id"]), strv(&payload["record"]["state"]));
            }
            Some("program_status_removed") => {
                for id in payload["ids"].as_array().into_iter().flatten() {
                    self.records.remove(&strv(id));
                }
            }
            Some("child_exited") => self.running = false,
            _ => {}
        }
    }
    /// Waits until `until` accepts the state; returns it, or None at the deadline.
    fn until(
        &mut self,
        client: &mut Client,
        deadline: Option<Instant>,
        until: impl Fn(&str) -> bool,
    ) -> Result<Option<&'static str>, (i32, String)> {
        loop {
            if until(self.state()) {
                return Ok(Some(self.state()));
            }
            match client.event(deadline).map_err(|e| (1, e))? {
                Some(event) => self.apply(&event),
                None => return Ok(None),
            }
        }
    }
}

fn parse_states(list: &str) -> Result<Vec<String>, (i32, String)> {
    list.split(',')
        .map(|s| s.trim().to_owned())
        .map(|s| {
            if STATES.contains(&s.as_str()) {
                Ok(s)
            } else {
                Err((
                    2,
                    format!("unknown status {s:?}; use {}", STATES.join(", ")),
                ))
            }
        })
        .collect()
}

/// `90`, `90s`, `500ms`, `10m` or `1h`.
fn parse_duration(text: &str) -> Result<Duration, (i32, String)> {
    let bad = || (2, format!("bad duration {text:?}; use e.g. 30s, 10m"));
    let (n, unit) = text.split_at(
        text.find(|c: char| !c.is_ascii_digit())
            .unwrap_or(text.len()),
    );
    let n: u64 = n.parse().map_err(|_| bad())?;
    Ok(match unit {
        "" | "s" => Duration::from_secs(n),
        "ms" => Duration::from_millis(n),
        "m" => Duration::from_secs(n * 60),
        "h" => Duration::from_secs(n * 3600),
        _ => return Err(bad()),
    })
}

fn deadline(args: &[String]) -> Result<Option<Instant>, (i32, String)> {
    option_value(args, &["-t", "--timeout"])
        .map(|t| parse_duration(&t).map(|d| Instant::now() + d))
        .transpose()
}

fn cmd_wait(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let wanted = option_value(args, &["--for"])
        .map(|l| parse_states(&l))
        .transpose()?;
    let deadline = deadline(args)?;
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let (session, pane) = target_pane(&snapshot, args, positionals(args).into_iter().next())?;
    let mut watch = Watch::start(client, &session, &pane)?;
    // Without --for, wait until it stops working.
    let state = watch.until(client, deadline, |s| match &wanted {
        Some(w) => w.iter().any(|x| x == s),
        None => s != "working",
    })?;
    match state {
        Some(state) => {
            println!("{state}");
            Ok(())
        }
        None => Err((5, format!("timed out; {pane} is {}", watch.state()))),
    }
}

fn cmd_prompt(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let [target, text] = pos.as_slice() else {
        return Err((2, "usage: zurafa prompt TARGET TEXT [--timeout D]".into()));
    };
    let deadline = deadline(args)?;
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let (session, pane) = target_pane(&snapshot, args, Some(target.clone()))?;
    let mut watch = Watch::start(client, &session, &pane)?;
    input(client, &pane, format!("{text}\r").as_bytes())?;
    // shortcut: a program that never reports working is treated as answered after 10s; screen-based detection would remove the guess.
    let started = Instant::now() + Duration::from_secs(10);
    if watch
        .until(
            client,
            Some(deadline.map_or(started, |d| d.min(started))),
            |s| s == "working",
        )?
        .is_some()
        && watch.until(client, deadline, |s| s != "working")?.is_none()
    {
        return Err((5, format!("timed out; {pane} is still working")));
    }
    println!("{}", screen(client, &pane, None)?);
    Ok(())
}

/// Opens a tab (or split) that runs the agent through the user's interactive login shell,
/// so it gets the shell's PATH, and leaves that shell behind when the agent exits.
fn cmd_spawn(client: &mut Client, args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let Some((agent, task)) = pos.split_first() else {
        return Err((2, "usage: zurafa spawn AGENT [TASK] [--split] [-s S] [-b PANE] [--axis A] [--cwd DIR] [-l LABEL]".into()));
    };
    // Goes into the shell script unquoted, so only a plain program name or path.
    if !agent.chars().all(|c| c.is_ascii_alphanumeric() || "._+-/~".contains(c)) {
        return Err((2, format!("{agent:?} is not a program name")));
    }
    let task = task.join(" ");
    let label = option_value(args, &["-l", "--label"]).unwrap_or_else(|| match task.as_str() {
        "" => agent.clone(),
        t => format!("{agent}: {}", truncate(t, 24)),
    });
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let split = has_flag(args, &["--split"]);
    let (session, pane) = if split {
        let (s, p) = target_pane(&snapshot, args, None)?;
        (s, Some(p))
    } else {
        let target = option_value(args, &["-s", "--session"])
            .or_else(|| env::var("ZURAFA_SESSION").ok())
            .unwrap_or_else(|| "default".into());
        (strv(&resolve_session(&snapshot, &target)?["session_id"]), None)
    };
    // shortcut: a pane's own command runs on this Mac, not the remote host; remote spawn needs the remote daemon to take a command.
    if !resolve_session(&snapshot, &session)?["remote"].is_null() {
        return Err((2, "spawn does not work in remote workspaces yet".into()));
    }
    let mut cwd = option_value(args, &["--cwd"])
        .or_else(|| env::current_dir().ok().map(|d| d.to_string_lossy().into_owned()));
    if let Some(name) = option_value(args, &["--worktree"]) {
        let repo = PathBuf::from(cwd.clone().unwrap_or_else(|| ".".into()));
        cwd = Some(ensure_worktree(&repo, &worktrees_root()?, &name)?.to_string_lossy().into_owned());
    }
    let shell = login_shell()
        .or_else(|| env::var("SHELL").ok().filter(|s| !s.is_empty()))
        .unwrap_or_else(|| "/bin/zsh".into());
    let run = if task.is_empty() { agent.clone() } else { format!("{agent} {}", shell_word(&task)) };
    // -i makes zsh and bash read .zshrc / .bashrc, where PATH is often set. fish reads config.fish
    // anyway, and an interactive fish here breaks the prompt of the fish that follows it.
    let interactive = if shell.ends_with("/fish") || shell == "fish" { "-l" } else { "-li" };
    // sh, bash, zsh and fish all accept this script.
    let command = json!([shell, interactive, "-c", format!("{run}; exec {} -l", shell_word(&shell))]);
    // The pane that ran spawn, so the app can show the new agent under it.
    let parent = env::var("ZURAFA_PANE").ok();
    let reply = match pane {
        Some(pane) => {
            let axis = option_value(args, &["--axis"]).unwrap_or_else(|| "horizontal".into());
            if axis != "horizontal" && axis != "vertical" {
                return Err((2, "--axis must be horizontal or vertical".into()));
            }
            client.request(json!({"type":"layout.split","session":session,"block":pane,"axis":axis,"cols":80,"rows":24,"cwd":cwd,"command":command,"parent":parent}))
        }
        None => client.request(json!({"type":"layout.tab","session":session,"label":label,"cols":80,"rows":24,"cwd":cwd,"command":command,"parent":parent})),
    }
    .map_err(|e| (1, e))?;
    println!("{}", strv(&reply["terminal"]));
    Ok(())
}

/// Every pane in every session, with the status the app shows for it.
fn cmd_panes(client: &mut Client, as_json: bool) -> Result<(), (i32, String)> {
    let snapshot = client.snapshot().map_err(|e| (1, e))?;
    let home = env::var("HOME").unwrap_or_default();
    let here = env::var("ZURAFA_PANE").ok();
    let mut rows = vec![];
    for session in sessions(&snapshot) {
        for tab in session["windows"].as_array().into_iter().flatten() {
            let mut ids = vec![];
            layout_panes(&tab["layout"], &mut ids);
            for id in ids {
                let pane = &session["blocks"][&id];
                let records = pane["statuses"]["records"].as_object();
                let states = records
                    .into_iter()
                    .flatten()
                    .map(|(k, r)| (k.clone(), strv(&r["state"])))
                    .collect::<BTreeMap<_, _>>();
                let status = pane_state(&states, pane["running"].as_bool().unwrap_or(false));
                let message = records
                    .into_iter()
                    .flatten()
                    .find(|(_, r)| r["state"] == status)
                    .map(|(_, r)| strv(&r["msg"]))
                    .unwrap_or_default();
                let cwd = strv(&pane["foreground"]["cwd"]);
                rows.push(json!({
                    "pane": id,
                    "session": strv(&session["session_id"]),
                    "tab": strv(&tab["label"]),
                    "program": strv(&pane["foreground"]["name"]),
                    "status": status,
                    "message": message,
                    "cwd": match cwd.strip_prefix(&home) { Some(rest) if !home.is_empty() => format!("~{rest}"), _ => cwd },
                    "current": here.as_deref() == Some(id.as_str()),
                }));
            }
        }
    }
    if as_json {
        println!("{}", serde_json::to_string_pretty(&rows).unwrap());
        return Ok(());
    }
    println!("{:<8} {:<12} {:<24} {:<10} {:<8} {:<28} MESSAGE", "PANE", "SESSION", "TAB", "PROGRAM", "STATUS", "CWD");
    for r in rows {
        let mark = if r["current"] == true { "*" } else { "" };
        println!(
            "{:<8} {:<12} {:<24} {:<10} {:<8} {:<28} {}",
            format!("{}{mark}", strv(&r["pane"])),
            truncate(&strv(&r["session"]), 12),
            truncate(&strv(&r["tab"]), 24),
            truncate(&strv(&r["program"]), 10),
            strv(&r["status"]),
            truncate(&strv(&r["cwd"]), 28),
            strv(&r["message"]),
        );
    }
    Ok(())
}

/// Pane ids in a tab's layout tree, in layout order.
fn layout_panes(layout: &Value, out: &mut Vec<String>) {
    match layout["block_id"].as_str() {
        Some(id) => out.push(id.to_owned()),
        None if layout.is_object() => {
            layout_panes(&layout["first"], out);
            layout_panes(&layout["second"], out);
        }
        None => {}
    }
}

const MCP_INSTRUCTIONS: &str = "Zurafa is the terminal workspace you are running in. Its panes are terminals; \
other coding agents may run in them. Use these tools to start agents on tasks (spawn), see every pane and \
whether it is idle, working, blocked (waiting on a person), done, error or exited (list_panes), type into a \
pane (send, key), read its screen (read), and wait for it to finish (wait, prompt). Statuses come from agents \
that report them, so a pane whose program reports nothing stays idle. Pane targets are ids like t3, a tab or \
session label, or a session (meaning its focused pane).";

fn mcp_tools() -> Value {
    let pane = json!({"type":"string","description":"Pane id (like t3), label, or session. Defaults to your own pane where that makes sense."});
    let timeout = json!({"type":"string","description":"How long to wait, like 30s, 10m or 1h. Default 10m."});
    json!([
        {"name":"list_panes","description":"List every pane in every Zurafa session with its tab, program, status (idle, working, blocked, done, error, exited), status message and directory. Your own pane is marked current.",
         "inputSchema":{"type":"object","properties":{}}},
        {"name":"spawn","description":"Start a coding agent (or any program) with a task in a new Zurafa tab, or beside a pane with split. The task is passed as the program's first argument, so `claude` starts an interactive session working on it. Returns the new pane id; use wait and read on it. Not available in remote workspaces.",
         "inputSchema":{"type":"object","properties":{
            "agent":{"type":"string","description":"Program to run, like claude, codex or pi."},
            "task":{"type":"string","description":"The task, passed as the program's first argument."},
            "split":{"type":"boolean","description":"Open beside a pane instead of in a new tab."},
            "pane":{"type":"string","description":"With split: the pane to split. Defaults to yours."},
            "cwd":{"type":"string","description":"Directory to start in. Defaults to your current directory."},
            "label":{"type":"string","description":"Tab name. Defaults to the agent and task."},
            "worktree":{"type":"string","description":"Run in its own git worktree on this branch, created from the current HEAD if new, so its changes stay apart from other agents'. Reuses the worktree if it exists."}},
          "required":["agent"]}},
        {"name":"send","description":"Type text into a pane, then press Enter unless enter is false. To answer another agent, send your message to its pane.",
         "inputSchema":{"type":"object","properties":{"pane":pane,"text":{"type":"string"},"enter":{"type":"boolean","description":"Press Enter after the text. Default true."}},"required":["pane","text"]}},
        {"name":"key","description":"Press keys in a pane: enter, tab, escape, up, down, left, right, backspace, ctrl+c and other ctrl+letter keys.",
         "inputSchema":{"type":"object","properties":{"pane":pane,"keys":{"type":"array","items":{"type":"string"}}},"required":["pane","keys"]}},
        {"name":"read","description":"Read a pane's screen as text, or its last N lines including scrollback.",
         "inputSchema":{"type":"object","properties":{"pane":pane,"lines":{"type":"integer","minimum":1}},"required":["pane"]}},
        {"name":"wait","description":"Wait until a pane stops working, or reaches one of the given statuses, and return its status. Needs the pane's program to report status.",
         "inputSchema":{"type":"object","properties":{"pane":pane,"for":{"type":"array","items":{"type":"string","enum":["idle","working","blocked","done","error","exited"]}},"timeout":timeout},"required":["pane"]}},
        {"name":"prompt","description":"Send text and Enter to a pane, wait until its agent finishes, and return the screen. The quickest way to ask another agent something.",
         "inputSchema":{"type":"object","properties":{"pane":pane,"text":{"type":"string"},"timeout":timeout},"required":["pane","text"]}}
    ])
}

/// The `zurafa` arguments that carry out an MCP tool call.
fn tool_args(name: &str, a: &Value) -> Result<Vec<String>, String> {
    let s = |k: &str| a[k].as_str().map(str::to_owned);
    let need = |k: &str| s(k).filter(|v| !v.is_empty()).ok_or(format!("{k} is required"));
    // The CLI would read these as options rather than text.
    let text = |k: &str| {
        need(k).and_then(|v| match v.starts_with('-') {
            true => Err(format!("{k} cannot start with '-'")),
            false => Ok(v),
        })
    };
    let timeout = || s("timeout").unwrap_or_else(|| "10m".into());
    Ok(match name {
        "list_panes" => vec!["panes".into()],
        "spawn" => {
            let mut v = vec!["spawn".into(), text("agent")?];
            if s("task").is_some_and(|t| !t.is_empty()) {
                v.push(text("task")?);
            }
            if a["split"] == true {
                v.push("--split".into());
            }
            for (flag, key) in [("-b", "pane"), ("--cwd", "cwd"), ("-l", "label"), ("--worktree", "worktree")] {
                if let Some(x) = s(key) {
                    v.extend([flag.into(), x]);
                }
            }
            v
        }
        "send" => {
            let mut v = vec!["send".into(), need("pane")?, text("text")?];
            if a["enter"] != false {
                v.push("--enter".into());
            }
            v
        }
        "key" => {
            let keys = a["keys"].as_array().filter(|k| !k.is_empty()).ok_or("keys is required")?;
            [vec!["key".into(), need("pane")?], keys.iter().map(strv).collect()].concat()
        }
        "read" => {
            let mut v = vec!["read".into(), need("pane")?];
            if let Some(n) = a["lines"].as_u64() {
                v.extend(["-n".into(), n.to_string()]);
            }
            v
        }
        "wait" => {
            let mut v = vec!["wait".into(), need("pane")?, "-t".into(), timeout()];
            if let Some(states) = a["for"].as_array().filter(|s| !s.is_empty()) {
                v.extend(["--for".into(), states.iter().map(strv).collect::<Vec<_>>().join(",")]);
            }
            v
        }
        "prompt" => vec!["prompt".into(), need("pane")?, text("text")?, "-t".into(), timeout()],
        other => return Err(format!("unknown tool {other:?}")),
    })
}

/// Runs a tool by running this same binary, so tools behave exactly like the commands
/// and nothing they print can reach the MCP stream.
fn call_tool(params: &Value, socket: &Option<String>) -> Value {
    let result = tool_args(&strv(&params["name"]), &params["arguments"]).and_then(|args| {
        let mut cmd = process::Command::new(env::current_exe().map_err(|e| e.to_string())?);
        if let Some(s) = socket {
            cmd.args(["--socket", s]);
        }
        let out = cmd.args(args).stdin(process::Stdio::null()).output().map_err(|e| e.to_string())?;
        let text = [out.stdout, out.stderr].concat();
        let text = String::from_utf8_lossy(&text).trim_end().to_owned();
        match (out.status.success(), text.is_empty()) {
            (true, true) => Ok("done".to_owned()),
            (true, false) => Ok(text),
            (false, _) => Err(text),
        }
    });
    let (text, is_error) = match result {
        Ok(t) => (t, false),
        Err(e) => (e, true),
    };
    json!({"content":[{"type":"text","text":text}],"isError":is_error})
}

/// The reply to one MCP message, or None for notifications and replies.
fn mcp_reply(msg: &Value, socket: &Option<String>) -> Option<Value> {
    let id = msg.get("id")?.clone();
    let method = msg.get("method")?.as_str().unwrap_or_default();
    let result = match method {
        "initialize" => Ok(json!({
            // Only plain tools are used, which every protocol version has.
            "protocolVersion": msg["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "zurafa", "version": env!("CARGO_PKG_VERSION")},
            "instructions": MCP_INSTRUCTIONS,
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": mcp_tools()})),
        "tools/call" => Ok(call_tool(&msg["params"], socket)),
        _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
    };
    Some(match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
    })
}

/// An MCP server on stdin/stdout, one JSON-RPC message per line. Each message gets its own
/// thread, so an agent can wait on one pane while it works with another.
fn cmd_mcp(socket: Option<String>) -> Result<(), (i32, String)> {
    use std::io::BufRead;
    let out = std::sync::Arc::new(std::sync::Mutex::new(std::io::stdout()));
    let write = |out: &std::sync::Mutex<std::io::Stdout>, v: Value| {
        let mut o = out.lock().unwrap();
        let _ = writeln!(o, "{v}").and_then(|_| o.flush());
    };
    for line in std::io::stdin().lock().lines() {
        let line = line.map_err(|e| (1, e.to_string()))?;
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                write(&out, json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":e.to_string()}}));
                continue;
            }
        };
        let (out, socket) = (out.clone(), socket.clone());
        std::thread::spawn(move || {
            if let Some(reply) = mcp_reply(&msg, &socket) {
                write(&out, reply);
            }
        });
    }
    Ok(())
}

/// Where `--worktree` puts worktrees: ~/.zurafa/worktrees/<repo>/<name>.
fn worktrees_root() -> Result<PathBuf, (i32, String)> {
    env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".zurafa/worktrees"))
        .ok_or((1, "HOME is not set".to_owned()))
}

/// Runs git in `dir` and returns its trimmed output, or its error message.
fn git(dir: &std::path::Path, args: &[&str]) -> Result<String, String> {
    let out = process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(process::Stdio::null())
        .output()
        .map_err(|e| format!("cannot run git: {e}"))?;
    let text = |b: Vec<u8>| String::from_utf8_lossy(&b).trim().to_owned();
    if out.status.success() {
        Ok(text(out.stdout))
    } else {
        Err(text(out.stderr))
    }
}

/// The main repository of `dir` (also from inside one of its worktrees) and where
/// the worktree for branch `name` goes.
fn worktree_path(dir: &std::path::Path, root: &std::path::Path, name: &str) -> Result<(String, PathBuf), (i32, String)> {
    let common = git(dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .map_err(|e| (2, format!("{} is not in a git repository: {e}", dir.display())))?;
    git(dir, &["check-ref-format", "--branch", name]).map_err(|_| (2, format!("{name:?} is not a valid branch name")))?;
    let repo = PathBuf::from(&common);
    // A bare clone's common dir is the repo itself; a normal one's is <repo>/.git.
    let repo_dir = if repo.file_name().is_some_and(|n| n == ".git") { repo.parent().unwrap().to_path_buf() } else { repo };
    let repo_name = repo_dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "repo".into());
    Ok((common, root.join(repo_name).join(name.replace('/', "-"))))
}

/// The worktree for branch `name` of the repo at `dir`, made from HEAD (or the existing
/// branch) when it doesn't exist yet.
fn ensure_worktree(dir: &std::path::Path, root: &std::path::Path, name: &str) -> Result<PathBuf, (i32, String)> {
    let (common, path) = worktree_path(dir, root, name)?;
    if path.exists() {
        // Same folder name from another repo of the same name, or something else entirely.
        let theirs = git(&path, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).ok();
        if theirs.as_deref() != Some(common.as_str()) {
            return Err((1, format!("{} exists but is not a worktree of this repository", path.display())));
        }
        return Ok(path);
    }
    let path_str = path.to_string_lossy().into_owned();
    let exists = git(dir, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{name}")]).is_ok();
    let args: Vec<&str> = if exists {
        vec!["worktree", "add", &path_str, name]
    } else {
        vec!["worktree", "add", "-b", name, &path_str, "HEAD"]
    };
    git(dir, &args).map_err(|e| (1, format!("git worktree add failed: {e}")))?;
    Ok(path)
}

/// Removes the worktree for branch `name` and, if it is merged, the branch.
fn remove_worktree(dir: &std::path::Path, root: &std::path::Path, name: &str, force: bool) -> Result<String, (i32, String)> {
    let (common, path) = worktree_path(dir, root, name)?;
    if git(&path, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).ok().as_deref() != Some(common.as_str()) {
        return Err((3, format!("no worktree {name:?} for this repository at {}", path.display())));
    }
    let branch = git(&path, &["branch", "--show-current"]).unwrap_or_default();
    let path_str = path.to_string_lossy().into_owned();
    let mut args = vec!["worktree", "remove", path_str.as_str()];
    if force {
        args.push("--force");
    }
    git(dir, &args).map_err(|e| (1, format!("{e}\nCommit or stash the changes first, or pass --force to discard them.")))?;
    let mut done = format!("Removed {}", path.display());
    if !branch.is_empty() {
        // -d keeps a branch with unmerged commits, so no work is lost.
        match git(dir, &["branch", "-d", &branch]) {
            Ok(_) => done += &format!(" and branch {branch}"),
            Err(_) => done += &format!("; kept branch {branch}, which has unmerged commits"),
        }
    }
    Ok(done)
}

fn cmd_worktree(socket: Option<String>, args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let dir = PathBuf::from(option_value(args, &["--cwd"]).unwrap_or_else(|| ".".into()));
    let root = worktrees_root()?;
    match pos.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["add", name] => println!("{}", ensure_worktree(&dir, &root, name)?.display()),
        ["remove", name] => {
            let force = has_flag(args, &["--force", "-f"]);
            let (_, path) = worktree_path(&dir, &root, name)?;
            // Pulling the folder out from under a running agent would break it.
            if !force {
                if let Ok(snapshot) = Client::connect(socket).and_then(|mut c| c.snapshot()) {
                    let busy: Vec<String> = sessions(&snapshot)
                        .iter()
                        .flat_map(|s| s["blocks"].as_object().cloned().unwrap_or_default())
                        .filter(|(_, b)| b["running"] == true)
                        .filter(|(_, b)| b["foreground"]["cwd"].as_str().is_some_and(|c| std::path::Path::new(c).starts_with(&path)))
                        .map(|(id, _)| id)
                        .collect();
                    if !busy.is_empty() {
                        return Err((1, format!("panes {} are open in {}; close them or pass --force", busy.join(", "), path.display())));
                    }
                }
            }
            println!("{}", remove_worktree(&dir, &root, name, force)?);
        }
        _ => return Err((2, "usage: zurafa worktree add NAME | remove NAME [--force]  (in the repository, or with --cwd DIR)".into())),
    }
    Ok(())
}

/// The account's login shell, which the daemon gives every new pane (same lookup as its pty.rs).
fn login_shell() -> Option<String> {
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    // SAFETY: getpwuid_r fills entry from buffer; pw_shell is read only on success, while buffer lives.
    let status = unsafe {
        libc::getpwuid_r(libc::getuid(), entry.as_mut_ptr(), buffer.as_mut_ptr().cast(), buffer.len(), &mut result)
    };
    if status != 0 || result.is_null() || unsafe { (*result).pw_shell }.is_null() {
        return None;
    }
    let shell = unsafe { std::ffi::CStr::from_ptr((*result).pw_shell) }.to_str().ok()?;
    (!shell.is_empty()).then(|| shell.to_owned())
}

/// Quotes `text` as one word that sh, bash, zsh and fish all read back unchanged.
/// Control characters become spaces: typed into a shell they would edit the line.
fn shell_word(text: &str) -> String {
    let mut out = String::from("'");
    for c in text.chars() {
        match c {
            // Fish reads \' and \\ inside single quotes, so both go outside them.
            '\'' => out.push_str(r#"'"'"'"#),
            '\\' => out.push_str(r#"'"\\"'"#),
            c if c.is_control() => out.push(' '),
            c => out.push(c),
        }
    }
    out.push('\'');
    out
}

fn cmd_events(client: &mut Client, args: &[String], as_json: bool) -> Result<(), (i32, String)> {
    let wanted = option_value(args, &["--for"])
        .map(|l| parse_states(&l))
        .transpose()?;
    let once = has_flag(args, &["--once"]);
    let deadline = deadline(args)?;
    let filter = match positionals(args).into_iter().next() {
        Some(target) => {
            let snapshot = client.snapshot().map_err(|e| (1, e))?;
            json!({"block": target_pane(&snapshot, args, Some(target))?.1})
        }
        None => json!({}),
    };
    client
        .request(json!({"type":"events.subscribe","subscription":"events","filter":filter}))
        .map_err(|e| (1, e))?;
    loop {
        let Some(event) = client.event(deadline).map_err(|e| (1, e))? else {
            return Err((5, "timed out".into()));
        };
        let name = match event["category"].as_str() {
            Some("terminal") => format!("terminal.{}", strv(&event["name"])),
            _ => strv(&event["type"]),
        };
        let state = strv(&event["payload"]["record"]["state"]);
        if let Some(w) = &wanted {
            if name != "terminal.program_status_changed" || !w.contains(&state) {
                continue;
            }
        }
        if as_json {
            println!("{event}");
        } else {
            let detail = match name.as_str() {
                "terminal.program_status_changed" => {
                    let msg = strv(&event["payload"]["record"]["msg"]);
                    if msg.is_empty() {
                        state
                    } else {
                        format!("{state}  {msg}")
                    }
                }
                "terminal.child_exited" => format!("exit {}", event["payload"]["exit_code"]),
                "terminal.title_changed" => strv(&event["payload"]["title"]),
                _ => String::new(),
            };
            println!(
                "{}  {:<10}  {:<6}  {:<32}  {}",
                clock(event["timestamp"].as_u64().unwrap_or(0)),
                short(&strv(&event["session_id"])),
                strv(&event["block_id"]),
                name,
                detail
            );
        }
        let _ = std::io::stdout().flush();
        if once {
            return Ok(());
        }
    }
}

/// Local HH:MM:SS for a Unix time in milliseconds.
fn clock(ms: u64) -> String {
    let secs = (ms / 1000) as libc::time_t;
    let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
    unsafe { libc::localtime_r(&secs, &mut tm) };
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

/// Writes an OSC 7501 report to this terminal, which the daemon parses like any program's.
fn cmd_report(args: &[String]) -> Result<(), (i32, String)> {
    let pos = positionals(args);
    let Some((state, msg)) = pos.split_first() else {
        return Err((2, "usage: zurafa report STATE [MESSAGE] [--progress N] [--kind K] [--id ID] [--app APP] [--title T]".into()));
    };
    let state = match state.as_str() {
        "idle" | "working" | "blocked" | "done" | "error" | "clear" => state.as_str(),
        other => {
            return Err((
                2,
                format!(
                    "unknown state {other:?}; use idle, working, blocked, done, error or clear"
                ),
            ))
        }
    };
    let mut fields = vec![format!("state={state}")];
    if let Some(id) = option_value(args, &["--id"]) {
        fields.push(format!("id={id}"));
    }
    if let Some(kind) = option_value(args, &["--kind"]) {
        if !["permission", "question", "auth"].contains(&kind.as_str()) {
            return Err((2, "--kind must be permission, question or auth".into()));
        }
        fields.push(format!("kind={kind}"));
    }
    if let Some(progress) = option_value(args, &["--progress"]) {
        progress
            .parse::<u8>()
            .ok()
            .filter(|p| *p <= 100)
            .ok_or((2, "--progress takes 0 to 100".to_owned()))?;
        fields.push(format!("progress={progress}"));
    }
    if let Some(app) = option_value(args, &["--app"]) {
        fields.push(format!("app={app}"));
    }
    if let Some(title) = option_value(args, &["--title"]) {
        fields.push(format!("title={}", B64.encode(title)));
    }
    if !msg.is_empty() {
        fields.push(format!("msg={}", B64.encode(msg.join(" "))));
    }
    // An agent's command output is captured, so write to the terminal itself.
    let open = |path: &str| std::fs::OpenOptions::new().write(true).open(path);
    let mut tty = open("/dev/tty")
        // Claude Code runs hooks in a session of their own, without a controlling terminal,
        // so use the terminal of the nearest process that has one: the agent's.
        .or_else(|e| ancestor_tty().ok_or(e).and_then(|t| open(&t)))
        .map_err(|e| (1, format!("no terminal to report to: {e}")))?;
    write!(tty, "\x1b]7501;{}\x1b\\", fields.join(":")).map_err(|e| (1, e.to_string()))
}

/// The terminal device of the closest parent process that has one, like /dev/ttys002.
fn ancestor_tty() -> Option<String> {
    let mut pid = std::os::unix::process::parent_id();
    for _ in 0..16 {
        let out = process::Command::new("ps").args(["-o", "tty=,ppid=", "-p", &pid.to_string()]).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        let mut fields = text.split_whitespace();
        let (tty, parent) = (fields.next()?, fields.next()?.parse::<u32>().ok()?);
        // ps shows "??" (macOS) or "?" (Linux) for a process without a terminal.
        if !tty.starts_with('?') {
            return Some(format!("/dev/{tty}"));
        }
        if parent <= 1 {
            return None;
        }
        pid = parent;
    }
    None
}

/// The hooks the agents guide lists: (event, matcher, command).
const CLAUDE_HOOKS: [(&str, Option<&str>, &str); 4] = [
    ("UserPromptSubmit", None, "zurafa report working"),
    ("PostToolUse", None, "zurafa report working"),
    ("Notification", Some("permission_prompt"), "zurafa report blocked --kind permission"),
    ("Stop", None, "zurafa report done"),
];

fn cmd_setup(args: &[String]) -> Result<(), (i32, String)> {
    if positionals(args).first().map(String::as_str) != Some("claude") {
        return Err((2, "usage: zurafa setup claude".into()));
    }
    let dir = env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".claude")))
        .ok_or((1, "HOME is not set".to_owned()))?;
    let mut path = dir.join("settings.json");
    // Write through a symlinked settings.json (dotfiles) instead of replacing the link.
    if let Ok(real) = std::fs::canonicalize(&path) {
        path = real;
    }
    let original = match std::fs::read_to_string(&path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => return Err((1, format!("cannot read {}: {e}", path.display()))),
    };
    let mut settings = match &original {
        Some(text) if !text.trim().is_empty() => serde_json::from_str(text)
            .map_err(|e| (1, format!("{} is not valid JSON, left unchanged: {e}", path.display())))?,
        _ => json!({}),
    };
    let added = add_claude_hooks(&mut settings).map_err(|e| (1, format!("{}: {e}, left unchanged", path.display())))?;
    if added == 0 {
        println!("Claude Code already reports to Zurafa ({}).", path.display());
        return Ok(());
    }
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| (1, e.to_string()))?;
    // Settings can hold API keys in `env`, so copies keep the original's permissions.
    let perms = std::fs::metadata(&path).ok().map(|m| m.permissions());
    let keep_perms = |p: &PathBuf| match &perms {
        Some(perms) => std::fs::set_permissions(p, perms.clone()),
        None => Ok(()),
    };
    if let Some(text) = &original {
        let backup = path.with_extension("json.zurafa-backup");
        std::fs::write(&backup, text)
            .and_then(|_| keep_perms(&backup))
            .map_err(|e| (1, format!("cannot back up settings: {e}")))?;
        println!("Backed up the old settings to {}", backup.display());
    }
    let tmp = path.with_extension("json.zurafa-tmp");
    let body = serde_json::to_string_pretty(&settings).unwrap() + "\n";
    std::fs::write(&tmp, body)
        .and_then(|_| keep_perms(&tmp))
        .and_then(|_| std::fs::rename(&tmp, &path))
        .map_err(|e| (1, format!("cannot write {}: {e}", path.display())))?;
    println!("Added {added} Zurafa hooks to {}. Restart Claude Code in a Zurafa pane.", path.display());
    Ok(())
}

/// Adds the Zurafa hooks that are missing and returns how many it added.
/// Refuses, without changing anything, when `hooks` has an unexpected shape.
fn add_claude_hooks(settings: &mut Value) -> Result<usize, String> {
    let root = settings.as_object_mut().ok_or("settings are not a JSON object")?;
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().ok_or("\"hooks\" is not an object")?;
    for (event, _, _) in CLAUDE_HOOKS {
        if hooks.get(event).is_some_and(|v| !v.is_array()) {
            return Err(format!("\"hooks.{event}\" is not a list"));
        }
    }
    let mut added = 0;
    for (event, matcher, command) in CLAUDE_HOOKS {
        let list = hooks.entry(event).or_insert_with(|| json!([])).as_array_mut().unwrap();
        let present = list.iter().any(|entry| {
            entry["hooks"].as_array().is_some_and(|hs| hs.iter().any(|h| h["command"] == command))
        });
        if present {
            continue;
        }
        let mut entry = json!({ "hooks": [{ "type": "command", "command": command }] });
        if let Some(m) = matcher {
            entry["matcher"] = json!(m);
        }
        list.push(entry);
        added += 1;
    }
    Ok(added)
}

fn has_flag(args: &[String], names: &[&str]) -> bool {
    args.iter()
        .take_while(|a| *a != "--")
        .any(|a| names.contains(&a.as_str()))
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
/// Options that take a value, so their values are not mistaken for positional arguments.
const VALUED: [&str; 20] = [
    "--worktree",
    "-s",
    "--session",
    "-b",
    "--pane",
    "--block",
    "-l",
    "--label",
    "--cwd",
    "--axis",
    "-n",
    "--lines",
    "--for",
    "-t",
    "--timeout",
    "--progress",
    "--kind",
    "--id",
    "--app",
    "--title",
];
fn first_positional(args: &[String]) -> Option<String> {
    positionals(args).into_iter().next()
}
fn command_after_double_dash(args: &[String]) -> Option<Vec<String>> {
    args.iter()
        .position(|a| a == "--")
        .map(|i| args[i + 1..].to_vec())
        .filter(|v| !v.is_empty())
}

fn print_help() {
    println!("zurafa is the command-line interface to Zurafa.\n\nUSAGE:\n  zurafa [--socket PATH] [--json] <command>\n\nCOMMANDS:\n  ls                         List sessions\n  session inspect [TARGET]   Show session details\n  pane inspect [TARGET]      Show pane details\n  tab new [OPTIONS] [-- CMD] Create a tab\n  split [OPTIONS] [-- CMD]   Split a pane\n  preview [OPTIONS] FILE     Open FILE in the preview beside a pane\n  panes                      List every pane with its tab, program and status\n\nAGENTS:\n  spawn AGENT [TASK] [--split]         Start AGENT with TASK in a new tab (or split); prints the pane\n    [--worktree BRANCH]                ...in its own git worktree on BRANCH\n  worktree add|remove BRANCH           Create (and print) or remove an agent worktree\n  send TARGET TEXT [--enter] [-e]      Type TEXT into a pane (-e reads \\n \\r \\t \\e \\xHH)\n  key TARGET KEY...                    Press keys: enter, tab, escape, up, ctrl+c, ...\n  read [TARGET] [-n N]                 Print the screen, or its last N lines with scrollback\n  wait [TARGET] [--for S,..] [-t D]    Wait until it stops working, or reaches a status\n  prompt TARGET TEXT [-t D]            Send TEXT and Enter, wait, print the screen\n  events [TARGET] [--for S,..] [--once] Print events as they happen\n  report STATE [MSG] [--progress N] [--kind K] [--id ID] [--app A] [--title T]\n                                       Report this pane's status (OSC 7501)\n  setup claude                         Add the status hooks to Claude Code's settings\n  mcp                                  Serve these commands as MCP tools on stdin/stdout\n\n  Statuses: idle, working, blocked, done, error, exited. Durations: 30s, 10m.\n  wait, prompt and events exit 5 when --timeout passes.\n\nTARGETS:\n  Targets match a full ID, case-insensitive label, one-based position, or ID suffix.\n  Agent commands also accept a session, meaning its focused pane, and search every\n  session unless -s is given.\n\nENVIRONMENT:\n  ZURAFA_SOCKET, ZURAFA_SESSION, and ZURAFA_PANE provide defaults inside Zurafa terminals.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_and_keys() {
        assert_eq!(unescape(r"y\n\e\x41\\").unwrap(), b"y\n\x1bA\\");
        assert!(unescape(r"\q").is_err());
        assert_eq!(key_bytes("ctrl+c").unwrap(), [3]);
        assert_eq!(key_bytes("Enter").unwrap(), b"\r");
        assert!(key_bytes("ctrl+1").is_none());
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_duration("10m").unwrap(), Duration::from_secs(600));
        assert_eq!(parse_duration("500ms").unwrap(), Duration::from_millis(500));
        assert!(parse_duration("m").is_err());
    }

    #[test]
    fn state_most_needing_you_wins() {
        let records = BTreeMap::from([("a".into(), "done".into()), ("b".into(), "blocked".into())]);
        assert_eq!(pane_state(&records, true), "blocked");
        assert_eq!(pane_state(&BTreeMap::new(), true), "idle");
        assert_eq!(pane_state(&records, false), "exited");
    }

    #[test]
    fn claude_hooks_merge_once_and_keep_user_hooks() {
        let mut settings = json!({
            "model": "opus",
            "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }] }
        });
        assert_eq!(add_claude_hooks(&mut settings).unwrap(), 4);
        assert_eq!(settings["model"], "opus");
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["command"], "say done");
        assert_eq!(settings["hooks"]["Stop"][1]["hooks"][0]["command"], "zurafa report done");
        assert_eq!(settings["hooks"]["Notification"][0]["matcher"], "permission_prompt");
        assert_eq!(add_claude_hooks(&mut settings).unwrap(), 0);

        let mut odd = json!({ "hooks": { "Stop": "nope" } });
        assert!(add_claude_hooks(&mut odd).is_err());
        assert_eq!(odd, json!({ "hooks": { "Stop": "nope" } }));
        assert!(add_claude_hooks(&mut json!([])).is_err());
    }

    #[test]
    fn shell_word_reads_back_unchanged_in_every_shell() {
        let task = r#"fix "it" — don't $HOME `x` \n \\ !! *.rs"#;
        assert_eq!(shell_word("a\tb\nc"), "'a b c'");
        for shell in ["sh", "bash", "zsh", "fish"] {
            let script = format!("printf %s {}", shell_word(task));
            let Ok(out) = process::Command::new(shell).arg("-c").arg(&script).output() else {
                continue; // that shell isn't installed here
            };
            assert_eq!(String::from_utf8_lossy(&out.stdout), task, "{shell}");
        }
    }

    #[test]
    fn mcp_tools_map_to_commands() {
        let args = |name, a| tool_args(name, &a).unwrap();
        assert_eq!(args("send", json!({"pane":"t3","text":"go on"})), ["send", "t3", "go on", "--enter"]);
        assert_eq!(args("send", json!({"pane":"t3","text":"y","enter":false})), ["send", "t3", "y"]);
        assert_eq!(args("wait", json!({"pane":"t3","for":["blocked","done"]})), ["wait", "t3", "-t", "10m", "--for", "blocked,done"]);
        assert_eq!(
            args("spawn", json!({"agent":"claude","task":"fix it","split":true,"pane":"t1"})),
            ["spawn", "claude", "fix it", "--split", "-b", "t1"]
        );
        assert_eq!(args("key", json!({"pane":"t3","keys":["escape","enter"]})), ["key", "t3", "escape", "enter"]);
        assert!(tool_args("send", &json!({"pane":"t3","text":"--enter"})).is_err());
        assert!(tool_args("read", &json!({})).is_err());
        assert!(tool_args("rm", &json!({})).is_err());
    }

    #[test]
    fn mcp_answers_requests_but_not_notifications() {
        let init = mcp_reply(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}), &None).unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(init["id"], 1);
        let list = mcp_reply(&json!({"jsonrpc":"2.0","id":"a","method":"tools/list"}), &None).unwrap();
        let names: Vec<_> = list["result"]["tools"].as_array().unwrap().iter().map(|t| strv(&t["name"])).collect();
        assert_eq!(names, ["list_panes", "spawn", "send", "key", "read", "wait", "prompt"]);
        assert!(mcp_reply(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}), &None).is_none());
        assert_eq!(mcp_reply(&json!({"jsonrpc":"2.0","id":2,"method":"nope"}), &None).unwrap()["error"]["code"], -32601);
    }

    #[test]
    fn worktrees_are_made_reused_and_removed_safely() {
        let base = env::temp_dir().join(format!("zurafa-wt-{}", process::id()));
        let (repo, root) = (base.join("myrepo"), base.join("worktrees"));
        std::fs::create_dir_all(&repo).unwrap();
        let g = |dir: &std::path::Path, args: &[&str]| git(dir, args).unwrap();
        g(&repo, &["init", "-q", "-b", "main"]);
        g(&repo, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]);

        let path = ensure_worktree(&repo, &root, "agent/fix-login").unwrap();
        assert_eq!(path, root.join("myrepo/agent-fix-login"));
        assert_eq!(g(&path, &["branch", "--show-current"]), "agent/fix-login");
        // Again, and from inside the worktree itself: the same folder.
        assert_eq!(ensure_worktree(&repo, &root, "agent/fix-login").unwrap(), path);
        assert_eq!(ensure_worktree(&path, &root, "agent/fix-login").unwrap(), path);
        assert!(ensure_worktree(&repo, &root, "bad..name").is_err());

        // Uncommitted work blocks removal; a merged branch goes with the worktree.
        std::fs::write(path.join("wip.txt"), "x").unwrap();
        assert!(remove_worktree(&repo, &root, "agent/fix-login", false).is_err());
        assert!(path.join("wip.txt").exists());
        std::fs::remove_file(path.join("wip.txt")).unwrap();
        assert!(remove_worktree(&repo, &root, "agent/fix-login", false).unwrap().contains("and branch"));
        assert!(!path.exists());

        // A branch with unmerged commits is kept.
        let path = ensure_worktree(&repo, &root, "spike").unwrap();
        g(&path, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "wip"]);
        assert!(remove_worktree(&repo, &root, "spike", false).unwrap().contains("kept branch spike"));
        assert!(git(&repo, &["rev-parse", "--verify", "--quiet", "refs/heads/spike"]).is_ok());
        assert!(remove_worktree(&repo, &root, "spike", false).is_err()); // already gone
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn layout_panes_follow_the_tree() {
        let block = |id| json!({"type":"block","block_id":id});
        let split = |a, b| json!({"type":"split","axis":"vertical","ratio":0.5,"first":a,"second":b});
        let layout = split(block("t2"), split(block("t5"), block("t3")));
        let mut ids = vec![];
        layout_panes(&layout, &mut ids);
        assert_eq!(ids, ["t2", "t5", "t3"]);
        layout_panes(&json!({"type":"split"}), &mut ids); // malformed: no branches
        assert_eq!(ids.len(), 3);
    }

    #[test]
    fn screen_lines_include_scrollback() {
        let mut parser = vt100::Parser::new(3, 10, 100);
        parser.process(b"1\r\n2\r\n3\r\n4\r\n5");
        assert_eq!(screen_lines(&mut parser, None), ["3", "4", "5"]);
        assert_eq!(screen_lines(&mut parser, Some(4)), ["2", "3", "4", "5"]);
    }
}
