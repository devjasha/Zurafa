//! The app's own Tailscale device, as Rex has one: `zurafa-tailscale` (next to this binary) joins
//! the tailnet as its own device, serves HTTPS on :443 and forwards callers, named in
//! `Tailscale-User-Login`, to a `tailnet-serve://` socket here. Admission stays in `listen`.
//! The helper exits when this daemon closes its stdin, so it never outlives the daemon.
use crate::{
    listen::{self, Owner, Target},
    pty::Terminals,
};
use serde_json::Value;
use std::{
    io,
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, Command},
    task::AbortHandle,
};

struct Running {
    hostname: String,
    limit: bool,
    child: Child,
    stdin: ChildStdin,
    serve: AbortHandle,
    reader: AbortHandle,
}

static RUNNING: tokio::sync::Mutex<Option<Running>> = tokio::sync::Mutex::const_new(None);
/// The helper's latest status line; null while it is off.
static STATUS: Mutex<Value> = Mutex::new(Value::Null);

fn dir() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join("Library/Application Support/Zurafa/tailscale")
}

/// Starts, restarts (when the hostname or access limit changed) or stops the device.
/// Terminals and callers already connected stay connected.
/// Boxed with an explicit `Send`: connections it accepts can call it again, and the compiler
/// cannot infer `Send` through that cycle.
pub fn switch(terms: Arc<Terminals>, on: bool, limit: bool, hostname: String) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send>> {
    Box::pin(async move {
        let mut running = RUNNING.lock().await;
        if on && running.as_ref().is_some_and(|r| r.hostname == hostname && r.limit == limit) {
            return Ok(());
        }
        if let Some(mut old) = running.take() {
            old.serve.abort();
            old.reader.abort();
            let _ = old.child.kill().await;
            *STATUS.lock().unwrap() = Value::Null;
        }
        if !on {
            return Ok(());
        }
        let dir = dir();
        let socket = dir.join("serve.sock");
        let owner: Owner = Arc::new(Mutex::new(None));
        let serve = listen::start_serve(socket.clone(), owner.clone(), Target::Daemon(terms), !limit)?;
        let helper = std::env::current_exe()?.with_file_name("zurafa-tailscale");
        let mut child = match Command::new(&helper)
            .arg("-dir")
            .arg(dir.join("state"))
            .args(["-hostname", &hostname, "-socket"])
            .arg(&socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                serve.abort();
                return Err(io::Error::other(format!("cannot start {}: {e}", helper.display())));
            }
        };
        let (stdin, stdout) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
        *STATUS.lock().unwrap() = serde_json::json!({"state": "Starting"});
        let reader = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(status) = serde_json::from_str::<Value>(&line) else { continue };
                // Tagged devices have no owner, so only allow-identified callers get in.
                *owner.lock().unwrap() = status["login"].as_str().filter(|l| !l.is_empty()).map(str::to_owned);
                *STATUS.lock().unwrap() = status;
            }
            *STATUS.lock().unwrap() = serde_json::json!({"state": "Stopped", "error": "zurafa-tailscale exited"});
        })
        .abort_handle();
        *running = Some(Running { hostname, limit, child, stdin, serve, reader });
        Ok(())
    })
}

/// The device as the helper last reported it: state, auth_url, login, name, tags, cert, cert_error.
pub fn status() -> Value {
    STATUS.lock().unwrap().clone()
}

pub async fn on() -> bool {
    RUNNING.lock().await.is_some()
}

/// Signs the device out of Tailscale; it then waits for a new sign-in.
pub async fn logout() -> io::Result<()> {
    match RUNNING.lock().await.as_mut() {
        Some(r) => r.stdin.write_all(b"logout\n").await,
        None => Err(io::Error::other("Serve over Tailscale is off")),
    }
}
