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
    /// ActivityKit push-to-start token, hex.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_token: Option<String>,
    /// Push token of the phone's running Live Activity, hex; registering "" clears it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity_token: Option<String>,
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

    /// Registers a phone, or updates one with the same token: fields in `fields` overwrite, absent ones are kept.
    pub fn register(&mut self, fields: serde_json::Value) -> Result<(), String> {
        let mut merged = fields["token"]
            .as_str()
            .and_then(|t| self.list.iter().find(|d| d.token == t))
            .map(|d| serde_json::to_value(d).unwrap())
            .unwrap_or_else(|| serde_json::json!({}));
        for (k, v) in fields.as_object().ok_or("invalid push device")? {
            merged[k] = v.clone();
        }
        let mut device: Device = serde_json::from_value(merged).map_err(|e| e.to_string())?;
        let hex = |t: &str| t.len() >= 32 && t.len() <= 200 && t.bytes().all(|b| b.is_ascii_hexdigit());
        if !hex(&device.token)
            || device.start_token.as_deref().is_some_and(|t| !hex(t))
            || device.activity_token.as_deref().is_some_and(|t| !t.is_empty() && !hex(t))
        {
            return Err("invalid push token".into());
        }
        if device.activity_token.as_deref() == Some("") {
            device.activity_token = None;
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
        let device = |token: &str| Device { token: token.into(), sandbox: true, name: "iPhone".into(), start_token: None, activity_token: None };
        let json = |token: &str| serde_json::to_value(device(token)).unwrap();
        let mut devices = Devices::at(path.clone());
        devices.register(json(&"a".repeat(64))).unwrap();
        devices.register(json(&"b".repeat(64))).unwrap();
        assert_eq!(Devices::at(path.clone()).list(), vec![device(&"b".repeat(64))]);
        assert!(devices.register(json("not-hex")).is_err());
        devices.unregister(&"b".repeat(64)).unwrap();
        assert!(Devices::at(path.clone()).list().is_empty());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn merges_live_activity_tokens() {
        let path = std::env::temp_dir().join(format!("zurafa-push-merge-{}.json", std::process::id()));
        let (token, start, activity) = ("a".repeat(64), "c".repeat(64), "d".repeat(64));
        let mut devices = Devices::at(path.clone());
        devices.register(serde_json::json!({"token": token, "sandbox": true, "name": "iPhone", "start_token": start})).unwrap();
        devices.register(serde_json::json!({"token": token, "activity_token": activity})).unwrap();
        let full = Device { token: token.clone(), sandbox: true, name: "iPhone".into(), start_token: Some(start.clone()), activity_token: Some(activity) };
        assert_eq!(Devices::at(path.clone()).list(), vec![full.clone()]);
        devices.register(serde_json::json!({"token": token, "activity_token": ""})).unwrap();
        assert_eq!(devices.list(), vec![Device { activity_token: None, ..full.clone() }]);
        assert!(devices.register(serde_json::json!({"token": token, "start_token": "zz"})).is_err());
        assert!(devices.register(serde_json::json!({"token": token, "start_token": ""})).is_err());
        assert!(devices.register(serde_json::json!({"token": token, "activity_token": "not-hex"})).is_err());
        assert_eq!(devices.list(), vec![Device { activity_token: None, ..full }]);
        let _ = fs::remove_file(path);
    }
}
