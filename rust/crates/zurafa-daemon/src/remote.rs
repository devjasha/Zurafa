//! `zurafa-daemon remote <ssh destination args>` runs in a remote tab's local PTY in place of
//! `ssh -tt`. It keeps the shell in a daemon on the remote machine, reached through
//! `ssh … zurafa-daemon bridge`, so the shell survives dropped connections: it reconnects and
//! catches up from the remote replay buffer. Bytes pass through raw, so the local daemon still
//! parses titles, cwd and OSC 7501. Without a usable remote daemon it becomes plain `ssh -tt`.
//! When the host is a Tailscale peer whose daemon runs `--extra-listen tailnet://`, the tab skips
//! SSH and connects to that daemon directly, as Rex does.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
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

fn write_frame(w: &mut impl Write, v: &Value) -> io::Result<()> {
    let body = v.to_string();
    w.write_all(&(body.len() as u32).to_be_bytes())?;
    w.write_all(body.as_bytes())?;
    w.flush()
}

struct Writer(Mutex<Option<Box<dyn Write + Send>>>);

impl Writer {
    fn send(&self, v: Value) {
        if let Some(w) = self.0.lock().unwrap().as_mut() {
            let _ = write_frame(w, &v);
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

/// A connection to the remote daemon; `child` is the `ssh` process when it goes through SSH.
struct Conn {
    child: Option<Child>,
    to: Box<dyn Write + Send>,
    from: BufReader<Box<dyn Read + Send>>,
}

/// How this tab reaches its remote daemon. A reconnect must reach the same daemon to find its shell.
#[derive(Clone, Copy)]
enum Route {
    /// `tls`: HTTPS through Tailscale Serve, else plain HTTP to a `tailnet://` listener.
    Direct { addr: SocketAddr, tls: bool },
    Ssh,
}

enum Open {
    Ready(Conn),
    Need(String),
    Failed,
}

fn open(dest: &[String], build: &str) -> Open {
    let Ok(mut child) = ssh(dest, &[], bridge_script(build)).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn() else {
        return Open::Failed;
    };
    let mut to: Box<dyn Write + Send> = Box::new(child.stdin.take().unwrap());
    let mut from = BufReader::new(Box::new(child.stdout.take().unwrap()) as Box<dyn Read + Send>);
    let _ = write_frame(&mut to, &json!({"id":0,"type":"hello","protocol":2}));
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
        Open::Ready(Conn { child: Some(child), to, from })
    } else {
        let _ = child.kill();
        let _ = child.wait();
        Open::Failed
    }
}

/// `(user, host)` of the SSH destination, the last argument (`[user@]host`).
fn destination(dest: &[String]) -> (Option<&str>, &str) {
    let last = dest.last().map_or("", String::as_str);
    match last.split_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, last),
    }
}

/// Plain HTTP is only safe inside WireGuard, so connect directly only to a Tailscale peer.
fn is_tailnet(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]),
        IpAddr::V6(v6) => v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// The host's address when it resolves to one Tailscale knows as a peer.
fn tailnet_ip(host: &str) -> Option<IpAddr> {
    (host, 0)
        .to_socket_addrs()
        .ok()?
        .map(|a| a.ip())
        .filter(|ip| is_tailnet(*ip))
        // 100.64.0.0/10 is also carrier-grade NAT space: make sure it is really our tailnet.
        .find(|ip| crate::hosts::tailscale(&["whois", &ip.to_string()]).is_some())
}

/// Rex's order: HTTPS on 443 (Tailscale Serve, which only has certificates for `*.ts.net` names),
/// then plain HTTP on 7297 (a `tailnet://` listener).
fn open_first_direct(host: &str, user: Option<&str>) -> Option<(Route, Conn)> {
    let ip = tailnet_ip(host)?;
    let routes = [(443, true), (crate::listen::DEFAULT_PORT, false)];
    routes.into_iter().filter(|&(_, tls)| !tls || host.ends_with(".ts.net")).find_map(|(port, tls)| {
        let route = Route::Direct { addr: SocketAddr::new(ip, port), tls };
        Some((route, open_direct(route, host, user)?))
    })
}

