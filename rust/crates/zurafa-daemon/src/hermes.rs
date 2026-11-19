//! Experimental: a chat with the user's Hermes Agent (Nous Research) through its API server. The
//! daemon alone talks to Hermes, so its key never leaves this machine; clients read the chat as
//! `ui.chat.read` block "hermes", in the same JSON lines as `zurafa-orch follow` (see chat.rs).
//! HTTP goes through curl, with the key passed on its stdin, never on its command line.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    sync::{Arc, Mutex, OnceLock},
};

pub const BLOCK: &str = "hermes";
const NOT_CONNECTED: &str = "Hermes is not connected. Set it up in Settings → Hermes.";
const MODE: &str = r#"{"kind":"mode","mode":"full"}"#;

#[derive(Clone, Serialize, Deserialize)]
struct Config {
    url: String,
    #[serde(default)]
    key: String,
    #[serde(default)]
    session: Option<String>,
    /// What the user calls their agent; empty is "Hermes".
    #[serde(default)]
    name: String,
    /// Its pixel-art avatar and color ids (PixelAvatar.swift); empty is the clients' default.
    #[serde(default)]
    avatar: String,
    #[serde(default)]
    color: String,
}

impl Default for Config {
    fn default() -> Self {
        Self { url: "http://127.0.0.1:8642".into(), key: String::new(), session: None, name: String::new(), avatar: String::new(), color: String::new() }
    }
}

struct State {
    path: PathBuf,
    cfg: Config,
    /// The index of `lines[0]`: a new chat numbers its lines on from the old one, as chat.rs does.
    base: usize,
    lines: Vec<String>,
    /// Whether `lines` holds the stored session's history yet.
    loaded: bool,
    busy: bool,
    /// Bumped by a new chat, so a run still streaming into the old one stops.
    generation: u64,
    next_id: u64,
}

impl State {
    fn id(&mut self) -> String {
        self.next_id += 1;
        format!("hermes-{}", self.next_id)
    }

    fn save(&self) -> Result<(), String> {
        let parent = self.path.parent().ok_or("invalid Hermes settings path")?;
        fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e| e.to_string())?;
        let tmp = self.path.with_extension("json.tmp");
        let mut file = OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp).map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec_pretty(&self.cfg).unwrap()).map_err(|e| e.to_string())?;
        fs::rename(tmp, &self.path).map_err(|e| e.to_string())
    }

    /// Starts an empty chat, numbered on from the old one.
    fn reset(&mut self) {
        self.base += self.lines.len();
        self.lines = vec![MODE.into()];
        self.loaded = true;
        self.busy = false;
        self.generation += 1;
    }
}

type Shared = Arc<Mutex<State>>;

fn state() -> &'static Shared {
    static STATE: OnceLock<Shared> = OnceLock::new();
    STATE.get_or_init(|| {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let path = if cfg!(target_os = "macos") { home.join("Library/Application Support/Zurafa/hermes.json") } else { home.join(".zurafa/hermes.json") };
        open(path)
    })
}

fn open(path: PathBuf) -> Shared {
    // A missing or broken file only means Hermes isn't set up.
    let cfg = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    Arc::new(Mutex::new(State { path, cfg, base: 0, lines: vec![MODE.into()], loaded: false, busy: false, generation: 0, next_id: 0 }))
}

/// `ui.hermes.config`: saves `url` and `key` when given (`key: ""` clears it), then checks them.
/// The answer never holds the key.
pub fn config(url: Option<String>, key: Option<String>, name: Option<String>, look: Look) -> Result<Value, String> {
    config_in(state(), url, key, name, look)
}

/// `ui.hermes.config`'s avatar and color ids; the clients know the sets, so the daemon only checks their form.
#[derive(Default)]
pub struct Look {
    pub avatar: Option<String>,
    pub color: Option<String>,
}

/// What the user calls their agent and its avatar, for clients to show: read with every chat read.
pub fn identity() -> Value {
    identity_of(&state().lock().unwrap().cfg)
}

fn identity_of(cfg: &Config) -> Value {
    json!({"name":shown_name(cfg),"avatar":cfg.avatar,"color":cfg.color})
}

