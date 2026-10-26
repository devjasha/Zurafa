//! `--extra-listen tailnet://[:PORT]`: the daemon also listens on this machine's Tailscale
//! addresses, as Rex does. Tailscale says who is calling: by default only this device and its
//! owner get in; `--tailnet-allow-identified` admits anyone Tailscale can name, tagged devices
//! included. An admitted caller sends an HTTP/1.1 `GET` with `Upgrade: zurafa`; after the 101 the
//! connection carries the same length-prefixed frames as the Unix socket.
use crate::{hosts::tailscale, pty::Terminals, server};
use serde_json::{json, Value};
use std::{
    io::{self, ErrorKind},
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

pub const DEFAULT_PORT: u16 = 7297;

/// The port in `tailnet://:PORT`, or the default for `tailnet://`.
pub fn tailnet_port(spec: &str) -> Result<u16, String> {
    let rest = spec
        .strip_prefix("tailnet://")
        .ok_or_else(|| format!("unsupported listener {spec:?}; use tailnet://:PORT"))?;
    match rest {
        "" | ":" => Ok(DEFAULT_PORT),
        _ => rest
            .strip_prefix(':')
            .and_then(|p| p.parse().ok())
            .filter(|p| *p != 0)
            .ok_or_else(|| format!("bad port in {spec:?}")),
    }
}

/// Binds every Tailscale address of this machine, never a wildcard address.
pub async fn start(port: u16, terms: Arc<Terminals>, allow_identified: bool) -> io::Result<()> {
    let me: Value = tokio::task::spawn_blocking(|| tailscale(&["status", "--json"]))
        .await
        .ok()
        .flatten()
        .and_then(|out| serde_json::from_slice::<Value>(&out).ok())
        .map(|status| status["Self"].clone())
        .filter(|me| me["Online"] == true)
        .ok_or_else(|| io::Error::other("tailnet listener needs Tailscale running and signed in"))?;
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
        let listener = TcpListener::bind(addr).await?;
        eprintln!("zurafa-daemon listening on tailnet {addr}");
        let (terms, me) = (terms.clone(), me.clone());
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, peer)) => {
                        tokio::spawn(serve(stream, peer.ip(), terms.clone(), me.clone(), allow_identified));
                    }
                    // e.g. out of file descriptors: back off instead of spinning
                    Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
                }
            }
        });
    }
    Ok(())
}

async fn serve<S>(stream: S, peer: IpAddr, terms: Arc<Terminals>, me: Arc<Value>, allow_identified: bool)
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
    let principal = match admit(&whois, &me, allow_identified) {
        Ok(principal) => principal,
        Err(why) => {
            let body = format!("{why}\n");
            let _ = stream
                .write_all(format!("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes())
                .await;
            return;
        }
    };
    if upgrade(&mut stream).await.is_ok() {
        server::handle(stream, terms, principal).await;
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

/// Reads an HTTP/1.1 `GET` with `Upgrade: zurafa` (head at most 8 KiB) and answers 101.
async fn upgrade<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut BufReader<S>) -> io::Result<()> {
    let mut head = (&mut *stream).take(8192);
    let mut line = String::new();
    head.read_line(&mut line).await?;
    let get = line.starts_with("GET /") && line.trim_end().ends_with(" HTTP/1.1");
    let mut wants_zurafa = false;
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
            wants_zurafa |= name.trim().eq_ignore_ascii_case("upgrade") && value.trim().eq_ignore_ascii_case("zurafa");
        }
    }
    if !(get && wants_zurafa) {
        stream
            .write_all(b"HTTP/1.1 426 Upgrade Required\r\nUpgrade: zurafa\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            .await?;
        return Err(ErrorKind::InvalidData.into());
    }
    stream
        .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: zurafa\r\nConnection: Upgrade\r\n\r\n")
        .await
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
    fn parses_listener_specs() {
        assert_eq!(tailnet_port("tailnet://:7000"), Ok(7000));
        assert_eq!(tailnet_port("tailnet://"), Ok(DEFAULT_PORT));
        assert!(tailnet_port("tailnet://:0").is_err());
        assert!(tailnet_port(":7297").is_err());
    }

    #[tokio::test]
    async fn upgrade_switches_and_keeps_bytes_sent_after_the_head() {
        let (client, server) = tokio::io::duplex(1024);
        let mut server = BufReader::new(server);
        let (mut cr, mut cw) = tokio::io::split(client);
        cw.write_all(b"GET /zurafa HTTP/1.1\r\nHost: box\r\nConnection: Upgrade\r\nUpgrade: Zurafa\r\n\r\nFRAMES").await.unwrap();
        upgrade(&mut server).await.unwrap();
        let mut rest = [0; 6];
        server.read_exact(&mut rest).await.unwrap();
        assert_eq!(&rest, b"FRAMES");
        drop(server);
        let mut reply = String::new();
        cr.read_to_string(&mut reply).await.unwrap();
        assert!(reply.starts_with("HTTP/1.1 101 "));
    }

    #[tokio::test]
    async fn upgrade_refuses_plain_requests_and_endless_heads() {
        let (mut client, server) = tokio::io::duplex(1 << 16);
        client.write_all(b"GET / HTTP/1.1\r\nHost: box\r\n\r\n").await.unwrap();
        assert!(upgrade(&mut BufReader::new(server)).await.is_err());
        let (mut client, server) = tokio::io::duplex(1 << 16);
        client.write_all(&[b'a'; 10_000]).await.unwrap();
        assert!(upgrade(&mut BufReader::new(server)).await.is_err());
    }
}
