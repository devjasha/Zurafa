use crate::protocol::{read_frame, write_frame, Msg};
use crate::pty::{SpawnOptions, Terminals};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{broadcast::error::RecvError, mpsc},
    task::JoinHandle,
};
use zurafa_events::{status, Axis, Command, Filter, RemoteHost, TerminalEvent};
async fn recv<R: AsyncRead + Unpin>(r: &mut R) -> Option<Value> {
    let v: Value = serde_json::from_slice(&read_frame(r).await.ok()?).ok()?;
    v.is_object().then_some(v)
}
fn yes() -> bool {
    true
}

fn error(id: impl Serialize, message: impl ToString) -> Value {
    json!({"id":id,"type":"error","message":message.to_string()})
}
type Size = (u16, u16);
/// Who sizes each terminal. Only the owner's size reaches the PTY; every other viewer's size
/// is kept, so the terminal falls back to it when the owner leaves or stops showing it.
#[derive(Default)]
pub struct Owners(HashMap<String, Sizing>);
#[derive(Default)]
struct Sizing {
    owner: Option<String>,
    /// Each viewer's own size, most recently set last.
    wants: Vec<(String, Size)>,
}
impl Sizing {
    fn want(&mut self, client: &str, size: Size) {
        self.wants.retain(|(c, _)| c != client);
        self.wants.push((client.into(), size));
    }
    fn wanted(&self, client: &str) -> Option<Size> {
        self.wants.iter().find(|(c, _)| c == client).map(|w| w.1)
    }
}
/// Each returns the size to give the PTY now, if any.
impl Owners {
    pub fn owner(&self, terminal: &str) -> Option<&str> {
        self.0.get(terminal)?.owner.as_deref()
    }
    /// The first client to size a terminal owns it, so a lone or older client works as before.
    pub fn resize(&mut self, client: &str, terminal: &str, size: Size) -> Option<Size> {
        let s = self.0.entry(terminal.into()).or_default();
        s.want(client, size);
        (s.owner.get_or_insert_with(|| client.into()) == client).then_some(size)
    }
    pub fn claim(&mut self, client: &str, terminal: &str, size: Option<Size>) -> Option<Size> {
        let s = self.0.entry(terminal.into()).or_default();
        if let Some(size) = size {
            s.want(client, size);
        }
        s.owner = Some(client.into());
        s.wanted(client)
    }
    /// Typing takes the terminal, but only for a client showing it: `zurafa send` has no size.
    /// Input led by ESC is not typing: it is mostly the terminal answering a query, or a mouse or
    /// focus report, which every viewer sends after a resize, so it would trade the terminal back and forth.
    pub fn typed(&mut self, client: &str, terminal: &str, bytes: &[u8]) -> Option<Size> {
        if bytes.first() == Some(&0x1b) {
            return None;
        }
        let s = self.0.get_mut(terminal)?;
        if s.owner.as_deref() == Some(client) {
            return None;
        }
        let size = s.wanted(client)?;
        s.owner = Some(client.into());
        Some(size)
    }
    /// The client stopped showing the terminal; if it owned it, the latest other viewer takes over.
    pub fn release(&mut self, client: &str, terminal: &str) -> Option<Size> {
        let s = self.0.get_mut(terminal)?;
        s.wants.retain(|(c, _)| c != client);
        let owned = s.owner.as_deref() == Some(client);
        if owned {
            s.owner = s.wants.last().map(|w| w.0.clone());
        }
        let next = if owned { s.wants.last().map(|w| w.1) } else { None };
        if s.owner.is_none() && s.wants.is_empty() {
            self.0.remove(terminal);
        }
        next
    }
    /// Releases everything a disconnected client showed; returns the terminals it owned.
    pub fn left(&mut self, client: &str) -> Vec<(String, Option<Size>)> {
        let terminals: Vec<String> = self.0.keys().cloned().collect();
        terminals
            .into_iter()
            .filter_map(|t| {
                let owned = self.owner(&t) == Some(client);
                let next = self.release(client, &t);
                owned.then_some((t, next))
            })
            .collect()
    }
    pub fn forget(&mut self, terminal: &str) {
        self.0.remove(terminal);
    }
}
fn reply(msg: Msg, t: &Arc<Terminals>, client: &str) -> Option<Value> {
    Some(match msg {
        Msg::Hello {
            id,
            protocol: 1 | 2,
        } => json!({"id":id,"type":"error","message":"already initialized"}),
        Msg::Hello { id, .. } => error(id, "unsupported protocol"),
        Msg::Ping { id } => json!({"id":id,"type":"pong"}),
        Msg::Spawn {
            id,
            cols,
            rows,
            cwd,
            command,
            raw,
        } => match t.spawn(cols, rows, cwd, command, raw) {
            Ok(terminal) => json!({"id":id,"type":"spawned","terminal":terminal}),
            Err(e) => error(id, e),
        },
        Msg::Attach { id, terminal, since } => match t.attach(&terminal, since) {
            Ok((end, data, gap)) => {
                let (cols, rows) = t.size(&terminal).unwrap_or((80, 24));
                json!({"id":id,"type":"attached","terminal":terminal,
                "end":end,"data":B64.encode(data),"gap":gap,"cols":cols,"rows":rows})
            }
            Err(e) => error(id, e),
        },
        Msg::Kill { id, terminal } => match t.kill(&terminal) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Msg::Input { terminal, data } => {
            if let Ok(bytes) = B64.decode(data) {
                // Resized before the keys land, so they act on the grid the typist sees.
                let size = t.owners.lock().unwrap().typed(client, &terminal, &bytes);
                if size.is_some() {
                    t.sized(&terminal, size);
                }
                t.input(&terminal, &bytes);
            }
            return None;
        }
        Msg::Resize {
            terminal,
            cols,
            rows,
        } => {
            if cols > 0 && rows > 0 {
                let size = t.owners.lock().unwrap().resize(client, &terminal, (cols, rows));
                t.sized(&terminal, size);
            }
            return None;
        }
        Msg::Claim {
            terminal,
            cols,
            rows,
        } => {
            let size = cols.zip(rows).filter(|&(c, r)| c > 0 && r > 0);
            let size = t.owners.lock().unwrap().claim(client, &terminal, size);
            t.sized(&terminal, size);
            return None;
        }
        Msg::Release { terminal } => {
            let size = t.owners.lock().unwrap().release(client, &terminal);
            t.sized(&terminal, size);
            return None;
        }
    })
}
#[derive(Deserialize)]
// Unknown fields are ignored, so a newer client's optional fields work with this daemon.
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "hosts.list")]
    HostsList { id: u64 },
    #[serde(rename = "hosts.add")]
    HostsAdd { id: u64, host: RemoteHost },
    #[serde(rename = "hosts.update")]
    HostsUpdate { id: u64, host: RemoteHost },
    #[serde(rename = "hosts.tailnet")]
    HostsTailnet { id: u64 },
    #[serde(rename = "hosts.vms")]
    HostsVms { id: u64 },
    #[serde(rename = "hosts.remove")]
    HostsRemove { id: u64, host_id: String },
    #[serde(rename = "hosts.service")]
    HostsService { id: u64, host_id: String, enable: bool },
    #[serde(rename = "layout.resume")]
    LayoutResume { id: u64, block: String, agent: String, session: String },
    /// With `appearance` the Mac app publishes its look; without, a client asks for it.
    #[serde(rename = "ui.appearance")]
    UiAppearance { id: u64, appearance: Option<Value> },
    /// A pane's agent conversation as `zurafa-orch follow` lines, from index `from` (see chat.rs).
    #[serde(rename = "ui.chat.read")]
    UiChatRead {
        id: u64,
        block: String,
        #[serde(default)]
        from: usize,
    },
    /// One zurafa-orch command run on this machine (set, spawn, threads) and its output.
    #[serde(rename = "ui.orch")]
    UiOrch { id: u64, args: Vec<String> },
    /// A phone's pasted image or attached file, saved on the Mac so the pane's agent can read it by path.
    #[serde(rename = "ui.paste_image")]
    UiPasteImage {
        id: u64,
        data: String,
        /// The file's name on the phone; without one the bytes say png or jpg.
        #[serde(default)]
        name: Option<String>,
    },
    /// The Mac app's UI actions, sent on connect and whenever "Allow agents to control Zurafa"
    /// changes; an empty list means control is off.
    #[serde(rename = "ui.actions.register")]
    UiActionsRegister {
        id: u64,
        #[serde(default)]
        label: String,
        #[serde(default)]
        actions: Vec<Value>,
    },
    #[serde(rename = "ui.actions.list")]
    UiActionsList { id: u64 },
    /// Run an app's action; the reply comes once the app answers or `timeout_ms` passes.
    #[serde(rename = "ui.actions.run")]
    UiActionsRun {
        id: u64,
        #[serde(default)]
        client: Option<String>,
        action: String,
        #[serde(default)]
        args: serde_json::Map<String, Value>,
        #[serde(default)]
        timeout_ms: Option<u64>,
    },
    /// The app's answer to a `ui.action` the daemon sent it.
    #[serde(rename = "ui.action.result")]
    UiActionResult {
        #[serde(default)]
        id: Option<u64>,
        call: u64,
        ok: bool,
        #[serde(default)]
        message: String,
    },
    /// A phone asking for agent notifications, and the Mac app reading who to notify.
    #[serde(rename = "push.register")]
    PushRegister { id: u64, device: serde_json::Value },
    #[serde(rename = "push.unregister")]
    PushUnregister { id: u64, token: String },
    #[serde(rename = "push.list")]
    PushList { id: u64 },
    #[serde(rename = "server.status")]
    ServerStatus { id: u64 },
    #[serde(rename = "server.listen")]
    ServerListen {
        id: u64,
        enable: bool,
        /// Only the device's Tailscale owner; off admits every caller Tailscale identifies.
        #[serde(default = "yes")]
        limit: bool,
        /// The app's Tailscale device name, e.g. "my-mac-zurafa".
        #[serde(default)]
        hostname: Option<String>,
    },
    #[serde(rename = "server.logout")]
    ServerLogout { id: u64 },
    #[serde(rename = "events.subscribe")]
    Subscribe {
        id: u64,
        subscription: String,
        #[serde(default)]
        filter: Filter,
    },
    #[serde(rename = "events.subscribe_all")]
    SubscribeAll { id: u64, subscription: String },
    #[serde(rename = "events.unsubscribe")]
    Unsubscribe { id: u64, subscription: String },
    #[serde(rename = "events.snapshot")]
    Snapshot { id: u64 },
    #[serde(rename = "events.resync")]
    Resync { id: u64, subscription: String },
    #[serde(rename = "layout.command")]
    Layout { id: u64, command: Command },
    #[serde(rename = "layout.tab")]
    Tab {
        id: u64,
        session: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        #[serde(default = "label")]
        label: String,
        #[serde(default)]
        parent: Option<String>,
    },
    #[serde(rename = "layout.split")]
    Split {
        id: u64,
        session: String,
        block: String,
        axis: Axis,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        #[serde(default)]
        parent: Option<String>,
    },
    #[serde(rename = "layout.preview")]
    Preview {
        id: u64,
        session: String,
        block: String,
        path: String,
    },
    /// An OSC 7501 report for a pane, from a program that cannot write to the pane's terminal,
    /// like hooks Codex runs in its own background server.
    #[serde(rename = "status.report")]
    StatusReport {
        id: u64,
        session: String,
        block: String,
        body: String,
    },
}
/// Named like the Mac app's own pastes, so agents treat both alike; a phone file keeps its name,
/// reduced to characters that need no shell quoting.
fn save_image(bytes: &[u8], name: Option<&str>) -> std::io::Result<String> {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
    let file = match name.map(|n| n.chars().map(|c| if c.is_ascii_alphanumeric() || "._-".contains(c) { c } else { '_' }).collect::<String>()) {
        Some(n) if !n.trim_start_matches('.').is_empty() => format!("zurafa-paste-{nanos}-{}", n.trim_start_matches('.')),
        _ => format!("zurafa-paste-{nanos}.{}", if bytes.starts_with(b"\x89PNG") { "png" } else { "jpg" }),
    };
    let path = std::env::temp_dir().join(file);
    std::io::Write::write_all(&mut std::fs::OpenOptions::new().write(true).create_new(true).open(&path)?, bytes)?;
    Ok(path.to_string_lossy().into_owned())
}
fn label() -> String {
    "Terminal".into()
}
struct Subscription {
    filter: Filter,
    generation: u64,
    task: JoinHandle<()>,
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.task.abort();
    }
}
struct Delivery {
    subscription: String,
    generation: u64,
    message: Value,
}
fn subscribe(
    terms: &Terminals,
    tx: mpsc::Sender<Delivery>,
    subscription: String,
    filter: Filter,
    generation: u64,
) -> (Value, Subscription) {
    let (snapshot, mut rx) = terms.dispatcher.subscribe();
    let snapshot = serde_json::to_value(snapshot).unwrap();
    let instance = snapshot["instance"].clone();
    let mut cursor = snapshot["sequence"].as_u64().unwrap();
    let task_filter = filter.clone();
    let task = tokio::spawn(async move {
        loop {
            let message = match rx.recv().await {
                Ok(event) => {
                    cursor = event.sequence;
                    if !task_filter.matches(&event.event) {
                        continue;
                    }
                    json!({"type":"events.event","subscription":subscription,"event":event})
                }
                Err(RecvError::Lagged(missed)) => {
                    // Stop delivery until explicit resync; never silently continue with stale state.
                    let message = json!({"type":"events.gap","subscription":subscription,"instance":instance,"after_sequence":cursor,"missed":missed});
                    let _ = tx
                        .send(Delivery {
                            subscription: subscription.clone(),
                            generation,
                            message,
                        })
                        .await;
                    break;
                }
                Err(RecvError::Closed) => break,
            };
            if tx
                .send(Delivery {
                    subscription: subscription.clone(),
                    generation,
                    message,
                })
                .await
                .is_err()
            {
                break;
            }
        }
    });
    (
        snapshot,
        Subscription {
            filter,
            generation,
            task,
        },
    )
}
async fn request(
    v: Value,
    client: &str,
    terms: &Arc<Terminals>,
    subs: &mut HashMap<String, Subscription>,
    tx: &mpsc::Sender<Delivery>,
    generation: &mut u64,
    late: &mpsc::Sender<Value>,
) -> Option<Value> {
    let id = v.get("id").cloned();
    let ty = v.get("type").and_then(Value::as_str).unwrap_or("");
    if !ty.starts_with("events.") && !ty.starts_with("layout.") && !ty.starts_with("hosts.") && !ty.starts_with("status.") && !ty.starts_with("server.") && !ty.starts_with("ui.") && !ty.starts_with("push.") {
        let (t, client) = (terms.clone(), client.to_owned());
        return match serde_json::from_value::<Msg>(v) {
            Ok(m) => tokio::task::spawn_blocking(move || reply(m, &t, &client))
                .await
                .ok()
                .flatten(),
            Err(e) => id.map(|id| error(id, e)),
        };
    }
    let r = match serde_json::from_value::<Request>(v) {
        Ok(r) => r,
        Err(e) => return Some(error(id, e)),
    };
    Some(match r {
        Request::HostsList { id } => json!({"id":id,"type":"hosts.list","hosts":terms.hosts()}),
        Request::HostsAdd { id, host } => match terms.add_host(host) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::HostsUpdate { id, host } => match terms.update_host(host) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::HostsTailnet { id } => {
            let hosts = tokio::task::spawn_blocking(crate::hosts::tailnet).await.unwrap_or_default();
            json!({"id":id,"type":"hosts.tailnet","hosts":hosts})
        }
        Request::HostsVms { id } => {
            let hosts = tokio::task::spawn_blocking(crate::hosts::local_vms).await.unwrap_or_default();
            json!({"id":id,"type":"hosts.vms","hosts":hosts})
        }
        Request::HostsService { id, host_id, enable } => {
            let Some(host) = terms.hosts().into_iter().find(|h| h.id == host_id) else {
                return Some(error(id, "unknown host"));
            };
            // SSH setup takes seconds: reply later instead of holding up this client's output.
            let late = late.clone();
            tokio::spawn(async move {
                let dest = crate::hosts::ssh_destination(&host);
                let reply = match tokio::task::spawn_blocking(move || crate::remote::service(&dest, enable)).await {
                    Ok(Ok(message)) => json!({"id":id,"type":"ok","message":message}),
                    Ok(Err(e)) => error(id, e),
                    Err(e) => error(id, e),
                };
                let _ = late.send(reply).await;
            });
            return None;
        }
        Request::HostsRemove { id, host_id } => match terms.remove_host(&host_id) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::ServerStatus { id } => {
            json!({"id":id,"type":"server.status","stale":crate::stale(),"pid":std::process::id(),
                "started_at":crate::STARTED.get(),"tailscale":crate::tsnet::status()})
        }
        Request::ServerLogout { id } => match crate::tsnet::logout().await {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::PushRegister { id, device } => match terms.push.lock().unwrap().register(device) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::PushUnregister { id, token } => match terms.push.lock().unwrap().unregister(&token) {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::PushList { id } => json!({"id":id,"type":"push.list","devices":terms.push.lock().unwrap().list()}),
        Request::UiAppearance { id, appearance } => {
            if let Some(a) = appearance {
                terms.set_appearance(a);
            }
            json!({"id":id,"type":"ui.appearance","appearance":terms.appearance()})
        }
        Request::UiActionsRegister { id, label, actions } => match terms.actions.register(late, label, actions) {
            Ok(client) => json!({"id":id,"type":"ui.actions.registered","client":client}),
            Err(e) => error(id, e),
        },
        Request::UiActionsList { id } => json!({"id":id,"type":"ui.actions.list","clients":terms.actions.list()}),
        Request::UiActionsRun { id, client, action, args, timeout_ms } => {
            let (terms, late) = (terms.clone(), late.clone());
            let timeout = std::time::Duration::from_millis(timeout_ms.unwrap_or(10_000).clamp(1, 300_000));
            // Waits on another connection: reply later instead of holding up this client's output.
            tokio::spawn(async move {
                let reply = match terms.actions.run(client.as_deref(), &action, Value::Object(args), timeout).await {
                    Ok(message) => json!({"id":id,"type":"ui.actions.done","message":message}),
                    Err(e) => error(id, e),
                };
                let _ = late.send(reply).await;
            });
            return None;
        }
        Request::UiActionResult { id, call, ok, message } => {
            let known = terms.actions.answer(late, call, if ok { Ok(message) } else { Err(message) });
            return id.map(|id| if known { json!({"id":id,"type":"ok"}) } else { error(id, "unknown call") });
        }
        Request::UiChatRead { id, block, from } => {
            // A remote pane's agent runs on its host: the chat comes from the daemon there.
            let snapshot = terms.dispatcher.snapshot();
            let remote = snapshot.sessions.values().find_map(|s| {
                let b = s.blocks.get(&block)?;
                Some((crate::hosts::ssh_destination(s.remote.as_ref()?), b.foreground.as_ref().map(|p| p.pid)))
            });
            let remote = match remote {
                Some((_, None)) => return Some(error(id, "The remote pane has not reported its agent yet")),
                Some((dest, Some(pid))) => Some((dest, pid)),
                None => None,
            };
            match tokio::task::spawn_blocking(move || crate::chat::read(&block, from, remote)).await {
                Ok(Ok((lines, next))) => json!({"id":id,"type":"ui.chat","lines":lines,"next":next}),
                Ok(Err(e)) => error(id, e),
                Err(e) => error(id, e),
            }
        }
        Request::UiOrch { id, args } => match tokio::task::spawn_blocking(move || crate::chat::run(&args)).await {
            Ok(Ok(out)) => json!({"id":id,"type":"ui.orch","out":out}),
            Ok(Err(e)) => error(id, e),
            Err(e) => error(id, e),
        },
        Request::UiPasteImage { id, data, name } => match B64.decode(data).map_err(|e| e.to_string()).and_then(|b| save_image(&b, name.as_deref()).map_err(|e| e.to_string())) {
            Ok(path) => json!({"id":id,"type":"ui.paste_image","path":path}),
            Err(e) => error(id, e),
        },
        Request::LayoutResume { id, block, agent, session } => {
            match zurafa_events::Resume::new(&agent, &session).and_then(|r| terms.dispatcher.set_resume(&block, r)) {
                Ok(()) => json!({"id":id,"type":"ok"}),
                Err(e) => error(id, e),
            }
        }
        Request::ServerListen { id, enable, limit, hostname } => match crate::tsnet::switch(terms.clone(), enable, limit, hostname.filter(|h| !h.trim().is_empty()).unwrap_or_else(|| "zurafa".into())).await {
            Ok(()) => json!({"id":id,"type":"ok"}),
            Err(e) => error(id, e),
        },
        Request::Snapshot { id } => {
            json!({"id":id,"type":"events.snapshot","snapshot":terms.dispatcher.snapshot()})
        }
        Request::Subscribe {
            id,
            subscription,
            filter,
        } => install(
            Registration {
                id,
                name: subscription,
                filter,
                replace: false,
            },
            terms,
            subs,
            tx,
            generation,
        ),
        Request::SubscribeAll { id, subscription } => install(
            Registration {
                id,
                name: subscription,
                filter: Filter::default(),
                replace: false,
            },
            terms,
            subs,
            tx,
            generation,
        ),
        Request::Resync { id, subscription } => match subs.get(&subscription) {
            Some(s) => install(
                Registration {
                    id,
                    name: subscription.clone(),
                    filter: s.filter.clone(),
                    replace: true,
                },
                terms,
                subs,
                tx,
                generation,
            ),
            None => error(id, "unknown subscription"),
        },
        Request::Unsubscribe { id, subscription } => {
            if subs.remove(&subscription).is_some() {
                json!({"id":id,"type":"ok"})
            } else {
                error(id, "unknown subscription")
            }
        }
        Request::Layout { id, command } => {
            // A tab keeps one docked pane: floating its only one opens a shell in its place first.
            if let Command::Float { session, block, .. } = &command {
                if terms.dispatcher.sole_docked(session, block) {
                    let (t, session, block) = (terms.clone(), session.clone(), block.clone());
                    let (cols, rows) = terms.size(&block).unwrap_or((80, 24));
                    let options = SpawnOptions { cols, rows, cwd: None, command: None, session, split: Some(block), axis: Axis::Horizontal, label: label(), raw: false, parent: None };
                    match tokio::task::spawn_blocking(move || t.spawn_at(options)).await {
                        Ok(Ok(_)) => {}
                        Ok(Err(e)) => return Some(error(id, e)),
                        Err(e) => return Some(error(id, e)),
                    }
                }
            }
            let t = terms.clone();
            match tokio::task::spawn_blocking(move || t.command(command)).await {
                Ok(Ok(())) => json!({"id":id,"type":"ok"}),
                Ok(Err(e)) => error(id, e),
                Err(e) => error(id, e),
            }
        }
        Request::Tab {
            id,
            session,
            cols,
            rows,
            cwd,
            command,
            label,
            parent,
        } => {
            let t = terms.clone();
            spawn_reply(
                id,
                tokio::task::spawn_blocking(move || {
                    t.spawn_at(SpawnOptions {
                        cols,
                        rows,
                        cwd,
                        command,
                        session,
                        split: None,
                        axis: Axis::Horizontal,
                        label,
                        raw: false,
                        parent,
                    })
                })
                .await,
            )
        }
        Request::Split {
            id,
            session,
            block,
            axis,
            cols,
            rows,
            cwd,
            command,
            parent,
        } => {
            let t = terms.clone();
            spawn_reply(
                id,
                tokio::task::spawn_blocking(move || {
                    t.spawn_at(SpawnOptions {
                        cols,
                        rows,
                        cwd,
                        command,
                        session,
                        split: Some(block),
                        axis,
                        label: label(),
                        raw: false,
                        parent,
                    })
                })
                .await,
            )
        }
        Request::Preview {
            id,
            session,
            block,
            path,
        } => {
            if !path.starts_with('/') {
                return Some(error(id, "path must be absolute"));
            }
            match terms.dispatcher.validate_target(&session, Some(&block)) {
                Ok(()) => {
                    terms
                        .dispatcher
                        .terminal_event(&block, TerminalEvent::PreviewRequested { path });
                    json!({"id":id,"type":"ok"})
                }
                Err(e) => error(id, e),
            }
        }
        Request::StatusReport {
            id,
            session,
            block,
            body,
        } => match (terms.dispatcher.validate_target(&session, Some(&block)), status::parse(&body)) {
            (Err(e), _) => error(id, e),
            (Ok(()), None) => error(id, "not a valid OSC 7501 report"),
            (Ok(()), Some(report)) => {
                terms.dispatcher.report(&block, report);
                json!({"id":id,"type":"ok"})
            }
        },
    })
}
fn spawn_reply(id: u64, result: Result<Result<String, String>, tokio::task::JoinError>) -> Value {
    match result {
        Ok(Ok(terminal)) => json!({"id":id,"type":"spawned","terminal":terminal}),
        Ok(Err(e)) => error(id, e),
        Err(e) => error(id, e),
    }
}
struct Registration {
    id: u64,
    name: String,
    filter: Filter,
    replace: bool,
}
fn install(
    registration: Registration,
    terms: &Terminals,
    subs: &mut HashMap<String, Subscription>,
    tx: &mpsc::Sender<Delivery>,
    generation: &mut u64,
) -> Value {
    let Registration {
        id,
        name,
        filter,
        replace,
    } = registration;
    if name.is_empty() || name.len() > 128 {
        return error(id, "subscription id must be 1..128 bytes");
    }
    if !replace && subs.contains_key(&name) {
        return error(id, "subscription already exists");
    }
    if !replace && subs.len() >= 64 {
        return error(id, "subscription limit is 64");
    }
    *generation += 1;
    let (snapshot, sub) = subscribe(terms, tx.clone(), name.clone(), filter, *generation);
    subs.insert(name.clone(), sub);
    json!({"id":id,"type":"events.subscribed","subscription":name,"snapshot":snapshot})
}
struct Connected {
    terms: Arc<Terminals>,
    id: String,
}
impl Drop for Connected {
    fn drop(&mut self) {
        let owned = self.terms.owners.lock().unwrap().left(&self.id);
        for (terminal, size) in owned {
            self.terms.sized(&terminal, size);
        }
        self.terms.dispatcher.client_left(&self.id);
    }
}
pub async fn handle<S>(stream: S, terms: Arc<Terminals>, principal: Value)
where
    S: AsyncRead + AsyncWrite + Send + 'static,
{
    let (mut r, mut w) = tokio::io::split(stream);
    let Some(first) = recv(&mut r).await else {
        return;
    };
    let id = first.get("id").cloned();
    let Ok(Msg::Hello {
        id,
        protocol: version @ (1 | 2),
    }) = serde_json::from_value(first)
    else {
        let _ = write_frame(
            &mut w,
            error(id, "first message must be hello with protocol 1 or 2")
                .to_string()
                .as_bytes(),
        )
        .await;
        return;
    };
    let mut output = terms.events.subscribe();
    if write_frame(
        &mut w,
        json!({"id":id,"type":"hello_ok","protocol":version,"version":env!("CARGO_PKG_VERSION"),"user":std::env::var("USER").ok(),"stale":crate::stale()})
            .to_string()
            .as_bytes(),
    )
    .await
    .is_err()
    {
        return;
    }
    let connected = Connected {
        terms: terms.clone(),
        id: terms.dispatcher.client_joined(principal),
    };
    // Dedicated reader avoids cancelling a partially read length-prefixed frame.
    let (requests, mut incoming) = mpsc::channel(32);
    let reader = tokio::spawn(async move {
        while let Some(v) = recv(&mut r).await {
            if requests.send(v).await.is_err() {
                break;
            }
        }
    });
    let (tx, mut deliveries) = mpsc::channel::<Delivery>(128);
    let (late, mut late_replies) = mpsc::channel::<Value>(8);
    let mut subs = HashMap::new();
    let mut generation = 0;
    // A remote helper only wants its own terminal's bytes, not every terminal on the host.
    let mut own: HashSet<String> = HashSet::new();
    // A waiter (`events.subscribe`, nothing attached) never reads terminal output.
    let mut waiter = false;
    loop {
        let frame = tokio::select! {
            v=incoming.recv()=>match v {
                None=>break,
                Some(v)=>{
                    if version==1 && v["type"].as_str().is_some_and(|s|s.starts_with("events.")||s.starts_with("layout.")||s.starts_with("hosts.")||s.starts_with("status.")||s.starts_with("ui.")||s.starts_with("push.")) {
                        Some(error(v.get("id"),"requires protocol 2").to_string())
                    }else{
                        let narrows = v["type"]=="attach" || (v["type"]=="spawn" && v["raw"]==true);
                        waiter |= v["type"]=="events.subscribe";
                        let r = request(v,&connected.id,&terms,&mut subs,&tx,&mut generation,&late).await;
                        if let Some(t) = r.as_ref().filter(|_|narrows).and_then(|r|r["terminal"].as_str()) {
                            own.insert(t.to_owned());
                        }
                        r.map(|v|v.to_string())
                    }
                }
            },
            v=late_replies.recv()=>v.map(|v|v.to_string()),
            d=deliveries.recv()=>match d {
                Some(d) if subs.get(&d.subscription).is_some_and(|s:&Subscription|s.generation==d.generation)=>Some(d.message.to_string()),_=>None,
            },
            event=output.recv()=>match event {
                // Skip parsing every terminal's bytes for waiters and supervisors (zurafa-orch notes, wait, follow).
                Ok(frame) if version==2 && waiter && own.is_empty() && !frame.contains("\"appearance\"") => None,
                Ok(frame)=>{
                    let mut v = serde_json::from_str::<Value>(&frame).unwrap_or_default();
                    let mine = own.is_empty() || v["terminal"].as_str().is_some_and(|t|own.contains(t));
                    let look = version==2 && v["type"]=="appearance";
                    if v["type"]=="size" {
                        // Each viewer learns whether it is the one sizing the terminal.
                        v["mine"] = json!(v["owner"]==connected.id.as_str());
                        mine.then(||v.to_string())
                    } else if look || (mine && (version==1 || v["type"]=="output")){Some(frame)}else{None}
                },
                Err(RecvError::Lagged(missed))=>Some(json!({"type":"output.gap","missed":missed}).to_string()),
                Err(RecvError::Closed)=>break,
            },
        };
        if let Some(frame) = frame {
            if write_frame(&mut w, frame.as_bytes()).await.is_err() {
                break;
            }
        }
    }
    reader.abort();
    drop(subs);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pasted_image_is_saved_with_its_type() {
        let png = save_image(b"\x89PNG rest", None).unwrap();
        assert!(png.ends_with(".png"));
        assert_eq!(std::fs::read(&png).unwrap(), b"\x89PNG rest");
        assert!(save_image(b"\xff\xd8\xff", None).unwrap().ends_with(".jpg"));
    }
    #[test]
    fn attached_file_keeps_a_shell_safe_name() {
        let pdf = save_image(b"%PDF", Some("Q3 report (final).pdf")).unwrap();
        assert!(pdf.ends_with("-Q3_report__final_.pdf"), "{pdf}");
        let sneaky = save_image(b"x", Some("../../x")).unwrap();
        assert_eq!(std::path::Path::new(&sneaky).parent(), Some(std::env::temp_dir().as_path()));
    }
    #[test]
    fn only_the_owner_sizes_a_terminal() {
        let mut o = Owners::default();
        // The first viewer owns it; a second only records its own size.
        assert_eq!(o.resize("mac", "t", (120, 40)), Some((120, 40)));
        assert_eq!(o.resize("phone", "t", (50, 30)), None);
        assert_eq!(o.resize("mac", "t", (100, 40)), Some((100, 40)));
        assert_eq!(o.owner("t"), Some("mac"));
        // Typing on the phone hands it over at the phone's size; typing again changes nothing.
        // A terminal's own answer (here to `ESC[c`) is not typing.
        assert_eq!(o.typed("phone", "t", b"\x1b[?62;22c"), None);
        assert_eq!(o.owner("t"), Some("mac"));
        assert_eq!(o.typed("phone", "t", b"l"), Some((50, 30)));
        assert_eq!(o.typed("phone", "t", b"s"), None);
        assert_eq!(o.resize("mac", "t", (90, 40)), None);
        // A client that never sized the terminal, like `zurafa send`, cannot take it by typing.
        assert_eq!(o.typed("cli", "t", b"x"), None);
        assert_eq!(o.owner("t"), Some("phone"));
        // An explicit claim takes it, at the size it brings.
        assert_eq!(o.claim("mac", "t", Some((80, 24))), Some((80, 24)));
        assert_eq!(o.owner("t"), Some("mac"));
    }
    #[test]
    fn the_terminal_falls_back_when_its_owner_goes() {
        let mut o = Owners::default();
        o.resize("mac", "t", (120, 40));
        o.resize("phone", "t", (50, 30));
        o.resize("mac", "u", (80, 24));
        o.claim("phone", "t", None);
        // A viewer that leaves without owning changes nothing.
        assert_eq!(o.release("phone", "u"), None);
        assert_eq!(o.owner("u"), Some("mac"));
        // The owner hiding it hands the terminal to the remaining viewer's size.
        assert_eq!(o.release("phone", "t"), Some((120, 40)));
        assert_eq!(o.owner("t"), Some("mac"));
        o.resize("phone", "t", (50, 30));
        o.claim("phone", "t", None);
        // Disconnecting does the same for every terminal it owned.
        assert_eq!(o.left("phone"), vec![("t".to_owned(), Some((120, 40)))]);
        let mut gone = o.left("mac");
        gone.sort();
        assert_eq!(gone, vec![("t".to_owned(), None), ("u".to_owned(), None)]);
        assert!(o.0.is_empty());
    }
    #[test]
    fn size_changes_reach_viewers_with_the_owner() {
        let terms = Terminals::new();
        let id = terms.spawn(80, 24, None, Some(vec!["/bin/cat".into()]), true).unwrap();
        let mut events = terms.events.subscribe();
        let mut size = || loop {
            let v: Value = serde_json::from_str(&events.try_recv().unwrap()).unwrap();
            if v["type"] == "size" {
                break (v["cols"].clone(), v["rows"].clone(), v["owner"].clone());
            }
        };
        let send = |client, v: Value| reply(serde_json::from_value(v).unwrap(), &terms, client);
        send("mac", json!({"type":"resize","terminal":id,"cols":100,"rows":30}));
        assert_eq!(size(), (json!(100), json!(30), json!("mac")));
        send("phone", json!({"type":"resize","terminal":id,"cols":40,"rows":30}));
        assert_eq!(size(), (json!(100), json!(30), json!("mac")));
        send("phone", json!({"type":"input","terminal":id,"data":"eA=="}));
        assert_eq!(size(), (json!(40), json!(30), json!("phone")));
        assert_eq!(terms.size(&id), Some((40, 30)));
        send("phone", json!({"type":"release","terminal":id}));
        assert_eq!(size(), (json!(100), json!(30), json!("mac")));
        terms.kill(&id).unwrap();
    }
    #[tokio::test]
    async fn floating_a_tabs_only_pane_opens_a_shell_in_its_place() {
        let terms = Terminals::new();
        let mut c = Conn::new(&terms);
        let tab = c.send(json!({"id":1,"type":"layout.tab","session":"default","cols":80,"rows":24,"command":["/bin/cat"]})).await.unwrap();
        let pane = tab["terminal"].as_str().unwrap().to_string();
        let got = c.send(json!({"id":2,"type":"layout.command","command":{"op":"float","session":"default","block":pane}})).await.unwrap();
        assert_eq!(got["type"], "ok", "{got}");
        let s = terms.dispatcher.snapshot().sessions["default"].clone();
        let w = s.windows.iter().find(|w| w.floating.iter().any(|f| f.block_id == pane)).expect("pane floats");
        assert!(matches!(&w.layout, zurafa_events::Layout::Block { block_id } if *block_id != pane), "a new shell is docked behind it: {:?}", w.layout);
        for b in s.blocks.keys() { let _ = terms.kill(b); }
    }
    #[tokio::test]
    async fn appearance_is_kept_and_broadcast() {
        let terms = Terminals::new();
        let mut events = terms.events.subscribe();
        let (tx, _rx) = mpsc::channel(1);
        let (late, _late_rx) = mpsc::channel(1);
        let (mut subs, mut generation) = (HashMap::new(), 0);
        let look = json!({"mode":"dark"});
        request(json!({"id":1,"type":"ui.appearance","appearance":look}), "c", &terms, &mut subs, &tx, &mut generation, &late).await;
        let sent: Value = serde_json::from_str(&events.recv().await.unwrap()).unwrap();
        assert_eq!(sent, json!({"type":"appearance","appearance":look}));
        let got = request(json!({"id":2,"type":"ui.appearance"}), "c", &terms, &mut subs, &tx, &mut generation, &late).await.unwrap();
        assert_eq!(got["appearance"], look);
    }
    /// One client connection's request path: what `handle` gives `request` for it.
    struct Conn {
        terms: Arc<Terminals>,
        subs: HashMap<String, Subscription>,
        tx: mpsc::Sender<Delivery>,
        generation: u64,
        late: mpsc::Sender<Value>,
        late_rx: mpsc::Receiver<Value>,
        id: String,
    }
    impl Conn {
        fn new(terms: &Arc<Terminals>) -> Self {
            let (late, late_rx) = mpsc::channel(8);
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let id = format!("conn{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
            Self { terms: terms.clone(), subs: HashMap::new(), tx: mpsc::channel(1).0, generation: 0, late, late_rx, id }
        }
        async fn send(&mut self, v: Value) -> Option<Value> {
            request(v, &self.id, &self.terms, &mut self.subs, &self.tx, &mut self.generation, &self.late).await
        }
        async fn next(&mut self) -> Value {
            tokio::time::timeout(std::time::Duration::from_secs(2), self.late_rx.recv()).await.unwrap().unwrap()
        }
    }
    fn register(actions: Value) -> Value {
        json!({"id":1,"type":"ui.actions.register","label":"Zurafa","actions":actions})
    }
    #[tokio::test]
    async fn action_goes_to_the_app_and_its_answer_comes_back() {
        let terms = Terminals::new();
        let (mut app, mut cli) = (Conn::new(&terms), Conn::new(&terms));
        let got = app.send(register(json!([{"name":"tab.select","title":"Select Tab"}]))).await.unwrap();
        assert_eq!(got["client"], "c1");
        let list = cli.send(json!({"id":1,"type":"ui.actions.list"})).await.unwrap();
        assert_eq!(list["clients"][0]["actions"][0]["name"], "tab.select");
        assert!(cli.send(json!({"id":2,"type":"ui.actions.run","action":"tab.select","args":{"tab":"2"}})).await.is_none());
        let call = app.next().await;
        assert_eq!((call["type"].as_str(), call["args"]["tab"].as_str()), (Some("ui.action"), Some("2")));
        // Another connection cannot answer for the app.
        let spoof = cli.send(json!({"id":3,"type":"ui.action.result","call":call["call"],"ok":true})).await.unwrap();
        assert_eq!(spoof["type"], "error");
        assert!(app.send(json!({"type":"ui.action.result","call":call["call"],"ok":true,"message":"Selected tab 2"})).await.is_none());
        let done = cli.next().await;
        assert_eq!((done["id"].as_u64(), done["type"].as_str(), done["message"].as_str()), (Some(2), Some("ui.actions.done"), Some("Selected tab 2")));
        // The app's refusal reaches the caller as an error.
        cli.send(json!({"id":4,"type":"ui.actions.run","action":"tab.select","args":{"tab":"9"}})).await;
        let call = app.next().await;
        app.send(json!({"type":"ui.action.result","call":call["call"],"ok":false,"message":"no tab 9"})).await;
        assert_eq!(cli.next().await, json!({"id":4,"type":"error","message":"no tab 9"}));
        let unknown = { cli.send(json!({"id":5,"type":"ui.actions.run","action":"app.quit"})).await; cli.next().await };
        assert!(unknown["message"].as_str().unwrap().contains("no action \"app.quit\""));
    }
    #[tokio::test]
    async fn action_fails_without_an_app_while_disabled_and_on_timeout() {
        let terms = Terminals::new();
        let mut cli = Conn::new(&terms);
        let run = json!({"id":1,"type":"ui.actions.run","action":"tab.select","timeout_ms":50});
        cli.send(run.clone()).await;
        assert!(cli.next().await["message"].as_str().unwrap().contains("no Zurafa app"));
        let mut app = Conn::new(&terms);
        app.send(register(json!([]))).await;
        cli.send(run.clone()).await;
        assert_eq!(cli.next().await["message"], crate::actions::DISABLED);
        app.send(register(json!([{"name":"tab.select"}]))).await;
        cli.send(run.clone()).await;
        assert_eq!(app.next().await["type"], "ui.action");
        assert!(cli.next().await["message"].as_str().unwrap().contains("did not answer"));
        // A second app makes the caller pick one; a closed app drops out.
        let mut other = Conn::new(&terms);
        other.send(register(json!([{"name":"tab.select"}]))).await;
        cli.send(run.clone()).await;
        assert!(cli.next().await["message"].as_str().unwrap().contains("-C: c1 (Zurafa), c2 (Zurafa)"));
        cli.send(json!({"id":2,"type":"ui.actions.run","action":"tab.select","client":"c2","timeout_ms":50})).await;
        assert_eq!(other.next().await["type"], "ui.action");
        drop(other);
        cli.next().await;
        let list = cli.send(json!({"id":3,"type":"ui.actions.list"})).await.unwrap();
        assert_eq!(list["clients"].as_array().unwrap().len(), 1);
    }
    #[tokio::test]
    async fn lag_is_explicit_and_resync_replaces_receiver() {
        let terms = Terminals::new();
        let (tx, mut rx) = mpsc::channel(1);
        let mut subs = HashMap::new();
        let mut generation = 0;
        let before = install(
            Registration {
                id: 1,
                name: "s".into(),
                filter: Filter::default(),
                replace: false,
            },
            &terms,
            &mut subs,
            &tx,
            &mut generation,
        );
        for n in 0..1100 {
            terms
                .dispatcher
                .command(Command::Label {
                    session: "default".into(),
                    window: None,
                    label: n.to_string(),
                })
                .unwrap();
        }
        let delivery = rx.recv().await.unwrap();
        assert_eq!(delivery.message["type"], "events.gap");
        assert_eq!(
            delivery.message["after_sequence"],
            before["snapshot"]["sequence"]
        );
        let after = install(
            Registration {
                id: 2,
                name: "s".into(),
                filter: Filter::default(),
                replace: true,
            },
            &terms,
            &mut subs,
            &tx,
            &mut generation,
        );
        assert_eq!(after["snapshot"]["sessions"]["default"]["label"], "1099");
        terms
            .dispatcher
            .command(Command::Label {
                session: "default".into(),
                window: None,
                label: "next".into(),
            })
            .unwrap();
        let delivery = rx.recv().await.unwrap();
        assert_eq!(delivery.generation, generation);
        assert_eq!(
            delivery.message["event"]["sequence"].as_u64().unwrap(),
            after["snapshot"]["sequence"].as_u64().unwrap() + 1
        );
    }
    #[tokio::test]
    async fn stalled_subscription_does_not_block_output_or_other_subscribers() {
        let terms = Terminals::new();
        let (slow_tx, _slow_rx) = mpsc::channel(1);
        let (fast_tx, mut fast_rx) = mpsc::channel(8);
        let (_, slow) = subscribe(&terms, slow_tx, "slow".into(), Filter::default(), 1);
        let (_, fast) = subscribe(&terms, fast_tx, "fast".into(), Filter::default(), 1);
        let mut output = terms.events.subscribe();
        for n in 0..20 {
            terms
                .dispatcher
                .command(Command::Label {
                    session: "default".into(),
                    window: None,
                    label: n.to_string(),
                })
                .unwrap();
            assert_eq!(
                fast_rx.recv().await.unwrap().message["type"],
                "events.event"
            );
            assert_eq!(
                fast_rx.recv().await.unwrap().message["type"],
                "events.event"
            );
            terms.events.send("pty bytes".into()).unwrap();
            assert_eq!(output.recv().await.unwrap(), "pty bytes");
        }
        drop((slow, fast));
    }
}
