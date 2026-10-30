//! Keeps the layout on disk and rebuilds it when the daemon starts again, after a restart or an
//! update. Panes come back as shells in the folder they were in; a pane whose agent reported its
//! session (`layout.resume`) runs `claude --resume ID` or `codex resume ID` instead. Commands are
//! never run again, so a spawned agent does not redo its task.
use crate::pty::{default_shell, SpawnOptions, Terminals};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::sync::broadcast::error::{RecvError, TryRecvError};
use zurafa_events::{Axis, Block, Command, Layout, Session};

/// `layout.json` beside the daemon's socket, so each socket keeps its own layout.
pub fn path(socket: &Path) -> PathBuf {
    socket.with_file_name("layout.json")
}

/// Writes the layout at most once a second while it changes.
pub async fn save(terms: Arc<Terminals>, path: PathBuf) {
    let (_, mut changes) = terms.dispatcher.subscribe();
    loop {
        if let Err(RecvError::Closed) = changes.recv().await {
            return;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
        while !matches!(changes.try_recv(), Err(TryRecvError::Empty | TryRecvError::Closed)) {}
        if let Err(e) = write(&path, &terms.dispatcher.snapshot().sessions) {
            eprintln!("zurafa-daemon cannot save the layout to {}: {e}", path.display());
        }
    }
}

fn write(path: &Path, sessions: &BTreeMap<String, Session>) -> io::Result<()> {
    // Written whole and renamed, so a crash mid-write leaves the previous layout.
    let tmp = path.with_extension("json.tmp");
    let mut file = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
    file.write_all(&serde_json::to_vec(sessions)?)?;
    fs::rename(tmp, path)
}

/// Rebuilds the saved layout in this (still empty) daemon and returns how many panes it opened.
pub fn restore(terms: &Arc<Terminals>, path: &Path) -> Result<usize, String> {
    let Ok(text) = fs::read(path) else { return Ok(0) };
    let saved: BTreeMap<String, Session> = serde_json::from_slice(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    // shortcut: a child restored before its parent loses the link; parents are created first in practice, since a child is spawned from its parent's tab.
    let mut ids = HashMap::new();
    let mut failed = false;
    for s in saved.values() {
        // One broken workspace (say, its SSH host was deleted) must not cost the others.
        if let Err(e) = restore_session(terms, s, &mut ids) {
            eprintln!("zurafa-daemon cannot restore workspace {:?}: {e}", s.label);
            failed = true;
        }
    }
    // The next save overwrites the file, so keep what could not be restored.
    if failed {
        let _ = fs::copy(path, path.with_file_name("layout-failed.json"));
    }
    Ok(ids.len())
}

fn restore_session(terms: &Arc<Terminals>, s: &Session, ids: &mut HashMap<String, String>) -> Result<(), String> {
    // A fresh daemon already has an empty `default` workspace; fill that one in.
    let empty = terms.dispatcher.snapshot().sessions.get(&s.session_id).map(|e| e.windows.is_empty());
    match empty {
        None => terms.command(Command::CreateSession { session: s.session_id.clone(), label: s.label.clone(), remote: s.remote.clone() })?,
        Some(true) => terms.command(Command::Label { session: s.session_id.clone(), window: None, label: s.label.clone() })?,
        Some(false) => return Err("a workspace with this id is already open".into()),
    }
    for w in &s.windows {
        let first = first_leaf(&w.layout);
        let new = open(terms, s, &first, None, Axis::Horizontal, &w.label, ids)?;
        ids.insert(first, new.clone());
        build(terms, s, &w.layout, ids)?;
        let window = terms.dispatcher.snapshot().sessions[&s.session_id]
            .windows
            .iter()
            .find(|w| first_leaf(&w.layout) == new)
            .map(|w| w.window_id.clone())
            .ok_or("restored window vanished")?;
        // Splitting evens out panes; put back the sizes they had.
        ratios(terms, &s.session_id, &window, &w.layout, &mut vec![]);
        focus(terms, s, ids, &w.selected_block);
    }
    let active = s.windows.iter().find(|w| Some(&w.window_id) == s.active_window.as_ref());
    if let Some(w) = active {
        focus(terms, s, ids, &w.selected_block);
    }
    Ok(())
}

/// Splits the restored first pane of `node` until the tree has the saved shape. Splitting a pane
/// puts the new one second, so the second half is opened from the first, then each half is built.
fn build(terms: &Arc<Terminals>, s: &Session, node: &Layout, ids: &mut HashMap<String, String>) -> Result<(), String> {
    if let Layout::Split { axis, first, second, .. } = node {
        let anchor = ids[&first_leaf(first)].clone();
        let leaf = first_leaf(second);
        let new = open(terms, s, &leaf, Some(anchor), axis.clone(), "", ids)?;
        ids.insert(leaf, new);
        build(terms, s, second, ids)?;
        build(terms, s, first, ids)?;
    }
    Ok(())
}

fn ratios(terms: &Arc<Terminals>, session: &str, window: &str, node: &Layout, path: &mut Vec<usize>) {
    if let Layout::Split { ratio, first, second, .. } = node {
        let _ = terms.command(Command::Resize { session: session.into(), window: window.into(), path: path.clone(), ratio: *ratio });
        for (i, half) in [first, second].into_iter().enumerate() {
            path.push(i);
            ratios(terms, session, window, half, path);
            path.pop();
        }
    }
}

fn focus(terms: &Arc<Terminals>, s: &Session, ids: &HashMap<String, String>, old: &str) {
    if let Some(block) = ids.get(old) {
        let _ = terms.command(Command::Focus { session: s.session_id.clone(), block: block.clone() });
    }
}

fn first_leaf(node: &Layout) -> String {
    match node {
        Layout::Block { block_id } => block_id.clone(),
        Layout::Split { first, .. } => first_leaf(first),
    }
}

/// Opens the pane that stands in for saved pane `old`.
fn open(terms: &Arc<Terminals>, s: &Session, old: &str, split: Option<String>, axis: Axis, label: &str, ids: &HashMap<String, String>) -> Result<String, String> {
    let saved = s.blocks.get(old);
    let parent = saved.and_then(|b| b.parent.as_ref()).and_then(|p| ids.get(p)).cloned();
    let resume = saved.and_then(|b| b.resume.clone().filter(|_| agent_running(b)));
    let command = resume.as_ref().map(|r| resume_command(r, parent.as_deref(), &default_shell()));
    let new = terms.spawn_at(SpawnOptions {
        cols: 80,
        rows: 24,
        cwd: saved.and_then(cwd),
        command,
        session: s.session_id.clone(),
        split,
        axis,
        label: label.into(),
        raw: false,
        parent,
        outlive_parent: saved.is_some_and(|b| b.outlive_parent),
    })?;
    // Kept for the next restart, even when the agent's own hooks don't report it again.
    if let Some(r) = resume {
        let _ = terms.dispatcher.set_resume(&new, r);
    }
    Ok(new)
}

/// Like `zurafa spawn`: through the login shell, which stays open when the agent exits.
fn resume_command(r: &zurafa_events::Resume, parent: Option<&str>, shell: &str) -> Vec<String> {
    let interactive = if shell.ends_with("fish") { "-l" } else { "-li" };
    let mut command = vec![shell.into(), interactive.into(), "-c".into(), format!("{}; exec {} -l", r.command(), quote(shell))];
    if let Some(p) = parent {
        command.splice(0..0, ["/usr/bin/env".into(), format!("ZURAFA_PARENT={p}")]);
    }
    command
}

/// False once the agent has exited back to the shell: `fish -l`, not `fish -c "claude …"`.
fn agent_running(b: &Block) -> bool {
    let Some(fg) = &b.foreground else { return b.running };
    let shell = ["fish", "zsh", "bash", "sh"].contains(&fg.name.trim_start_matches('-'));
    let runs_command = fg.extra.get("argv").and_then(|a| a.as_array()).is_some_and(|a| a.iter().any(|x| x == "-c"));
    b.running && (!shell || runs_command)
}

fn cwd(b: &Block) -> Option<String> {
    if let Some(fg) = b.foreground.as_ref().filter(|p| !p.cwd.is_empty()) {
        return Some(fg.cwd.clone());
    }
    // OSC 7 gives file://host/path.
    // shortcut: percent-escapes in the path are kept as they are; decode them if a folder with spaces comes back wrong.
    let pwd = b.pwd.as_deref()?;
    Some(pwd.strip_prefix("file://").map_or(pwd, |rest| &rest[rest.find('/').unwrap_or(0)..]).to_owned())
}

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn block(fg: serde_json::Value) -> Block {
        serde_json::from_value(json!({"block_id":"t1","running":true,"exit_code":null,"statuses":{"records":{}},"title":null,"pwd":"file://mac/Users/me/src","foreground":fg})).unwrap()
    }

    #[test]
    fn resumes_only_while_the_agent_runs() {
        assert!(agent_running(&block(json!({"name":"2.1.314","cwd":"/x","pid":1}))));
        assert!(agent_running(&block(json!({"name":"fish","cwd":"/x","pid":1,"argv":["fish","-li","-c","claude task; exec fish -l"]}))));
        assert!(!agent_running(&block(json!({"name":"fish","cwd":"/x","pid":1,"argv":["fish","-l"]}))));
        assert!(!agent_running(&block(json!({"name":"-zsh","cwd":"/x","pid":1}))));
    }

    #[test]
    fn resume_commands_are_built_not_taken() {
        let r = zurafa_events::Resume::new("codex", "019a-b_c").unwrap();
        assert_eq!(resume_command(&r, Some("t4"), "/bin/zsh"), ["/usr/bin/env", "ZURAFA_PARENT=t4", "/bin/zsh", "-li", "-c", "codex resume 019a-b_c; exec '/bin/zsh' -l"]);
        assert!(zurafa_events::Resume::new("claude", "x; rm -rf ~").is_err());
        assert!(zurafa_events::Resume::new("sh", "abc").is_err());
    }

    #[test]
    fn folder_from_the_process_or_osc7() {
        assert_eq!(cwd(&block(json!({"name":"zsh","cwd":"/a","pid":1}))).as_deref(), Some("/a"));
        assert_eq!(cwd(&block(json!(null))).as_deref(), Some("/Users/me/src"));
    }

    #[test]
    fn rebuilds_tabs_splits_sizes_and_focus() {
        let terms = Terminals::new();
        let dir = std::env::temp_dir().join(format!("zurafa-restore-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("layout.json");
        // Two tabs; the first split three ways, with an agent in the right half.
        let layout = json!({"type":"split","axis":"horizontal","ratio":0.3,
            "first":{"type":"block","block_id":"t1"},
            "second":{"type":"split","axis":"vertical","ratio":0.6,"first":{"type":"block","block_id":"t2"},"second":{"type":"block","block_id":"t3"}}});
        // t3's agent has exited back to its shell, so it is not resumed (and no test starts claude).
        let b = |id: &str, resume: serde_json::Value| json!({"block_id":id,"running":true,"exit_code":null,"statuses":{"records":{}},"title":null,"pwd":null,
            "foreground":{"name":"fish","cwd":"/","pid":1,"argv":["fish","-l"]},"resume":resume});
        let saved = json!({"default":{"session_id":"default","label":"Work","revision":3,"active_window":"w9",
            "windows":[{"window_id":"w8","label":"Code","layout":layout,"selected_block":"t3","zoomed_block":null},
                       {"window_id":"w9","label":"Logs","layout":{"type":"block","block_id":"t4"},"selected_block":"t4","zoomed_block":null}],
            "blocks":{"t1":b("t1",json!(null)),"t2":b("t2",json!(null)),"t3":b("t3",json!({"agent":"claude","session":"abc-1"})),"t4":b("t4",json!(null))}}});
        fs::write(&file, saved.to_string()).unwrap();

        assert_eq!(restore(&terms, &file).unwrap(), 4);
        let s = &terms.dispatcher.snapshot().sessions["default"];
        assert_eq!(s.label, "Work");
        let labels: Vec<&str> = s.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, ["Code", "Logs"]);
        let Layout::Split { ratio, second, .. } = &s.windows[0].layout else { panic!("first tab is not split") };
        assert_eq!(*ratio, 0.3);
        let Layout::Split { ratio, second: agent, .. } = second.as_ref() else { panic!("right half is not split") };
        assert_eq!(*ratio, 0.6);
        let agent = first_leaf(agent);
        assert_eq!(s.blocks[&agent].resume, None);
        assert_eq!(s.windows[0].selected_block, agent);
        assert_eq!(s.active_window.as_ref(), Some(&s.windows[1].window_id));
        for id in s.blocks.keys() {
            let _ = terms.kill(id);
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
