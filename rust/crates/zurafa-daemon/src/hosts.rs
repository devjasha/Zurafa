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

/// Online Linux and macOS machines on the user's tailnet, as unsaved hosts (ID = MagicDNS name).
/// Empty when Tailscale is not installed or not running.
pub fn tailnet() -> Vec<RemoteHost> {
    tailscale(&["status", "--json"]).map(|out| tailnet_hosts(&out, resolves)).unwrap_or_default()
}

/// Stdout of a successful `tailscale <args>`.
pub fn tailscale(args: &[&str]) -> Option<Vec<u8>> {
    // The daemon starts from the app with launchd's PATH, so look in the usual install spots.
    const CLIS: [&str; 4] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ];
    CLIS.iter()
        .filter(|cli| std::path::Path::new(cli).is_file())
        // Without a terminal, Tailscale.app's binary starts its GUI instead of the CLI (and exits 0).
        .find_map(|cli| std::process::Command::new(cli).args(args).env("TAILSCALE_BE_CLI", "1").output().ok())
        .filter(|out| out.status.success())
        .map(|out| out.stdout)
}

fn resolves(name: &str) -> bool {
    use std::net::ToSocketAddrs;
    (name, 22).to_socket_addrs().is_ok_and(|mut a| a.next().is_some())
}

/// Uses the MagicDNS name when it resolves here, else the Tailscale IPv4: with "Use Tailscale
/// DNS" off on this Mac, `*.ts.net` names do not resolve but the 100.x addresses still route.
fn tailnet_hosts(status: &[u8], resolves: impl Fn(&str) -> bool) -> Vec<RemoteHost> {
    let Ok(status) = serde_json::from_slice::<serde_json::Value>(status) else { return Vec::new() };
    let mut hosts: Vec<RemoteHost> = status["Peer"]
        .as_object()
        .into_iter()
        .flat_map(|peers| peers.values())
        .filter(|p| p["Online"] == true && matches!(p["OS"].as_str(), Some("linux" | "macOS")))
        .filter_map(|p| {
            let name = p["DNSName"].as_str()?.trim_end_matches('.').to_owned();
            let ipv4 = p["TailscaleIPs"].as_array()?.iter().filter_map(|ip| ip.as_str()).find(|ip| ip.contains('.'));
            let hostname = match ipv4 {
                Some(ip) if !resolves(&name) => ip.to_owned(),
                _ => name.clone(),
            };
            let label = p["HostName"].as_str().filter(|l| !l.is_empty()).unwrap_or(&name).to_owned();
            let named = RemoteHost { id: name.clone(), label, hostname: name, user: None, port: 22 };
            let host = RemoteHost { hostname, ..named.clone() };
            (validate(&named).is_ok() && validate(&host).is_ok()).then_some(host)
        })
        .collect();
    hosts.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
    hosts
}

/// VMs on this Mac's shared network (UTM, Tart, Apple Virtualization), from the vmnet DHCP
/// leases, as unsaved hosts (ID = IP). Empty when no VM has ever leased an address.
pub fn local_vms() -> Vec<RemoteHost> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    fs::read_to_string("/var/db/dhcpd_leases").map(|text| vm_hosts(&text, now)).unwrap_or_default()
}

