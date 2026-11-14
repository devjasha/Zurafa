//! Agent chats for clients that cannot run zurafa-orch themselves (the phone): the daemon runs it
//! on this machine. `ui.chat.read` keeps one `zurafa-orch follow --pane` per pane and hands out its
//! JSON lines from an index; `ui.orch` runs one zurafa-orch command (set, spawn, threads). A client
//! that may use the daemon can already type into these panes, so neither gives it more power.
//! A remote pane's chat comes from the daemon on its host, which follows it the same way.
use std::{
    collections::HashMap,
    env,
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, OnceLock, Weak},
};

/// One agent's chat lines so far, and why following it last failed (a remote host out of reach).
/// Dropping it stops the follow: its zurafa-orch is killed, its remote connection closed.
struct Follow {
    /// The index of its first line: a pane's follows number their lines on from the last one, so a
    /// client's index only grows.
    base: usize,
    lines: Mutex<Vec<String>>,
    error: Mutex<Option<String>>,
    child: Mutex<Option<Child>>,
}

impl Drop for Follow {
    fn drop(&mut self) {
        if let Some(c) = self.child.get_mut().unwrap().as_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Per pane, the process it ran when its follow started, and the follow.
fn follows() -> &'static Mutex<HashMap<String, (u32, Arc<Follow>)>> {
    static FOLLOWS: OnceLock<Mutex<HashMap<String, (u32, Arc<Follow>)>>> = OnceLock::new();
    FOLLOWS.get_or_init(Default::default)
}

/// zurafa-orch: ZURAFA_ORCH, else the one the app ships in Resources beside this daemon's MacOS
/// folder, else one uploaded beside this daemon on a remote host, else one installed beside the
/// shell's tools.
fn orch() -> Option<PathBuf> {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let dir = env::current_exe().ok().and_then(|e| e.parent().map(PathBuf::from));
    let bundled = dir.iter().flat_map(|d| [d.join("../Resources/zurafa-orch"), d.join("zurafa-orch")]).collect::<Vec<_>>();
    env::var_os("ZURAFA_ORCH")
        .map(PathBuf::from)
        .into_iter()
        .chain(bundled)
        .chain([home.join(".local/bin"), home.join(".cargo/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into()].map(|d| d.join("zurafa-orch")))
        .find(|p| p.is_file())
}

fn command(args: &[String]) -> Result<Command, String> {
    let orch = orch().ok_or("zurafa-orch is missing from this Zurafa install")?;
    let mut cmd = Command::new(orch);
    cmd.args(args).stdin(Stdio::null()).stderr(Stdio::null());
    // It runs `zurafa`, which the app ships in Resources beside this daemon's MacOS folder.
    let home = env::var("HOME").unwrap_or_default();
    let bundled = env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("../Resources")));
    let path = [bundled.map(|b| b.display().to_string()).unwrap_or_default(), format!("{home}/.local/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into(), env::var("PATH").unwrap_or_default()];
    cmd.env("PATH", path.join(":"));
    Ok(cmd)
}

/// The chat lines of `block` from `from` on, and the index to ask from next. The first read starts
/// following the agent in front, process `pid`; later lines arrive as it writes them. Another
/// process in front (the agent restarted, or wasn't running yet) starts a new follow, numbered on
/// from the old one, which a client reads from its start. `remote` is the SSH destination of a
/// remote pane's host, where `pid` runs.
// shortcut: a pane's last follow runs until the daemon exits, even after the pane closes; drop them with their panes if many pile up.
pub fn read(block: &str, from: usize, pid: u32, remote: Option<Vec<String>>) -> Result<(Vec<String>, usize), String> {
    let follow = {
        let mut map = follows().lock().unwrap();
        match map.get(block) {
            Some((p, f)) if *p == pid => f.clone(),
            old => {
                let base = old.map_or(0, |(_, f)| f.base + f.lines.lock().unwrap().len());
                let follow = Arc::new(Follow { base, lines: Default::default(), error: Default::default(), child: Default::default() });
                let sink = Arc::downgrade(&follow);
                if let Some(dest) = remote {
                    std::thread::spawn(move || follow_remote(&dest, pid, sink));
                } else {
                    let mut child = command(&["follow".into(), "--pane".into(), block.into()])?.stdout(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
                    let out = child.stdout.take().ok_or("no output")?;
                    *follow.child.lock().unwrap() = Some(child);
                    std::thread::spawn(move || {
                        for line in BufReader::new(out).lines().map_while(Result::ok) {
                            let Some(f) = sink.upgrade() else { return };
                            f.lines.lock().unwrap().push(line);
                        }
                    });
                }
                // Replaces (and so stops) the follow of the agent that was here before.
                map.insert(block.to_owned(), (pid, follow.clone()));
                follow
            }
        }
    };
    let all = follow.lines.lock().unwrap();
    if all.is_empty() {
        if let Some(e) = follow.error.lock().unwrap().clone() {
            return Err(e);
        }
    }
    let end = follow.base + all.len();
    // shortcut: past the end means this daemon restarted and counts from 0 again; a client whose index the new count already passed misses lines, so send a follow id if restarts bite.
    let from = if from < follow.base || from > end { follow.base } else { from };
    Ok((all[from - follow.base..].to_vec(), end))
}

/// Copies a remote agent's chat into `sink` while anyone follows it, reconnecting after a dropped link.
fn follow_remote(dest: &[String], pid: u32, sink: Weak<Follow>) {
    // The host's index, kept across reconnects: the host keeps its follow.
    let mut next = 0;
    while sink.strong_count() > 0 {
        let push = |lines: Vec<String>| sink.upgrade().map(|f| f.lines.lock().unwrap().extend(lines)).is_some();
        let result = crate::remote::follow_chat(dest, pid, &mut next, &push);
        let Some(f) = sink.upgrade() else { return };
        *f.error.lock().unwrap() = result.err();
        drop(f);
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
}

/// Runs one zurafa-orch command and returns what it printed.
pub fn run(args: &[String]) -> Result<String, String> {
    let out = command(args)?.output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("zurafa-orch {} failed", args.first().map_or("", String::as_str)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// Reads `block` until a line comes, as a client polls.
    fn first_line(block: &str, from: usize, pid: u32) -> (String, usize) {
        for _ in 0..100 {
            let (lines, next) = read(block, from, pid, None).unwrap();
            if let Some(l) = lines.first() {
                return (l.clone(), next);
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        panic!("no chat line");
    }

    #[test]
    fn a_new_agent_in_front_gets_a_new_follow_and_stops_the_old_one() {
        // A zurafa-orch that prints its own pid, then waits like a follow does.
        let orch = env::temp_dir().join(format!("zurafa-orch-test-{}", std::process::id()));
        std::fs::write(&orch, "#!/bin/sh\necho $$\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&orch, std::fs::Permissions::from_mode(0o755)).unwrap();
        env::set_var("ZURAFA_ORCH", &orch);

        let (old, next) = first_line("chat-test", 0, 1);
        assert_eq!(read("chat-test", next, 1, None).unwrap().0, Vec::<String>::new(), "same agent: same follow");
        // The client still asks from the old follow's end: the new one is read from its start.
        let (new, _) = first_line("chat-test", next, 2);
        assert_ne!(old, new);
        let alive = |pid: &str| Command::new("kill").args(["-0", pid]).stderr(Stdio::null()).status().unwrap().success();
        assert!(!alive(&old), "the old follow's zurafa-orch was stopped");
        assert!(alive(&new));
        follows().lock().unwrap().remove("chat-test");
        assert!(!alive(&new));
        let _ = std::fs::remove_file(orch);
    }
}
