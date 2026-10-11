mod hosts;
mod osc7501;
mod protocol;
mod pty;
mod server;

use std::os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt};
use std::{env, fs, io, path::PathBuf};
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
            home.join("Library/Application Support/Zurafa/daemon.sock")
        })
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let path = socket_path();
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
    loop {
        tokio::select! {
            r = listener.accept() => {
                if let Ok((stream, _)) = r {
                    tokio::spawn(server::handle(stream, terms.clone()));
                }
            }
            _ = term.recv() => break,
            _ = int.recv() => break,
        }
    }
    fs::remove_file(&path)
}