fn shown_name(cfg: &Config) -> String {
    if cfg.name.is_empty() { "Hermes".into() } else { cfg.name.clone() }
}

fn config_in(s: &Shared, url: Option<String>, key: Option<String>, name: Option<String>, look: Look) -> Result<Value, String> {
    let cfg = {
        let mut st = s.lock().unwrap();
        if look.avatar.is_some() || look.color.is_some() {
            let cfg = &mut st.cfg;
            for (given, field) in [(look.avatar, &mut cfg.avatar), (look.color, &mut cfg.color)] {
                let Some(id) = given else { continue };
                if id.len() > 20 || !id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') {
                    return Err("Avatar and color ids are short lowercase words".into());
                }
                *field = id;
            }
            st.save()?;
        }
        if let Some(name) = name {
            let name = name.trim();
            if name.chars().count() > 40 || name.chars().any(char::is_control) {
                return Err("The name must be one line of at most 40 characters".into());
            }
            st.cfg.name = name.to_owned();
            st.save()?;
        }
        if url.is_some() || key.is_some() {
            if let Some(url) = url {
                let url = url.trim().trim_end_matches('/').to_owned();
                if !(url.starts_with("http://") || url.starts_with("https://")) || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
                    return Err("The Hermes URL must start with http:// or https://".into());
                }
                if url != st.cfg.url {
                    // Another server doesn't know this one's session.
                    st.cfg.session = None;
                    st.reset();
                }
                st.cfg.url = url;
            }
            if let Some(key) = key {
                if key.chars().any(char::is_control) {
                    return Err("The API key has an invalid character".into());
                }
                st.cfg.key = key.trim().to_owned();
            }
            st.save()?;
        }
        st.cfg.clone()
    };
    let check = if cfg.key.is_empty() { Err(None) } else { call(&cfg, "GET", "/v1/models", None).map_err(Some) };
    let mut v = identity_of(&cfg);
    v["url"] = cfg.url.clone().into();
    v["hasKey"] = (!cfg.key.is_empty()).into();
    v["connected"] = check.is_ok().into();
    if let Err(Some(e)) = check {
        v["error"] = e.into();
    }
    Ok(v)
}

/// `ui.chat.read` of block "hermes": lines from `from` on, the index to ask from next, and whether
/// Hermes is answering. The first read loads the stored session's history.
pub fn read(from: usize) -> Result<(Vec<String>, usize, bool), String> {
    read_in(state(), from)
}

fn read_in(s: &Shared, from: usize) -> Result<(Vec<String>, usize, bool), String> {
    load(s)?;
    let st = s.lock().unwrap();
    let end = st.base + st.lines.len();
    let from = if from < st.base || from > end { st.base } else { from };
    Ok((st.lines[from - st.base..].to_vec(), end, st.busy))
}

/// Loads the stored session's history once, without holding the lock over the request.
fn load(s: &Shared) -> Result<(), String> {
    let (cfg, generation) = {
        let st = s.lock().unwrap();
        if st.cfg.key.is_empty() {
            return Err(NOT_CONNECTED.into());
        }
        if st.loaded {
            return Ok(());
        }
        (st.cfg.clone(), st.generation)
    };
    let history = match &cfg.session {
        Some(id) => Some(call(&cfg, "GET", &format!("/api/sessions/{id}/messages"), None)?),
        None => None,
    };
    let mut st = s.lock().unwrap();
    if !st.loaded && st.generation == generation {
        st.loaded = true;
        if let Some(h) = history {
            let lines = history_lines(&mut st, &h);
            st.lines.extend(lines);
        }
    }
    Ok(())
}

/// `ui.hermes.send`: adds the user's line and streams Hermes' answer in the background.
/// `images` are files on this machine (a phone's go through `ui.paste_image` first).
pub fn send(text: String, images: Vec<String>) -> Result<(), String> {
    send_in(state(), text, &images)
}

