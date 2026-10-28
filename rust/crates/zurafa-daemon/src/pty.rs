use crate::hosts::{self, HostRegistry};
use crate::osc7501::{Action, Filter};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ffi::CStr;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::{env, thread, time::Duration};
use tokio::sync::broadcast;
use zurafa_events::{
    status::{Report, State},
    Axis, Command, Dispatcher, RemoteHost,
};

struct Term {
    master: Mutex<Box<dyn MasterPty + Send>>,
    input: mpsc::SyncSender<Vec<u8>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    running: AtomicBool,
    replay: Mutex<Replay>,
}

/// Recent output kept so a client that reconnects can catch up on what it missed.
const REPLAY_BYTES: usize = 256 * 1024;

#[derive(Default)]
struct Replay {
    buf: VecDeque<u8>,
    /// Total bytes ever output; `buf` holds the last `buf.len()` of them.
    end: u64,
}

/// Read the foreground process from the PTY's process group. This comes from
/// the kernel, never from terminal text or a guessed window title.
#[cfg(target_os = "macos")]
fn foreground_process(pid: libc::pid_t) -> Option<zurafa_events::Process> {
    if pid <= 0 { return None; }
    let mut name = [0u8; 256];
    let n = unsafe { libc::proc_name(pid, name.as_mut_ptr().cast(), name.len() as u32) };
    if n <= 0 { return None; }
    let name = String::from_utf8_lossy(&name[..n as usize]).into_owned();
    let mut info = unsafe { std::mem::zeroed::<libc::proc_vnodepathinfo>() };
    let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0,
        (&mut info as *mut libc::proc_vnodepathinfo).cast(),
        std::mem::size_of::<libc::proc_vnodepathinfo>() as i32) };
    if n < std::mem::size_of::<libc::proc_vnodepathinfo>() as i32 { return None; }
    let cwd = unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) }.to_str().ok()?.to_owned();
    if cwd.is_empty() { return None; }
    let mut extra = BTreeMap::new();
    let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let path_len = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if path_len > 0 {
        if let Ok(path) = std::str::from_utf8(&path[..path_len as usize]) {
            extra.insert("executable".to_owned(), serde_json::Value::String(path.to_owned()));
        }
    }
    if let Some(argv) = process_args(pid) {
        extra.insert("argv".to_owned(), serde_json::Value::Array(argv.into_iter().map(serde_json::Value::String).collect()));
    }
    Some(zurafa_events::Process { name, cwd, pid: pid as u32, extra })
}

#[cfg(target_os = "macos")]
fn process_args(pid: libc::pid_t) -> Option<Vec<String>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size = 0usize;
    if unsafe { libc::sysctl(mib.as_mut_ptr(), mib.len() as u32, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) } != 0 || size < 4 {
        return None;
    }
    let mut buf = vec![0u8; size];
    if unsafe { libc::sysctl(mib.as_mut_ptr(), mib.len() as u32, buf.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) } != 0 {
        return None;
    }
    buf.truncate(size);
    let argc = i32::from_ne_bytes(buf.get(0..4)?.try_into().ok()?).max(0) as usize;
    let mut i = 4;
    while i < buf.len() && buf[i] != 0 { i += 1; }
    while i < buf.len() && buf[i] == 0 { i += 1; }
    let mut args = Vec::new();
    for _ in 0..argc {
        if i >= buf.len() { break; }
        let start = i;
        while i < buf.len() && buf[i] != 0 { i += 1; }
        if i > start { args.push(String::from_utf8_lossy(&buf[start..i]).into_owned()); }
        while i < buf.len() && buf[i] == 0 { i += 1; }
    }
    (!args.is_empty()).then_some(args)
}

