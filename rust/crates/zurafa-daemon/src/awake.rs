//! Keeps the Mac out of idle sleep while the app's tailnet listener is on and something needs the
//! Mac: another device is connected, or an agent is working. Sleep with the lid closed is the
//! app's own opt-in setting (`pmset disablesleep`); this only covers idle sleep.
use crate::pty::Terminals;
use serde_json::Value;
use std::{process::Child, sync::Arc, time::Duration};

/// A device connected over the network (local clients have no principal), or an agent working.
fn needed(snapshot: &Value) -> bool {
    let entries = |v: &Value| v.as_object().into_iter().flat_map(|m| m.values()).cloned().collect::<Vec<_>>();
    let remote = entries(&snapshot["clients"]).iter().any(|c| !c["principal"].is_null());
    let working = entries(&snapshot["sessions"])
        .iter()
        .flat_map(|s| entries(&s["blocks"]))
        .flat_map(|b| entries(&b["statuses"]["records"]))
        .any(|r| r["state"] == "working");
    remote || working
}

pub fn run(terms: Arc<Terminals>) {
    if !cfg!(target_os = "macos") {
        return;
    }
    tokio::spawn(async move {
        // shortcut: polls every 10 s and runs `caffeinate -i` instead of holding an IOKit assertion; switch if 10 s ever matters.
        let mut caffeinate: Option<Child> = None;
        loop {
            let listening = !crate::listen::switched_addresses().await.is_empty();
            let want = listening && serde_json::to_value(terms.dispatcher.snapshot()).is_ok_and(|s| needed(&s));
            match (caffeinate.as_mut(), want) {
                // -w: caffeinate also ends if this daemon dies.
                (None, true) => {
                    caffeinate = std::process::Command::new("/usr/bin/caffeinate")
                        .args(["-i", "-w", &std::process::id().to_string()])
                        .spawn()
                        .ok()
                }
                (Some(c), false) => {
                    let _ = c.kill();
                    let _ = c.wait();
                    caffeinate = None;
                }
                _ => {}
            }
            tokio::time::sleep(Duration::from_secs(10)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn needed_for_remote_devices_and_working_agents_only() {
        assert!(!needed(&json!({"clients":{"c1":{"principal":null}},"sessions":{}})));
        assert!(needed(&json!({"clients":{"c1":{"principal":{"kind":"tailnet"}}},"sessions":{}})));
        let working = json!({"clients":{},"sessions":{"s":{"blocks":{"b":{"statuses":{"records":{"":{"state":"working"}}}}}}}});
        assert!(needed(&working));
        let done = json!({"clients":{},"sessions":{"s":{"blocks":{"b":{"statuses":{"records":{"":{"state":"done"}}}}}}}});
        assert!(!needed(&done));
    }
}
