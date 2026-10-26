//! Network listeners, as Rex has them. Tailscale says who is calling; by default only this device
//! and its owner get in, and `--tailnet-allow-identified` admits anyone Tailscale can name.
//! - `tailnet://[:PORT]` binds this machine's Tailscale addresses and asks `tailscale whois`.
//! - `tailnet-serve:///path.sock` is a Unix socket for `tailscale serve … unix:/path.sock`, which
//!   names the caller in `Tailscale-User-Login` (never for tagged devices, which have no user).
//!
//! An admitted caller sends an HTTP/1.1 `GET` with `Upgrade: zurafa`; after the 101 the
//! connection carries the same length-prefixed frames as the daemon's own Unix socket.
use crate::{hosts::tailscale, pty::Terminals, server};
use serde_json::{json, Value};
use std::{
    fs,
    io::{self, ErrorKind},
    net::{IpAddr, SocketAddr},
    os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener};

pub const DEFAULT_PORT: u16 = 7297;

#[derive(Debug, PartialEq)]
pub enum Listen {
    Tailnet(u16),
    Serve(PathBuf),
}

/// `tailnet://:PORT` (default port 7297) or `tailnet-serve:///absolute/path.sock`.
pub fn parse(spec: &str) -> Result<Listen, String> {
    if let Some(path) = spec.strip_prefix("tailnet-serve://") {
        return path
            .starts_with('/')
            .then(|| Listen::Serve(path.into()))
            .ok_or_else(|| format!("{spec:?} needs an absolute socket path, like tailnet-serve:///run/zurafa/serve.sock"));
    }
    let rest = spec
        .strip_prefix("tailnet://")
        .ok_or_else(|| format!("unsupported listener {spec:?}; use tailnet://:PORT or tailnet-serve:///path.sock"))?;
    match rest {
        "" | ":" => Ok(Listen::Tailnet(DEFAULT_PORT)),
        _ => rest
            .strip_prefix(':')
            .and_then(|p| p.parse().ok())
            .filter(|p| *p != 0)
            .map(Listen::Tailnet)
            .ok_or_else(|| format!("bad port in {spec:?}")),
    }
}

/// This machine's `Self` from `tailscale status --json`, plus its owner's login name.
async fn whoami() -> io::Result<(Value, Option<String>)> {
    let status: Value = tokio::task::spawn_blocking(|| tailscale(&["status", "--json"]))
        .await
        .ok()
        .flatten()
        .and_then(|out| serde_json::from_slice(&out).ok())
        .filter(|status: &Value| status["Self"]["Online"] == true)
        .ok_or_else(|| io::Error::other("network listeners need Tailscale running and signed in"))?;
    let me = status["Self"].clone();
    let tagged = me["Tags"].as_array().is_some_and(|t| !t.is_empty());
    // Tagged devices have no owner.
    let owner = me["UserID"]
        .as_u64()
        .filter(|_| !tagged)
        .and_then(|id| status["User"][id.to_string()]["LoginName"].as_str())
        .map(str::to_owned);
    Ok((me, owner))
}

pub async fn start(listen: Listen, terms: Arc<Terminals>, allow_identified: bool) -> io::Result<()> {
    let (me, owner) = whoami().await?;
    match listen {
        Listen::Tailnet(port) => start_tailnet(port, me, terms, allow_identified).await,
        Listen::Serve(path) => start_serve(path, owner, terms, allow_identified),
    }
}

/// Binds every Tailscale address of this machine, never a wildcard address.
async fn start_tailnet(port: u16, me: Value, terms: Arc<Terminals>, allow_identified: bool) -> io::Result<()> {
    let ips: Vec<IpAddr> = me["TailscaleIPs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|ip| ip.as_str()?.parse().ok())
        .collect();
    if ips.is_empty() {
        return Err(io::Error::other("Tailscale reports no addresses for this machine"));
    }
    let me = Arc::new(me);
    for ip in ips {
        let addr = SocketAddr::new(ip, port);
        let listener = match TcpListener::bind(addr).await {
            Ok(listener) => listener,
            // Tailscale in userspace networking has no local interface for its addresses.
            Err(e) if e.kind() == ErrorKind::AddrNotAvailable => {
                eprintln!("zurafa-daemon cannot listen on tailnet {addr} (userspace networking?); use tailnet-serve:// there");
                continue;
            }
            Err(e) => return Err(e),
        };
        eprintln!("zurafa-daemon listening on tailnet {addr}");
        let (terms, me) = (terms.clone(), me.clone());
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, peer)) => {
                        tokio::spawn(serve_tailnet(stream, peer.ip(), terms.clone(), me.clone(), allow_identified));
                    }
                    // e.g. out of file descriptors: back off instead of spinning
                    Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
                }
            }
        });
    }
    Ok(())
}

