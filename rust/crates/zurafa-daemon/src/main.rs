mod hosts;
mod listen;
mod osc7501;
mod protocol;
mod pty;
mod remote;
mod server;

use std::os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::process::Stdio;
use std::{env, fs, io, path::PathBuf};
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::signal::unix::{signal, SignalKind};

fn socket_path() -> PathBuf {
    let mut args = env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--socket" {
            if let Some(p) = args.next() {
                return p.into();
            }
        }
    }
    env::var_os("ZURAFA_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
            if cfg!(target_os = "macos") {
                home.join("Library/Application Support/Zurafa/daemon.sock")
            } else {
                // Not $XDG_RUNTIME_DIR: logind deletes it when the last login ends, orphaning the daemon.
                home.join(".zurafa/daemon.sock")
            }
        })
}

/// `zurafa-daemon bridge`: what `ssh host -- zurafa-daemon bridge` runs. Pipes stdin/stdout to
/// this machine's daemon socket, first starting a detached daemon that outlives the SSH login.
async fn bridge(path: PathBuf) -> io::Result<()> {
    let stream = match UnixStream::connect(&path).await {
        Ok(stream) => stream,
        Err(_) => {
            let mut daemon = std::process::Command::new(env::current_exe()?);
            daemon.args(["--exit-when-idle", "--socket"]).arg(&path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
            // SAFETY: setsid is async-signal-safe; a new session keeps SSH's hangup away from the daemon.
            unsafe { daemon.pre_exec(|| { libc::setsid(); Ok(()) }) };
            daemon.spawn()?;
            let mut tries = 0;
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                match UnixStream::connect(&path).await {
                    Ok(stream) => break stream,
                    Err(e) if tries == 100 => return Err(e),
                    Err(_) => tries += 1,
                }
            }
        }
    };
    let (mut from_daemon, mut to_daemon) = stream.into_split();
    let (mut stdin, mut stdout) = (tokio::io::stdin(), tokio::io::stdout());
    tokio::select! {
        r = tokio::io::copy(&mut stdin, &mut to_daemon) => r.map(drop),
        r = async { tokio::io::copy(&mut from_daemon, &mut stdout).await?; stdout.flush().await } => r,
    }
}

#[tokio::main]
async fn main() -> io::Result<()> {
    if env::args().nth(1).as_deref() == Some("remote") {
        remote::run(env::args().skip(2).collect());
    }
    let path = socket_path();
    if env::args().nth(1).as_deref() == Some("bridge") {
        return bridge(path).await;
    }
    env::set_var("ZURAFA_SOCKET", &path);
    if let Some(dir) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
    }
    if UnixStream::connect(&path).await.is_ok() {
        println!("zurafa-daemon is already running at {}", path.display());
        return Ok(());
    }
    // stale socket: remove it, but never some other kind of file
    if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_socket()) {
        fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    // shortcut: chmod after bind leaves a brief umask-mode window, covered by the 0700 parent dir; upgrade to umask(0o177) around bind if --socket may sit in a shared dir
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;

    let _hup = signal(SignalKind::hangup())?; // installing a handler (not SIG_IGN) keeps children's default dispositions
    let (mut term, mut int) = (
        signal(SignalKind::terminate())?,
        signal(SignalKind::interrupt())?,
    );
    let terms = pty::Terminals::new();
    let allow_identified = env::args().any(|a| a == "--tailnet-allow-identified");
    let mut args = env::args();
    while let Some(a) = args.next() {
        if a == "--extra-listen" {
            let port = listen::tailnet_port(&args.next().unwrap_or_default()).map_err(io::Error::other)?;
            listen::start(port, terms.clone(), allow_identified).await?;
        }
    }
    // Daemons a bridge starts on a remote host stop once nothing uses them, so old builds don't pile up.
    let exit_when_idle = env::args().any(|a| a == "--exit-when-idle");
    let mut idle_check = tokio::time::interval(std::time::Duration::from_secs(60));
    idle_check.tick().await;
    loop {
        tokio::select! {
            _ = idle_check.tick(), if exit_when_idle => if terms.idle() { break },
            r = listener.accept() => {
                if let Ok((stream, _)) = r {
                    tokio::spawn(server::handle(stream, terms.clone(), serde_json::Value::Null));
                }
            }
            _ = term.recv() => break,
            _ = int.recv() => break,
        }
    }
    fs::remove_file(&path)
}
