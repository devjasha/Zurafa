//! `zurafa-daemon install-service` / `uninstall-service`, run on a Linux host (the app runs them
//! over SSH): a systemd user service keeps a daemon listening on the tailnet, so remote tabs to
//! this host connect directly instead of through SSH.
//!
//! `sudo zurafa-daemon install-login-server` / `uninstall-login-server` set up the system-wide
//! login server instead (see `login`), as Rex's `rex-login-server.service`.
use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::{env, thread, time::Duration};

const UNIT: &str = "zurafa.service";

const UNIT_FILE: &str = "\
[Unit]
Description=Zurafa daemon for direct connections over Tailscale
After=network-online.target
# Tailscale may come up after us: keep retrying instead of giving up.
StartLimitIntervalSec=0

[Service]
ExecStart=%h/.zurafa/service/zurafa-daemon --socket %h/.zurafa/service/daemon.sock --extra-listen tailnet://:7297 --extra-listen tailnet-serve://%h/.zurafa/service/serve.sock
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
";

fn home() -> Result<PathBuf, String> {
    env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".into())
}

fn unit_path() -> Result<PathBuf, String> {
    let config = env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).map_or_else(|| home().map(|h| h.join(".config")), Ok)?;
    Ok(config.join("systemd/user").join(UNIT))
}

