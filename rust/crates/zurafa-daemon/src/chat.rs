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
    process::{Command, Stdio},
    sync::{Arc, Mutex, OnceLock},
};

/// A pane's chat lines so far, and why following it last failed (a remote host out of reach).
#[derive(Default)]
struct Follow {
    lines: Mutex<Vec<String>>,
    error: Mutex<Option<String>>,
}

fn follows() -> &'static Mutex<HashMap<String, Arc<Follow>>> {
    static FOLLOWS: OnceLock<Mutex<HashMap<String, Arc<Follow>>>> = OnceLock::new();
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
/// following the pane; later lines arrive as its agent writes them. `remote` is the SSH destination
/// of a remote pane's host and the process its pane runs there.
// shortcut: a follow runs until the daemon exits, even after its pane closes; stop idle ones if many pile up.
pub fn read(block: &str, from: usize, remote: Option<(Vec<String>, u32)>) -> Result<(Vec<String>, usize), String> {
    let follow = {
        let mut map = follows().lock().unwrap();
        if let Some(f) = map.get(block) {
            f.clone()
        } else {
            let follow: Arc<Follow> = Default::default();
            let sink = follow.clone();
            if let Some((dest, pid)) = remote {
                std::thread::spawn(move || loop {
                    let result = crate::remote::follow_chat(&dest, pid, &sink.lines);
                    *sink.error.lock().unwrap() = result.err();
                    // Reconnects after a dropped link; the host's index carries on where it was.
                    std::thread::sleep(std::time::Duration::from_secs(5));
                });
            } else {
                let mut child = command(&["follow".into(), "--pane".into(), block.into()])?.stdout(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
                let out = child.stdout.take().ok_or("no output")?;
                std::thread::spawn(move || {
                    for line in BufReader::new(out).lines().map_while(Result::ok) {
                        sink.lines.lock().unwrap().push(line);
                    }
                    let _ = child.wait();
                });
            }
            map.insert(block.to_owned(), follow.clone());
            follow
        }
    };
    let all = follow.lines.lock().unwrap();
    if all.is_empty() {
        if let Some(e) = follow.error.lock().unwrap().clone() {
            return Err(e);
        }
    }
    let from = from.min(all.len());
    Ok((all[from..].to_vec(), all.len()))
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