fn open_direct(route: Route, host: &str, user: Option<&str>) -> Option<Conn> {
    let Route::Direct { addr, tls } = route else { return None };
    let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(3)).ok()?;
    // run() pings every 15 s, so 45 s of silence means a dead link, like SSH's ServerAlive settings.
    stream.set_read_timeout(Some(Duration::from_secs(45))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(45))).ok()?;
    let (from, mut to): (Box<dyn Read + Send>, Box<dyn Write + Send>) = if tls {
        tls::split(stream, host)?
    } else {
        (Box::new(stream.try_clone().ok()?), Box::new(stream))
    };
    let mut from = BufReader::new(from);
    write!(to, "GET /zurafa HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: zurafa\r\n\r\n").ok()?;
    to.flush().ok()?;
    let mut head = (&mut from).take(8192);
    let mut line = String::new();
    head.read_line(&mut line).ok()?;
    if !line.starts_with("HTTP/1.1 101 ") {
        return None;
    }
    loop {
        line.clear();
        match head.read_line(&mut line).ok()? {
            0 => return None,
            _ if line.trim_end().is_empty() => break,
            _ => {}
        }
    }
    write_frame(&mut to, &json!({"id":0,"type":"hello","protocol":2})).ok()?;
    let reply = read_frame(&mut from).ok()?;
    // The daemon runs as one account; an explicit SSH user that differs must go through SSH.
    let user_ok = user.map_or(true, |u| reply["user"] == u);
    (reply["type"] == "hello_ok" && user_ok).then_some(Conn { child: None, to, from })
}

/// The first SSH connection, installing the remote daemon if the host lacks this build.
fn open_ssh(dest: &[String], build: &str) -> Conn {
    match open(dest, build) {
        Open::Ready(conn) => conn,
        Open::Failed => fallback(dest, "Remote daemon unavailable"),
        Open::Need(uname) => match binary_for(&uname) {
            None => fallback(dest, &format!("No Zurafa daemon build for {uname}")),
            Some(bin) => {
                notice(&format!("Installing the Zurafa daemon on this host ({uname})…"));
                if !upload(dest, build, &bin) {
                    fallback(dest, "Installing the remote daemon failed");
                }
                match open(dest, build) {
                    Open::Ready(conn) => conn,
                    _ => fallback(dest, "Remote daemon unavailable"),
                }
            }
        },
    }
}

fn reopen(route: Route, dest: &[String], build: &str) -> Option<Conn> {
    match route {
        Route::Direct { .. } => {
            let (user, host) = destination(dest);
            open_direct(route, host, user)
        }
        Route::Ssh => match open(dest, build) {
            Open::Ready(conn) => Some(conn),
            _ => None,
        },
    }
}

/// Runs `install-service` (or `uninstall-service`) on the host over SSH, uploading this build first if needed.
pub fn service(dest: &[String], enable: bool) -> Result<String, String> {
    let build = build_id();
    let sub = if enable { "install-service" } else { "uninstall-service" };
    let script = remote_command(&format!(
        "d=\"$HOME/.zurafa/{build}\"; [ -x \"$d/zurafa-daemon\" ] && exec \"$d/zurafa-daemon\" {sub}; echo \"zurafa-need $(uname -sm)\""
    ));
    for _ in 0..2 {
        let out = ssh(dest, &[], script.clone())
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| format!("cannot run ssh: {e}"))?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        if let Some(uname) = text.strip_prefix("zurafa-need ") {
            let bin = binary_for(uname).ok_or_else(|| format!("No Zurafa daemon build for {uname}"))?;
            if !upload(dest, &build, &bin) {
                return Err("Installing the Zurafa daemon on the host failed".into());
            }
            continue;
        }
        return match (out.status.success(), text.is_empty()) {
            (true, _) => Ok(text),
            (false, true) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let why = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("no error output");
                Err(format!("SSH to the host failed ({}): {}", out.status, why.trim()))
            }
            (false, false) => Err(text),
        };
    }
    Err("Installing the Zurafa daemon on the host failed".into())
}

#[cfg(target_os = "macos")]
mod tls {
    //! Blocking TLS that one thread reads while another writes. rustls does no I/O itself, so the
    //! reader waits on the socket without holding the session lock.
    use rustls::{pki_types::ServerName, ClientConfig, ClientConnection, RootCertStore};
    use std::io::{self, Read, Write};
    use std::net::TcpStream;
    use std::sync::{Arc, Mutex};

    type Session = Arc<Mutex<ClientConnection>>;

    pub fn split(sock: TcpStream, host: &str) -> Option<(Box<dyn Read + Send>, Box<dyn Write + Send>)> {
        // Tailscale Serve certificates come from Let's Encrypt, which these roots include.
        let roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let config = ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .ok()?
            .with_root_certificates(roots)
            .with_no_client_auth();
        let name = ServerName::try_from(host.to_owned()).ok()?;
        let session: Session = Arc::new(Mutex::new(ClientConnection::new(Arc::new(config), name).ok()?));
        let writer = sock.try_clone().ok()?;
        Some((Box::new(Reader(session.clone(), sock)), Box::new(Writer(session, writer))))
    }

    /// Sends what the session has queued: handshake messages, alerts and data.
    fn send(session: &mut ClientConnection, sock: &mut TcpStream) -> io::Result<()> {
        while session.wants_write() {
            session.write_tls(sock)?;
        }
        Ok(())
    }

