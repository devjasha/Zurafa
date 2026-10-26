//! `zurafa-daemon login-server`, as Rex has it: runs as root and hands each caller to a daemon
//! running as one account. `/etc/zurafa/accounts.jsonc` says which accounts each caller may use:
//!
//! ```jsonc
//! {
//!   "version": 1,
//!   "accounts": {
//!     "alice": { "principals": ["tailscale:alice@example.com"] },
//!     "root": { "principals": ["tailscale:alice@example.com"] },
//!   },
//!   "defaults": { "tailscale:alice@example.com": "alice" },
//! }
//! ```
//!
//! Principals: `tailscale:<login>`, `tailscale:tag:<tag>`, `tailscale:*` (any person),
//! `tailscale:tag:*` (any tagged device), `identified` and `anonymous`. The account `"*"` grants
//! every regular account (user ID 1000 or more), never to anonymous callers, and anonymous callers
//! never get root. A caller names an account with a `Zurafa-Account` header; otherwise the most
//! specific matching default applies, else the one account it may use.
//!
//! No passwords: the network identity is the authentication. `runuser -l` opens the account's
//! PAM session (limits, environment, account checks) and runs `zurafa-daemon bridge`, which starts
//! or reuses that account's own daemon, so sessions survive login server restarts and upgrades.
use crate::listen::{self, Target};
use serde::{de, Deserialize, Deserializer};
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::{env, fmt, io, sync::Arc};
use tokio::io::{AsyncRead, AsyncWrite, BufReader};
use tokio::process::Command;
use tokio::signal::unix::{signal, SignalKind};

pub const ACCOUNTS: &str = "/etc/zurafa/accounts.jsonc";

pub struct Config {
    accounts: PathBuf,
    exe: PathBuf,
}

#[derive(Deserialize, Default)]
struct Accounts {
    #[serde(default)]
    accounts: HashMap<String, Account>,
    #[serde(default)]
    defaults: Ordered,
}

#[derive(Deserialize)]
struct Account {
    #[serde(default)]
    principals: Vec<String>,
}

/// `defaults` in file order: on a tie, the first entry wins.
#[derive(Default)]
struct Ordered(Vec<(String, String)>);

impl<'de> Deserialize<'de> for Ordered {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Pairs;
        impl<'de> de::Visitor<'de> for Pairs {
            type Value = Ordered;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a map from principal to account")
            }
            fn visit_map<A: de::MapAccess<'de>>(self, mut map: A) -> Result<Ordered, A::Error> {
                let mut pairs = Vec::new();
                while let Some(pair) = map.next_entry()? {
                    pairs.push(pair);
                }
                Ok(Ordered(pairs))
            }
        }
        d.deserialize_map(Pairs)
    }
}

/// JSON with comments and trailing commas, as the accounts file allows, to plain JSON.
pub(crate) fn jsonc(text: &str) -> String {
    scan(&scan(text, true), false)
}

/// One pass over JSON text that leaves strings alone: drops comments, or else trailing commas.
fn scan(text: &str, comments: bool) -> String {
    let mut plain = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                plain.push(c);
                while let Some(c) = chars.next() {
                    plain.push(c);
                    match c {
                        '\\' => plain.extend(chars.next()),
                        '"' => break,
                        _ => {}
                    }
                }
            }
            '/' if comments && chars.peek() == Some(&'/') => {
                while chars.next().is_some_and(|c| c != '\n') {}
                plain.push('\n');
            }
            '/' if comments && chars.peek() == Some(&'*') => {
                chars.next();
                let mut prev = ' ';
                for c in chars.by_ref() {
                    if prev == '*' && c == '/' {
                        break;
                    }
                    prev = c;
                }
                plain.push(' ');
            }
            ',' if !comments && matches!(chars.clone().find(|c| !c.is_whitespace()), Some('}' | ']')) => {}
            _ => plain.push(c),
        }
    }
    plain
}

