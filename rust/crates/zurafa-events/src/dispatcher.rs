use crate::*;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::broadcast;
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub protocol: u32,
    pub instance: String,
    pub sequence: u64,
    pub timestamp: u64,
    #[serde(flatten)]
    pub event: Event,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Layout {
    Block {
        block_id: String,
    },
    Split {
        axis: Axis,
        ratio: f64,
        first: Box<Layout>,
        second: Box<Layout>,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Axis {
    Horizontal,
    Vertical,
}
impl Layout {
    fn contains(&self, id: &str) -> bool {
        match self {
            Self::Block { block_id } => block_id == id,
            Self::Split { first, second, .. } => first.contains(id) || second.contains(id),
        }
    }
    /// Splits `id`, then evens out the run of same-axis splits around it so every pane in that row or column gets an equal share.
    /// Returns `Some(true)` while the caller is still inside that run, `None` when `id` is absent.
    fn split(&mut self, id: &str, new: &str, axis: Axis) -> Option<bool> {
        match self {
            Self::Block { block_id } if block_id == id => {
                *self = Self::Split {
                    axis,
                    ratio: 0.5,
                    first: Box::new(self.clone()),
                    second: Box::new(Self::Block {
                        block_id: new.into(),
                    }),
                };
                Some(true)
            }
            Self::Split {
                axis: own,
                ratio,
                first,
                second,
            } => {
                let run = first
                    .split(id, new, axis.clone())
                    .or_else(|| second.split(id, new, axis.clone()))?;
                if !run || *own != axis {
                    return Some(false);
                }
                let (a, b) = (first.span(own), second.span(own));
                *ratio = a / (a + b);
                Some(true)
            }
            _ => None,
        }
    }
    /// Panes along `axis`; a split across the other axis counts as one.
    fn span(&self, axis: &Axis) -> f64 {
        match self {
            Self::Split {
                axis: own,
                first,
                second,
                ..
            } if own == axis => first.span(axis) + second.span(axis),
            _ => 1.0,
        }
    }
    fn remove(self, id: &str) -> Option<Self> {
        match self {
            Self::Block { ref block_id } => {
                if block_id == id {
                    None
                } else {
                    Some(self)
                }
            }
            Self::Split {
                axis,
                ratio,
                first,
                second,
            } => match (first.remove(id), second.remove(id)) {
                (Some(a), Some(b)) => Some(Self::Split {
                    axis,
                    ratio,
                    first: Box::new(a),
                    second: Box::new(b),
                }),
                (a, b) => a.or(b),
            },
        }
    }
    fn first(&self) -> String {
        match self {
            Self::Block { block_id } => block_id.clone(),
            Self::Split { first, .. } => first.first(),
        }
    }
    fn resize(&mut self, path: &[usize], value: f64) -> Result<(), String> {
        match self {
            Self::Split {
                ratio,
                first,
                second,
                ..
            } => {
                if path.is_empty() {
                    *ratio = value;
                    Ok(())
                } else {
                    match path[0] {
                        0 => first.resize(&path[1..], value),
                        1 => second.resize(&path[1..], value),
                        _ => Err("invalid split path".into()),
                    }
                }
            }
            _ => Err("path does not identify a split".into()),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Window {
    pub window_id: String,
    pub label: String,
    pub layout: Layout,
    pub selected_block: String,
    pub zoomed_block: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub block_id: String,
    pub running: bool,
    pub exit_code: Option<i32>,
    pub statuses: status::Records,
    pub title: Option<String>,
    pub pwd: Option<String>,
    #[serde(default)]
    pub foreground: Option<crate::Process>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<RemoteHost>,
    pub revision: u64,
    pub active_window: Option<String>,
    pub windows: Vec<Window>,
    pub blocks: BTreeMap<String, Block>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteHost {
    pub id: String,
    pub label: String,
    pub hostname: String,
    pub user: Option<String>,
    pub port: u16,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub protocol: u32,
    pub instance: String,
    pub sequence: u64,
    pub sessions: BTreeMap<String, Session>,
    pub clients: BTreeMap<String, Client>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Focus {
        session: String,
        block: String,
    },
    Zoom {
        session: String,
        block: String,
        enabled: bool,
    },
    Resize {
        session: String,
        window: String,
        path: Vec<usize>,
        ratio: f64,
    },
    Close {
        session: String,
        block: String,
    },
    Label {
        session: String,
        window: Option<String>,
        label: String,
    },
    CreateSession {
        session: String,
        label: String,
        #[serde(default)]
        remote: Option<RemoteHost>,
    },
    DestroySession {
        session: String,
    },
}
struct Inner {
    snapshot: Snapshot,
    next_window: u64,
    tx: broadcast::Sender<Envelope>,
}
pub struct Dispatcher {
    inner: Mutex<Inner>,
}
impl Inner {
    fn emit(&mut self, event: Event) {
        self.snapshot.sequence += 1;
        let _ = self.tx.send(Envelope {
            protocol: 2,
            instance: self.snapshot.instance.clone(),
            sequence: self.snapshot.sequence,
            timestamp: now(),
            event,
        });
    }
    fn session_event(&mut self, id: &str, event: SessionEvent) {
        self.emit(Event::Session {
            session_id: id.into(),
            event,
        });
    }
    fn changed(&mut self, id: &str) {
        let s = self.snapshot.sessions.get_mut(id).unwrap();
        s.revision += 1;
        let revision = s.revision;
        self.session_event(id, SessionEvent::SessionViewChanged { revision });
    }
    fn terminal(&mut self, id: &str, block: &str, event: TerminalEvent) {
        self.emit(Event::Terminal {
            session_id: id.into(),
            block_id: block.into(),
            creator_name: "com.superlogical.terminal".into(),
            kind: BlockEventType::BlockEvent,
            event,
        });
    }
}
impl Dispatcher {
    pub fn new(capacity: usize) -> Self {
        let instance = format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let this = Self {
            inner: Mutex::new(Inner {
                snapshot: Snapshot {
                    protocol: 2,
                    instance,
                    sequence: 0,
                    sessions: BTreeMap::new(),
                    clients: BTreeMap::new(),
                },
                next_window: 0,
                tx: broadcast::channel(capacity.max(1)).0,
            }),
        };
        this.command(Command::CreateSession {
            session: "default".into(),
            label: "Workspace".into(),
            remote: None,
        })
        .unwrap();
        this
    }
    pub fn client_joined(&self, principal: serde_json::Value) -> String {
        let mut i = self.inner.lock().unwrap();
        let id = format!("client-{}", i.snapshot.sequence + 1);
        let client = Client {
            client_id: id.clone(),
            info: ClientInfo {
                kind: "ipc".into(),
                name: "IPC client".into(),
                platform: "unknown".into(),
                version: "unknown".into(),
            },
            principal,
            connected_at: serde_json::json!(now()),
        };
        i.snapshot.clients.insert(id.clone(), client.clone());
        i.emit(Event::Server {
            event: ServerEvent::ClientJoined { client },
        });
        id
    }
    pub fn client_left(&self, id: &str) {
        let mut i = self.inner.lock().unwrap();
        if i.snapshot.clients.remove(id).is_some() {
            i.emit(Event::Server {
                event: ServerEvent::ClientLeft {
                    client_id: id.into(),
                },
            });
        }
    }
    pub fn snapshot(&self) -> Snapshot {
        self.inner.lock().unwrap().snapshot.clone()
    }
    pub fn hosts_changed(&self, hash: String) {
        self.inner.lock().unwrap().emit(Event::Server {
            event: ServerEvent::HostsChanged { hash },
        });
    }
    /// Refresh remote session definitions after the saved host has been updated.
    /// Existing PTYs retain their process; the next terminal spawn uses this host.
    pub fn host_updated(&self, host: &RemoteHost, hash: String) {
        let mut inner = self.inner.lock().unwrap();
        for session in inner.snapshot.sessions.values_mut() {
            if session
                .remote
                .as_ref()
                .is_some_and(|remote| remote.id == host.id)
            {
                session.remote = Some(host.clone());
            }
        }
        inner.emit(Event::Server {
            event: ServerEvent::HostsChanged { hash },
        });
    }
    /// Register the receiver and clone the state under the same publication lock.
    pub fn subscribe(&self) -> (Snapshot, broadcast::Receiver<Envelope>) {
        let i = self.inner.lock().unwrap();
        (i.snapshot.clone(), i.tx.subscribe())
    }
    pub fn validate_target(&self, session: &str, split: Option<&str>) -> Result<(), String> {
        let i = self.inner.lock().unwrap();
        let s = i.snapshot.sessions.get(session).ok_or("unknown session")?;
        if split.is_some_and(|b| !s.blocks.contains_key(b)) {
            return Err("unknown block".into());
        }
        Ok(())
    }
    pub fn add_block(
        &self,
        session: &str,
        block: &str,
        split: Option<&str>,
        axis: Axis,
        label: String,
    ) -> Result<(), String> {
        let mut i = self.inner.lock().unwrap();
        let s = i.snapshot.sessions.get(session).ok_or("unknown session")?;
        if i.snapshot
            .sessions
            .values()
            .any(|s| s.blocks.contains_key(block))
        {
            return Err("duplicate block".into());
        }
        if split.is_some_and(|b| !s.blocks.contains_key(b)) {
            return Err("unknown block".into());
        }
        i.next_window += 1;
        let next = format!("w{}", i.next_window);
        let s = i.snapshot.sessions.get_mut(session).unwrap();
        s.blocks.insert(
            block.into(),
            Block {
                block_id: block.into(),
                running: true,
                exit_code: None,
                statuses: status::Records::default(),
                title: None,
                pwd: None,
                foreground: None,
            },
        );
        let (window, created) = if let Some(target) = split {
            let w = s
                .windows
                .iter_mut()
                .find(|w| w.layout.contains(target))
                .unwrap();
            w.layout.split(target, block, axis);
            w.selected_block = block.into();
            w.zoomed_block = None;
            (w.window_id.clone(), false)
        } else {
            s.windows.push(Window {
                window_id: next.clone(),
                label: label.clone(),
                layout: Layout::Block {
                    block_id: block.into(),
                },
                selected_block: block.into(),
                zoomed_block: None,
            });
            (next, true)
        };
        let active_changed = s.active_window.as_ref() != Some(&window);
        s.active_window = Some(window.clone());
        if created {
            i.session_event(
                session,
                SessionEvent::WindowCreated {
                    window_id: window.clone(),
                    label,
                },
            );
        }
        i.session_event(
            session,
            SessionEvent::BlockCreated {
                block_id: block.into(),
            },
        );
        if active_changed {
            i.session_event(
                session,
                SessionEvent::ActiveWindowChanged { window_id: window },
            );
        }
        i.changed(session);
        Ok(())
    }
    pub fn command(&self, command: Command) -> Result<Vec<String>, String> {
        let mut i = self.inner.lock().unwrap();
        let mut killed = vec![];
        if let Command::CreateSession {
            session,
            label,
            remote,
        } = command
        {
            if session.is_empty() || i.snapshot.sessions.contains_key(&session) {
                return Err("session already exists or empty id".into());
            }
            i.snapshot.sessions.insert(
                session.clone(),
                Session {
                    session_id: session.clone(),
                    label: label.clone(),
                    remote,
                    revision: 0,
                    active_window: None,
                    windows: vec![],
                    blocks: BTreeMap::new(),
                },
            );
            i.emit(Event::Server {
                event: ServerEvent::SessionCreated {
                    session: SessionInfo {
                        session_id: session,
                        label,
                    },
                },
            });
            return Ok(killed);
        }
        if let Command::DestroySession { session } = command {
            let s = i
                .snapshot
                .sessions
                .remove(&session)
                .ok_or("unknown session")?;
            killed.extend(s.blocks.keys().cloned());
            i.emit(Event::Server {
                event: ServerEvent::SessionDestroyed {
                    session_id: session,
                },
            });
            return Ok(killed);
        }
        let sid = match &command {
            Command::Focus { session, .. }
            | Command::Zoom { session, .. }
            | Command::Resize { session, .. }
            | Command::Close { session, .. }
            | Command::Label { session, .. } => session.clone(),
            _ => unreachable!(),
        };
        // Work on a copy: invalid commands cannot partially mutate authoritative state.
        let mut s = i
            .snapshot
            .sessions
            .get(&sid)
            .ok_or("unknown session")?
            .clone();
        let mut events = vec![];
        let zoom = matches!(command, Command::Zoom { .. });
        match command {
            Command::Focus { block, .. }
            | Command::Zoom {
                block,
                enabled: true,
                ..
            } => {
                let w = s
                    .windows
                    .iter_mut()
                    .find(|w| w.layout.contains(&block))
                    .ok_or("unknown block")?;
                w.selected_block = block.clone();
                if zoom || w.zoomed_block.is_some() {
                    w.zoomed_block = Some(block);
                }
                if s.active_window.as_ref() != Some(&w.window_id) {
                    events.push(SessionEvent::ActiveWindowChanged {
                        window_id: w.window_id.clone(),
                    });
                }
                s.active_window = Some(w.window_id.clone());
            }
            Command::Zoom {
                block,
                enabled: false,
                ..
            } => {
                let w = s
                    .windows
                    .iter_mut()
                    .find(|w| w.layout.contains(&block))
                    .ok_or("unknown block")?;
                w.zoomed_block = None;
            }
            Command::Resize {
                window,
                path,
                ratio,
                ..
            } => {
                if !ratio.is_finite() || !(0.05..=0.95).contains(&ratio) {
                    return Err("ratio must be between 0.05 and 0.95".into());
                }
                s.windows
                    .iter_mut()
                    .find(|w| w.window_id == window)
                    .ok_or("unknown window")?
                    .layout
                    .resize(&path, ratio)?;
            }
            Command::Close { block, .. } => {
                s.blocks.remove(&block).ok_or("unknown block")?;
                killed.push(block.clone());
                events.push(SessionEvent::BlockClosed {
                    block_id: block.clone(),
                });
                let pos = s
                    .windows
                    .iter()
                    .position(|w| w.layout.contains(&block))
                    .unwrap();
                let w = &mut s.windows[pos];
                if let Some(layout) = w.layout.clone().remove(&block) {
                    w.layout = layout;
                    if w.selected_block == block {
                        w.selected_block = w.layout.first();
                    }
                    if w.zoomed_block.as_ref() == Some(&block) {
                        w.zoomed_block = None;
                    }
                } else {
                    let w = s.windows.remove(pos);
                    events.push(SessionEvent::WindowClosed {
                        window_id: w.window_id.clone(),
                    });
                    if s.active_window.as_ref() == Some(&w.window_id) {
                        s.active_window = s.windows.first().map(|w| w.window_id.clone());
                        if let Some(id) = &s.active_window {
                            events.push(SessionEvent::ActiveWindowChanged {
                                window_id: id.clone(),
                            });
                        }
                    }
                }
            }
            Command::Label { window, label, .. } => {
                if let Some(window) = window {
                    let w = s
                        .windows
                        .iter_mut()
                        .find(|w| w.window_id == window)
                        .ok_or("unknown window")?;
                    w.label = label.clone();
                    events.push(SessionEvent::WindowLabelChanged {
                        window_id: window,
                        label,
                    });
                } else {
                    s.label = label.clone();
                    events.push(SessionEvent::SessionLabelChanged { label });
                }
            }
            _ => unreachable!(),
        }
        if serde_json::to_value(&s).unwrap()
            == serde_json::to_value(&i.snapshot.sessions[&sid]).unwrap()
        {
            return Ok(killed);
        }
        i.snapshot.sessions.insert(sid.clone(), s);
        for event in events {
            i.session_event(&sid, event);
        }
        i.changed(&sid);
        Ok(killed)
    }
    pub fn terminal_event(&self, block: &str, event: TerminalEvent) {
        let mut i = self.inner.lock().unwrap();
        let Some(sid) = i
            .snapshot
            .sessions
            .iter()
            .find(|(_, s)| s.blocks.contains_key(block))
            .map(|(id, _)| id.clone())
        else {
            return;
        };
        let b = i
            .snapshot
            .sessions
            .get_mut(&sid)
            .unwrap()
            .blocks
            .get_mut(block)
            .unwrap();
        if !b.running {
            return;
        }
        match &event {
            TerminalEvent::TitleChanged { title, .. } => b.title = Some(title.clone()),
            TerminalEvent::PwdChanged { pwd, .. } => b.pwd = Some(pwd.clone()),
            TerminalEvent::ProcessChanged { foreground, .. } => b.foreground = foreground.clone(),
            _ => (),
        }
        i.terminal(&sid, block, event);
    }
    pub fn report(&self, block: &str, report: status::Report) {
        self.status_update(block, Some(report), "");
    }
    pub fn lifecycle(&self, block: &str, reason: &str) {
        self.status_update(block, None, reason);
    }
    fn status_update(&self, block: &str, report: Option<status::Report>, reason: &str) {
        let mut i = self.inner.lock().unwrap();
        let Some(sid) = i
            .snapshot
            .sessions
            .iter()
            .find(|(_, s)| s.blocks.contains_key(block))
            .map(|(id, _)| id.clone())
        else {
            return;
        };
        let b = i
            .snapshot
            .sessions
            .get_mut(&sid)
            .unwrap()
            .blocks
            .get_mut(block)
            .unwrap();
        if !b.running {
            return;
        }
        let events = if let Some(r) = report {
            b.statuses.apply(r)
        } else {
            b.statuses.lifecycle(reason)
        };
        for e in events {
            i.terminal(&sid, block, e);
        }
    }
    pub fn exited(&self, block: &str, code: Option<i32>) {
        let mut i = self.inner.lock().unwrap();
        let Some(sid) = i
            .snapshot
            .sessions
            .iter()
            .find(|(_, s)| s.blocks.contains_key(block))
            .map(|(id, _)| id.clone())
        else {
            return;
        };
        let b = i
            .snapshot
            .sessions
            .get_mut(&sid)
            .unwrap()
            .blocks
            .get_mut(block)
            .unwrap();
        if !b.running {
            return;
        }
        b.running = false;
        b.exit_code = code;
        let events = b.statuses.lifecycle("process_exit");
        for e in events {
            i.terminal(&sid, block, e);
        }
        i.terminal(
            &sid,
            block,
            TerminalEvent::ChildExited {
                exit_code: code,
                error: if code == Some(0) {
                    None
                } else {
                    Some(
                        code.map(|c| format!("exit status {c}"))
                            .unwrap_or("wait failed".into()),
                    )
                },
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn add(d: &Dispatcher, id: &str, target: Option<&str>) {
        d.add_block("default", id, target, Axis::Horizontal, "Shell".into())
            .unwrap();
    }
    #[test]
    fn splits_share_space_evenly_along_their_axis() {
        let d = Dispatcher::new(32);
        add(&d, "a", None);
        add(&d, "b", Some("a"));
        d.add_block("default", "c", Some("b"), Axis::Vertical, "Shell".into())
            .unwrap();
        d.add_block("default", "d", Some("c"), Axis::Vertical, "Shell".into())
            .unwrap();
        let layout = d.snapshot().sessions["default"].windows[0].layout.clone();
        let Layout::Split { ratio, second, .. } = layout else {
            panic!()
        };
        assert_eq!(ratio, 0.5, "the horizontal split is untouched");
        let Layout::Split { ratio, second, .. } = *second else {
            panic!()
        };
        assert!((ratio - 1.0 / 3.0).abs() < 1e-9);
        let Layout::Split { ratio, .. } = *second else {
            panic!()
        };
        assert_eq!(ratio, 0.5);
    }
    #[test]
    fn atomic_snapshot_boundary_and_restart() {
        let d = Dispatcher::new(32);
        add(&d, "a", None);
        let (s, mut rx) = d.subscribe();
        add(&d, "b", Some("a"));
        let first = rx.try_recv().unwrap();
        assert_eq!(first.sequence, s.sequence + 1);
        assert_eq!(first.instance, s.instance);
        assert_eq!(s.sessions["default"].blocks.len(), 1);
        assert_eq!(d.snapshot().sessions["default"].blocks.len(), 2);
        assert_ne!(s.instance, Dispatcher::new(32).snapshot().instance);
    }
    #[test]
    fn invalid_commands_do_not_publish_or_mutate() {
        let d = Dispatcher::new(32);
        add(&d, "a", None);
        let (before, mut rx) = d.subscribe();
        assert!(d
            .command(Command::Resize {
                session: "default".into(),
                window: "w1".into(),
                path: vec![],
                ratio: 0.7
            })
            .is_err());
        assert!(d
            .command(Command::Focus {
                session: "default".into(),
                block: "absent".into()
            })
            .is_err());
        assert_eq!(
            serde_json::to_value(before).unwrap(),
            serde_json::to_value(d.snapshot()).unwrap()
        );
        assert!(rx.try_recv().is_err());
    }
    #[test]
    fn layout_selection_zoom_resize_close() {
        let d = Dispatcher::new(128);
        add(&d, "a", None);
        add(&d, "b", Some("a"));
        d.command(Command::Resize {
            session: "default".into(),
            window: "w1".into(),
            path: vec![],
            ratio: 0.7,
        })
        .unwrap();
        d.command(Command::Zoom {
            session: "default".into(),
            block: "b".into(),
            enabled: true,
        })
        .unwrap();
        d.command(Command::Focus {
            session: "default".into(),
            block: "a".into(),
        })
        .unwrap();
        assert_eq!(
            d.snapshot().sessions["default"].windows[0]
                .zoomed_block
                .as_deref(),
            Some("a")
        );
        d.command(Command::Close {
            session: "default".into(),
            block: "a".into(),
        })
        .unwrap();
        let s = d.snapshot();
        let w = &s.sessions["default"].windows[0];
        assert_eq!(w.selected_block, "b");
        assert_eq!(
            w.layout,
            Layout::Block {
                block_id: "b".into()
            }
        );
        assert_eq!(w.zoomed_block, None);
        d.command(Command::Close {
            session: "default".into(),
            block: "b".into(),
        })
        .unwrap();
        assert!(d.snapshot().sessions["default"].windows.is_empty());
    }
    #[test]
    fn bounded_receivers_detect_gap_independently() {
        let d = Dispatcher::new(2);
        let (_, mut slow) = d.subscribe();
        let (_, mut fast) = d.subscribe();
        for n in 0..20 {
            d.command(Command::Label {
                session: "default".into(),
                window: None,
                label: n.to_string(),
            })
            .unwrap();
            assert!(fast.try_recv().is_ok());
            assert!(fast.try_recv().is_ok());
        }
        assert!(matches!(
            slow.try_recv(),
            Err(broadcast::error::TryRecvError::Lagged(_))
        ));
        let (s, mut fresh) = d.subscribe();
        assert_eq!(s.sessions["default"].label, "19");
        assert!(fresh.try_recv().is_err());
    }
    #[test]
    fn lifecycle_snapshot_and_exactly_one_exit() {
        let d = Dispatcher::new(32);
        add(&d, "a", None);
        let (_, mut rx) = d.subscribe();
        d.report("a", status::parse("state=working:id=a").unwrap());
        d.report("a", status::parse("state=done:id=b").unwrap());
        d.exited("a", Some(2));
        d.exited("a", Some(2));
        d.report("a", status::parse("state=working:id=c").unwrap());
        let b = &d.snapshot().sessions["default"].blocks["a"];
        assert!(!b.running);
        assert_eq!(b.statuses.records.len(), 1);
        assert!(b.statuses.records.contains_key("b"));
        let mut events = vec![];
        while let Ok(e) = rx.try_recv() {
            events.push(e.event.name());
        }
        assert_eq!(
            events,
            vec![
                "terminal.program_status_changed",
                "terminal.program_status_changed",
                "terminal.program_status_removed",
                "terminal.child_exited"
            ]
        );
    }
    #[test]
    fn concurrent_publication_has_one_total_order() {
        let d = std::sync::Arc::new(Dispatcher::new(1024));
        let (s, mut rx) = d.subscribe();
        std::thread::scope(|scope| {
            for _ in 0..4 {
                let d = d.clone();
                scope.spawn(move || {
                    for i in 0..50 {
                        d.command(Command::Label {
                            session: "default".into(),
                            window: None,
                            label: i.to_string(),
                        })
                        .unwrap();
                    }
                });
            }
        });
        let mut last = s.sequence;
        while let Ok(e) = rx.try_recv() {
            assert_eq!(e.sequence, last + 1);
            last = e.sequence;
        }
        assert_eq!(last, d.snapshot().sequence);
    }
    #[test]
    fn server_lifecycle_and_noop_commands() {
        let d = Dispatcher::new(32);
        let (_, mut rx) = d.subscribe();
        let client = d.client_joined(serde_json::Value::Null);
        assert!(d.snapshot().clients.contains_key(&client));
        assert_eq!(rx.try_recv().unwrap().event.name(), "client_joined");
        d.client_left(&client);
        assert_eq!(rx.try_recv().unwrap().event.name(), "client_left");
        d.client_left(&client);
        assert!(rx.try_recv().is_err());
        let before = d.snapshot().sequence;
        d.command(Command::Label {
            session: "default".into(),
            window: None,
            label: "Workspace".into(),
        })
        .unwrap();
        assert_eq!(d.snapshot().sequence, before);
        d.command(Command::CreateSession {
            session: "s".into(),
            label: "Project".into(),
            remote: None,
        })
        .unwrap();
        assert_eq!(rx.try_recv().unwrap().event.name(), "session_created");
        d.command(Command::DestroySession {
            session: "s".into(),
        })
        .unwrap();
        assert_eq!(rx.try_recv().unwrap().event.name(), "session_destroyed");
        assert!(!d.snapshot().sessions.contains_key("s"));
    }
}
