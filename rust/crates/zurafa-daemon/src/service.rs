//! `zurafa-daemon install-service` / `uninstall-service`, run on a Linux host (the app runs them
//! over SSH): a systemd user service keeps a daemon listening on the tailnet, so remote tabs to
//! this host connect directly instead of through SSH. Rex ships the same as a system service.
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
ExecStart=%h/.zurafa/service/zurafa-daemon --socket %h/.zurafa/service/daemon.sock --extra-listen tailnet://:7297
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

fn systemctl(args: &[&str]) -> Result<(), String> {
    let out = Command::new("systemctl")
        .arg("--user")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("cannot run systemctl ({e}); direct connections need systemd"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("systemctl --user {} failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
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
    systemctl(&["daemon-reload"])?;
    systemctl(&["enable", UNIT])?;
    systemctl(&[if changed { "restart" } else { "start" }, UNIT])?;
    // Without lingering, systemd stops user services at logout.
    let lingers = Command::new("loginctl").arg("enable-linger").stdin(Stdio::null()).output().is_ok_and(|o| o.status.success());
    thread::sleep(Duration::from_secs(2));
    if systemctl(&["is-active", "--quiet", UNIT]).is_err() {
        return Err("the Zurafa service did not start; see `journalctl --user -u zurafa` on the host (is Tailscale running?)".into());
    }
    Ok(if lingers {
        "Direct connection is on: new tabs to this host skip SSH.".into()
    } else {
        "Direct connection is on until you log out of this host (`loginctl enable-linger` failed).".into()
    })
}

pub fn uninstall() -> Result<String, String> {
    let unit = unit_path()?;
    if unit.exists() {
        systemctl(&["disable", "--now", UNIT])?;
        fs::remove_file(&unit).map_err(|e| e.to_string())?;
        systemctl(&["daemon-reload"])?;
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
    fn service_listens_only_on_the_tailnet() {
        let exec = UNIT_FILE.lines().find(|l| l.starts_with("ExecStart=")).unwrap();
        assert!(exec.ends_with("--extra-listen tailnet://:7297"));
        assert!(!exec.contains("--exit-when-idle") && !exec.contains("--tailnet-allow-identified"));
    }
}