/// The caller's identity comes from headers, so only this user (and root's tailscaled) may connect.
fn start_serve(path: PathBuf, owner: Option<String>, terms: Arc<Terminals>, allow_identified: bool) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    // stale socket: remove it, but never some other kind of file
    if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_socket()) {
        fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    // shortcut: chmod after bind leaves a brief umask-mode window, as for the daemon socket; upgrade to umask(0o177) around bind if the parent may be shared
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    eprintln!("zurafa-daemon listening for Tailscale Serve on {}", path.display());
    let owner = Arc::new(owner);
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    tokio::spawn(serve_serve(stream, terms.clone(), owner.clone(), allow_identified));
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
    });
    Ok(())
}

async fn serve_tailnet<S>(stream: S, peer: IpAddr, terms: Arc<Terminals>, me: Arc<Value>, allow_identified: bool)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let whois = tokio::task::spawn_blocking(move || tailscale(&["whois", "--json", &peer.to_string()]))
        .await
        .ok()
        .flatten()
        .and_then(|out| serde_json::from_slice(&out).ok())
        .unwrap_or(Value::Null);
    let mut stream = BufReader::new(stream);
    // Admit before reading anything from the caller. Any Tailscale-User-* headers are ignored here:
    // only Serve can vouch for those.
    match admit(&whois, &me, allow_identified) {
        Ok(principal) => {
            if let Ok(Some(_)) = read_upgrade(&mut stream).await {
                if respond(&mut stream, SWITCHING).await.is_ok() {
                    server::handle(stream, terms, principal).await;
                }
            } else {
                let _ = respond(&mut stream, UPGRADE_REQUIRED).await;
            }
        }
        Err(why) => {
            let _ = respond(&mut stream, &forbidden(why)).await;
        }
    }
}

async fn serve_serve<S>(stream: S, terms: Arc<Terminals>, owner: Arc<Option<String>>, allow_identified: bool)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut stream = BufReader::new(stream);
    let Ok(Some(headers)) = read_upgrade(&mut stream).await else {
        let _ = respond(&mut stream, UPGRADE_REQUIRED).await;
        return;
    };
    let login = headers.iter().find(|(name, _)| name == "tailscale-user-login").map(|(_, v)| v.as_str());
    match admit_serve(login, owner.as_deref(), allow_identified) {
        Ok(principal) => {
            if respond(&mut stream, SWITCHING).await.is_ok() {
                server::handle(stream, terms, principal).await;
            }
        }
        Err(why) => {
            let _ = respond(&mut stream, &forbidden(why)).await;
        }
    }
}

/// The client principal for a caller's `tailscale whois`, or why it is refused.
/// `me` is this machine's `Self` from `tailscale status --json`.
fn admit(whois: &Value, me: &Value, allow_identified: bool) -> Result<Value, &'static str> {
    let node = &whois["Node"];
    let Some(stable_id) = node["StableID"].as_str() else {
        return Err("Tailscale cannot identify this caller");
    };
    let tagged = |n: &Value| n["Tags"].as_array().is_some_and(|t| !t.is_empty());
    let same_device = me["ID"].as_str() == Some(stable_id);
    // Tagged devices have no owner, so "same owner" never matches one.
    let same_owner = !tagged(node) && !tagged(me) && node["User"].as_u64().is_some_and(|u| me["UserID"].as_u64() == Some(u));
    if !(same_device || same_owner || allow_identified) {
        return Err("only this machine's Tailscale owner may connect; start the daemon with --tailnet-allow-identified to admit others");
    }
    Ok(json!({
        "kind": "tailnet",
        "login": whois["UserProfile"]["LoginName"],
        "node": node["Name"].as_str().unwrap_or_default().trim_end_matches('.'),
        "tags": node["Tags"],
    }))
}

/// Like `admit`, from the login Tailscale Serve puts in `Tailscale-User-Login`.
fn admit_serve(login: Option<&str>, owner: Option<&str>, allow_identified: bool) -> Result<Value, &'static str> {
    let Some(login) = login.filter(|l| !l.is_empty()) else {
        return Err("Tailscale Serve did not identify this caller; tagged devices must use the tailnet:// listener");
    };
    if !(allow_identified || owner == Some(login)) {
        return Err("only this machine's Tailscale owner may connect; start the daemon with --tailnet-allow-identified to admit others");
    }
    Ok(json!({"kind": "tailscale-serve", "login": login}))
}

const SWITCHING: &str = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: zurafa\r\nConnection: Upgrade\r\n\r\n";
const UPGRADE_REQUIRED: &str = "HTTP/1.1 426 Upgrade Required\r\nUpgrade: zurafa\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";

