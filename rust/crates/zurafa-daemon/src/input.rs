//! Tells a client's input apart: what the user typed, what its terminal emulator answered, and mouse reports.
//! Keys can start with ESC too (arrows, and every key under the kitty keyboard protocol), so the
//! difference is in each escape sequence's shape, not its first byte.

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Kind {
    /// Typed or pasted: text, legacy and kitty key sequences, bracketed paste.
    Key,
    /// The emulator speaking for itself: answers to queries (DA, CPR, DSR, DECRPM, kitty flags,
    /// OSC/DCS/APC replies) and focus reports. Every viewer of a pane sends these.
    Reply,
    Mouse,
}

/// Splits input into its sequences, each with its kind. Concatenated, the pieces are the input.
pub fn parts(bytes: &[u8]) -> impl Iterator<Item = (Kind, &[u8])> {
    let mut rest = bytes;
    std::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        let (len, kind) = sequence(rest);
        let (part, tail) = rest.split_at(len);
        rest = tail;
        Some((kind, part))
    })
}

/// The length and kind of the sequence `b` starts with. An unfinished sequence is the rest of the
/// input, as a key, so an input split mid-reply passes untouched.
fn sequence(b: &[u8]) -> (usize, Kind) {
    const ESC: u8 = 0x1b;
    if b[0] != ESC {
        return (b.iter().position(|&c| c == ESC).unwrap_or(b.len()), Kind::Key);
    }
    match b.get(1) {
        Some(b'[') => {
            let Some(end) = b[2..].iter().position(|c| (0x40..=0x7e).contains(c)).map(|i| i + 3) else {
                return (b.len(), Kind::Key);
            };
            let (params, last) = (&b[2..end - 1], b[end - 1]);
            let private = matches!(params.first(), Some(b'?' | b'>' | b'='));
            match last {
                // X10 mouse: `CSI M` and three raw bytes.
                b'M' if params.is_empty() => ((end + 3).min(b.len()), Kind::Mouse),
                b'M' | b'm' => (end, Kind::Mouse),
                b'I' | b'O' if params.is_empty() => (end, Kind::Reply),
                // CPR, DSR, DECRPM, window reports, DECREQTPARM.
                b'R' | b'n' | b'y' | b't' | b'x' => (end, Kind::Reply),
                b'c' | b'u' if private => (end, Kind::Reply),
                _ => (end, Kind::Key),
            }
        }
        // OSC, DCS, APC, PM, SOS: strings only an emulator sends, ended by BEL or ST.
        Some(b']' | b'P' | b'_' | b'^' | b'X') => {
            match b.windows(2).skip(2).position(|w| w[0] == 7 || w == [ESC, b'\\']) {
                Some(i) => (i + 2 + if b[i + 2] == 7 { 1 } else { 2 }, Kind::Reply),
                None if b.last() == Some(&7) => (b.len(), Kind::Reply),
                None => (b.len(), Kind::Key),
            }
        }
        Some(b'O') => (3.min(b.len()), Kind::Key),
        Some(_) => (2, Kind::Key),
        None => (1, Kind::Key),
    }
}

/// The input without replies, for a viewer whose emulator another viewer's already answers for.
pub fn without_replies(bytes: &[u8]) -> Vec<u8> {
    parts(bytes).filter(|(k, _)| *k != Kind::Reply).flat_map(|(_, p)| p.iter().copied()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn kinds(b: &[u8]) -> Vec<(Kind, &[u8])> {
        parts(b).collect()
    }
    #[test]
    fn keys_even_when_escape_led() {
        for key in [
            b"x".as_slice(), b"\x1b", b"\x1b[A", b"\x1bOA", b"\x1b[1;5C", b"\x1b[3~", b"\x1b[Z", b"\x1bx",
            b"\x1b[99;5u", b"\x1b[27u", b"\x1b[97;1:3u", b"\x1b[13;2u", b"\x1b[P", b"\x1b[200~hi\x1b[201~",
        ] {
            assert!(parts(key).all(|(k, _)| k == Kind::Key), "{key:?}");
        }
    }
    #[test]
    fn replies_and_mouse() {
        for reply in [
            b"\x1b[?62;22c".as_slice(), b"\x1b[>1;10;0c", b"\x1b[12;40R", b"\x1b[0n", b"\x1b[?997;1n", b"\x1b[I",
            b"\x1b[O", b"\x1b[?1u", b"\x1b[?2026;2$y", b"\x1b[8;24;80t", b"\x1b]11;rgb:0000/0000/0000\x1b\\",
            b"\x1b]10;rgb:ffff/ffff/ffff\x07", b"\x1bP1+r544e=787465726d\x1b\\", b"\x1b_Gi=1;OK\x1b\\",
        ] {
            assert_eq!(kinds(reply), [(Kind::Reply, reply)], "{reply:?}");
        }
        assert_eq!(kinds(b"\x1b[<0;3;4M\x1b[<0;3;4m\x1b[M !!a").iter().map(|p| p.0).collect::<Vec<_>>(),
            [Kind::Mouse, Kind::Mouse, Kind::Mouse, Kind::Key]);
    }
    #[test]
    fn mixed_input_keeps_keys_and_unfinished_sequences() {
        let input = b"a\x1b[?1;2c\x1b[27u\x1b]11;rgb:0/0/0\x07b\x1b]11;rgb";
        assert_eq!(without_replies(input), b"a\x1b[27ub\x1b]11;rgb");
        assert_eq!(parts(input).flat_map(|p| p.1.to_vec()).collect::<Vec<_>>(), input);
        assert_eq!(without_replies(b"\x1b["), b"\x1b[");
    }
}