#[cfg(target_os = "linux")]
fn foreground_process(pid: libc::pid_t) -> Option<zurafa_events::Process> {
    if pid <= 0 { return None; }
    let dir = format!("/proc/{pid}");
    let name = std::fs::read_to_string(format!("{dir}/comm")).ok()?.trim_end().to_owned();
    let cwd = std::fs::read_link(format!("{dir}/cwd")).ok()?.to_str()?.to_owned();
    let mut extra = BTreeMap::new();
    if let Some(exe) = std::fs::read_link(format!("{dir}/exe")).ok().and_then(|p| p.to_str().map(str::to_owned)) {
        extra.insert("executable".to_owned(), serde_json::Value::String(exe));
    }
    let argv: Vec<serde_json::Value> = std::fs::read(format!("{dir}/cmdline")).unwrap_or_default()
        .split(|b| *b == 0).filter(|a| !a.is_empty())
        .map(|a| serde_json::Value::String(String::from_utf8_lossy(a).into_owned())).collect();
    if !argv.is_empty() {
        extra.insert("argv".to_owned(), serde_json::Value::Array(argv));
    }
    Some(zurafa_events::Process { name, cwd, pid: pid as u32, extra })
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn foreground_process(_pid: libc::pid_t) -> Option<zurafa_events::Process> { None }

pub struct SpawnOptions {
    pub cols: u16,
    pub rows: u16,
    pub cwd: Option<String>,
    pub command: Option<Vec<String>>,
    pub session: String,
    pub split: Option<String>,
    pub axis: Axis,
    pub label: String,
    /// Pass bytes through untouched (no OSC filtering): a remote client parses them itself.
    pub raw: bool,
}

pub struct Terminals {
    /// Serialized events for every connected client.
    pub events: broadcast::Sender<String>,
    pub dispatcher: Dispatcher,
    control: Mutex<()>,
    map: Mutex<HashMap<String, Arc<Term>>>,
    hosts: Mutex<HostRegistry>,
    next: AtomicU64,
}

fn err(e: impl ToString) -> String {
    e.to_string()
}

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// The account database is authoritative for a GUI app's default shell: launchd's
/// inherited SHELL can be stale or absent even when the user's login shell changed.
fn login_shell() -> Option<String> {
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    // SAFETY: getpwuid_r writes into the supplied entry and buffer. We read
    // pw_shell only after success, while the backing buffer is still alive.
    let status = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    let shell_ptr = unsafe { (*result).pw_shell };
    if shell_ptr.is_null() {
        return None;
    }
    let shell = unsafe { CStr::from_ptr(shell_ptr) }.to_str().ok()?;
    (!shell.is_empty()).then(|| shell.to_owned())
}

fn default_shell() -> String {
    choose_shell(login_shell().as_deref(), env::var("SHELL").ok().as_deref())
}

fn choose_shell(account: Option<&str>, inherited: Option<&str>) -> String {
    account
        .filter(|s| !s.is_empty())
        .or_else(|| inherited.filter(|s| !s.is_empty()))
        .map(str::to_owned)
        .unwrap_or_else(|| "/bin/zsh".into())
}

impl Terminals {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            events: broadcast::channel(4096).0,
            dispatcher: Dispatcher::new(1024),
            control: Mutex::new(()),
            map: Mutex::default(),
            hosts: Mutex::new(HostRegistry::load()),
            next: AtomicU64::new(1),
        })
    }

    fn emit(&self, event: Value) {
        let _ = self.events.send(event.to_string());
    }

    fn output(&self, terminal: &str, term: &Term, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let mut replay = term.replay.lock().unwrap();
        replay.end += data.len() as u64;
        replay.buf.extend(data);
        let excess = replay.buf.len().saturating_sub(REPLAY_BYTES);
        replay.buf.drain(..excess);
        // Emitted under the lock, so `attach` sees each chunk either in its copy or after its `end`.
        self.emit(json!({"type": "output", "terminal": terminal, "data": B64.encode(data), "end": replay.end}));
    }

    /// Output after byte offset `since`, plus the current end offset. If `since` already
    /// fell out of the buffer, returns the whole buffer and `gap = true`.
    pub fn attach(&self, id: &str, since: u64) -> Result<(u64, Vec<u8>, bool), String> {
        let t = self.get(id).ok_or("unknown terminal")?;
        let replay = t.replay.lock().unwrap();
        let start = replay.end - replay.buf.len() as u64;
        let gap = since < start || since > replay.end;
        let skip = if gap { 0 } else { (since - start) as usize };
        Ok((replay.end, replay.buf.iter().skip(skip).copied().collect(), gap))
    }

    fn action(&self, terminal: &str, action: Action) {
        match action {
            Action::Report(Report::Query) => self.input(terminal, b"\x1b]7501;?\x1b\\"),
            Action::Report(report) => {
                if let Report::Set(_, r) = &report {
                    let state = match r.state {
                        State::Done => "completed",
                        State::Idle => "idle",
                        State::Working => "working",
                        State::Blocked => "blocked",
                        State::Error => "error",
                    };
                    self.emit(
                        json!({"type":"status","terminal":terminal,"state":state,"message":r.msg}),
                    );
                }
                self.dispatcher.report(terminal, report);
            }
            Action::Lifecycle(reason) => self.dispatcher.lifecycle(terminal, reason),
            Action::Event(event) => self.dispatcher.terminal_event(terminal, event),
        }
    }

    pub fn command(&self, command: Command) -> Result<(), String> {
        let _guard = self.control.lock().unwrap();
        if let Command::CreateSession {
            remote: Some(host), ..
        } = &command
        {
            hosts::validate(host)?;
            if !self.hosts.lock().unwrap().contains(host) {
                return Err("remote host is not saved".into());
            }
        }
        for block in self.dispatcher.command(command)? {
            let _ = self.kill(&block);
        }
        Ok(())
    }

    /// No terminals running and no clients connected.
    pub fn idle(&self) -> bool {
        self.map.lock().unwrap().is_empty() && self.dispatcher.snapshot().clients.is_empty()
    }

    pub fn hosts(&self) -> Vec<RemoteHost> {
        self.hosts.lock().unwrap().list()
    }

    pub fn add_host(&self, host: RemoteHost) -> Result<(), String> {
        let hash = self.hosts.lock().unwrap().add(host)?;
        self.dispatcher.hosts_changed(hash);
        Ok(())
    }

    pub fn update_host(&self, host: RemoteHost) -> Result<(), String> {
        let _guard = self.control.lock().unwrap();
        let hash = self.hosts.lock().unwrap().update(host.clone())?;
        self.dispatcher.host_updated(&host, hash);
        Ok(())
    }

    pub fn remove_host(&self, id: &str) -> Result<(), String> {
        let hash = self.hosts.lock().unwrap().remove(id)?;
        self.dispatcher.hosts_changed(hash);
        Ok(())
    }

    fn get(&self, id: &str) -> Option<Arc<Term>> {
        self.map.lock().unwrap().get(id).cloned()
    }

    pub fn spawn(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        raw: bool,
    ) -> Result<String, String> {
        self.spawn_at(SpawnOptions {
            cols,
            rows,
            cwd,
            command,
            session: "default".into(),
            split: None,
            axis: Axis::Horizontal,
            label: "Terminal".into(),
            raw,
        })
    }

    pub fn spawn_at(self: &Arc<Self>, options: SpawnOptions) -> Result<String, String> {
        let SpawnOptions {
            cols,
            rows,
            cwd,
            command,
            session,
            split,
            axis,
            label,
            raw,
        } = options;
        let session = session.as_str();
        let split = split.as_deref();
        let _guard = self.control.lock().unwrap();
        if cols == 0 || rows == 0 {
            return Err("terminal dimensions must be positive".into());
        }
        if command
            .as_ref()
            .is_some_and(|c| c.is_empty() || c[0].is_empty())
        {
            return Err("command must not be empty".into());
        }
        self.dispatcher.validate_target(session, split)?;
        let id = format!("t{}", self.next.fetch_add(1, Ordering::Relaxed));
        let pair = native_pty_system().openpty(size(cols, rows)).map_err(err)?;
        let mut reader = pair.master.try_clone_reader().map_err(err)?;
        let mut writer = pair.master.take_writer().map_err(err)?;
        let remote = self
            .dispatcher
            .snapshot()
            .sessions
            .get(session)
            .and_then(|s| s.remote.clone());
        let mut cmd = match command.as_deref() {
            Some([prog, args @ ..]) => {
                let mut c = CommandBuilder::new(prog);
                c.args(args);
                c
            }
            Some([]) => return Err("command must not be empty".into()),
            None if remote.is_some() => {
                // Keeps the shell in a daemon on the remote host; falls back to `ssh -tt` itself.
                let mut c = CommandBuilder::new(env::current_exe().map_err(err)?);
                c.arg("remote");
                c.args(hosts::ssh_destination(remote.as_ref().unwrap()));
                c
            }
            None => {
                let shell = default_shell();
                let mut c = CommandBuilder::new(&shell);
                c.arg("-l");
                c.env("SHELL", shell);
                c
            }
        };
        if let Some(dir) = cwd.or_else(|| env::var("HOME").ok()) {
            cmd.cwd(dir);
        }
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Zurafa");
        // GUI launches inherit no locale; without UTF-8, TUIs like Emacs print `?` for every non-ASCII glyph.
        if ["LC_ALL", "LC_CTYPE", "LANG"].iter().all(|k| env::var(k).map_or(true, |v| v.is_empty())) {
            cmd.env("LANG", "en_US.UTF-8");
        }
        cmd.env("ZURAFA_SESSION", session);
        cmd.env("ZURAFA_PANE", &id);
        cmd.env("ZURAFA_BLOCK", &id);
        if let Ok(socket) = env::var("ZURAFA_SOCKET") {
            cmd.env("ZURAFA_SOCKET", socket);
        }
        let mut child = pair.slave.spawn_command(cmd).map_err(err)?;
        drop(pair.slave); // otherwise the reader never sees EOF
        self.dispatcher
            .add_block(session, &id, split, axis, label)?;
        let (input, input_rx) = mpsc::sync_channel::<Vec<u8>>(64);
        thread::spawn(move || {
            while let Ok(bytes) = input_rx.recv() {
                if writer.write_all(&bytes).is_err() {
                    break;
                }
            }
        });
        let term = Term {
            master: Mutex::new(pair.master),
            input,
            killer: Mutex::new(child.clone_killer()),
            running: AtomicBool::new(true),
            replay: Mutex::default(),
        };
        let term = Arc::new(term);
        self.map.lock().unwrap().insert(id.clone(), term.clone());

        let (this, tid, sampled) = (self.clone(), id.clone(), term.clone());
        thread::spawn(move || {
            let term = sampled;
            let mut previous = None;
            let mut generation = 0;
            while term.running.load(Ordering::Relaxed) {
                let current = term.master.lock().unwrap().process_group_leader()
                    .filter(|pid| *pid != std::process::id() as libc::pid_t)
                    .and_then(foreground_process)
                    // The forked child briefly retains our executable name before exec.
                    .filter(|process| process.name != "zurafa-daemon");
                if current != previous {
                    generation += 1;
                    this.dispatcher.terminal_event(&tid, zurafa_events::TerminalEvent::ProcessChanged {
                        generation, foreground: current.clone(), ancestors: Vec::new(),
                    });
                    previous = current;
                }
                thread::sleep(Duration::from_millis(250));
            }
        });

        let (done_tx, done_rx) = mpsc::channel();
        let (this, tid) = (self.clone(), id.clone());
        thread::spawn(move || {
            let (mut filter, mut buf) = (Filter::default(), [0u8; 8192]);
            // a read error (EIO once the child side closes) ends the stream like EOF
            while let Ok(n @ 1..) = reader.read(&mut buf) {
                if raw {
                    this.output(&tid, &term, &buf[..n]);
                    continue;
                }
                let (data, statuses) = filter.feed(&buf[..n]);
                this.output(&tid, &term, &data);
                for s in statuses {
                    this.action(&tid, s);
                }
            }
            if !raw {
                this.output(&tid, &term, &filter.finish());
            }
            let _ = done_tx.send(());
        });
        let (this, tid) = (self.clone(), id.clone());
        thread::spawn(move || {
            let code = child.wait().ok().map(|s| s.exit_code() as i32);
            // let the reader drain first, but a grandchild holding the pty must not delay `exited` forever
            let _ = done_rx.recv_timeout(Duration::from_millis(200));
            this.dispatcher.exited(&tid, code);
            if let Some(term) = this.map.lock().unwrap().remove(&tid) {
                term.running.store(false, Ordering::Relaxed);
            }
            this.emit(json!({"type": "exited", "terminal": tid, "code": code}));
        });
        Ok(id)
    }

    pub fn kill(&self, id: &str) -> Result<(), String> {
        let t = self.get(id).ok_or("unknown terminal")?;
        let r = t.killer.lock().unwrap().kill();
        r.map_err(err)
    }

    pub fn input(&self, id: &str, data: &[u8]) {
        if let Some(t) = self.get(id) {
            if data.len() <= 1024 * 1024 {
                let _ = t.input.try_send(data.to_vec());
            }
        }
    }

    /// The PTY's current cell size, so a client can lay out a replay as the screen shows it.
    pub fn size(&self, id: &str) -> Option<(u16, u16)> {
        let size = self.get(id)?.master.lock().unwrap().get_size().ok()?;
        Some((size.cols, size.rows))
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) {
        if cols == 0 || rows == 0 {
            return;
        }
        if let Some(t) = self.get(id) {
            let _ = t.master.lock().unwrap().resize(size(cols, rows));
        }
    }
}

#[cfg(test)]
mod shell_tests {
    use super::*;

    #[test]
    fn account_shell_takes_precedence_over_gui_environment() {
        assert_eq!(
            choose_shell(Some("/opt/homebrew/bin/fish"), Some("/bin/zsh")),
            "/opt/homebrew/bin/fish"
        );
        assert_eq!(choose_shell(None, Some("/bin/sh")), "/bin/sh");
        assert_eq!(choose_shell(None, None), "/bin/zsh");
    }

    #[test]
    fn current_account_shell_is_resolved() {
        assert_eq!(
            default_shell(),
            login_shell().expect("user account has a login shell")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_real_foreground_process_metadata() {
        let process = foreground_process(std::process::id() as libc::pid_t).unwrap();
        assert_eq!(process.pid, std::process::id());
        assert!(!process.name.is_empty());
        assert!(std::path::Path::new(&process.cwd).is_absolute());
    }
}
