//! Bounded streaming OSC scanner. Only 7501 is removed from the display stream.
use zurafa_events::{
    status::{self, Report},
    TerminalEvent,
};
#[derive(Debug)]
pub enum Action {
    Report(Report),
    Lifecycle(&'static str),
    Event(TerminalEvent),
}
#[derive(Default)]
pub struct Filter {
    pending: Vec<u8>,
    discard: bool,
    passthrough: bool,
    discard_esc: bool,
}
impl Filter {
    pub fn feed(&mut self, input: &[u8]) -> (Vec<u8>, Vec<Action>) {
        let mut out = vec![];
        let mut actions = vec![];
        for &b in input {
            if self.discard {
                if self.passthrough {
                    out.push(b);
                }
                if b == 7 || (self.discard_esc && b == b'\\') {
                    self.discard = false;
                }
                self.discard_esc = b == 27;
                continue;
            }
            if self.pending.is_empty() {
                if b == 27 {
                    self.pending.push(b);
                } else {
                    out.push(b);
                    if b == 7 {
                        actions.push(Action::Event(TerminalEvent::Bell {}));
                    }
                }
                continue;
            }
            if self.pending.len() == 1 {
                match b {
                    b']' => self.pending.push(b),
                    b'c' => {
                        out.extend([27, b'c']);
                        self.pending.clear();
                        actions.push(Action::Lifecycle("reset"));
                    }
                    27 => out.push(27),
                    _ => {
                        out.extend([27, b]);
                        self.pending.clear();
                    }
                }
                continue;
            }
            let after_esc = self.pending.last() == Some(&27);
            self.pending.push(b);
            let status = self.pending.starts_with(b"\x1b]7501;");
            if self.pending.len() > 4096 {
                if !status {
                    out.append(&mut self.pending);
                } else {
                    self.pending.clear();
                }
                self.discard = !(b == 7 || (after_esc && b == b'\\'));
                self.discard_esc = b == 27;
                self.passthrough = !status;
                continue;
            }
            if b == 7 || (after_esc && b == b'\\') {
                let end = self.pending.len() - if b == 7 { 1 } else { 2 };
                if let Ok(body) = std::str::from_utf8(&self.pending[2..end]) {
                    if let Some(body) = body.strip_prefix("7501;") {
                        if let Some(report) = status::parse(body) {
                            actions.push(Action::Report(report));
                        }
                    } else {
                        Self::observe(body, &mut actions);
                    }
                }
                if !status {
                    out.append(&mut self.pending);
                } else {
                    self.pending.clear();
                }
            } else if after_esc {
                // An embedded escape aborts an unfinished OSC; allow a fresh OSC/RIS.
                let tail = self.pending.split_off(self.pending.len() - 2);
                out.append(&mut self.pending);
                if b == b']' {
                    self.pending = tail;
                } else if b == b'c' {
                    out.extend(tail);
                    actions.push(Action::Lifecycle("reset"));
                } else {
                    out.extend(tail);
                }
            }
        }
        (out, actions)
    }
    fn observe(body: &str, actions: &mut Vec<Action>) {
        let Some((code, value)) = body.split_once(';') else {
            return;
        };
        let event = match code {
            "0" | "2" => Some(TerminalEvent::TitleChanged {
                title: value.into(),
                owner: None,
            }),
            "7" if value.starts_with("file://") => Some(TerminalEvent::PwdChanged {
                pwd: value.into(),
                owner: None,
            }),
            "133" if value == "A" || value.starts_with("A;") => {
                actions.push(Action::Lifecycle("shell_prompt"));
                None
            }
            "9" => {
                if let Some(progress) = value.strip_prefix("4;") {
                    let mut parts = progress.split(';');
                    let state = parts.next().and_then(|s| s.parse::<u8>().ok());
                    let progress = parts
                        .next()
                        .and_then(|s| s.parse::<u8>().ok())
                        .filter(|p| *p <= 100);
                    state
                        .filter(|s| *s <= 4)
                        .map(|state| TerminalEvent::ProgressReport { state, progress })
                } else {
                    Some(TerminalEvent::DesktopNotification {
                        title: String::new(),
                        body: value.into(),
                    })
                }
            }
            "777" => value
                .strip_prefix("notify;")
                .and_then(|s| s.split_once(';'))
                .map(|(title, body)| TerminalEvent::DesktopNotification {
                    title: title.into(),
                    body: body.into(),
                }),
            "52" => {
                use base64::{engine::general_purpose::STANDARD, Engine};
                value
                    .split_once(';')
                    .and_then(|(_, data)| STANDARD.decode(data).ok())
                    .and_then(|b| String::from_utf8(b).ok())
                    .map(|text| TerminalEvent::ClipboardWritten { text })
            }
            _ => None,
        };
        if let Some(event) = event {
            actions.push(Action::Event(event));
        }
    }
    pub fn finish(&mut self) -> Vec<u8> {
        if self.pending.starts_with(b"\x1b]7501;") {
            self.pending.clear();
        }
        std::mem::take(&mut self.pending)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn run(input: &[u8], chunk: usize) -> (Vec<u8>, Vec<String>) {
        let mut f = Filter::default();
        let mut out = vec![];
        let mut actions = vec![];
        for bytes in input.chunks(chunk) {
            let (o, a) = f.feed(bytes);
            out.extend(o);
            actions.extend(a.into_iter().map(|a| format!("{a:?}")));
        }
        out.extend(f.finish());
        (out, actions)
    }
    #[test]
    fn fragmentation_and_reports() {
        let input = b"hi\x1b]7501;state=done:msg=aGk\x1b\\\x1b]2;title\x07\x07\x1b]133;A\x07\x1bc";
        let expected = run(input, input.len());
        for chunk in 1..input.len() {
            assert_eq!(run(input, chunk), expected);
        }
        assert_eq!(expected.0, b"hi\x1b]2;title\x07\x07\x1b]133;A\x07\x1bc");
        assert_eq!(expected.1.len(), 5);
    }
    #[test]
    fn overflow_discarded_and_recovers() {
        let mut input = b"\x1b]7501;state=done:msg=".to_vec();
        input.extend(vec![b'a'; 5000]);
        input.extend(b"\x07ok\x1b]7501;?\x07");
        let (out, a) = run(&input, 1);
        assert_eq!(out, b"ok");
        assert_eq!(a.len(), 1);
    }
    #[test]
    fn ordinary_escape_passthrough() {
        let input = b"\x1b[31mhello\x1b]0;world\x07\x1b[!p\x1b";
        assert_eq!(run(input, 1).0, input);
    }
    #[test]
    fn exact_sequence_limit_and_other_osc_overflow() {
        for end in [b"\x07".as_slice(), b"\x1b\\".as_slice()] {
            let mut legal = b"\x1b]7501;state=done:x=".to_vec();
            legal.resize(4096 - end.len(), b'a');
            legal.extend(end);
            assert_eq!(run(&legal, 1).1.len(), 1);
            let mut oversized = legal.clone();
            oversized.insert(20, b'a');
            assert!(run(&oversized, 1).1.is_empty());
        }
        let mut ordinary = b"\x1b]2;".to_vec();
        ordinary.extend(vec![b'a'; 5000]);
        ordinary.push(7);
        let (out, actions) = run(&ordinary, 1);
        assert_eq!(out, ordinary);
        assert!(actions.is_empty());
    }
    #[test]
    fn soft_reset_and_alternate_screen_do_not_clear_records() {
        let input = b"\x1b[!p\x1b[?1049h\x1b[?1049l";
        let (out, actions) = run(input, 1);
        assert_eq!(out, input);
        assert!(actions.is_empty());
    }
}
