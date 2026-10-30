//! Phones that asked for agent notifications. The iOS app registers its APNs token here; the Mac
//! app reads the list and sends each notification through the push relay.
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Device {
    /// APNs device token, hex.
    pub token: String,
    /// Development builds get pushes through Apple's sandbox.
    #[serde(default)]
    pub sandbox: bool,
    #[serde(default)]
    pub name: String,
}

pub struct Devices {
    path: PathBuf,
    list: Vec<Device>,
}

impl Devices {
    pub fn load() -> Self {
        let path = PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
            .join("Library/Application Support/Zurafa/push-devices.json");
        Self::at(path)
    }

    fn at(path: PathBuf) -> Self {
        // A missing or broken file only means no phone gets notified until it registers again.
        let list = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { path, list }
    }

    pub fn list(&self) -> Vec<Device> {
        self.list.clone()
    }

    pub fn register(&mut self, device: Device) -> Result<(), String> {
        if device.token.len() < 32 || !device.token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("invalid push token".into());
        }
        // One entry per phone: a reinstall gets a new token under the same name.
        self.list.retain(|d| d.token != device.token && (device.name.is_empty() || d.name != device.name));
        self.list.push(device);
        self.save()
    }

    pub fn unregister(&mut self, token: &str) -> Result<(), String> {
        self.list.retain(|d| d.token != token);
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&self.list).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        fs::rename(tmp, &self.path).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_once_per_phone_and_persists() {
        let path = std::env::temp_dir().join(format!("zurafa-push-{}.json", std::process::id()));
        let device = |token: &str| Device { token: token.into(), sandbox: true, name: "iPhone".into() };
        let mut devices = Devices::at(path.clone());
        devices.register(device(&"a".repeat(64))).unwrap();
        devices.register(device(&"b".repeat(64))).unwrap();
        assert_eq!(Devices::at(path.clone()).list(), vec![device(&"b".repeat(64))]);
        assert!(devices.register(device("not-hex")).is_err());
        devices.unregister(&"b".repeat(64)).unwrap();
        assert!(Devices::at(path.clone()).list().is_empty());
        let _ = fs::remove_file(path);
    }
}