/// `scope` is `--user` or `--system`.
fn systemctl(scope: &str, args: &[&str]) -> Result<(), String> {
    let out = Command::new("systemctl")
        .arg(scope)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("cannot run systemctl ({e}); direct connections need systemd"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("systemctl {scope} {} failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

pub fn install() -> Result<String, String> {
    if !cfg!(target_os = "linux") {
        return Err("direct connections need a Linux host with systemd".into());
    }
    let dir = home()?.join(".zurafa/service");
    DirBuilder::new().recursive(true).mode(0o700).create(&dir).map_err(|e| e.to_string())?;
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let bin = dir.join("zurafa-daemon");
    let mut changed = fs::read(&bin).ok() != fs::read(&exe).ok();
    if changed {
        // Copy, then rename over the old binary, which may be running.
        let tmp = dir.join("zurafa-daemon.tmp");
        fs::copy(&exe, &tmp).map_err(|e| e.to_string())?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        fs::rename(&tmp, &bin).map_err(|e| e.to_string())?;
    }
    let unit = unit_path()?;
    if fs::read_to_string(&unit).ok().as_deref() != Some(UNIT_FILE) {
        fs::create_dir_all(unit.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(&unit, UNIT_FILE).map_err(|e| e.to_string())?;
        changed = true;
    }
    systemctl("--user", &["daemon-reload"])?;
    systemctl("--user", &["enable", UNIT])?;
    systemctl("--user", &[if changed { "restart" } else { "start" }, UNIT])?;
    // Without lingering, systemd stops user services at logout.
    let lingers = Command::new("loginctl").arg("enable-linger").stdin(Stdio::null()).output().is_ok_and(|o| o.status.success());
    thread::sleep(Duration::from_secs(2));
    if systemctl("--user", &["is-active", "--quiet", UNIT]).is_err() {
        return Err("the Zurafa service did not start; see `journalctl --user -u zurafa` on the host (is Tailscale running?)".into());
    }
    Ok(if lingers {
        "Direct connection is on: new tabs to this host skip SSH.".into()
    } else {
        "Direct connection is on until you log out of this host (`loginctl enable-linger` failed).".into()
    })
}

const LOGIN_UNIT: &str = "zurafa-login-server.service";
const LOGIN_DIR: &str = "/usr/local/lib/zurafa";

const LOGIN_UNIT_FILE: &str = "\
[Unit]
Description=Zurafa login server
After=network-online.target tailscaled.service
Wants=tailscaled.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/lib/zurafa/zurafa-daemon login-server --accounts /etc/zurafa/accounts.jsonc --extra-listen tailnet://:7297 --extra-listen tailnet-serve:///run/zurafa/serve.sock
Restart=on-failure
RestartSec=5
# Account daemons run in their own login sessions; stopping or upgrading this leaves them running.
KillMode=process

[Install]
WantedBy=multi-user.target
";

/// A new accounts file: the sudo user's own account for this machine's Tailscale owner, when
/// both are known, else nobody.
fn accounts_file(account: Option<&str>, login: Option<&str>) -> String {
    let (accounts, defaults) = match (account, login) {
        (Some(a), Some(l)) => (
            format!("    \"{a}\": {{ \"principals\": [\"tailscale:{l}\"] }},\n"),
            format!("    \"tailscale:{l}\": \"{a}\",\n"),
        ),
        _ => ("    // \"alice\": { \"principals\": [\"tailscale:alice@example.com\"] },\n".into(), String::new()),
    };
    format!(
        "// Which accounts each caller may use; see `zurafa-daemon` docs (login server).\n\
         // Principals: tailscale:<login>, tailscale:tag:<tag>, tailscale:*, tailscale:tag:*, identified, anonymous.\n\
         // Edits apply to the next connection.\n\
         {{\n  \"version\": 1,\n  \"accounts\": {{\n{accounts}  }},\n  \"defaults\": {{\n{defaults}  }},\n}}\n"
    )
}

/// This machine's Tailscale owner login, if the machine has one (tagged machines do not).
fn owner_login() -> Option<String> {
    let status: serde_json::Value = serde_json::from_slice(&crate::hosts::tailscale(&["status", "--json"])?).ok()?;
    let me = &status["Self"];
    if me["Tags"].as_array().is_some_and(|t| !t.is_empty()) {
        return None;
    }
    status["User"][me["UserID"].as_u64()?.to_string()]["LoginName"].as_str().map(str::to_owned)
}

pub fn install_login_server() -> Result<String, String> {
    if !cfg!(target_os = "linux") {
        return Err("the login server needs a Linux host with systemd".into());
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err("run it with sudo: the login server is a system service".into());
    }
    DirBuilder::new().recursive(true).mode(0o755).create(LOGIN_DIR).map_err(|e| e.to_string())?;
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let bin = PathBuf::from(LOGIN_DIR).join("zurafa-daemon");
    let mut changed = fs::read(&bin).ok() != fs::read(&exe).ok();
    if changed {
        let tmp = bin.with_extension("tmp");
        fs::copy(&exe, &tmp).map_err(|e| e.to_string())?;
        // Every account's session runs this binary, so it must be world-executable and root-owned.
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        fs::rename(&tmp, &bin).map_err(|e| e.to_string())?;
    }
    let accounts = PathBuf::from(crate::login::ACCOUNTS);
    let mut note = String::new();
    if !accounts.exists() {
        DirBuilder::new().recursive(true).mode(0o755).create(accounts.parent().unwrap()).map_err(|e| e.to_string())?;
        let user = env::var("SUDO_USER").ok().filter(|u| u != "root");
        let login = owner_login();
        fs::write(&accounts, accounts_file(user.as_deref(), login.as_deref())).map_err(|e| e.to_string())?;
        fs::set_permissions(&accounts, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        note = match (user, login) {
            (Some(u), Some(l)) => format!(" {l} gets the {u} account; edit {} to change who gets what.", accounts.display()),
            _ => format!(" Nobody may log in yet: add accounts to {}.", accounts.display()),
        };
    }
    let unit = PathBuf::from("/etc/systemd/system").join(LOGIN_UNIT);
    if fs::read_to_string(&unit).ok().as_deref() != Some(LOGIN_UNIT_FILE) {
        fs::write(&unit, LOGIN_UNIT_FILE).map_err(|e| e.to_string())?;
        changed = true;
    }
    systemctl("--system", &["daemon-reload"])?;
    systemctl("--system", &["enable", LOGIN_UNIT])?;
    systemctl("--system", &[if changed { "restart" } else { "start" }, LOGIN_UNIT])?;
    thread::sleep(Duration::from_secs(2));
    if systemctl("--system", &["is-active", "--quiet", LOGIN_UNIT]).is_err() {
        return Err(format!(
            "the login server did not start; see `journalctl -u zurafa-login-server`. If your own direct connection \
             (systemctl --user status zurafa) holds port 7297, turn it off first with the bolt button.{note}"
        ));
    }
    Ok(format!(
        "The Zurafa login server is running on tailnet port 7297.{note} For HTTPS, run: \
         sudo tailscale serve --bg --https=443 unix:/run/zurafa/serve.sock"
    ))
}

pub fn uninstall_login_server() -> Result<String, String> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("run it with sudo: the login server is a system service".into());
    }
    let unit = PathBuf::from("/etc/systemd/system").join(LOGIN_UNIT);
    if unit.exists() {
        systemctl("--system", &["disable", "--now", LOGIN_UNIT])?;
        fs::remove_file(&unit).map_err(|e| e.to_string())?;
        systemctl("--system", &["daemon-reload"])?;
    }
    if PathBuf::from(LOGIN_DIR).exists() {
        fs::remove_dir_all(LOGIN_DIR).map_err(|e| e.to_string())?;
    }
    Ok(format!("The Zurafa login server is removed; {} is kept.", crate::login::ACCOUNTS))
}

pub fn uninstall() -> Result<String, String> {
    let unit = unit_path()?;
    if unit.exists() {
        systemctl("--user", &["disable", "--now", UNIT])?;
        fs::remove_file(&unit).map_err(|e| e.to_string())?;
        systemctl("--user", &["daemon-reload"])?;
    }
    let dir = home()?.join(".zurafa/service");
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok("Direct connection is off: tabs to this host use SSH.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_accounts_file_grants_only_the_installer() {
        let mine = accounts_file(Some("yareliu"), Some("devjasha@github"));
        assert!(mine.contains(r#""yareliu": { "principals": ["tailscale:devjasha@github"] }"#));
        assert!(mine.contains(r#""tailscale:devjasha@github": "yareliu""#));
        assert!(!accounts_file(None, Some("devjasha@github")).contains("devjasha"));
        for text in [mine, accounts_file(None, None)] {
            let parsed: serde_json::Value = serde_json::from_str(&crate::login::jsonc(&text)).unwrap();
            assert_eq!(parsed["version"], 1);
        }
    }

    #[test]
    fn service_listens_only_on_the_tailnet() {
        let exec = UNIT_FILE.lines().find(|l| l.starts_with("ExecStart=")).unwrap();
        assert!(exec.contains("--extra-listen tailnet://:7297 "));
        assert!(exec.ends_with("--extra-listen tailnet-serve://%h/.zurafa/service/serve.sock"));
        assert!(!exec.contains("--exit-when-idle") && !exec.contains("--tailnet-allow-identified"));
    }
}
