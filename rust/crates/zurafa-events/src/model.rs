use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Owner {
    pub pid: u32,
    pub name: String,
}
/// The reference leaves process details beyond these fields unspecified.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Process {
    pub name: String,
    pub cwd: String,
    pub pid: u32,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ClientInfo {
    pub kind: String,
    pub name: String,
    pub platform: String,
    pub version: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Client {
    pub client_id: String,
    pub info: ClientInfo,
    // Rex documents these fields but does not constrain their JSON representation.
    pub principal: serde_json::Value,
    pub connected_at: serde_json::Value,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionInfo {
    pub session_id: String,
    pub label: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum SessionEvent {
    WindowCreated {
        window_id: String,
        label: String,
    },
    WindowClosed {
        window_id: String,
    },
    WindowLabelChanged {
        window_id: String,
        label: String,
    },
    ActiveWindowChanged {
        window_id: String,
    },
    BlockCreated {
        block_id: String,
    },
    BlockClosed {
        block_id: String,
    },
    SessionLabelChanged {
        label: String,
    },
    SessionViewChanged {
        revision: u64,
    },
    ClientConnected {
        client_id: String,
        principal: serde_json::Value,
        connected_at: serde_json::Value,
    },
    ClientDisconnected {
        client_id: String,
        principal: serde_json::Value,
    },
    ClientConnectionChanged {
        client_id: String,
        principal: serde_json::Value,
        connection_state: String,
    },
    CreatorChanged {},
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "name", content = "payload", rename_all = "snake_case")]
pub enum TerminalEvent {
    ChildExited {
        exit_code: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    PwdChanged {
        pwd: String,
        owner: Option<Owner>,
    },
    TitleChanged {
        title: String,
        owner: Option<Owner>,
    },
    Bell {},
    ProcessChanged {
        generation: u64,
        foreground: Option<Process>,
        ancestors: Vec<Process>,
    },
    DesktopNotification {
        title: String,
        body: String,
    },
    ProgressReport {
        state: u8,
        progress: Option<u8>,
    },
    ClipboardWritten {
        text: String,
    },
    PreviewRequested {
        path: String,
    },
    ProgramStatusChanged {
        id: String,
        record: crate::status::Record,
        reason: String,
        /// The pane's turn after this change (see `status::Records::turn`).
        #[serde(default)]
        turn: u64,
    },
    ProgramStatusRemoved {
        ids: Vec<String>,
        reason: String,
        #[serde(default)]
        turn: u64,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ServerEvent {
    SessionCreated { session: SessionInfo },
    SessionDestroyed { session_id: String },
    ClientJoined { client: Client },
    ClientLeft { client_id: String },
    ClientChanged { client: Client },
    KeymapChanged { generation: u64, hash: String },
    HostsChanged { hash: String },
    TailscaleStatusChanged {},
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub enum BlockEventType {
    #[default]
    #[serde(rename = "block_event")]
    BlockEvent,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "category", rename_all = "snake_case")]
pub enum Event {
    Session {
        session_id: String,
        #[serde(flatten)]
        event: SessionEvent,
    },
    Terminal {
        session_id: String,
        block_id: String,
        creator_name: String,
        #[serde(rename = "type")]
        kind: BlockEventType,
        #[serde(flatten)]
        event: TerminalEvent,
    },
    Server {
        #[serde(flatten)]
        event: ServerEvent,
    },
}
impl Event {
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Self::Session { session_id, .. } | Self::Terminal { session_id, .. } => {
                Some(session_id)
            }
            Self::Server {
                event: ServerEvent::SessionCreated { session },
            } => Some(&session.session_id),
            Self::Server {
                event: ServerEvent::SessionDestroyed { session_id },
            } => Some(session_id),
            _ => None,
        }
    }
    pub fn name(&self) -> String {
        let v = serde_json::to_value(self).expect("event serialization");
        if matches!(self, Self::Terminal { .. }) {
            format!("terminal.{}", v["name"].as_str().unwrap())
        } else {
            v["type"].as_str().unwrap().to_owned()
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct Filter {
    pub session: Option<String>,
    pub block: Option<String>,
    pub category: Option<Category>,
    pub name: Option<String>,
    /// OR alternatives, combined with the legacy `name` field when present.
    /// Omission imposes no name constraint; an explicit empty list matches none.
    pub types: Option<Vec<String>>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    Session,
    Terminal,
    Server,
}
impl Filter {
    pub fn matches(&self, e: &Event) -> bool {
        self.session
            .as_deref()
            .is_none_or(|s| e.session_id() == Some(s))
            && self
                .block
                .as_deref()
                .is_none_or(|b| matches!(e, Event::Terminal{block_id,..} if block_id==b))
            && self.category.as_ref().is_none_or(|c| {
                matches!(
                    (c, e),
                    (Category::Session, Event::Session { .. })
                        | (Category::Terminal, Event::Terminal { .. })
                        | (Category::Server, Event::Server { .. })
                )
            })
            && if self.name.is_none() && self.types.is_none() {
                true
            } else {
                let name = e.name();
                self.name.as_ref().is_some_and(|n| n == &name)
                    || self
                        .types
                        .as_ref()
                        .is_some_and(|names| names.contains(&name))
            }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    #[test]
    fn every_reference_payload_round_trips() {
        let session = [
            json!({"type":"window_created","payload":{"window_id":"w","label":"work"}}),
            json!({"type":"window_closed","payload":{"window_id":"w"}}),
            json!({"type":"window_label_changed","payload":{"window_id":"w","label":"work"}}),
            json!({"type":"active_window_changed","payload":{"window_id":"w"}}),
            json!({"type":"block_created","payload":{"block_id":"b"}}),
            json!({"type":"block_closed","payload":{"block_id":"b"}}),
            json!({"type":"session_label_changed","payload":{"label":"work"}}),
            json!({"type":"session_view_changed","payload":{"revision":2}}),
            json!({"type":"client_connected","payload":{"client_id":"c","principal":null,"connected_at":123}}),
            json!({"type":"client_disconnected","payload":{"client_id":"c","principal":null}}),
            json!({"type":"client_connection_changed","payload":{"client_id":"c","principal":null,"connection_state":"connected"}}),
            json!({"type":"creator_changed","payload":{}}),
        ];
        for v in session {
            let e: SessionEvent = serde_json::from_value(v.clone()).unwrap();
            assert_eq!(serde_json::to_value(e).unwrap(), v);
        }
        let client = json!({"client_id":"c","info":{"kind":"ipc","name":"n","platform":"macos","version":"1"},"principal":null,"connected_at":123});
        let server = [
            json!({"type":"session_created","payload":{"session":{"session_id":"s","label":"work"}}}),
            json!({"type":"session_destroyed","payload":{"session_id":"s"}}),
            json!({"type":"client_joined","payload":{"client":client}}),
            json!({"type":"client_left","payload":{"client_id":"c"}}),
            json!({"type":"client_changed","payload":{"client":client}}),
            json!({"type":"keymap_changed","payload":{"generation":1,"hash":"a"}}),
            json!({"type":"hosts_changed","payload":{"hash":"a"}}),
            json!({"type":"tailscale_status_changed","payload":{}}),
        ];
        for v in server {
            let e: ServerEvent = serde_json::from_value(v.clone()).unwrap();
            assert_eq!(serde_json::to_value(e).unwrap(), v);
        }
        let terminal = [
            json!({"name":"child_exited","payload":{"exit_code":0}}),
            json!({"name":"child_exited","payload":{"exit_code":2,"error":"exit status 2"}}),
            json!({"name":"pwd_changed","payload":{"pwd":"file://host/path","owner":{"pid":2,"name":"sh"}}}),
            json!({"name":"title_changed","payload":{"title":"work","owner":null}}),
            json!({"name":"bell","payload":{}}),
            json!({"name":"process_changed","payload":{"generation":1,"foreground":null,"ancestors":[]}}),
            json!({"name":"desktop_notification","payload":{"title":"t","body":"b"}}),
            json!({"name":"progress_report","payload":{"state":1,"progress":20}}),
            json!({"name":"clipboard_written","payload":{"text":"copy"}}),
            json!({"name":"preview_requested","payload":{"path":"/tmp/a.md"}}),
            json!({"name":"program_status_changed","payload":{"id":"a","record":{"state":"working"},"reason":"report","turn":0}}),
            json!({"name":"program_status_removed","payload":{"ids":["a"],"reason":"clear","turn":1}}),
        ];
        for v in terminal {
            let e: TerminalEvent = serde_json::from_value(v.clone()).unwrap();
            assert_eq!(serde_json::to_value(e).unwrap(), v);
        }
    }
    #[test]
    fn filters_combine_and_unknown_names_match_nothing() {
        let e = Event::Terminal {
            session_id: "s".into(),
            block_id: "b".into(),
            creator_name: "com.superlogical.terminal".into(),
            kind: BlockEventType::BlockEvent,
            event: TerminalEvent::Bell {},
        };
        for v in [
            json!({}),
            json!({"session":"s"}),
            json!({"block":"b"}),
            json!({"category":"terminal"}),
            json!({"name":"terminal.bell"}),
            json!({"session":"s","block":"b","name":"terminal.bell","category":"terminal"}),
        ] {
            let f: Filter = serde_json::from_value(v).unwrap();
            assert!(f.matches(&e));
        }
        for v in [
            json!({"session":"x"}),
            json!({"block":"x"}),
            json!({"category":"server"}),
            json!({"name":"future"}),
        ] {
            let f: Filter = serde_json::from_value(v).unwrap();
            assert!(!f.matches(&e));
        }
        let encoded: Value = serde_json::to_value(&e).unwrap();
        assert_eq!(serde_json::from_value::<Event>(encoded).unwrap(), e);
    }
    #[test]
    fn plural_names_match_any_selected_name_and_preserve_other_constraints() {
        let filter: Filter = serde_json::from_value(json!({
            "session":"s", "block":"b", "category":"terminal",
            "types":["terminal.bell", "terminal.title_changed"]
        }))
        .unwrap();
        let event = |event| Event::Terminal {
            session_id: "s".into(),
            block_id: "b".into(),
            creator_name: "com.superlogical.terminal".into(),
            kind: BlockEventType::BlockEvent,
            event,
        };
        let bell = event(TerminalEvent::Bell {});
        let title = event(TerminalEvent::TitleChanged {
            title: "Build".into(),
            owner: None,
        });
        let pwd = event(TerminalEvent::PwdChanged {
            pwd: "file://host/tmp".into(),
            owner: None,
        });
        assert!(filter.matches(&bell));
        assert!(filter.matches(&title));
        assert!(!filter.matches(&pwd));
        for mismatched in [
            Filter {
                session: Some("other".into()),
                ..filter.clone()
            },
            Filter {
                block: Some("other".into()),
                ..filter.clone()
            },
            Filter {
                category: Some(Category::Server),
                ..filter.clone()
            },
        ] {
            assert!(!mismatched.matches(&bell));
        }
        let encoded = serde_json::to_value(&filter).unwrap();
        assert_eq!(
            encoded["types"],
            json!(["terminal.bell", "terminal.title_changed"])
        );
        assert_eq!(serde_json::from_value::<Filter>(encoded).unwrap(), filter);

        // `name` remains a compatible additional alternative, not an intersection.
        let combined = Filter {
            name: Some("terminal.pwd_changed".into()),
            ..filter
        };
        assert!(combined.matches(&bell));
        assert!(combined.matches(&title));
        assert!(combined.matches(&pwd));
        let empty: Filter = serde_json::from_value(json!({"types":[]})).unwrap();
        assert!(!empty.matches(&bell));
        let legacy = Filter {
            name: Some("terminal.bell".into()),
            ..empty
        };
        assert!(legacy.matches(&bell));
        assert!(!legacy.matches(&title));
        let unknown: Filter = serde_json::from_value(json!({"types":["future"]})).unwrap();
        assert!(!unknown.matches(&bell));
    }
}