fn forbidden(why: &str) -> String {
    let body = format!("{why}\n");
    format!("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
}

async fn respond<S: AsyncWrite + Unpin>(stream: &mut S, response: &str) -> io::Result<()> {
    stream.write_all(response.as_bytes()).await?;
    stream.flush().await
}

/// Reads an HTTP/1.1 request head (at most 8 KiB). Its headers, names lowercased, when it is a
/// `GET` with `Upgrade: zurafa`; `None` for any other request.
async fn read_upgrade<S: AsyncRead + Unpin>(stream: &mut BufReader<S>) -> io::Result<Option<Vec<(String, String)>>> {
    let mut head = (&mut *stream).take(8192);
    let mut line = String::new();
    head.read_line(&mut line).await?;
    let get = line.starts_with("GET /") && line.trim_end().ends_with(" HTTP/1.1");
    let mut headers = Vec::new();
    loop {
        line.clear();
        if head.read_line(&mut line).await? == 0 {
            return Err(ErrorKind::UnexpectedEof.into());
        }
        let header = line.trim_end_matches(['\r', '\n']);
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_owned()));
        }
    }
    let wants_zurafa = headers.iter().any(|(name, value)| name == "upgrade" && value.eq_ignore_ascii_case("zurafa"));
    Ok((get && wants_zurafa).then_some(headers))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn whois(stable_id: &str, user: u64, tags: Value) -> Value {
        json!({"Node":{"StableID":stable_id,"User":user,"Tags":tags,"Name":"box.tail.ts.net."},
               "UserProfile":{"LoginName":"alice@github"}})
    }

    #[test]
    fn admits_this_device_and_its_owner_by_default() {
        let me = json!({"ID":"nSELF","UserID":1,"Tags":null});
        let p = admit(&whois("nOTHER", 1, Value::Null), &me, false).unwrap();
        assert_eq!(p, json!({"kind":"tailnet","login":"alice@github","node":"box.tail.ts.net","tags":null}));
        assert!(admit(&whois("nSELF", 1, Value::Null), &me, false).is_ok());
        assert!(admit(&whois("nOTHER", 2, Value::Null), &me, false).is_err());
        assert!(admit(&whois("nOTHER", 1, json!(["tag:ci"])), &me, false).is_err());
        assert!(admit(&Value::Null, &me, true).is_err());
    }

    #[test]
    fn allow_identified_admits_other_users_and_tagged_devices() {
        let me = json!({"ID":"nSELF","UserID":1,"Tags":null});
        assert!(admit(&whois("nOTHER", 2, Value::Null), &me, true).is_ok());
        assert!(admit(&whois("nOTHER", 1, json!(["tag:ci"])), &me, true).is_ok());
    }

    #[test]
    fn a_tagged_server_has_no_owner() {
        let me = json!({"ID":"nSELF","UserID":9,"Tags":["tag:server"]});
        assert!(admit(&whois("nOTHER", 9, Value::Null), &me, false).is_err());
        assert!(admit(&whois("nSELF", 9, json!(["tag:server"])), &me, false).is_ok());
    }

    #[test]
    fn serve_admits_the_owner_login_only_unless_allowed() {
        let p = admit_serve(Some("alice@github"), Some("alice@github"), false).unwrap();
        assert_eq!(p, json!({"kind":"tailscale-serve","login":"alice@github"}));
        assert!(admit_serve(Some("bob@github"), Some("alice@github"), false).is_err());
        assert!(admit_serve(Some("bob@github"), Some("alice@github"), true).is_ok());
        // No header: a tagged device, or not through Serve at all.
        assert!(admit_serve(None, Some("alice@github"), true).is_err());
        assert!(admit_serve(Some(""), Some(""), true).is_err());
        // A tagged server has no owner.
        assert!(admit_serve(Some("alice@github"), None, false).is_err());
    }

    #[test]
    fn parses_listener_specs() {
        assert_eq!(parse("tailnet://:7000"), Ok(Listen::Tailnet(7000)));
        assert_eq!(parse("tailnet://"), Ok(Listen::Tailnet(DEFAULT_PORT)));
        assert_eq!(parse("tailnet-serve:///run/z/serve.sock"), Ok(Listen::Serve("/run/z/serve.sock".into())));
        assert!(parse("tailnet-serve://serve.sock").is_err());
        assert!(parse("tailnet://:0").is_err());
        assert!(parse(":7297").is_err());
    }

    #[tokio::test]
    async fn upgrade_returns_headers_and_keeps_bytes_sent_after_the_head() {
        let (mut client, server) = tokio::io::duplex(1024);
        let mut server = BufReader::new(server);
        client
            .write_all(b"GET /zurafa HTTP/1.1\r\nHost: box\r\nConnection: Upgrade\r\nUpgrade: Zurafa\r\nTailscale-User-Login: al@gh\r\n\r\nFRAMES")
            .await
            .unwrap();
        let headers = read_upgrade(&mut server).await.unwrap().unwrap();
        assert!(headers.contains(&("tailscale-user-login".into(), "al@gh".into())));
        let mut rest = [0; 6];
        server.read_exact(&mut rest).await.unwrap();
        assert_eq!(&rest, b"FRAMES");
    }

    #[tokio::test]
    async fn upgrade_refuses_plain_requests_and_endless_heads() {
        let (mut client, server) = tokio::io::duplex(1 << 16);
        client.write_all(b"GET / HTTP/1.1\r\nHost: box\r\n\r\n").await.unwrap();
        assert_eq!(read_upgrade(&mut BufReader::new(server)).await.unwrap(), None);
        let (mut client, server) = tokio::io::duplex(1 << 16);
        client.write_all(&[b'a'; 10_000]).await.unwrap();
        assert!(read_upgrade(&mut BufReader::new(server)).await.is_err());
    }
}