/// Unexpired leases, newest IP per VM name. A stopped VM keeps its lease until it expires,
/// so it can still be listed; connecting then fails like any offline host.
fn vm_hosts(leases: &str, now: u64) -> Vec<RemoteHost> {
    let mut leased: Vec<(u64, RemoteHost)> = Vec::new();
    for block in leases.split('{').skip(1) {
        let field = |key: &str| {
            block.lines().find_map(|line| line.trim().strip_prefix(key)?.strip_prefix('=').map(str::trim))
        };
        let (Some(ip), Some(expiry)) = (field("ip_address"), field("lease")) else { continue };
        let expiry = u64::from_str_radix(expiry.trim_start_matches("0x"), 16).unwrap_or(0);
        if expiry <= now || ip.parse::<std::net::Ipv4Addr>().is_err() {
            continue;
        }
        let label = field("name").filter(|n| !n.is_empty()).unwrap_or(ip).to_owned();
        let host = RemoteHost { id: ip.to_owned(), label, hostname: ip.to_owned(), user: None, port: 22 };
        if validate(&host).is_ok() {
            leased.push((expiry, host));
        }
    }
    leased.sort_by(|a, b| b.0.cmp(&a.0));
    let mut hosts: Vec<RemoteHost> = Vec::new();
    for (_, host) in leased {
        if !hosts.iter().any(|h| h.label == host.label) {
            hosts.push(host);
        }
    }
    hosts.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
    hosts
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
    fn tailnet_lists_online_ssh_capable_peers() {
        let status = br#"{"Peer":{
            "a":{"HostName":"stuart","DNSName":"stuart.tail1.ts.net.","OS":"linux","Online":true,"TailscaleIPs":["100.86.111.84","fd7a::1"]},
            "b":{"HostName":"Chec's MacBook","DNSName":"checs-mb.tail1.ts.net.","OS":"macOS","Online":true,"TailscaleIPs":["100.1.2.3"]},
            "c":{"HostName":"localhost","DNSName":"iphone.tail1.ts.net.","OS":"iOS","Online":true,"TailscaleIPs":["100.1.2.4"]},
            "d":{"HostName":"old","DNSName":"old.tail1.ts.net.","OS":"linux","Online":false,"TailscaleIPs":["100.1.2.5"]},
            "e":{"HostName":"","DNSName":"-oProxyCommand=x.","OS":"linux","Online":true,"TailscaleIPs":["100.1.2.6"]}}}"#;
        let hosts = tailnet_hosts(status, |_| true);
        let names: Vec<_> = hosts.iter().map(|h| (h.label.as_str(), h.hostname.as_str())).collect();
        assert_eq!(names, [("Chec's MacBook", "checs-mb.tail1.ts.net"), ("stuart", "stuart.tail1.ts.net")]);
        assert!(hosts.iter().all(|h| h.port == 22 && h.user.is_none()));
        assert!(tailnet_hosts(b"not json", |_| true).is_empty());
        // MagicDNS off on this machine: fall back to the Tailscale IPv4, keep the name as label.
        let by_ip = tailnet_hosts(status, |name| name.starts_with("checs"));
        let names: Vec<_> = by_ip.iter().map(|h| (h.label.as_str(), h.hostname.as_str())).collect();
        assert_eq!(names, [("Chec's MacBook", "checs-mb.tail1.ts.net"), ("stuart", "100.86.111.84")]);
    }

    #[test]
    fn local_vms_lists_unexpired_leases() {
        // A VM that got a new address keeps its old lease too; the later expiry wins.
        let leases = "{\n\tip_address=192.168.64.2\n\thw_address=1,a\n\tlease=0x1ff\n\tname=kali-linux-vm-1\n}\n\
            {\n\tip_address=192.168.64.5\n\thw_address=1,a\n\tlease=0x200\n\tname=kali-linux-vm-1\n}\n\
            {\n\tip_address=192.168.64.3\n\tlease=0x200\n}\n\
            {\n\tip_address=192.168.64.4\n\tlease=0x10\n\tname=stopped-long-ago\n}\n\
            {\n\tip_address=-oProxyCommand=x\n\tlease=0x200\n\tname=bad\n}\n";
        let hosts = vm_hosts(leases, 0x100);
        let names: Vec<_> = hosts.iter().map(|h| (h.label.as_str(), h.hostname.as_str())).collect();
        assert_eq!(names, [("192.168.64.3", "192.168.64.3"), ("kali-linux-vm-1", "192.168.64.5")]);
        assert!(hosts.iter().all(|h| h.port == 22 && h.user.is_none()));
        assert!(vm_hosts("", 0).is_empty());
    }

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