fn send_in(s: &Shared, text: String, images: &[String]) -> Result<(), String> {
    load(s)?;
    let parts = image_parts(images)?;
    // Hermes takes text and images as parts, like OpenAI's chat content; text alone as a string.
    let input = if parts.is_empty() { json!(text) } else { Value::Array([json!({"type":"text","text":text})].into_iter().filter(|_| !text.is_empty()).chain(parts).collect()) };
    let shown = images.iter().fold(text.clone(), |t, p| {
        let name = Path::new(p).file_name().map_or(p.clone(), |n| n.to_string_lossy().into_owned());
        if t.is_empty() { format!("🖼 {name}") } else { format!("{t}\n🖼 {name}") }
    });
    let generation = {
        let mut st = s.lock().unwrap();
        if st.busy {
            return Err("Hermes is still answering".into());
        }
        st.busy = true;
        let line = json!({"kind":"user","id":st.id(),"text":shown,"at":now()}).to_string();
        st.lines.push(line);
        st.generation
    };
    let s = s.clone();
    std::thread::spawn(move || {
        let result = stream(&s, generation, &input);
        let mut st = s.lock().unwrap();
        if st.generation == generation {
            if let Err(e) = result {
                let line = json!({"kind":"assistant","id":st.id(),"text":format!("Hermes failed: {e}"),"at":now()}).to_string();
                st.lines.push(line);
            }
            st.busy = false;
        }
    });
    Ok(())
}

/// `ui.hermes.new`: forgets the session; the next send starts one.
pub fn new_chat() -> Result<(), String> {
    let mut st = state().lock().unwrap();
    st.cfg.session = None;
    st.reset();
    st.save()
}

