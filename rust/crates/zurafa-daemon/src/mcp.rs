//! Lets the user's Hermes Agent, on another machine of their tailnet, see and control Zurafa: an
//! MCP server (Streamable HTTP, stateless, JSON replies) at `POST /mcp` on the app's own Tailscale
//! device (tsnet.rs), so it is reachable only from the tailnet and only while Remote Access is on.
//! Off by default; when off, or without this Zurafa's bearer token, every request is refused.
//! Each message is answered by `zurafa mcp`, the same tools local agents get.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::PathBuf,
    process::Stdio,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};

/// The largest request body: tool arguments are a few lines of text.
const MAX_BODY: usize = 1 << 20;

#[derive(Default, Serialize, Deserialize)]
struct Config {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    token: String,
}

fn path() -> PathBuf {
    let home = PathBuf::from(env::var_os("HOME").unwrap_or_default());
    if cfg!(target_os = "macos") { home.join("Library/Application Support/Zurafa/hermes-mcp.json") } else { home.join(".zurafa/hermes-mcp.json") }
}

fn load() -> Config {
    fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save(cfg: &Config) -> Result<(), String> {
    let path = path();
    let parent = path.parent().ok_or("invalid settings path")?;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    let mut file = OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec_pretty(cfg).unwrap()).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}

fn new_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).map_err(|e| e.to_string())?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// `ui.hermes.control`: turns control on or off and makes a new token when asked (or when it has
/// none yet). The answer holds the switch, the token and the endpoint's URL, once Remote Access
/// has a name for this Mac.
pub fn control(enabled: Option<bool>, renew: bool) -> Result<Value, String> {
    let mut cfg = load();
    let before = (cfg.enabled, cfg.token.clone());
    if let Some(on) = enabled {
        cfg.enabled = on;
    }
    if renew || cfg.token.is_empty() {
        cfg.token = new_token()?;
    }
    if (cfg.enabled, &cfg.token) != (before.0, &before.1) {
        save(&cfg)?;
    }
    let url = crate::tsnet::status()["name"].as_str().filter(|n| !n.is_empty()).map(|n| format!("https://{n}/mcp"));
    Ok(json!({"enabled": cfg.enabled, "token": cfg.token, "url": url}))
}

/// Whether an HTTP request line is for this endpoint.
pub fn wants(request_line: &str) -> bool {
    let path = request_line.split(' ').nth(1).unwrap_or_default();
    matches!(path.split('?').next(), Some("/mcp" | "/mcp/"))
}

/// Why a request may not run tools: the HTTP status and a reason.
fn refuse(cfg: &Config, method: &str, headers: &[(String, String)]) -> Option<(u16, &'static str)> {
    if !cfg.enabled || cfg.token.is_empty() {
        return Some((403, "Zurafa control is off. Turn it on in Zurafa Settings → Hermes."));
    }
    let given = headers.iter().find(|(name, _)| name == "authorization").and_then(|(_, v)| v.strip_prefix("Bearer ")).unwrap_or_default();
    // Constant time, so the token cannot be guessed byte by byte.
    let same = given.len() == cfg.token.len() && given.bytes().zip(cfg.token.bytes()).fold(0, |d, (a, b)| d | (a ^ b)) == 0;
    if !same {
        return Some((401, "Wrong or missing bearer token."));
    }
    // A stateless server has no event stream to GET and no session to DELETE.
    (method != "POST").then_some((405, "Only POST is supported."))
}

fn reply(status: u16, content_type: &str, body: &str) -> String {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Payload Too Large",
        _ => "Internal Server Error",
    };
    let extra = match status {
        401 => "WWW-Authenticate: Bearer\r\n",
        405 => "Allow: POST\r\n",
        _ => "",
    };
    format!("HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
}

fn text(status: u16, why: &str) -> String {
    reply(status, "text/plain; charset=utf-8", &format!("{why}\n"))
}

/// The `zurafa` command: the one the app ships in Resources beside this daemon's MacOS folder, or
/// one beside this daemon (a development build).
fn cli() -> Option<PathBuf> {
    let dir = env::current_exe().ok()?.parent()?.to_path_buf();
    [dir.join("../Resources/zurafa"), dir.join("zurafa")].into_iter().find(|p| p.is_file())
}

