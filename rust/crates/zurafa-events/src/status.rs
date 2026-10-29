//! OSC 7501 revision 0.3 validation and terminal-local record lifecycle.
use crate::TerminalEvent;
use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
    Engine,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Permission,
    Question,
    Auth,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Record {
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<Kind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub enum Report {
    Query,
    Clear(String),
    Set(String, Record),
}
fn segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
}
fn decode(s: &str, encoded: usize, decoded: usize) -> Option<String> {
    if s.len() > encoded {
        return None;
    }
    let bytes = STANDARD
        .decode(s)
        .or_else(|_| STANDARD_NO_PAD.decode(s))
        .ok()?;
    if bytes.len() > decoded {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    (!text.chars().any(char::is_control)).then_some(text)
}
pub fn parse(body: &str) -> Option<Report> {
    if body.len() + 8 > 4096 {
        return None;
    }
    if body == "?" {
        return Some(Report::Query);
    }
    // Only the old semicolon grammar enables literal `message` and `completed`.
    let legacy =
        body.find(';').is_some_and(|n| !body[..n].contains(':')) || body == "state=completed";
    let mut pairs = HashMap::new();
    for pair in body.split(if legacy { ';' } else { ':' }) {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim());
        if k.len() > 16 {
            return None;
        }
        if k.is_empty() || !k.bytes().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        // An explicitly malformed ID must never silently become the root ID.
        if k == "id" && !v.split('/').all(segment) {
            return None;
        }
        if !legacy
            && !v
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b))
        {
            continue;
        }
        // Validate every pair, even one superseded by a later occurrence.
        match k {
            "msg" => {
                decode(v, 2732, 2048)?;
            }
            "title" => {
                decode(v, 256, 192)?;
            }
            "app" if v.len() > 32 => return None,
            "id" if v.len() > 128
                || v.split('/').count() > 8
                || v.split('/').any(|s| s.len() > 32) =>
            {
                return None
            }
            _ => (),
        }
        pairs.insert(k, v);
    }
    let id = pairs.get("id").copied().unwrap_or("");
    if pairs.contains_key("id") && !id.split('/').all(segment) {
        return None;
    }
    let state = match *pairs.get("state")? {
        "clear" => return Some(Report::Clear(id.into())),
        "idle" => State::Idle,
        "working" => State::Working,
        "done" => State::Done,
        "blocked" => State::Blocked,
        "error" => State::Error,
        "completed" if legacy => State::Done,
        _ => return None,
    };
    let kind = if state == State::Blocked {
        match pairs.get("kind").copied() {
            Some("permission") => Some(Kind::Permission),
            Some("question") => Some(Kind::Question),
            Some("auth") => Some(Kind::Auth),
            _ => None,
        }
    } else {
        None
    };
    let progress = if matches!(state, State::Working | State::Blocked) {
        pairs
            .get("progress")
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse::<u8>().ok())
            .filter(|p| *p <= 100)
    } else {
        None
    };
    let msg = if let Some(s) = pairs.get("msg") {
        Some(decode(s, 2732, 2048)?)
    } else if legacy {
        let m = pairs.get("message").map(|s| s.to_string());
        if m.as_ref()
            .is_some_and(|s| s.len() > 2048 || s.chars().any(char::is_control))
        {
            return None;
        }
        m
    } else {
        None
    };
    Some(Report::Set(
        id.into(),
        Record {
            state,
            kind,
            progress,
            app: pairs
                .get("app")
                .filter(|s| segment(s))
                .map(|s| s.to_string()),
            title: match pairs.get("title") {
                Some(s) => Some(decode(s, 256, 192)?),
                None => None,
            },
            msg,
        },
    ))
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Records {
    pub records: BTreeMap<String, Record>,
    /// Goes up each time the root record leaves `working`, for any reason.
    #[serde(default)]
    pub turn: u64,
    /// The program has reported a status; until then it is still starting.
    #[serde(default)]
    pub reported: bool,
    #[serde(skip)]
    order: BTreeMap<String, u64>,
    #[serde(skip)]
    clock: u64,
}
impl Records {
    pub fn effective_app(&self, id: &str) -> Option<&str> {
        let mut current = id;
        loop {
            if let Some(app) = self.records.get(current).and_then(|r| r.app.as_deref()) {
                return Some(app);
            }
            if current.is_empty() {
                return None;
            }
            current = current.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
        }
    }
    fn root_working(&self) -> bool {
        self.records.get("").is_some_and(|r| r.state == State::Working)
    }
    /// Counts a turn that just ended and stamps the events with the turn.
    fn end_turn(&mut self, was_working: bool, mut events: Vec<TerminalEvent>) -> Vec<TerminalEvent> {
        if was_working && !self.root_working() {
            self.turn += 1;
        }
        for e in &mut events {
            if let TerminalEvent::ProgramStatusChanged { turn, .. }
            | TerminalEvent::ProgramStatusRemoved { turn, .. } = e
            {
                *turn = self.turn;
            }
        }
        events
    }
    fn remove(&mut self, ids: Vec<String>, reason: &str) -> Vec<TerminalEvent> {
        for id in &ids {
            self.records.remove(id);
            self.order.remove(id);
        }
        if ids.is_empty() {
            vec![]
        } else {
            vec![TerminalEvent::ProgramStatusRemoved {
                ids,
                reason: reason.into(),
                turn: self.turn,
            }]
        }
    }
    pub fn lifecycle(&mut self, reason: &str) -> Vec<TerminalEvent> {
        let was_working = self.root_working();
        let ids = self
            .records
            .iter()
            .filter(|(_, r)| {
                reason == "reset" || matches!(r.state, State::Working | State::Blocked)
            })
            .map(|(id, _)| id.clone())
            .collect();
        let events = self.remove(ids, reason);
        self.end_turn(was_working, events)
    }
    pub fn apply(&mut self, report: Report) -> Vec<TerminalEvent> {
        let was_working = self.root_working();
        // Only a status counts: Claude's SessionStart hook clears its subagents before any turn.
        self.reported |= matches!(report, Report::Set(..));
        let events = match report {
            Report::Query => vec![],
            Report::Clear(id) => {
                let prefix = format!("{id}/");
                let ids = self
                    .records
                    .keys()
                    .filter(|k| id.is_empty() || **k == id || k.starts_with(&prefix))
                    .cloned()
                    .collect();
                self.remove(ids, "clear")
            }
            Report::Set(id, mut record) => {
                // Claude Code reports done itself right after its Stop hook reported done with the
                // answer; a report that only repeats the state keeps the message it would wipe.
                if let Some(old) = self.records.get(&id).filter(|o| o.state == record.state) {
                    record.msg = record.msg.or_else(|| old.msg.clone());
                }
                let mut events = vec![];
                if !self.records.contains_key(&id) && self.records.len() >= 256 {
                    // Deserialized snapshots omit update order; treat their untouched
                    // records as older than any subsequent local report.
                    let old = self
                        .records
                        .keys()
                        .find(|id| !self.order.contains_key(*id))
                        .cloned()
                        .unwrap_or_else(|| {
                            self.order.iter().min_by_key(|(_, v)| *v).unwrap().0.clone()
                        });
                    events.extend(self.remove(vec![old], "capacity"));
                }
                self.clock += 1;
                self.order.insert(id.clone(), self.clock);
                self.records.insert(id.clone(), record.clone());
                events.push(TerminalEvent::ProgramStatusChanged {
                    id,
                    record,
                    reason: "report".into(),
                    turn: self.turn,
                });
                events
            }
        };
        self.end_turn(was_working, events)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replacement_hierarchy_and_lifetime() {
        let mut r = Records::default();
        for s in [
            "state=done:app=cargo",
            "state=blocked:id=a:kind=auth:msg=aGk",
            "state=working:id=a/b",
        ] {
            r.apply(parse(s).unwrap());
        }
        assert_eq!(r.effective_app("a/b"), Some("cargo"));
        r.apply(parse("state=done:id=a").unwrap());
        assert_eq!(r.records["a"].msg, None);
        r.lifecycle("process_exit");
        assert!(!r.records.contains_key("a/b"));
        assert_eq!(r.records.len(), 2);
        r.apply(parse("state=clear").unwrap());
        assert!(r.records.is_empty());
    }
    #[test]
    fn repeating_a_state_keeps_its_message() {
        let mut r = Records::default();
        r.apply(parse(&format!("state=done:msg={}", STANDARD.encode("Fixed it"))).unwrap());
        r.apply(parse("state=done:app=claude-code").unwrap());
        assert_eq!(r.records[""].msg.as_deref(), Some("Fixed it"));
        r.apply(parse("state=working").unwrap());
        r.apply(parse("state=done").unwrap());
        assert_eq!(r.records[""].msg, None, "a new turn starts without it");
    }
    #[test]
    fn the_turn_counts_each_time_the_root_leaves_working() {
        let mut r = Records::default();
        r.apply(parse("state=clear:id=agent").unwrap());
        assert!(!r.reported);
        r.apply(parse("state=idle").unwrap());
        assert!(r.reported);
        r.apply(parse("state=working").unwrap());
        r.apply(parse("state=working:id=agent/a").unwrap());
        assert_eq!(r.turn, 0);
        let events = r.apply(parse("state=done").unwrap());
        assert!(matches!(events[..], [TerminalEvent::ProgramStatusChanged { turn: 1, .. }]));
        r.apply(parse("state=done:id=agent/a").unwrap());
        r.apply(parse("state=working").unwrap());
        r.lifecycle("process_exit");
        assert_eq!(r.turn, 2, "exiting mid-turn ends it too");
        r.apply(parse("state=idle").unwrap());
        assert_eq!(r.turn, 2, "only leaving working counts");
    }
    #[test]
    fn limits_and_invalid_reports_are_atomic() {
        for s in [
            "state=done:msg=AA==",
            "state=done:title=***:msg=AA==",
            "state=done:id=bad//id",
            "state=done:msg=a:msg=aGk=",
        ] {
            assert!(parse(s).is_none(), "{s}");
        }
        assert!(parse(&format!("state=done:app={}", "a".repeat(33))).is_none());
        assert!(parse("state=working:progress=101").is_some());
        assert!(parse("state=done:unknown=yes:msg=aGk").is_some());
    }
    #[test]
    fn bounded_lru_and_subtree_clear() {
        let mut r = Records::default();
        for i in 0..257 {
            r.apply(parse(&format!("state=done:id=r{i}")).unwrap());
        }
        assert_eq!(r.records.len(), 256);
        assert!(!r.records.contains_key("r0"));
        r.apply(parse("state=done:id=r1/a").unwrap());
        r.apply(parse("state=clear:id=r1").unwrap());
        assert!(!r.records.contains_key("r1/a"));
    }
    #[test]
    fn all_field_limits_and_duplicate_validation() {
        for body in [
            format!("state=done:msg={}", STANDARD.encode("a".repeat(2049))),
            format!("state=done:title={}", STANDARD.encode("a".repeat(193))),
            format!("state=done:{}=x", "a".repeat(17)),
            format!("state=done:id={}", ["a"; 9].join("/")),
            "state=done:id=bad!".into(),
            "state=done:id=".into(),
            "state=done:msg=wog=".into(),
            "state=done:msg=/w==".into(),
        ] {
            assert!(parse(&body).is_none(), "{body}");
        }
        let Some(Report::Set(_, record)) = parse(
            " state = working : progress = 23 :state=blocked:kind=question:msg=aGk=:unknown=x;y",
        ) else {
            panic!("valid pairs must survive a malformed unknown pair");
        };
        assert_eq!(record.state, State::Blocked);
        assert_eq!(record.progress, Some(23));
        assert_eq!(record.msg.as_deref(), Some("hi"));
    }
    #[test]
    fn inherited_app_tracks_replacement_and_deserialized_records_remain_bounded() {
        let mut records = Records::default();
        for body in [
            "state=done:app=root",
            "state=done:id=a:app=parent",
            "state=done:id=a/b",
        ] {
            records.apply(parse(body).unwrap());
        }
        assert_eq!(records.effective_app("a/b"), Some("parent"));
        records.apply(parse("state=done:id=a").unwrap());
        assert_eq!(records.effective_app("a/b"), Some("root"));
        for i in 0..256 {
            records.apply(parse(&format!("state=done:id=x{i}")).unwrap());
        }
        let mut restored: Records =
            serde_json::from_value(serde_json::to_value(records).unwrap()).unwrap();
        restored.apply(parse("state=done:id=new").unwrap());
        assert_eq!(restored.records.len(), 256);
    }
}