fn load(path: &Path) -> Result<Accounts, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    serde_json::from_str(&jsonc(&text)).map_err(|e| format!("bad {}: {e}", path.display()))
}

/// The caller's principals, most specific first: login, tags, Tailscale wildcard, `identified`,
/// `anonymous`. From the principal a listener admitted it with.
fn caller(principal: &Value) -> Vec<Vec<String>> {
    if principal["kind"] == "anonymous" {
        return vec![vec!["anonymous".into()]];
    }
    let tags: Vec<String> = principal["tags"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|t| Some(format!("tailscale:{}", t.as_str()?)))
        .collect();
    if !tags.is_empty() {
        // A tagged device has no person behind it, so it never matches a login or `tailscale:*`.
        return vec![vec![], tags, vec!["tailscale:tag:*".into()], vec!["identified".into()]];
    }
    match principal["login"].as_str().filter(|l| !l.is_empty()) {
        Some(login) => vec![vec![format!("tailscale:{login}")], vec![], vec!["tailscale:*".into()], vec!["identified".into()]],
        None => vec![vec!["anonymous".into()]],
    }
}

/// The account this caller gets, or why it gets none. `uid_of` looks up local accounts.
fn choose(file: &Accounts, caller: &[Vec<String>], requested: Option<&str>, uid_of: impl Fn(&str) -> Option<u32>) -> Result<String, String> {
    let all: Vec<&String> = caller.iter().flatten().collect();
    let anonymous = all.iter().any(|p| *p == "anonymous");
    let matches = |account: &str| file.accounts.get(account).is_some_and(|a| a.principals.iter().any(|p| all.contains(&p)));
    // `"*"` only grants regular accounts, and never to anonymous callers.
    let star = !anonymous && matches("*");
    let may_use = |account: &str| match uid_of(account) {
        None => false,
        Some(0) if anonymous => false,
        Some(uid) => account != "*" && (matches(account) || (star && uid >= 1000 && uid != 65534)),
    };
    let decide = |account: &str, why: &str| {
        if may_use(account) {
            Ok(account.to_owned())
        } else {
            Err(format!("{why} {account} account is not allowed for you in {ACCOUNTS}"))
        }
    };
    if let Some(account) = requested {
        return decide(account, "the");
    }
    for tier in caller {
        if let Some((_, account)) = file.defaults.0.iter().find(|(principal, _)| tier.contains(principal)) {
            return decide(account, "your default");
        }
    }
    let usable: Vec<&String> = file.accounts.keys().filter(|a| may_use(a)).collect();
    match (usable.as_slice(), star) {
        ([only], false) => Ok((*only).clone()),
        ([], false) => Err(format!("no account in {ACCOUNTS} allows you ({})", all.first().map_or("", |p| p.as_str()))),
        _ => Err("several accounts allow you; name one in the host's user field, like root@host".into()),
    }
}

struct User {
    uid: u32,
    shell: String,
}

/// `/etc/passwd` lookup. shortcut: the static musl build has no NSS, so LDAP or SSSD accounts are not found; build against glibc if a host needs them.
fn user(name: &str) -> Option<User> {
    let name = CString::new(name).ok()?;
    let mut pw = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut buf = vec![0 as libc::c_char; 16 * 1024];
    let mut found = std::ptr::null_mut();
    let rc = unsafe { libc::getpwnam_r(name.as_ptr(), &mut pw, buf.as_mut_ptr(), buf.len(), &mut found) };
    if rc != 0 || found.is_null() {
        return None;
    }
    let shell = unsafe { CStr::from_ptr(pw.pw_shell) }.to_string_lossy().into_owned();
    Some(User { uid: pw.pw_uid, shell })
}