    struct Reader(Session, TcpStream);

    impl Read for Reader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            loop {
                {
                    let mut session = self.0.lock().unwrap();
                    send(&mut session, &mut self.1)?;
                    match session.reader().read(buf) {
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                        done => return done,
                    }
                }
                let mut raw = [0u8; 16 * 1024];
                let n = self.1.read(&mut raw)?;
                if n == 0 {
                    return Ok(0);
                }
                let mut session = self.0.lock().unwrap();
                let mut data = &raw[..n];
                while !data.is_empty() {
                    session.read_tls(&mut data)?;
                    session.process_new_packets().map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
                }
            }
        }
    }

    struct Writer(Session, TcpStream);

    impl Write for Writer {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let mut session = self.0.lock().unwrap();
            let n = session.writer().write(buf)?;
            send(&mut session, &mut self.1)?;
            Ok(n)
        }

        fn flush(&mut self) -> io::Result<()> {
            send(&mut self.0.lock().unwrap(), &mut self.1)
        }
    }
}

/// Only the Mac app opens remote tabs, so Linux builds leave HTTPS out.
#[cfg(not(target_os = "macos"))]
mod tls {
    use std::io::{Read, Write};
    pub fn split(_: std::net::TcpStream, _: &str) -> Option<(Box<dyn Read + Send>, Box<dyn Write + Send>)> {
        None
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
    let (user, host) = destination(&dest);
    let (route, conn) = match open_first_direct(host, user) {
        Some(direct) => direct,
        None => (Route::Ssh, open_ssh(&dest, &build)),
    };
    let Conn { mut child, to, mut from } = conn;
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
        for tick in 1u64.. {
            thread::sleep(Duration::from_millis(100));
            // Keeps a direct connection's 45 s read timeout from firing on an idle shell.
            if tick % 150 == 0 {
                w.send(json!({"id":4,"type":"ping"}));
            }
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
        if let Some(c) = child.as_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
        *writer.0.lock().unwrap() = None;
        if first {
            fallback(&dest, "Remote daemon did not start a shell");
        }
        notice("Connection lost; reconnecting…");
        let mut delay = Duration::from_secs(1);
        (child, from) = loop {
            thread::sleep(delay);
            if let Some(conn) = reopen(route, &dest, &build) {
                *writer.0.lock().unwrap() = Some(conn.to);
                break (conn.child, conn.from);
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
    fn direct_only_to_tailnet_addresses() {
        assert_eq!(destination(&["-p".into(), "22".into(), "--".into(), "al@box.ts.net".into()]), (Some("al"), "box.ts.net"));
        assert_eq!(destination(&["--".into(), "box".into()]), (None, "box"));
        assert!(is_tailnet("100.86.111.84".parse().unwrap()));
        assert!(is_tailnet("fd7a:115c:a1e0::4832:8975".parse().unwrap()));
        assert!(!is_tailnet("100.128.0.1".parse().unwrap()));
        assert!(!is_tailnet("192.168.1.2".parse().unwrap()));
    }

    /// A one-shot daemon stand-in: answers the upgrade with `status`, then hello as `user`.
    fn fake_daemon(status: &'static str, user: &'static str) -> SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut r = BufReader::new(stream.try_clone().unwrap());
            let mut w = stream;
            let mut line = String::new();
            while r.read_line(&mut line).unwrap() > 0 && line != "\r\n" {
                line.clear();
            }
            write!(w, "HTTP/1.1 {status}\r\nUpgrade: zurafa\r\n\r\n").unwrap();
            if status.starts_with("101") {
                assert_eq!(read_frame(&mut r).unwrap()["type"], "hello");
                write_frame(&mut w, &json!({"id":0,"type":"hello_ok","protocol":2,"user":user})).unwrap();
                let _ = read_frame(&mut r); // hold the connection until the client drops it
            }
        });
        addr
    }

    #[test]
    fn opens_direct_connections_only_as_the_right_user() {
        let plain = |addr| Route::Direct { addr, tls: false };
        assert!(open_direct(plain(fake_daemon("101 Switching Protocols", "al")), "box", None).is_some());
        assert!(open_direct(plain(fake_daemon("101 Switching Protocols", "al")), "box", Some("al")).is_some());
        assert!(open_direct(plain(fake_daemon("101 Switching Protocols", "al")), "box", Some("root")).is_none());
        assert!(open_direct(plain(fake_daemon("403 Forbidden", "al")), "box", None).is_none());
    }

    #[test]
    fn picks_a_build_per_remote_platform() {
        assert_eq!(binary_for("FreeBSD amd64"), None);
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert_eq!(binary_for("Darwin arm64\n"), env::current_exe().ok());
        }
    }
}
