//! Parents and children: news a pane spawned from another can't report itself
//! (it is blocked, hit an error, or ended) is typed into its parent as a marked
//! note, and a parent that ends closes the panes it spawned.
use crate::pty::Terminals;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::{env, fs, path::PathBuf, time::Duration};
use tokio::sync::broadcast::error::RecvError;
use zurafa_events::{status::State, Block, Command, Event, SessionEvent, Snapshot, TerminalEvent};

/// Pause between a note and its Enter, as in the CLI's `submit`: a TUI reads
/// input that arrives together as one paste, so an Enter sent with it is a newline.
const PASTE_GAP: Duration = Duration::from_millis(200);

/// Watches the panes for as long as the daemon runs.
pub async fn run(terms: Arc<Terminals>) {
    let (_, mut events) = terms.dispatcher.subscribe();
    let mut notes = Notes::default();
    loop {
        match events.recv().await {
            Ok(e) if !matters(&e.event) => continue,
            Err(RecvError::Closed) => return,
            // A gap only means a fresh look at the snapshot, which is all a step uses.
            _ => {}
        }
        let (typed, closed) = notes.step(&terms.dispatcher.snapshot());
        for (session, block) in closed {
            let _ = terms.command(Command::Close { session, block });
        }
        if typed.is_empty() || !enabled() {
            continue;
        }
        for (parent, text) in typed {
            terms.paste(&parent, &text);
            tokio::time::sleep(PASTE_GAP).await;
            terms.input(&parent, b"\r");
        }
    }
}

fn matters(event: &Event) -> bool {
    match event {
        Event::Terminal { event, .. } => matches!(
            event,
            TerminalEvent::ProgramStatusChanged { .. }
                | TerminalEvent::ProgramStatusRemoved { .. }
                | TerminalEvent::ChildExited { .. }
                | TerminalEvent::ProcessChanged { .. }
        ),
        Event::Session { event, .. } => matches!(event, SessionEvent::BlockClosed { .. }),
        Event::Server { .. } => false,
    }
}

/// `agent-notes = false` in config.zurafa turns notes off.
fn enabled() -> bool {
    let dir = env::var_os("XDG_CONFIG_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")));
    let text = dir.and_then(|d| fs::read_to_string(d.join("config.zurafa")).ok()).unwrap_or_default();
    !text
        .lines()
        .filter_map(|l| l.split_once('='))
        .any(|(k, v)| k.trim() == "agent-notes" && v.trim() == "false")
}

/// A pane's agent left and its login shell is back, as `zurafa spawn` leaves it.
/// A shell still running `-c` is the one that started the agent, not the one after it.
fn agent_left(b: &Block) -> bool {
    b.statuses.reported
        && b.foreground.as_ref().is_some_and(|p| {
            ["zsh", "bash", "fish", "sh", "dash", "ksh"].contains(&p.name.as_str())
                && p.extra.get("argv").and_then(Value::as_array).is_some_and(|a| !a.iter().any(|x| x == "-c"))
        })
}

/// The pane's record in `state`; subagent records (`agent/…`) never stand for the pane.
fn record(b: &Block, state: State) -> Option<&zurafa_events::status::Record> {
    b.statuses.records.iter().find(|(id, r)| r.state == state && !id.starts_with("agent/")).map(|(_, r)| r)
}

/// What a pane can't report itself: "exited", "blocked", "error", or nothing.
fn news(b: &Block) -> &'static str {
    if !b.running || agent_left(b) {
        "exited"
    } else if record(b, State::Blocked).is_some() {
        "blocked"
    } else if record(b, State::Error).is_some() {
        "error"
    } else {
        ""
    }
}

/// A parent can take a note: a live agent that has reported and isn't on a
/// dialog (typing could answer it). A working agent takes it as a message.
fn can_take(b: &Block) -> bool {
    b.statuses.reported && !matches!(news(b), "exited" | "blocked")
}

/// `<zurafa from="t7 review">is blocked (permission); see zurafa read t7</zurafa>`
fn note(id: &str, label: Option<&str>, b: &Block) -> String {
    let what = match news(b) {
        "blocked" => {
            let kind = record(b, State::Blocked).and_then(|r| r.kind.as_ref());
            let kind = kind.and_then(|k| serde_json::to_value(k).ok()).map_or("waiting".into(), |k| strv(&k));
            format!("is blocked ({kind})")
        }
        "error" => match record(b, State::Error).and_then(|r| r.msg.as_deref()).and_then(|m| m.lines().next()) {
            Some(m) if !m.trim().is_empty() => format!("hit an error: {}", m.trim().chars().take(200).collect::<String>()),
            _ => "hit an error".into(),
        },
        _ => match (b.running, b.exit_code) {
            (false, Some(code)) => format!("exited (exit {code})"),
            _ => "exited".into(),
        },
    };
    let from = match label {
        Some(l) => format!("{id} {}", l.replace('"', "'")),
        None => id.into(),
    };
    // Typed into the parent, so nothing in it may act as a key.
    format!("<zurafa from=\"{from}\">{what}; see zurafa read {id}</zurafa>").chars().filter(|c| !c.is_control()).collect()
}

fn strv(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_owned()
}

#[derive(Default)]
struct Notes {
    /// Each pane's news at the last step.
    last: HashMap<String, &'static str>,
    /// How many times each pane had news, and how many its parent was told.
    count: HashMap<String, u64>,
    told: HashMap<String, u64>,
    /// The first step only learns the panes: news from before the daemon started is old.
    primed: bool,
}