/// Account names go on `runuser`'s command line, so only plain user names, never an option.
fn plain_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 32 && !name.starts_with('-') && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// Admitted by a listener: pick the account, answer 101 or 403, then splice the connection to a
/// bridge into that account's daemon.
pub async fn handle<S>(mut stream: BufReader<S>, config: Arc<Config>, principal: Value, headers: Vec<(String, String)>)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let requested = headers.iter().find(|(name, _)| name == "zurafa-account").map(|(_, v)| v.clone());
    let who = principal["login"].as_str().unwrap_or("anonymous caller").to_owned();
    let accounts = config.accounts.clone();
    let chosen = tokio::task::spawn_blocking(move || -> Result<String, String> {
        if let Some(name) = requested.as_deref().filter(|n| !plain_name(n)) {
            return Err(format!("{name:?} is not an account name"));
        }
        // Read every time, so edits apply to the next connection without a reload.
        let account = choose(&load(&accounts)?, &caller(&principal), requested.as_deref(), |a| user(a).map(|u| u.uid))?;
        let user = user(&account).ok_or("no such account")?;
        if user.shell.ends_with("/nologin") || user.shell.ends_with("/false") {
            return Err(format!("the {account} account cannot log in"));
        }
        if user.uid != 0 && Path::new("/etc/nologin").exists() {
            return Err("logins are disabled (/etc/nologin)".into());
        }
        Ok(account)
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()));
    let account = match chosen {
        Ok(account) => account,
        Err(why) => {
            eprintln!("zurafa login: refused {who}: {why}");
            let _ = listen::respond(&mut stream, &listen::forbidden(&why)).await;
            return;
        }
    };
    // `sh -s`: the account's own shell may be fish or something else non-POSIX.
    let bridge = format!("exec '{}' bridge", config.exe.display());
    let child = Command::new("runuser")
        .args(["-l", &account, "-s", "/bin/sh", "-c", &bridge])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match child {
        Ok(child) => child,
        Err(e) => {
            eprintln!("zurafa login: cannot run runuser for {account}: {e}");
            let _ = listen::respond(&mut stream, &listen::forbidden("this host cannot start sessions (runuser missing?)")).await;
            return;
        }
    };
    eprintln!("zurafa login: {who} -> {account}");
    if listen::respond(&mut stream, listen::SWITCHING).await.is_err() {
        return;
    }
    let mut session = tokio::io::join(child.stdout.take().unwrap(), child.stdin.take().unwrap());
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut session).await;
    // Closing the pipes ends the bridge; the account's daemon and its terminals keep running.
    drop(session);
    let _ = child.wait().await;
}

