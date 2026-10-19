//! `zurafa-daemon remote <ssh destination args>` runs in a remote tab's local PTY in place of
//! `ssh -tt`. It keeps the shell in a daemon on the remote machine, reached through
//! `ssh … zurafa-daemon bridge`, so the shell survives dropped connections: it reconnects and
//! catches up from the remote replay buffer. Bytes pass through raw, so the local daemon still
//! parses titles, cwd and OSC 7501. Without a usable remote daemon it becomes plain `ssh -tt`.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{env, thread};

static HANGUP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_hangup(_: libc::c_int) {
    HANGUP.store(true, Ordering::Relaxed);
}

fn ssh_program() -> String {
    env::var("ZURAFA_SSH").unwrap_or_else(|_| "/usr/bin/ssh".into())
}

/// `sh -c` because the login shell running the remote command may be fish or something else non-POSIX.
fn remote_command(script: &str) -> String {
    format!("sh -c '{script}'")
}

/// Identifies this build, so an app update installs and talks to a matching remote daemon.
/// The Linux builds are bundled with this binary, so hashing it covers them too.
fn build_id() -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    env::current_exe().and_then(std::fs::read).unwrap_or_default().hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// The socket sits beside the binary: one daemon per build, never a Zurafa app's own daemon on that host.
fn bridge_script(build: &str) -> String {
    remote_command(&format!(
        "d=\"$HOME/.zurafa/{build}\"; [ -x \"$d/zurafa-daemon\" ] && exec \"$d/zurafa-daemon\" bridge --socket \"$d/daemon.sock\"; echo \"zurafa-need $(uname -sm)\""
    ))
}

fn upload_script(build: &str) -> String {
    remote_command(&format!(
        "d=\"$HOME/.zurafa/{build}\"; mkdir -p -m 700 \"$d\" && cat > \"$d/zurafa-daemon.tmp\" && chmod 755 \"$d/zurafa-daemon.tmp\" && mv \"$d/zurafa-daemon.tmp\" \"$d/zurafa-daemon\""
    ))
}

/// The daemon build to upload for a remote `uname -sm`.
fn binary_for(uname: &str) -> Option<PathBuf> {
    let exe = env::current_exe().ok()?;
    let triple = match uname.trim() {
        "Linux x86_64" => "x86_64-unknown-linux-musl",
        "Linux aarch64" | "Linux arm64" => "aarch64-unknown-linux-musl",
        "Darwin arm64" if cfg!(all(target_os = "macos", target_arch = "aarch64")) => return Some(exe),
        _ => return None,
    };
    let dir = env::var_os("ZURAFA_REMOTE_BINARIES")
        .map(PathBuf::from)
        .unwrap_or_else(|| exe.parent().unwrap_or(&exe).join("../Resources/remote"));
    Some(dir.join(triple).join("zurafa-daemon")).filter(|p| p.is_file())
}

fn ssh(dest: &[String], extra: &[&str], command: String) -> Command {
    let mut c = Command::new(ssh_program());
    // BatchMode: no tty for prompts here; anything interactive falls back to plain `ssh -tt`.
    c.args(["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
        .args(extra)
        .args(dest)
        .arg(command)
        // The remote end must find its own daemon, never the local one this tab runs under.
        .env_remove("ZURAFA_SOCKET")
        .stderr(Stdio::null());
    c
}

struct Writer(Mutex<Option<ChildStdin>>);

impl Writer {
    fn send(&self, v: Value) {
        let body = v.to_string();
        if let Some(w) = self.0.lock().unwrap().as_mut() {
            let _ = w.write_all(&(body.len() as u32).to_be_bytes()).and_then(|_| w.write_all(body.as_bytes())).and_then(|_| w.flush());
        }
    }
}

fn read_frame(r: &mut impl Read) -> io::Result<Value> {
    let mut len = [0; 4];
    r.read_exact(&mut len)?;
    read_body(r, len)
}

fn read_body(r: &mut impl Read, len: [u8; 4]) -> io::Result<Value> {
    let len = u32::from_be_bytes(len) as usize;
    if len > crate::protocol::MAX_FRAME {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|_| io::ErrorKind::InvalidData.into())
}

enum Open {
    Ready(Child, ChildStdin, BufReader<ChildStdout>),
    Need(String),
    Failed,
}

fn open(dest: &[String], build: &str) -> Open {
    let Ok(mut child) = ssh(dest, &[], bridge_script(build)).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn() else {
        return Open::Failed;
    };
    let (mut to, mut from) = (child.stdin.take().unwrap(), BufReader::new(child.stdout.take().unwrap()));
    let hello = json!({"id":0,"type":"hello","protocol":2}).to_string();
    let _ = to.write_all(&(hello.len() as u32).to_be_bytes()).and_then(|_| to.write_all(hello.as_bytes())).and_then(|_| to.flush());
    let mut head = [0; 4];
    let reply = match from.read_exact(&mut head) {
        Ok(()) if &head == b"zura" => {
            let mut line = String::new();
            let _ = from.read_line(&mut line);
            let _ = child.wait();
            return line.strip_prefix("fa-need ").map_or(Open::Failed, |u| Open::Need(u.trim().into()));
        }
        Ok(()) => read_body(&mut from, head).ok(),
        Err(_) => None,
    };
    if reply.is_some_and(|r| r["type"] == "hello_ok") {
        Open::Ready(child, to, from)
    } else {
        let _ = child.kill();
        let _ = child.wait();
        Open::Failed
    }
}

fn upload(dest: &[String], build: &str, binary: &PathBuf) -> bool {
    let Ok(file) = std::fs::File::open(binary) else { return false };
    ssh(dest, &[], upload_script(build)).stdin(file).stdout(Stdio::null()).status().is_ok_and(|s| s.success())
}

fn fallback(dest: &[String], why: &str) -> ! {
    print!("\r\n\x1b[2m[zurafa] {why}; using plain SSH. This session will not survive a dropped connection.\x1b[0m\r\n");
    let _ = io::stdout().flush();
    let err = Command::new(ssh_program()).arg("-tt").args(dest).exec();
    eprintln!("zurafa: cannot run ssh: {err}");
    std::process::exit(127)
}

fn window_size() -> (u16, u16) {
    let mut ws = unsafe { std::mem::zeroed::<libc::winsize>() };
    if unsafe { libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (80, 24)
    }
}

/// The remote PTY does echo and line editing, so the local one must pass keys through untouched.
fn raw_mode() {
    let mut t = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(0, &mut t) } == 0 {
        unsafe { libc::cfmakeraw(&mut t) };
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &t) };
    }
}

