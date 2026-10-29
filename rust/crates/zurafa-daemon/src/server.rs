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
fn error(id: impl Serialize, message: impl ToString) -> Value {
    json!({"id":id,"type":"error","message":message.to_string()})
}
fn reply(msg: Msg, t: &Arc<Terminals>) -> Option<Value> {
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
                t.input(&terminal, &bytes);
            }
            return None;
        }
        Msg::Resize {
            terminal,
            cols,
            rows,
        } => {
            t.resize(&terminal, cols, rows);
            return None;
        }
    })
}
#[derive(Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
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
    terms: &Arc<Terminals>,
    subs: &mut HashMap<String, Subscription>,
    tx: &mpsc::Sender<Delivery>,
    generation: &mut u64,
    late: &mpsc::Sender<Value>,
) -> Option<Value> {
    let id = v.get("id").cloned();
    let ty = v.get("type").and_then(Value::as_str).unwrap_or("");
    if !ty.starts_with("events.") && !ty.starts_with("layout.") && !ty.starts_with("hosts.") && !ty.starts_with("status.") {
        let t = terms.clone();
        return match serde_json::from_value::<Msg>(v) {
            Ok(m) => tokio::task::spawn_blocking(move || reply(m, &t))
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
        json!({"id":id,"type":"hello_ok","protocol":version,"version":env!("CARGO_PKG_VERSION"),"user":std::env::var("USER").ok()})
            .to_string()
            .as_bytes(),
    )
    .await
    .is_err()
    {
        return;
    }
    let _connected = Connected {
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
    loop {
        let frame = tokio::select! {
            v=incoming.recv()=>match v {
                None=>break,
                Some(v)=>{
                    if version==1 && v["type"].as_str().is_some_and(|s|s.starts_with("events.")||s.starts_with("layout.")||s.starts_with("hosts.")||s.starts_with("status.")) {
                        Some(error(v.get("id"),"requires protocol 2").to_string())
                    }else{
                        let narrows = v["type"]=="attach" || (v["type"]=="spawn" && v["raw"]==true);
                        let r = request(v,&terms,&mut subs,&tx,&mut generation,&late).await;
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
                Ok(frame)=>{
                    let v = serde_json::from_str::<Value>(&frame).unwrap_or_default();
                    let mine = own.is_empty() || v["terminal"].as_str().is_some_and(|t|own.contains(t));
                    if mine && (version==1 || v["type"]=="output"){Some(frame)}else{None}
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