/// One JSON-RPC message through `zurafa mcp`; its reply line, empty for a notification.
async fn run(message: &Value) -> Result<String, String> {
    let cli = cli().ok_or("zurafa is missing from this Zurafa install")?;
    let mut child = tokio::process::Command::new(cli)
        .arg("mcp")
        // It reaches this daemon by ZURAFA_SOCKET; it is in no pane of its own.
        .env_remove("ZURAFA_PANE")
        .env_remove("ZURAFA_BLOCK")
        .env_remove("ZURAFA_SESSION")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(format!("{message}\n").as_bytes()).await.map_err(|e| e.to_string())?;
    drop(stdin);
    let out = child.wait_with_output().await.map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// Answers one HTTP request whose head has been read; `headers` have lowercase names.
pub async fn serve<S>(mut stream: BufReader<S>, request_line: &str, headers: &[(String, String)])
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let method = request_line.split(' ').next().unwrap_or_default();
    let header = |name: &str| headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str());
    let response = match refuse(&load(), method, headers) {
        Some((status, why)) => text(status, why),
        None if header("transfer-encoding").is_some() => text(411, "Send a Content-Length."),
        None => match header("content-length").and_then(|l| l.parse::<usize>().ok()) {
            None => text(411, "Send a Content-Length."),
            Some(len) if len > MAX_BODY => text(413, "The request is too large."),
            Some(len) => {
                let mut body = vec![0; len];
                if stream.read_exact(&mut body).await.is_err() {
                    return;
                }
                match serde_json::from_slice::<Value>(&body) {
                    Err(e) => reply(400, "application/json", &json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":e.to_string()}}).to_string()),
                    Ok(message) => match run(&message).await {
                        Ok(out) if out.is_empty() => reply(202, "text/plain", ""),
                        Ok(out) => reply(200, "application/json", &out),
                        Err(e) => text(500, &e),
                    },
                }
            }
        },
    };
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.flush().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auth(v: &str) -> Vec<(String, String)> {
        vec![("authorization".into(), v.into())]
    }

    #[test]
    fn refuses_all_while_off_and_without_the_token() {
        let off = Config { enabled: false, token: "abc".into() };
        assert_eq!(refuse(&off, "POST", &auth("Bearer abc")).unwrap().0, 403);
        let on = Config { enabled: true, token: "abc".into() };
        assert_eq!(refuse(&on, "POST", &auth("Bearer abc")), None);
        assert_eq!(refuse(&on, "POST", &auth("Bearer abd")).unwrap().0, 401);
        assert_eq!(refuse(&on, "POST", &auth("Bearer ab")).unwrap().0, 401);
        assert_eq!(refuse(&on, "POST", &auth("abc")).unwrap().0, 401);
        assert_eq!(refuse(&on, "POST", &[]).unwrap().0, 401);
        // Hermes probes with HEAD and GET first; 405 tells it this is a POST-only endpoint.
        assert_eq!(refuse(&on, "GET", &auth("Bearer abc")).unwrap().0, 405);
        assert_eq!(refuse(&Config { enabled: true, token: String::new() }, "POST", &auth("Bearer ")).unwrap().0, 403);
    }

    #[test]
    fn serves_only_its_path() {
        assert!(wants("POST /mcp HTTP/1.1"));
        assert!(wants("HEAD /mcp/ HTTP/1.1"));
        assert!(wants("POST /mcp?x=1 HTTP/1.1"));
        assert!(!wants("GET /zurafa HTTP/1.1"));
        assert!(!wants("POST /mcpx HTTP/1.1"));
    }

    #[tokio::test]
    async fn answers_over_http_without_running_tools_when_refused() {
        let (mut client, server) = tokio::io::duplex(4096);
        let headers = vec![("content-length".into(), "2".into())];
        let task = tokio::spawn(async move { serve(BufReader::new(server), "POST /mcp HTTP/1.1", &headers).await });
        client.write_all(b"{}").await.unwrap();
        let mut out = String::new();
        client.read_to_string(&mut out).await.unwrap();
        task.await.unwrap();
        // No token was sent: refused whether control is on or off on this machine.
        assert!(out.starts_with("HTTP/1.1 40"), "{out}");
        assert!(out.contains("Connection: close"));
    }

    #[test]
    fn tokens_are_random_hex() {
        let (a, b) = (new_token().unwrap(), new_token().unwrap());
        assert_eq!(a.len(), 64);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}