fn notice(text: &str) {
    let mut out = io::stdout();
    let _ = write!(out, "\r\n\x1b[2m[zurafa] {text}\x1b[0m\r\n");
    let _ = out.flush();
}

/// Closes the remote terminal (and its block in the remote layout), then exits with `code`.
fn finish(writer: &Writer, terminal: &str, code: i32) -> ! {
    writer.send(json!({"id":1,"type":"layout.command","command":{"op":"close","session":"default","block":terminal}}));
    *writer.0.lock().unwrap() = None;
    thread::sleep(Duration::from_millis(100)); // let the bridge forward the close before ssh goes away
    std::process::exit(code)
}

pub fn run(dest: Vec<String>) -> ! {
    let build = build_id();
    let (mut child, to, mut from) = match open(&dest, &build) {
        Open::Ready(c, t, f) => (c, t, f),
        Open::Failed => fallback(&dest, "Remote daemon unavailable"),
        Open::Need(uname) => match binary_for(&uname) {
            None => fallback(&dest, &format!("No Zurafa daemon build for {uname}")),
            Some(bin) => {
                notice(&format!("Installing the Zurafa daemon on this host ({uname})…"));
                if !upload(&dest, &build, &bin) {
                    fallback(&dest, "Installing the remote daemon failed");
                }
                match open(&dest, &build) {
                    Open::Ready(c, t, f) => (c, t, f),
                    _ => fallback(&dest, "Remote daemon unavailable"),
                }
            }
        },
    };
    unsafe {
        libc::signal(libc::SIGHUP, on_hangup as extern "C" fn(libc::c_int) as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_hangup as extern "C" fn(libc::c_int) as libc::sighandler_t);
    }
    raw_mode();
    let writer = Arc::new(Writer(Mutex::new(Some(to))));
    let terminal: Arc<Mutex<Option<String>>> = Arc::default();

    // Keys: the local PTY closing (EOF) means the tab is gone, same as a hangup.
    let (w, t) = (writer.clone(), terminal.clone());
    thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut stdin = io::stdin().lock();
        while let Ok(n @ 1..) = stdin.read(&mut buf) {
            if let Some(t) = t.lock().unwrap().as_deref() {
                w.send(json!({"type":"input","terminal":t,"data":B64.encode(&buf[..n])}));
            }
        }
        HANGUP.store(true, Ordering::Relaxed);
    });
    // shortcut: polls window size and hangup every 100 ms instead of SIGWINCH/self-pipe; fine for one tab, upgrade if CPU wakeups matter.
    let (w, t) = (writer.clone(), terminal.clone());
    thread::spawn(move || {
        let mut size = window_size();
        loop {
            thread::sleep(Duration::from_millis(100));
            let current = t.lock().unwrap().clone();
            if HANGUP.load(Ordering::Relaxed) {
                match current {
                    Some(t) => finish(&w, &t, 129),
                    None => std::process::exit(129),
                }
            }
            let now = window_size();
            if let (Some(t), true) = (current, now != size) {
                size = now;
                w.send(json!({"type":"resize","terminal":t,"cols":now.0,"rows":now.1}));
            }
        }
    });

    let mut end = 0u64;
    let mut first = true;
    loop {
        // Set up: start (or re-find) the remote terminal, catching up on what we missed.
        let (cols, rows) = window_size();
        let current = terminal.lock().unwrap().clone();
        writer.send(match &current {
            None => json!({"id":2,"type":"spawn","cols":cols,"rows":rows,"raw":true}),
            Some(t) => json!({"id":2,"type":"attach","terminal":t,"since":end}),
        });
        let mut stash = Vec::new();
        let ready = loop {
            match read_frame(&mut from) {
                Ok(v) if v["id"] == 2 => break Some(v),
                Ok(v) if v["type"] == "output" => stash.push(v),
                Ok(_) => {}
                Err(_) => break None,
            }
        };
        let id = match (ready, current) {
            (Some(v), None) if v["type"] == "spawned" => v["terminal"].as_str().unwrap_or_default().to_owned(),
            (Some(v), Some(t)) if v["type"] == "attached" => {
                let data = B64.decode(v["data"].as_str().unwrap_or_default()).unwrap_or_default();
                let mut out = io::stdout();
                if v["gap"] == true {
                    let _ = out.write_all(b"\x1bc"); // missed more than the replay buffer holds: redraw from what it has
                }
                let _ = out.write_all(&data).and_then(|_| out.flush());
                end = v["end"].as_u64().unwrap_or(end);
                t
            }
            (Some(_), Some(t)) => {
                // Unknown terminal: it ended while we were away. Its retained block still has the exit code.
                writer.send(json!({"id":3,"type":"events.snapshot"}));
                let code = std::iter::from_fn(|| read_frame(&mut from).ok())
                    .find(|v| v["id"] == 3)
                    .and_then(|v| v["snapshot"]["sessions"]["default"]["blocks"][&t]["exit_code"].as_i64());
                notice("The remote shell ended while disconnected.");
                finish(&writer, &t, code.unwrap_or(1) as i32)
            }
            (Some(v), None) => fallback(&dest, &format!("Remote spawn failed: {}", v["message"])),
            (None, _) => {
                stash.clear();
                String::new()
            }
        };
        if !id.is_empty() {
            *terminal.lock().unwrap() = Some(id.clone());
            writer.send(json!({"id":3,"type":"events.subscribe","subscription":"exit",
                "filter":{"block":id,"types":["terminal.child_exited"]}}));
            if !first {
                notice("Reconnected.");
                // Nudge full-screen programs into redrawing.
                writer.send(json!({"type":"resize","terminal":id,"cols":cols,"rows":rows.saturating_sub(1).max(1)}));
                writer.send(json!({"type":"resize","terminal":id,"cols":cols,"rows":rows}));
            }
            first = false;
            let mut out = io::stdout();
            let frames = stash.into_iter().map(Ok).chain(std::iter::from_fn(|| Some(read_frame(&mut from))));
            for frame in frames {
                let Ok(v) = frame else { break };
                match v["type"].as_str() {
                    Some("output") if v["terminal"] == id.as_str() => {
                        let chunk_end = v["end"].as_u64().unwrap_or(0);
                        if chunk_end > end {
                            let data = B64.decode(v["data"].as_str().unwrap_or_default()).unwrap_or_default();
                            let _ = out.write_all(&data).and_then(|_| out.flush());
                            end = chunk_end;
                        }
                    }
                    Some("events.subscribed") => {
                        let block = &v["snapshot"]["sessions"]["default"]["blocks"][&id];
                        if block["running"] == false {
                            finish(&writer, &id, block["exit_code"].as_i64().unwrap_or(1) as i32);
                        }
                    }
                    Some("events.event") if v["event"]["name"] == "child_exited" => {
                        finish(&writer, &id, v["event"]["payload"]["exit_code"].as_i64().unwrap_or(1) as i32);
                    }
                    _ => {}
                }
            }
        }
        // Connection lost: reconnect until it works or the tab closes.
        let _ = child.kill();
        let _ = child.wait();
        *writer.0.lock().unwrap() = None;
        if first {
            fallback(&dest, "Remote daemon did not start a shell");
        }
        notice("Connection lost; reconnecting…");
        let mut delay = Duration::from_secs(1);
        (child, from) = loop {
            thread::sleep(delay);
            if let Open::Ready(c, t, f) = open(&dest, &build) {
                *writer.0.lock().unwrap() = Some(t);
                break (c, f);
            }
            delay = (delay * 2).min(Duration::from_secs(10));
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_scripts_are_single_quoted_posix_sh() {
        let build = build_id();
        assert_eq!(build.len(), 16);
        for script in [bridge_script(&build), upload_script(&build)] {
            assert!(script.starts_with("sh -c '") && script.ends_with('\''));
            assert_eq!(script.matches('\'').count(), 2, "{script}");
            assert!(script.contains(&format!("$HOME/.zurafa/{build}")));
        }
    }

    #[test]
    fn picks_a_build_per_remote_platform() {
        assert_eq!(binary_for("FreeBSD amd64"), None);
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert_eq!(binary_for("Darwin arm64\n"), env::current_exe().ok());
        }
    }
}
