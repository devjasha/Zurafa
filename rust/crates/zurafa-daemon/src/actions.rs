//! Client actions: a connected app (the Mac app) registers UI actions, and another client
//! (the CLI) asks the daemon to run one there. The daemon only routes; the app validates.
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Mutex, time::Duration};
use tokio::sync::{mpsc, oneshot};

pub const DISABLED: &str = "Zurafa does not allow agents to control it. Turn on \
Settings → Integrations → Allow agents to control Zurafa.";
const NO_APP: &str = "no Zurafa app is connected to this server";

struct App {
    client: String,
    label: String,
    actions: Vec<Value>,
    /// The app connection's own reply channel, so frames reach it in order with its replies.
    tx: mpsc::Sender<Value>,
}

#[derive(Default)]
struct Inner {
    clients: u64,
    calls_made: u64,
    apps: Vec<App>,
    calls: HashMap<u64, (mpsc::Sender<Value>, oneshot::Sender<Result<String, String>>)>,
}

#[derive(Default)]
pub struct Apps(Mutex<Inner>);

impl Apps {
    /// Registers or replaces the actions of the connection behind `tx`; no actions means control is off.
    pub fn register(&self, tx: &mpsc::Sender<Value>, label: String, actions: Vec<Value>) -> Result<String, String> {
        if actions.len() > 64 || actions.iter().any(|a| a["name"].as_str().is_none_or(str::is_empty)) {
            return Err("actions must be at most 64, each with a name".into());
        }
        let mut s = self.0.lock().unwrap();
        s.apps.retain(|a| !a.tx.is_closed());
        let label: String = label.chars().take(128).collect();
        if let Some(app) = s.apps.iter_mut().find(|a| a.tx.same_channel(tx)) {
            (app.label, app.actions) = (label, actions);
            return Ok(app.client.clone());
        }
        s.clients += 1;
        let client = format!("c{}", s.clients);
        s.apps.push(App { client: client.clone(), label, actions, tx: tx.clone() });
        Ok(client)
    }

    pub fn list(&self) -> Value {
        let mut s = self.0.lock().unwrap();
        s.apps.retain(|a| !a.tx.is_closed());
        s.apps.iter().map(|a| json!({"client":a.client,"label":a.label,"enabled":!a.actions.is_empty(),"actions":a.actions})).collect()
    }

    /// Sends `action` to one app and waits for its answer.
    pub async fn run(&self, client: Option<&str>, action: &str, args: Value, timeout: Duration) -> Result<String, String> {
        let (call, rx) = {
            let mut s = self.0.lock().unwrap();
            s.apps.retain(|a| !a.tx.is_closed());
            if s.apps.is_empty() {
                return Err(NO_APP.into());
            }
            let picked: Vec<&App> = match client {
                Some(c) => s.apps.iter().filter(|a| a.client == c || a.label.eq_ignore_ascii_case(c)).collect(),
                None => s.apps.iter().filter(|a| !a.actions.is_empty()).collect(),
            };
            let app = match picked[..] {
                [] if client.is_some() => return Err(format!("no app client {:?}; run `zurafa actions` to list them", client.unwrap())),
                [] => return Err(DISABLED.into()),
                [app] => app,
                _ => {
                    let names: Vec<String> = picked.iter().map(|a| format!("{} ({})", a.client, a.label)).collect();
                    return Err(format!("several Zurafa apps are connected; pick one with -C: {}", names.join(", ")));
                }
            };
            if app.actions.is_empty() {
                return Err(DISABLED.into());
            }
            if !app.actions.iter().any(|a| a["name"] == action) {
                return Err(format!("{} has no action {action:?}; run `zurafa actions` to list them", app.label));
            }
            let tx = app.tx.clone();
            s.calls_made += 1;
            let call = s.calls_made;
            tx.try_send(json!({"type":"ui.action","call":call,"action":action,"args":args}))
                .map_err(|_| "the Zurafa app is busy; try again".to_string())?;
            let (done, rx) = oneshot::channel();
            s.calls.insert(call, (tx, done));
            (call, rx)
        };
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("the Zurafa app went away".into()),
            Err(_) => {
                self.0.lock().unwrap().calls.remove(&call);
                Err(format!("the Zurafa app did not answer within {}s", timeout.as_secs_f32()))
            }
        }
    }

    /// An app's answer to `call`; only the connection the call went to may answer it.
    pub fn answer(&self, tx: &mpsc::Sender<Value>, call: u64, result: Result<String, String>) -> bool {
        let mut s = self.0.lock().unwrap();
        if !s.calls.get(&call).is_some_and(|(to, _)| to.same_channel(tx)) {
            return false;
        }
        let (_, done) = s.calls.remove(&call).unwrap();
        let _ = done.send(result);
        true
    }
}