/// `zurafa-daemon login-server [--accounts PATH] --extra-listen SPEC… [--allow-anonymous]`.
pub async fn run() -> io::Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::Error::other("the login server must run as root"));
    }
    let mut args = env::args().skip(2);
    let mut accounts = PathBuf::from(ACCOUNTS);
    let mut listens = Vec::new();
    let mut allow_anonymous = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--accounts" => accounts = args.next().unwrap_or_default().into(),
            "--extra-listen" => listens.push(listen::parse(&args.next().unwrap_or_default()).map_err(io::Error::other)?),
            "--allow-anonymous" => allow_anonymous = true,
            _ => return Err(io::Error::other(format!("unknown login-server option {arg:?}"))),
        }
    }
    if listens.is_empty() {
        return Err(io::Error::other("the login server needs at least one --extra-listen"));
    }
    load(&accounts).map_err(io::Error::other)?;
    let config = Arc::new(Config { accounts, exe: env::current_exe()? });
    for spec in listens {
        // Every caller Tailscale can name gets in; the accounts file decides what it may use.
        listen::start(spec, Target::Login(config.clone()), true, allow_anonymous).await?;
    }
    let (mut term, mut int) = (signal(SignalKind::terminate())?, signal(SignalKind::interrupt())?);
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn file(text: &str) -> Accounts {
        serde_json::from_str(&jsonc(text)).unwrap()
    }

    fn uid(name: &str) -> Option<u32> {
        match name {
            "root" => Some(0),
            "alice" => Some(1000),
            "bob" => Some(1001),
            "guest" => Some(1002),
            "daemon" => Some(1),
            _ => None,
        }
    }

    const ALICE: &str = r#"{
        // Alice may use her account and root; she gets hers unless she asks.
        "version": 1,
        "accounts": {
            "alice": { "principals": ["tailscale:alice@example.com"] },
            "root": { "principals": ["tailscale:alice@example.com", "anonymous"], },
            "guest": { "principals": ["anonymous", "tailscale:tag:ci"] }, /* shared */
        },
        "defaults": { "tailscale:alice@example.com": "alice", "anonymous": "guest", },
    }"#;

    #[test]
    fn reads_comments_and_trailing_commas_but_not_inside_strings() {
        assert_eq!(jsonc(r#"{"a": "x // y, }", /* c */ "b": [1, 2,],}"#), r#"{"a": "x // y, }",   "b": [1, 2]}"#);
        assert_eq!(file(ALICE).defaults.0[1], ("anonymous".into(), "guest".into()));
    }

    #[test]
    fn principals_from_listener_identities() {
        let person = caller(&json!({"kind":"tailnet","login":"alice@example.com","tags":null}));
        assert_eq!(person[0], ["tailscale:alice@example.com"]);
        assert!(person.concat().contains(&"identified".to_string()));
        let tagged = caller(&json!({"kind":"tailnet","login":"tagged-devices","tags":["tag:ci"]}));
        assert_eq!(tagged.concat(), ["tailscale:tag:ci", "tailscale:tag:*", "identified"]);
        assert_eq!(caller(&json!({"kind":"anonymous"})), [["anonymous"]]);
        assert_eq!(caller(&json!({"kind":"tailscale-serve","login":"alice@example.com"}))[0], ["tailscale:alice@example.com"]);
    }

    #[test]
    fn defaults_and_requests() {
        let f = file(ALICE);
        let alice = caller(&json!({"kind":"tailnet","login":"alice@example.com"}));
        assert_eq!(choose(&f, &alice, None, uid), Ok("alice".into()));
        assert_eq!(choose(&f, &alice, Some("root"), uid), Ok("root".into()));
        assert!(choose(&f, &alice, Some("bob"), uid).is_err());
        assert!(choose(&f, &alice, Some("nobody-here"), uid).is_err());
        let bob = caller(&json!({"kind":"tailnet","login":"bob@example.com"}));
        assert!(choose(&f, &bob, None, uid).is_err());
    }

    #[test]
    fn anonymous_callers_never_get_root() {
        let f = file(ALICE);
        let anon = caller(&json!({"kind":"anonymous"}));
        assert_eq!(choose(&f, &anon, None, uid), Ok("guest".into()));
        assert!(choose(&f, &anon, Some("root"), uid).is_err());
    }

    #[test]
    fn a_tagged_device_gets_the_one_account_it_may_use() {
        let ci = caller(&json!({"kind":"tailnet","login":"tagged-devices","tags":["tag:ci"]}));
        assert_eq!(choose(&file(ALICE), &ci, None, uid), Ok("guest".into()));
    }

    #[test]
    fn star_grants_regular_accounts_only() {
        let f = file(r#"{"accounts": {"*": {"principals": ["tailscale:*", "anonymous"]}}}"#);
        let bob = caller(&json!({"kind":"tailnet","login":"bob@example.com"}));
        assert_eq!(choose(&f, &bob, Some("bob"), uid), Ok("bob".into()));
        assert!(choose(&f, &bob, Some("root"), uid).is_err());
        assert!(choose(&f, &bob, Some("daemon"), uid).is_err());
        assert!(choose(&f, &bob, None, uid).is_err(), "must name one");
        let anon = caller(&json!({"kind":"anonymous"}));
        assert!(choose(&f, &anon, Some("bob"), uid).is_err());
    }

    #[test]
    fn account_names_cannot_be_options() {
        assert!(plain_name("alice") && plain_name("svc.build-1_x"));
        assert!(!plain_name("-froot") && !plain_name("a b") && !plain_name("") && !plain_name("a;b"));
    }
}
