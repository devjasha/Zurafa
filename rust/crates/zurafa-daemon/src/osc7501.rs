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
                        // A remote tab's bridge reports the remote pane's foreground process; empty = none.
                        if let Some(json) = body.strip_prefix("fg;") {
                            if let Ok(foreground) = serde_json::from_str(if json.is_empty() { "null" } else { json }) {
                                actions.push(Action::Event(TerminalEvent::ProcessChanged {
                                    generation: 0,
                                    foreground,
                                    ancestors: Vec::new(),
                                }));
                            }
                        } else if let Some(report) = status::parse(body) {
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
/// The kitty keyboard protocol flags the program asked for, so `zurafa key` can encode keys the
/// way it reads them. Sees all output, so unlike a replay it survives the replay buffer's trimming.
/// https://sw.kovidgoyal.net/kitty/keyboard-protocol/#progressive-enhancement
#[derive(Default)]
pub struct Keyboard {
    /// One stack per screen: main, alternate.
    stacks: [Vec<u8>; 2],
    alternate: bool,
    /// The escape sequence being read: ESC and what follows, up to its final byte.
    seq: Vec<u8>,
}
impl Keyboard {
    /// Kitty's own limit; a push onto a full stack drops the oldest entry.
    const DEPTH: usize = 8;
    pub fn flags(&self) -> u8 {
        self.stacks[self.alternate as usize].last().copied().unwrap_or(0)
    }
    pub fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes {
            if b == 27 {
                self.seq = vec![b];
            } else if self.seq.len() == 1 {
                match b {
                    b'[' => self.seq.push(b),
                    b'c' => *self = Self::default(),
                    _ => self.seq.clear(),
                }
            } else if !self.seq.is_empty() {
                self.seq.push(b);
                if (0x40..=0x7e).contains(&b) {
                    let seq = std::mem::take(&mut self.seq);
                    self.csi(&seq[2..seq.len() - 1], b);
                } else if self.seq.len() > 64 {
                    self.seq.clear();
                }
            }
        }
    }
    fn csi(&mut self, params: &[u8], last: u8) {
        let Ok(params) = std::str::from_utf8(params) else { return };
        let mut chars = params.chars();
        let lead = chars.next();
        let nums: Vec<Option<u32>> = chars.as_str().split(';').map(|n| n.parse().ok()).collect();
        let arg = |i: usize, default: u32| nums.get(i).copied().flatten().unwrap_or(default);
        let stack = &mut self.stacks[self.alternate as usize];
        match (lead, last) {
            (Some('?'), b'h' | b'l') => {
                if nums.iter().any(|n| matches!(n, Some(47 | 1047 | 1049))) {
                    self.alternate = last == b'h';
                }
            }
            (Some('>'), b'u') => {
                if stack.len() == Self::DEPTH {
                    stack.remove(0);
                }
                stack.push(arg(0, 0) as u8 & 0x1f);
            }
            (Some('<'), b'u') => {
                let n = arg(0, 1) as usize;
                stack.truncate(stack.len().saturating_sub(n));
            }
            (Some('='), b'u') => {
                let (flags, current) = (arg(0, 0) as u8 & 0x1f, stack.last().copied().unwrap_or(0));
                let flags = match arg(1, 1) {
                    1 => flags,
                    2 => current | flags,
                    3 => current & !flags,
                    _ => return,
                };
                match stack.last_mut() {
                    Some(top) => *top = flags,
                    None => stack.push(flags),
                }
            }
            _ => {}
        }
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
    fn remote_foreground_is_hidden_and_reported() {
        let (out, a) = run(b"a\x1b]7501;fg;{\"name\":\"nvim\",\"cwd\":\"/r\",\"pid\":7,\"argv\":[\"nvim\"]}\x1b\\b\x1b]7501;fg;\x07", 3);
        assert_eq!(out, b"ab");
        assert_eq!(a.len(), 2);
        assert!(a[0].contains("name: \"nvim\"") && a[1].contains("foreground: None"), "{a:?}");
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
    #[test]
    fn kitty_keyboard_flags_follow_the_program() {
        let flags = |input: &[u8]| {
            let mut k = Keyboard::default();
            // Byte by byte, as a read may split a sequence anywhere.
            input.iter().for_each(|b| k.feed(&[*b]));
            k.flags()
        };
        assert_eq!(flags(b""), 0);
        assert_eq!(flags(b"\x1b[>1u"), 1);
        assert_eq!(flags(b"\x1b[>1u\x1b[>31u"), 31);
        assert_eq!(flags(b"\x1b[>1u\x1b[>31u\x1b[<u"), 1);
        assert_eq!(flags(b"\x1b[>1u\x1b[>3u\x1b[<5u"), 0);
        assert_eq!(flags(b"\x1b[=5u"), 5);
        assert_eq!(flags(b"\x1b[>1u\x1b[=8;2u"), 9);
        assert_eq!(flags(b"\x1b[>9u\x1b[=1;3u"), 8);
        assert_eq!(flags(b"\x1b[>1u\x1bc"), 0);
        assert_eq!(flags(b"\x1b[>1u\x1b[?u\x1b[1;5u\x1b[31mx"), 1);
        // The alternate screen has its own stack; leaving it finds the main screen's again.
        assert_eq!(flags(b"\x1b[>1u\x1b[?1049h"), 0);
        assert_eq!(flags(b"\x1b[>1u\x1b[?1049h\x1b[>11u"), 11);
        assert_eq!(flags(b"\x1b[>1u\x1b[?1049h\x1b[>11u\x1b[?1049l"), 1);
        // A full stack drops its oldest entry.
        let mut pushes = b"\x1b[>2u".repeat(Keyboard::DEPTH);
        pushes.extend(b"\x1b[<7u");
        assert_eq!(flags(&[b"\x1b[>1u".as_slice(), &pushes].concat()), 2);
    }
}
