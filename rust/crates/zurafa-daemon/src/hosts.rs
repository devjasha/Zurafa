use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;
use zurafa_events::RemoteHost;

pub struct HostRegistry {
    path: PathBuf,
    hosts: Vec<RemoteHost>,
}

impl HostRegistry {
    pub fn load() -> Self {
        let path = std::env::var_os("ZURAFA_HOSTS_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join("Library/Application Support/Zurafa/hosts.json")
            });
        let hosts = match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(hosts) => hosts,
                Err(e) => {
                    eprintln!("Cannot read saved Zurafa hosts: {e}");
                    Vec::new()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => {
                eprintln!("Cannot read saved Zurafa hosts: {e}");
                Vec::new()
            }
        };
        Self { path, hosts }
    }

    pub fn list(&self) -> Vec<RemoteHost> {
        self.hosts.clone()
    }

    pub fn contains(&self, host: &RemoteHost) -> bool {
        self.hosts.iter().any(|h| h == host)
    }

    pub fn add(&mut self, host: RemoteHost) -> Result<String, String> {
        validate(&host)?;
        if self.hosts.iter().any(|h| h.id == host.id) {
            return Err("host ID already exists".into());
        }
        let mut next = self.hosts.clone();
        next.push(host);
        self.save(next)
    }

    pub fn update(&mut self, host: RemoteHost) -> Result<String, String> {
        validate(&host)?;
        let mut next = self.hosts.clone();
        let saved = next
            .iter_mut()
            .find(|saved| saved.id == host.id)
            .ok_or("unknown host")?;
        *saved = host;
        self.save(next)
    }

    pub fn remove(&mut self, id: &str) -> Result<String, String> {
        let mut next = self.hosts.clone();
        next.retain(|h| h.id != id);
        if next.len() == self.hosts.len() {
            return Err("unknown host".into());
        }
        self.save(next)
    }

    fn save(&mut self, next: Vec<RemoteHost>) -> Result<String, String> {
        let parent = self.path.parent().ok_or("invalid hosts path")?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|e| e.to_string())?;
        let tmp = self.path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(&next).map_err(|e| e.to_string())?;
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        file.write_all(&bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(tmp, &self.path).map_err(|e| e.to_string())?;
        self.hosts = next;
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        bytes.hash(&mut hasher);
        Ok(format!("{:016x}", hasher.finish()))
    }
}

pub fn validate(host: &RemoteHost) -> Result<(), String> {
    let clean =
        |s: &str, max: usize| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control);
    if !clean(&host.id, 128) || !clean(&host.label, 128) {
        return Err("host ID and label must be nonempty".into());
    }
    if !clean(&host.hostname, 255)
        || host.hostname.starts_with('-')
        || host.hostname.chars().any(char::is_whitespace)
        || host.hostname.contains('@')
        || host.hostname.contains('/')
    {
        return Err("invalid SSH hostname".into());
    }
    if host.user.as_ref().is_some_and(|user| {
        !clean(user, 64)
            || user.starts_with('-')
            || user.chars().any(char::is_whitespace)
            || user.contains('@')
            || user.contains('/')
    }) {
        return Err("invalid SSH username".into());
    }
    if host.port == 0 {
        return Err("SSH port must be positive".into());
    }
    Ok(())
}

/// The ssh arguments naming `host`: `[-p port] -- user@hostname`.
pub fn ssh_destination(host: &RemoteHost) -> Vec<String> {
    let destination = match &host.user {
        Some(user) => format!("{user}@{}", host.hostname),
        None => host.hostname.clone(),
    };
    let mut args = Vec::new();
    // Leave the default port to OpenSSH so a Host alias can supply Port in
    // ~/.ssh/config. An explicit non-default port still takes precedence.
    if host.port != 22 {
        args.extend(["-p".into(), host.port.to_string()]);
    }
    args.extend(["--".into(), destination]);
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_arguments_are_separate_and_host_input_is_checked() {
        let host = RemoteHost {
            id: "id".into(),
            label: "Remote".into(),
            hostname: "hill.example.ts.net".into(),
            user: Some("alice".into()),
            port: 2222,
        };
        validate(&host).unwrap();
        assert_eq!(
            ssh_destination(&host),
            [
                "-p",
                "2222",
                "--",
                "alice@hill.example.ts.net"
            ]
        );
        assert!(validate(&RemoteHost {
            hostname: "-oProxyCommand=evil".into(),
            ..host.clone()
        })
        .is_err());
        let default_port = RemoteHost {
            port: 22,
            hostname: "workbox".into(),
            ..host.clone()
        };
        assert_eq!(ssh_destination(&default_port), ["--", "alice@workbox"]);
        assert!(validate(&RemoteHost {
            user: Some("a b".into()),
            ..host
        })
        .is_err());
    }
}