impl Notes {
    /// Notes to type (parent, text) and panes to close (session, block), given the
    /// panes now. A note waits until its parent can take it and is dropped once
    /// the news is stale (the child got going again).
    // shortcut: a parent already in `zurafa wait` on the child gets the note too (herdr skips it);
    // the daemon can't tell whose subscription is whose, upgrade when clients say which pane they are.
    fn step(&mut self, snapshot: &Snapshot) -> (Vec<(String, String)>, Vec<(String, String)>) {
        let blocks: HashMap<&str, (&str, &Block)> = snapshot
            .sessions
            .values()
            .flat_map(|s| s.blocks.iter().map(move |(id, b)| (id.as_str(), (s.session_id.as_str(), b))))
            .collect();
        // Parents that ended since the last step: closed, exited, or their agent left.
        let mut ended: Vec<String> = self.last.iter().filter(|(id, n)| **n != "exited" && !blocks.contains_key(id.as_str())).map(|(id, _)| id.clone()).collect();
        self.last.retain(|id, _| blocks.contains_key(id.as_str()));
        self.count.retain(|id, _| blocks.contains_key(id.as_str()));
        self.told.retain(|id, _| blocks.contains_key(id.as_str()));
        for (id, (_, b)) in &blocks {
            let now = news(b);
            if self.last.insert(id.to_string(), now).unwrap_or("") != now && !now.is_empty() {
                *self.count.entry(id.to_string()).or_default() += 1;
                if now == "exited" {
                    ended.push(id.to_string());
                }
            }
        }
        if !std::mem::replace(&mut self.primed, true) {
            self.told = self.count.clone();
            return (vec![], vec![]);
        }
        let mut closed = vec![];
        let mut typed: Vec<(String, String)> = vec![];
        for (id, (session, b)) in &blocks {
            let Some(parent) = b.parent.as_deref() else { continue };
            if ended.iter().any(|e| e == parent) && !b.outlive_parent {
                closed.push((session.to_string(), id.to_string()));
                continue;
            }
            let count = self.count.get(*id).copied().unwrap_or(0);
            let ready = blocks.get(parent).is_some_and(|(_, p)| can_take(p));
            if !ready || news(b).is_empty() || self.told.get(*id).copied().unwrap_or(0) >= count {
                continue;
            }
            self.told.insert(id.to_string(), count);
            let label = snapshot.sessions[*session]
                .windows
                .iter()
                .find(|w| w.layout == zurafa_events::Layout::Block { block_id: id.to_string() })
                .map(|w| w.label.as_str());
            typed.push((parent.to_string(), note(id, label, b)));
        }
        // One write per parent: several notes go in as one message.
        let mut joined: Vec<(String, String)> = vec![];
        for (parent, text) in typed {
            match joined.iter_mut().find(|(p, _)| *p == parent) {
                Some((_, all)) => *all = format!("{all} {text}"),
                None => joined.push((parent, text)),
            }
        }
        (joined, closed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zurafa_events::{status::parse, Axis, Dispatcher};

    fn pane(d: &Dispatcher, id: &str, parent: Option<&str>, outlive: bool) {
        d.add_block("default", id, None, Axis::Horizontal, id.into(), parent.map(Into::into), outlive).unwrap();
    }

    #[test]
    fn a_child_stuck_or_gone_is_told_once_when_its_parent_can_take_it() {
        let d = Dispatcher::new(64);
        let mut notes = Notes::default();
        pane(&d, "t1", None, false);
        pane(&d, "t2", Some("t1"), false);
        notes.step(&d.snapshot());
        d.report("t2", parse("state=blocked:kind=permission").unwrap());
        assert!(notes.step(&d.snapshot()).0.is_empty(), "the parent hasn't reported yet");
        d.report("t1", parse("state=blocked").unwrap());
        assert!(notes.step(&d.snapshot()).0.is_empty(), "the parent is on a dialog");
        d.report("t1", parse("state=working").unwrap());
        let told = vec![("t1".to_string(), "<zurafa from=\"t2 t2\">is blocked (permission); see zurafa read t2</zurafa>".to_string())];
        assert_eq!(notes.step(&d.snapshot()).0, told);
        assert!(notes.step(&d.snapshot()).0.is_empty(), "the same news once");
        d.report("t2", parse("state=working").unwrap());
        d.exited("t2", Some(3));
        assert_eq!(notes.step(&d.snapshot()).0[0].1, "<zurafa from=\"t2 t2\">exited (exit 3); see zurafa read t2</zurafa>");
    }

    #[test]
    fn a_parent_that_ends_closes_its_children_unless_they_outlive_it() {
        let d = Dispatcher::new(64);
        let mut notes = Notes::default();
        pane(&d, "t1", None, false);
        pane(&d, "t2", Some("t1"), false);
        pane(&d, "t3", Some("t1"), true);
        assert!(notes.step(&d.snapshot()).1.is_empty());
        assert!(notes.step(&d.snapshot()).1.is_empty());
        d.exited("t1", Some(0));
        assert_eq!(notes.step(&d.snapshot()).1, vec![("default".to_string(), "t2".to_string())]);
        assert!(notes.step(&d.snapshot()).1.is_empty(), "closed once");
    }

    #[test]
    fn news_from_before_the_daemon_started_is_left_alone() {
        let d = Dispatcher::new(64);
        pane(&d, "t1", None, false);
        pane(&d, "t2", Some("t1"), false);
        pane(&d, "t3", Some("t2"), false);
        d.report("t1", parse("state=working").unwrap());
        d.exited("t2", Some(0));
        let mut notes = Notes::default();
        assert_eq!(notes.step(&d.snapshot()), (vec![], vec![]));
        assert_eq!(notes.step(&d.snapshot()), (vec![], vec![]));
    }
}
