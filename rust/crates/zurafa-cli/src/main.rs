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
    let mut tty = std::fs::OpenOptions::new()
        .write(true)
        .open("/dev/tty")
        .map_err(|e| (1, format!("no terminal to report to: {e}")))?;
    write!(tty, "\x1b]7501;{}\x1b\\", fields.join(":")).map_err(|e| (1, e.to_string()))
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
const VALUED: [&str; 19] = [
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
    println!("zurafa is the command-line interface to Zurafa.\n\nUSAGE:\n  zurafa [--socket PATH] [--json] <command>\n\nCOMMANDS:\n  ls                         List sessions\n  session inspect [TARGET]   Show session details\n  pane inspect [TARGET]      Show pane details\n  tab new [OPTIONS] [-- CMD] Create a tab\n  split [OPTIONS] [-- CMD]   Split a pane\n  preview [OPTIONS] FILE     Open FILE in the preview beside a pane\n\nAGENTS:\n  send TARGET TEXT [--enter] [-e]      Type TEXT into a pane (-e reads \\n \\r \\t \\e \\xHH)\n  key TARGET KEY...                    Press keys: enter, tab, escape, up, ctrl+c, ...\n  read [TARGET] [-n N]                 Print the screen, or its last N lines with scrollback\n  wait [TARGET] [--for S,..] [-t D]    Wait until it stops working, or reaches a status\n  prompt TARGET TEXT [-t D]            Send TEXT and Enter, wait, print the screen\n  events [TARGET] [--for S,..] [--once] Print events as they happen\n  report STATE [MSG] [--progress N] [--kind K] [--id ID] [--app A] [--title T]\n                                       Report this pane's status (OSC 7501)\n\n  Statuses: idle, working, blocked, done, error, exited. Durations: 30s, 10m.\n  wait, prompt and events exit 5 when --timeout passes.\n\nTARGETS:\n  Targets match a full ID, case-insensitive label, one-based position, or ID suffix.\n  Agent commands also accept a session, meaning its focused pane, and search every\n  session unless -s is given.\n\nENVIRONMENT:\n  ZURAFA_SOCKET, ZURAFA_SESSION, and ZURAFA_PANE provide defaults inside Zurafa terminals.");
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
    fn screen_lines_include_scrollback() {
        let mut parser = vt100::Parser::new(3, 10, 100);
        parser.process(b"1\r\n2\r\n3\r\n4\r\n5");
        assert_eq!(screen_lines(&mut parser, None), ["3", "4", "5"]);
        assert_eq!(screen_lines(&mut parser, Some(4)), ["2", "3", "4", "5"]);
    }
}