/// Runs one turn: creates the session if there is none, then turns Hermes' SSE events into lines.
fn stream(s: &Shared, generation: u64, input: &Value) -> Result<(), String> {
    let cfg = s.lock().unwrap().cfg.clone();
    let session = match cfg.session.clone() {
        Some(id) => id,
        None => {
            let v = call(&cfg, "POST", "/api/sessions", Some(&json!({})))?;
            let id = [&v["id"], &v["session_id"], &v["session"]["id"]]
                .into_iter()
                .find_map(|i| i.as_str().map(str::to_owned).or_else(|| i.as_u64().map(|n| n.to_string())))
                .ok_or("Hermes created a session without an id")?;
            let mut st = s.lock().unwrap();
            if st.generation != generation {
                return Ok(());
            }
            st.cfg.session = Some(id.clone());
            st.save()?;
            id
        }
    };
    let (mut child, _body) = curl(&cfg, "POST", &format!("/api/sessions/{session}/chat/stream"), Some(&json!({"input":input})), true).map_err(|e| e.to_string())?;
    let out = child.stdout.take().ok_or("no output")?;
    let mut turn = Turn::default();
    let (mut event, mut data) = (String::new(), String::new());
    let mut ended = false;
    for line in BufReader::new(out).lines() {
        let line = line.map_err(|e| e.to_string())?;
        if let Some(e) = line.strip_prefix("event:") {
            event = e.trim().to_owned();
        } else if let Some(d) = line.strip_prefix("data:") {
            data.push_str(d.strip_prefix(' ').unwrap_or(d));
        } else if line.is_empty() && !data.is_empty() {
            let v: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
            let name = if event.is_empty() { v["type"].as_str().or(v["event"].as_str()).unwrap_or("").to_owned() } else { std::mem::take(&mut event) };
            data.clear();
            let mut st = s.lock().unwrap();
            if st.generation != generation {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(());
            }
            let lines = turn.event(&mut st, &name, &v);
            st.lines.extend(lines);
            ended |= name.starts_with("run.");
        }
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    let mut st = s.lock().unwrap();
    let flushed = turn.flush(&mut st);
    st.lines.extend(flushed);
    if !output.status.success() {
        return Err(failure(&cfg, &output));
    }
    if !ended {
        return Err("the answer stopped before it finished".into());
    }
    Ok(())
}

/// One run's text not yet complete, and its tools by Hermes' id.
#[derive(Default)]
struct Turn {
    text: String,
    tools: HashMap<String, String>,
    last_tool: Option<String>,
}

impl Turn {
    fn event(&mut self, st: &mut State, name: &str, v: &Value) -> Vec<String> {
        match name {
            "assistant.delta" => {
                self.text.push_str(&text(v));
                vec![]
            }
            // A finished piece of the answer; its deltas, if any, came before it.
            "assistant.commentary" => {
                let t = text(v);
                if !t.is_empty() {
                    self.text = t;
                }
                self.flush(st)
            }
            "tool.started" => {
                let mut out = self.flush(st);
                let id = st.id();
                if let Some(h) = hermes_id(v) {
                    self.tools.insert(h, id.clone());
                }
                self.last_tool = Some(id.clone());
                let tool = [&v["tool"], &v["name"], &v["tool_name"]].into_iter().find_map(Value::as_str).unwrap_or("tool");
                out.push(json!({"kind":"tool","id":id,"tool":tool,"input":preview(v, &["preview", "input", "args", "arguments"]),"at":now()}).to_string());
                out
            }
            "tool.completed" | "tool.failed" => {
                let Some(id) = hermes_id(v).and_then(|h| self.tools.get(&h).cloned()).or_else(|| self.last_tool.clone()) else { return vec![] };
                vec![json!({"kind":"result","for":id,"text":preview(v, &["preview", "result", "output", "error"]),"ok":name == "tool.completed","at":now()}).to_string()]
            }
            "run.completed" | "run.cancelled" => {
                if self.text.is_empty() {
                    self.text = [&v["output"], &v["text"], &v["content"]].into_iter().find_map(Value::as_str).unwrap_or("").to_owned();
                }
                self.flush(st)
            }
            "run.failed" => {
                let mut out = self.flush(st);
                let e = preview(v, &["error", "message", "detail"]);
                out.push(json!({"kind":"assistant","id":st.id(),"text":format!("Hermes failed: {}", if e.is_empty() { "unknown error" } else { &e }),"at":now()}).to_string());
                out
            }
            _ => vec![],
        }
    }

    /// The text so far as one complete assistant line: clients never update a line.
    fn flush(&mut self, st: &mut State) -> Vec<String> {
        if self.text.trim().is_empty() {
            self.text.clear();
            return vec![];
        }
        vec![json!({"kind":"assistant","id":st.id(),"text":std::mem::take(&mut self.text),"at":now()}).to_string()]
    }
}

fn hermes_id(v: &Value) -> Option<String> {
    [&v["id"], &v["tool_call_id"], &v["call_id"]].into_iter().find_map(|i| i.as_str().map(str::to_owned))
}

/// Text in `delta`, `text` or `content`, which may be OpenAI-style parts.
fn text(v: &Value) -> String {
    for k in ["delta", "text", "content"] {
        match &v[k] {
            Value::String(s) => return s.clone(),
            Value::Array(parts) => {
                return parts.iter().filter_map(|p| p["text"].as_str().or(p.as_str()).or(p.get("image_url").map(|_| "\n🖼 image\n"))).collect::<Vec<_>>().join("").trim().to_owned()
            }
            _ => {}
        }
    }
    String::new()
}

/// The first of `keys` present, as text, cut short: previews go to the phone.
fn preview(v: &Value, keys: &[&str]) -> String {
    let s = keys.iter().map(|k| &v[*k]).find(|x| !x.is_null()).map_or(String::new(), |x| x.as_str().map_or_else(|| x.to_string(), str::to_owned));
    s.chars().take(2000).collect()
}

/// A session's stored messages as chat lines.
fn history_lines(st: &mut State, h: &Value) -> Vec<String> {
    let messages = h.as_array().or(h["messages"].as_array()).or(h["data"].as_array()).cloned().unwrap_or_default();
    let mut tools = HashMap::new();
    let mut out = vec![];
    for m in &messages {
        match m["role"].as_str().unwrap_or("") {
            "user" => out.push(json!({"kind":"user","id":st.id(),"text":text(m)}).to_string()),
            "assistant" => {
                let t = text(m);
                if !t.trim().is_empty() {
                    out.push(json!({"kind":"assistant","id":st.id(),"text":t}).to_string());
                }
                for c in m["tool_calls"].as_array().into_iter().flatten() {
                    let id = st.id();
                    if let Some(h) = c["id"].as_str() {
                        tools.insert(h.to_owned(), id.clone());
                    }
                    let tool = c["function"]["name"].as_str().or(c["name"].as_str()).unwrap_or("tool");
                    out.push(json!({"kind":"tool","id":id,"tool":tool,"input":preview(&c["function"], &["arguments"])}).to_string());
                }
            }
            "tool" => {
                if let Some(id) = m["tool_call_id"].as_str().and_then(|h| tools.get(h)) {
                    out.push(json!({"kind":"result","for":id,"text":preview(&json!({"t":text(m)}), &["t"]),"ok":true}).to_string());
                }
            }
            _ => {}
        }
    }
    out
}

/// The images of one message as Hermes' `image_url` parts with data URLs. Hermes takes images only,
/// and at most 10 MB per request: base64 makes 7 MiB of images about 9.8 MB.
fn image_parts(paths: &[String]) -> Result<Vec<Value>, String> {
    let mut total = 0;
    paths
        .iter()
        .map(|p| {
            let name = Path::new(p).file_name().map_or(p.clone(), |n| n.to_string_lossy().into_owned());
            let bytes = fs::read(p).map_err(|e| format!("Cannot read {name}: {e}"))?;
            let mime = match bytes.as_slice() {
                [0x89, b'P', b'N', b'G', ..] => "image/png",
                [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
                [b'G', b'I', b'F', b'8', ..] => "image/gif",
                [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
                _ => return Err(format!("Hermes takes images only (PNG, JPEG, GIF or WebP), and {name} is not one.")),
            };
            total += bytes.len();
            if total > 7 << 20 {
                return Err("The images are too large for Hermes, which takes up to 7 MB of images per message.".into());
            }
            Ok(json!({"type":"image_url","image_url":{"url":format!("data:{mime};base64,{}", B64.encode(&bytes))}}))
        })
        .collect()
}

/// A request body curl reads from a file: an image message is too long for a config line. Removed when dropped.
struct BodyFile(PathBuf);
impl Drop for BodyFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Starts curl for one request. Everything, the key included, goes in its config on stdin; a body goes
/// in a private file, kept until the returned guard drops (after curl is done).
fn curl(cfg: &Config, method: &str, path: &str, body: Option<&Value>, stream: bool) -> std::io::Result<(Child, Option<BodyFile>)> {
    let q = |s: &str| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""));
    let mut conf = format!("url = {}\nrequest = {method}\nconnect-timeout = 5\n", q(&format!("{}{path}", cfg.url)));
    if !cfg.key.is_empty() {
        conf += &format!("header = {}\n", q(&format!("Authorization: Bearer {}", cfg.key)));
    }
    let file = match body {
        Some(b) => {
            static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!("zurafa-hermes-{}-{}.json", std::process::id(), N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
            let file = BodyFile(path);
            OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&file.0)?.write_all(b.to_string().as_bytes())?;
            conf += &format!("header = \"Content-Type: application/json\"\ndata-binary = {}\n", q(&format!("@{}", file.0.display())));
            Some(file)
        }
        None => None,
    };
    conf += if stream { "no-buffer\nheader = \"Accept: text/event-stream\"\n" } else { "max-time = 20\n" };
    let mut child = Command::new("curl")
        .args(["--silent", "--show-error", "--fail-with-body", "--config", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(conf.as_bytes())?;
    Ok((child, file))
}

/// One request's JSON answer.
fn call(cfg: &Config, method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
    let out = curl(cfg, method, path, body, false).and_then(|(c, _body)| c.wait_with_output()).map_err(|e| format!("cannot run curl: {e}"))?;
    if !out.status.success() {
        return Err(failure(cfg, &out));
    }
    serde_json::from_slice(&out.stdout).map_err(|_| "Hermes answered with something other than JSON".into())
}

fn failure(cfg: &Config, out: &Output) -> String {
    match out.status.code() {
        Some(7) => return format!("Cannot reach Hermes at {}. Is `hermes gateway` running with API_SERVER_ENABLED=true?", cfg.url),
        Some(28) => return "Hermes did not answer in time".into(),
        _ => {}
    }
    let body: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    let said = [&body["error"]["message"], &body["error"], &body["detail"], &body["message"]].into_iter().find_map(Value::as_str);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let e = said.map(str::to_owned).unwrap_or_else(|| stderr.trim().trim_start_matches("curl: ").to_owned());
    if e.contains("401") || e.contains("403") { format!("Hermes refused the API key ({e})") } else { e }
}

/// Now in ISO 8601 UTC with milliseconds, as ChatLog parses it.
fn now() -> String {
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    iso(d.as_secs() as i64, d.subsec_millis())
}

fn iso(secs: i64, millis: u32) -> String {
    // Howard Hinnant's days-to-civil.
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{millis:03}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_dates() {
        assert_eq!(iso(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso(1_709_210_096, 5), "2024-02-29T12:34:56.005Z");
    }

    /// A fake Hermes: python's http.server answering the endpoints Zurafa uses, checking the key.
    const FAKE: &str = r#"
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def auth(self):
        if self.headers.get("Authorization") != 'Bearer s3"cr\\et':
            self.send_response(401); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}'); return False
        return True
    def reply(self, v):
        b = json.dumps(v).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if not self.auth(): return
        if self.path == "/v1/models": self.reply({"data": [{"id": "hermes"}]})
        elif self.path == "/api/sessions/old/messages": self.reply({"messages": [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "function": {"name": "ls", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": "a.txt"},
            {"role": "assistant", "content": [{"type": "text", "text": "One file."}]}]})
        else: self.send_error(404)
    def do_POST(self):
        if not self.auth(): return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/sessions": self.reply({"session_id": "s1"})
        elif self.path == "/api/sessions/s1/chat/stream":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            def ev(name, v): self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(v))).encode()); self.wfile.flush()
            self.wfile.write(b": keepalive\n\n")
            ev("assistant.delta", {"delta": "Let me "}); ev("assistant.delta", {"delta": "look."})
            ev("assistant.commentary", {"message_id": "m1", "text": "Let me look.", "already_streamed": True})
            ev("tool.started", {"tool_call_id": "t1", "tool": "terminal", "preview": "ls"})
            ev("tool.completed", {"tool_call_id": "t1", "preview": "a.txt"})
            i = body["input"]
            ev("assistant.delta", {"delta": "You said: " + (i if isinstance(i, str) else " + ".join(p.get("text") or p["image_url"]["url"][:22] for p in i))})
            ev("run.completed", {})
        else: self.send_error(404)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
"#;

    struct Fake(Child, String);
    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    fn fake() -> Fake {
        let mut c = Command::new("python3").args(["-c", FAKE]).stdout(Stdio::piped()).spawn().expect("python3");
        let mut port = String::new();
        BufReader::new(c.stdout.take().unwrap()).read_line(&mut port).unwrap();
        Fake(c, format!("http://127.0.0.1:{}", port.trim()))
    }

    fn temp(name: &str) -> Shared {
        let dir = std::env::temp_dir().join(format!("zurafa-hermes-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        open(dir.join("hermes.json"))
    }

    fn kinds(lines: &[String]) -> Vec<String> {
        lines.iter().map(|l| serde_json::from_str::<Value>(l).unwrap()["kind"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn connects_streams_a_turn_and_reloads_history() {
        let f = fake();
        let s = temp("chat");
        assert_eq!(read_in(&s, 0).unwrap_err(), NOT_CONNECTED);
        let bad = config_in(&s, Some(f.1.clone()), Some("wrong".into()), None, Look::default()).unwrap();
        assert_eq!((bad["connected"].as_bool(), bad["hasKey"].as_bool()), (Some(false), Some(true)));
        assert!(bad["error"].as_str().unwrap().contains("bad key"), "{bad}");
        let good = config_in(&s, None, Some("s3\"cr\\et".into()), None, Look::default()).unwrap();
        assert_eq!(good["connected"], true, "{good}");
        assert!(good.get("key").is_none());
        let saved = fs::read_to_string(&s.lock().unwrap().path).unwrap();
        assert!(saved.contains("s3\\\"cr"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&s.lock().unwrap().path).unwrap().permissions().mode() & 0o777, 0o600);

        send_in(&s, "hello".into(), &[]).unwrap();
        assert!(send_in(&s, "again".into(), &[]).is_err(), "busy");
        let (lines, next, _) = (0..100)
            .map(|_| {
                std::thread::sleep(std::time::Duration::from_millis(50));
                read_in(&s, 0).unwrap()
            })
            .find(|r| !r.2)
            .expect("the run ends");
        assert_eq!(kinds(&lines), ["mode", "user", "assistant", "tool", "result", "assistant"], "{lines:?}");
        let v: Vec<Value> = lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(v[2]["text"], "Let me look.");
        assert_eq!((v[3]["tool"].as_str(), v[3]["input"].as_str()), (Some("terminal"), Some("ls")));
        assert_eq!((&v[4]["for"], v[4]["ok"].as_bool()), (&v[3]["id"], Some(true)));
        assert_eq!(v[5]["text"], "You said: hello");
        assert_eq!(read_in(&s, next).unwrap().0.len(), 0);
        assert_eq!(s.lock().unwrap().cfg.session.as_deref(), Some("s1"));

        // A daemon restart reads the stored session's history.
        let path = s.lock().unwrap().path.clone();
        let mut cfg: Config = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        cfg.session = Some("old".into());
        fs::write(&path, serde_json::to_vec(&cfg).unwrap()).unwrap();
        let s = open(path.clone());
        let (lines, _, busy) = read_in(&s, 0).unwrap();
        assert!(!busy);
        assert_eq!(kinds(&lines), ["mode", "user", "tool", "result", "assistant"], "{lines:?}");

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn sends_images_as_data_urls_and_refuses_other_files() {
        let f = fake();
        let s = temp("images");
        config_in(&s, Some(f.1.clone()), Some("s3\"cr\\et".into()), None, Look::default()).unwrap();
        let dir = s.lock().unwrap().path.parent().unwrap().to_owned();
        let (png, txt) = (dir.join("shot.png"), dir.join("notes.txt"));
        fs::write(&png, b"\x89PNG\r\n\x1a\nrest").unwrap();
        fs::write(&txt, b"hello").unwrap();
        let err = send_in(&s, "look".into(), &[txt.display().to_string()]).unwrap_err();
        assert!(err.contains("notes.txt is not one"), "{err}");
        assert!(!s.lock().unwrap().busy, "a refused message starts no run");

        send_in(&s, "look".into(), &[png.display().to_string()]).unwrap();
        let (lines, _, _) = (0..100)
            .map(|_| {
                std::thread::sleep(std::time::Duration::from_millis(50));
                read_in(&s, 0).unwrap()
            })
            .find(|r| !r.2)
            .expect("the run ends");
        let v: Vec<Value> = lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(v[1]["text"], "look\n🖼 shot.png");
        assert_eq!(v.last().unwrap()["text"], "You said: look + data:image/png;base64,");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn unreachable_hermes_says_so() {
        let s = temp("down");
        let v = config_in(&s, Some("http://127.0.0.1:9".into()), Some("k".into()), None, Look::default()).unwrap();
        assert_eq!(v["connected"], false);
        assert!(v["error"].as_str().unwrap().contains("Cannot reach Hermes"), "{v}");
        assert!(config_in(&s, Some("file:///etc/passwd".into()), None, None, Look::default()).is_err());
        assert_eq!(v["name"], "Hermes", "no name set");
        assert_eq!(config_in(&s, None, None, Some("  Jarvis ".into()), Look::default()).unwrap()["name"], "Jarvis");
        assert!(config_in(&s, None, None, Some("two\nlines".into()), Look::default()).is_err());
        assert_eq!(config_in(&s, None, None, Some("".into()), Look::default()).unwrap()["name"], "Hermes", "cleared");
        assert_eq!(v["avatar"], "", "no avatar set");
        let look = Look { avatar: Some("fox".into()), color: Some("teal".into()) };
        let v = config_in(&s, None, None, None, look).unwrap();
        assert_eq!((v["avatar"].as_str(), v["color"].as_str()), (Some("fox"), Some("teal")));
        assert_eq!(identity_of(&open(s.lock().unwrap().path.clone()).lock().unwrap().cfg)["avatar"], "fox", "kept in hermes.json");
        assert!(config_in(&s, None, None, None, Look { avatar: Some("../x".into()), color: None }).is_err());
        let _ = fs::remove_dir_all(s.lock().unwrap().path.parent().unwrap());
    }
}
