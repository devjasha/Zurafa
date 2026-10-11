use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command};
use std::time::{Duration, Instant};
use std::{env, fs, thread};

struct Daemon(Child, std::path::PathBuf);

impl Daemon {
    fn start(name: &str) -> Self {
        static SCRATCH: std::sync::Once = std::sync::Once::new();
        SCRATCH.call_once(|| env::set_current_dir(env::temp_dir()).unwrap());
        let path = std::path::PathBuf::from(format!("zurafa-{name}-{}.sock", std::process::id()));
        let child = Command::new(env!("CARGO_BIN_EXE_zurafa-daemon"))
            .env("ZURAFA_SOCKET", &path)
            .env("ZURAFA_HOSTS_FILE", path.with_extension("hosts.json"))
            .spawn()
            .unwrap();
        Daemon(child, path)
    }

    fn connect(&self) -> Client {
        let start = Instant::now();
        loop {
            match UnixStream::connect(&self.1) {
                Ok(s) => {
                    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                    return Client(s);
                }
                Err(e) if start.elapsed() > Duration::from_secs(10) => panic!("connect: {e}"),
                Err(_) => thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
        let _ = fs::remove_file(&self.1);
        let _ = fs::remove_file(self.1.with_extension("hosts.json"));
    }
}

struct Client(UnixStream);

impl Client {
    fn send(&mut self, v: Value) {
        let body = v.to_string();
        self.0
            .write_all(&(body.len() as u32).to_be_bytes())
            .unwrap();
        self.0.write_all(body.as_bytes()).unwrap();
    }

    fn recv(&mut self) -> Option<Value> {
        let mut len = [0; 4];
        self.0.read_exact(&mut len).ok()?;
        let mut body = vec![0; u32::from_be_bytes(len) as usize];
        self.0.read_exact(&mut body).ok()?;
        Some(serde_json::from_slice(&body).unwrap())
    }

    /// Reads messages until `done` accepts the list so far.
    fn collect(&mut self, done: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        let mut all = Vec::new();
        while !done(&all) {
            all.push(self.recv().expect("connection closed or timed out"));
        }
        all
    }
}

fn of_type<'a>(msgs: &'a [Value], t: &'a str) -> impl Iterator<Item = &'a Value> {
    msgs.iter().filter(move |m| m["type"] == t)
}

fn output(msgs: &[Value]) -> Vec<u8> {
    of_type(msgs, "output")
        .flat_map(|m| B64.decode(m["data"].as_str().unwrap()).unwrap())
        .collect()
}

#[test]
fn request_before_hello_is_rejected() {
    let d = Daemon::start("nohello");
    let mut c = d.connect();
    c.send(json!({"id": 7, "type": "ping"}));
    let r = c.recv().unwrap();
    assert_eq!(
        (r["type"].as_str(), r["id"].as_u64()),
        (Some("error"), Some(7))
    );
    assert!(c.recv().is_none(), "connection should be closed");
}

#[test]
fn spawn_status_exit_and_input() {
    let d = Daemon::start("main");
    let mut c = d.connect();
    c.send(json!({"id": 1, "type": "hello", "protocol": 1}));
    let r = c.recv().unwrap();
    assert_eq!(
        (r["type"].as_str(), r["id"].as_u64()),
        (Some("hello_ok"), Some(1))
    );

    // events may overtake the spawn reply, so gather everything up to exited
    c.send(json!({"id": 2, "type": "spawn", "cols": 80, "rows": 24,
        "command": ["/bin/sh", "-c", r"printf 'hi\033]7501;state=completed\007'"]}));
    let msgs = c.collect(|m| of_type(m, "exited").count() > 0);
    let spawned = of_type(&msgs, "spawned").next().expect("spawned reply");
    assert_eq!(spawned["id"], 2);
    let t = spawned["terminal"].as_str().unwrap();
    let out = output(&msgs);
    assert!(String::from_utf8_lossy(&out).contains("hi"));
    assert!(
        !out.windows(4).any(|w| w == b"7501"),
        "sequence must be stripped"
    );
    let status = of_type(&msgs, "status").next().expect("status event");
    assert_eq!(
        (status["terminal"].as_str(), status["state"].as_str()),
        (Some(t), Some("completed"))
    );
    assert_eq!(of_type(&msgs, "exited").next().unwrap()["code"], 0);

    c.send(json!({"id": 3, "type": "spawn", "cols": 80, "rows": 24, "command": ["/bin/cat"]}));
    let msgs = c.collect(|m| of_type(m, "spawned").count() > 0);
    let cat = of_type(&msgs, "spawned").next().unwrap()["terminal"]
        .as_str()
        .unwrap()
        .to_string();
    c.send(json!({"type": "input", "terminal": cat, "data": B64.encode("abc\n")}));
    let msgs = c.collect(|m| String::from_utf8_lossy(&output(m)).contains("abc"));
    assert!(of_type(&msgs, "output").all(|m| m["terminal"] == cat.as_str()));
    c.send(json!({"id": 4, "type": "kill", "terminal": cat}));
    let msgs = c.collect(|m| of_type(m, "ok").count() > 0);
    assert_eq!(of_type(&msgs, "ok").next().unwrap()["id"], 4);
}

impl Client {
    fn hello(&mut self) {
        self.send(json!({"id":1,"type":"hello","protocol":2}));
        assert_eq!(self.recv().unwrap()["type"], "hello_ok");
    }
    fn request(&mut self, value: Value) -> Value {
        let id = value["id"].clone();
        self.send(value);
        self.collect(|m| m.iter().any(|v| v["id"] == id))
            .into_iter()
            .find(|v| v["id"] == id)
            .unwrap()
    }
}
fn event_name(v: &Value, name: &str) -> bool {
    v["type"] == "events.event" && v["event"]["name"] == name
}

#[cfg(target_os = "macos")]
#[test]
fn real_pty_reports_foreground_process_and_snapshot() {
    let d = Daemon::start("process-icon");
    let mut c = d.connect();
    c.hello();
    c.request(json!({"id":2,"type":"events.subscribe_all","subscription":"all"}));
    c.send(json!({"id":3,"type":"spawn","cols":80,"rows":24,
        "command":["/bin/sleep","2"]}));
    let messages = c.collect(|m| m.iter().any(|v| event_name(v, "process_changed")));
    let event = messages.iter().find(|v| event_name(v, "process_changed")).unwrap();
    assert_eq!(event["event"]["payload"]["foreground"]["name"], "sleep");
    let snapshot = c.request(json!({"id":4,"type":"events.snapshot"}));
    let block = event["event"]["block_id"].as_str().unwrap();
    assert_eq!(snapshot["snapshot"]["sessions"]["default"]["blocks"][block]["foreground"]["name"], "sleep");
}

#[test]
fn saved_ssh_host_opens_remote_session_and_tabs_use_ssh() {
    let d = Daemon::start("ssh-host");
    let mut c = d.connect();
    c.hello();
    c.request(json!({"id":2,"type":"events.subscribe_all","subscription":"all"}));
    let host = json!({"id":"h1","label":"Test host","hostname":"127.0.0.1","user":null,"port":1});
    let added = c.request(json!({"id":3,"type":"hosts.add","host":host}));
    assert_eq!(added["type"], "ok", "{added}");
    let list = c.request(json!({"id":4,"type":"hosts.list"}));
    assert_eq!(list["hosts"][0]["hostname"], "127.0.0.1");
    let create = c.request(json!({"id":5,"type":"layout.command","command":{"op":"create_session","session":"remote-test","label":"Test host","remote":host}}));
    assert_eq!(create["type"], "ok");
    let state = c.request(json!({"id":6,"type":"events.snapshot"}));
    assert_eq!(
        state["snapshot"]["sessions"]["remote-test"]["remote"]["port"],
        1
    );
    c.send(json!({"id":7,"type":"layout.tab","session":"remote-test","cols":80,"rows":24}));
    let msgs = c.collect(|m| m.iter().any(|v| event_name(v, "child_exited")));
    assert_eq!(of_type(&msgs, "spawned").count(), 1);
    assert!(String::from_utf8_lossy(&output(&msgs)).contains("127.0.0.1"));
    assert_eq!(
        c.request(json!({"id":8,"type":"hosts.remove","host_id":"h1"}))["type"],
        "ok"
    );
    assert!(c.request(json!({"id":9,"type":"hosts.list"}))["hosts"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn v2_reports_filters_snapshots_and_resync() {
    let d = Daemon::start("v2reports");
    let mut c = d.connect();
    c.hello();
    let subscribed = c.request(json!({"id":2,"type":"events.subscribe_all","subscription":"all"}));
    let boundary = subscribed["snapshot"]["sequence"].as_u64().unwrap();
    c.request(json!({"id":3,"type":"events.subscribe","subscription":"exit","filter":{"category":"terminal","name":"terminal.child_exited"}}));
    c.send(json!({"id":4,"type":"layout.tab","session":"default","cols":80,"rows":24,"command":["/bin/sh","-c",r"printf 'hello\033]2;title\007\033]7;file://host/tmp\007\007\033]9;4;1;42\007\033]777;notify;title;body\007\033]52;c;aGk=\007\033]7501;state=working:id=build:app=cargo\007\033]7501;state=done:id=build/test:msg=b2s=\007'; exit 7"]}));
    let msgs = c.collect(|m| {
        m.iter().filter(|v| event_name(v, "child_exited")).count() == 2
            && m.iter().any(|v| v["id"] == 4)
    });
    let block = of_type(&msgs, "spawned").next().unwrap()["terminal"]
        .as_str()
        .unwrap();
    let events: Vec<_> = of_type(&msgs, "events.event").collect();
    for e in &events {
        assert!(e["event"]["sequence"].as_u64().unwrap() > boundary);
        if e["subscription"] == "exit" {
            assert_eq!(e["event"]["name"], "child_exited");
        }
    }
    for name in [
        "title_changed",
        "pwd_changed",
        "bell",
        "progress_report",
        "desktop_notification",
        "clipboard_written",
        "program_status_changed",
        "program_status_removed",
        "child_exited",
    ] {
        assert!(msgs.iter().any(|v| event_name(v, name)), "missing {name}");
    }
    let exit = msgs.iter().find(|v| event_name(v, "child_exited")).unwrap();
    assert_eq!(exit["event"]["payload"]["exit_code"], 7);
    assert_eq!(exit["event"]["payload"]["error"], "exit status 7");
    let snapshot = c.request(json!({"id":5,"type":"events.snapshot"}));
    let b = &snapshot["snapshot"]["sessions"]["default"]["blocks"][block];
    assert_eq!(b["running"], false);
    assert_eq!(b["title"], "title");
    assert_eq!(b["pwd"], "file://host/tmp");
    assert_eq!(b["statuses"]["records"].as_object().unwrap().len(), 1);
    assert_eq!(b["statuses"]["records"]["build/test"]["msg"], "ok");
    let resync = c.request(json!({"id":6,"type":"events.resync","subscription":"all"}));
    assert_eq!(
        resync["snapshot"]["sequence"],
        snapshot["snapshot"]["sequence"]
    );
    assert_eq!(
        c.request(json!({"id":7,"type":"events.unsubscribe","subscription":"exit"}))["type"],
        "ok"
    );
    assert_eq!(
        c.request(json!({"id":8,"type":"events.unsubscribe","subscription":"exit"}))["type"],
        "error"
    );
    let bytes = output(&msgs);
    assert!(!bytes.windows(4).any(|b| b == b"7501"));
}
#[test]
fn v2_layout_commands_and_validation() {
    let d = Daemon::start("layouts");
    let mut c = d.connect();
    c.hello();
    let first=c.request(json!({"id":2,"type":"layout.tab","session":"default","cols":80,"rows":24,"command":["/bin/cat"],"label":"one"}));
    let a = first["terminal"].as_str().unwrap();
    let second=c.request(json!({"id":3,"type":"layout.split","session":"default","block":a,"axis":"vertical","cols":40,"rows":24,"command":["/bin/cat"]}));
    let b = second["terminal"].as_str().unwrap();
    let snap = c.request(json!({"id":4,"type":"events.snapshot"}));
    let window = snap["snapshot"]["sessions"]["default"]["windows"][0]["window_id"]
        .as_str()
        .unwrap();
    for (n, command) in [
        json!({"op":"resize","session":"default","window":window,"path":[],"ratio":0.7}),
        json!({"op":"zoom","session":"default","block":b,"enabled":true}),
        json!({"op":"focus","session":"default","block":a}),
        json!({"op":"label","session":"default","window":window,"label":"renamed"}),
    ]
    .into_iter()
    .enumerate()
    {
        assert_eq!(
            c.request(json!({"id":10+n,"type":"layout.command","command":command}))["type"],
            "ok"
        );
    }
    let before = c.request(json!({"id":20,"type":"events.snapshot"}));
    assert_eq!(c.request(json!({"id":21,"type":"layout.command","command":{"op":"resize","session":"default","window":window,"path":[0],"ratio":0.2}}))["type"],"error");
    let after = c.request(json!({"id":22,"type":"events.snapshot"}));
    assert_eq!(before["snapshot"], after["snapshot"]);
    let w = &after["snapshot"]["sessions"]["default"]["windows"][0];
    assert_eq!(w["label"], "renamed");
    assert_eq!(w["selected_block"], a);
    assert_eq!(w["zoomed_block"], a);
    assert_eq!(w["layout"]["ratio"], 0.7);
    for (id, block) in [(30, a), (31, b)] {
        assert_eq!(c.request(json!({"id":id,"type":"layout.command","command":{"op":"close","session":"default","block":block}}))["type"],"ok");
    }
    let snap = c.request(json!({"id":32,"type":"events.snapshot"}));
    assert!(snap["snapshot"]["sessions"]["default"]["windows"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        c.request(json!({"id":33,"type":"layout.tab","session":"default","cols":0,"rows":24}))
            ["type"],
        "error"
    );
}
#[test]
fn real_pty_detection_prompt_reset_and_survival() {
    let d = Daemon::start("statuslife");
    let mut c = d.connect();
    c.hello();
    c.request(json!({"id":2,"type":"events.subscribe_all","subscription":"s"}));
    c.send(json!({"id":3,"type":"spawn","cols":80,"rows":24,"command":["/bin/sh","-c",r#"stty -echo -icanon min 1 time 0
printf '\033]7501;?\033\\'
reply=$(dd bs=1 count=10 2>/dev/null)
[ "$reply" = "$(printf '\033]7501;?\033\\')" ] || exit 9
printf 'detected\033]7501;state=working:id=w\007\033]7501;state=blocked:id=b\007\033]7501;state=done:id=d\007\033]7501;state=error:id=e\007\033]133;A\007'
dd bs=1 count=1 >/dev/null 2>&1
printf '\033c'
dd bs=1 count=1 >/dev/null 2>&1
"#]}));
    let messages = c.collect(|m| {
        m.iter().any(|v| {
            event_name(v, "program_status_removed")
                && v["event"]["payload"]["reason"] == "shell_prompt"
        }) && m.iter().any(|v| v["id"] == 3)
    });
    let block = of_type(&messages, "spawned").next().unwrap()["terminal"]
        .as_str()
        .unwrap();
    assert!(String::from_utf8_lossy(&output(&messages)).contains("detected"));
    let s = c.request(json!({"id":4,"type":"events.snapshot"}));
    let records = &s["snapshot"]["sessions"]["default"]["blocks"][block]["statuses"]["records"];
    assert_eq!(records.as_object().unwrap().len(), 2);
    assert_eq!(records["d"]["state"], "done");
    assert_eq!(records["e"]["state"], "error");
    c.send(json!({"type":"input","terminal":block,"data":B64.encode("x")}));
    c.collect(|m| {
        m.iter().any(|v| {
            event_name(v, "program_status_removed") && v["event"]["payload"]["reason"] == "reset"
        })
    });
    let s = c.request(json!({"id":5,"type":"events.snapshot"}));
    assert!(
        s["snapshot"]["sessions"]["default"]["blocks"][block]["statuses"]["records"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    c.send(json!({"type":"input","terminal":block,"data":B64.encode("x")}));
    let msgs = c.collect(|m| m.iter().any(|v| event_name(v, "child_exited")));
    assert_eq!(
        msgs.iter().find(|v| event_name(v, "child_exited")).unwrap()["event"]["payload"]
            ["exit_code"],
        0
    );
}
#[test]
fn daemon_restart_changes_instance_and_clears_snapshots() {
    let old = {
        let d = Daemon::start("restart");
        let mut c = d.connect();
        c.hello();
        let s = c.request(json!({"id":2,"type":"events.snapshot"}));
        s["snapshot"]["instance"].clone()
    };
    let d = Daemon::start("restart");
    let mut c = d.connect();
    c.hello();
    let s = c.request(json!({"id":2,"type":"events.subscribe_all","subscription":"new"}));
    assert_ne!(s["snapshot"]["instance"], old);
    assert!(s["snapshot"]["sessions"]["default"]["blocks"]
        .as_object()
        .unwrap()
        .is_empty());
}

#[test]
fn real_pty_slow_subscriber_reports_gap_without_stalling_output() {
    let d = Daemon::start("slow");
    let mut slow = d.connect();
    slow.hello();
    slow.request(json!({"id":2,"type":"events.subscribe_all","subscription":"slow"}));
    let mut producer = d.connect();
    producer.hello();
    producer.send(json!({"id":2,"type":"spawn","cols":80,"rows":24,"command":["/bin/sh","-c",r"i=0; while [ $i -lt 6000 ]; do printf '\033]7501;state=working:id=job\007'; i=$((i+1)); done; printf finished"]}));
    // Deliberately do not drain `slow` while the child runs and emits reports.
    let messages = producer.collect(|m| {
        String::from_utf8_lossy(&output(m)).contains("finished") && m.iter().any(|v| v["id"] == 2)
    });
    assert!(String::from_utf8_lossy(&output(&messages)).contains("finished"));
    assert_eq!(
        producer.request(json!({"id":3,"type":"ping"}))["type"],
        "pong"
    );
    let messages = slow.collect(|m| of_type(m, "events.gap").next().is_some());
    assert!(
        of_type(&messages, "events.gap").next().unwrap()["missed"]
            .as_u64()
            .unwrap()
            > 0
    );
    let recovered = slow.request(json!({"id":3,"type":"events.resync","subscription":"slow"}));
    assert_eq!(recovered["type"], "events.subscribed");
    assert!(recovered["snapshot"]["sequence"].as_u64().unwrap() > 6000);
}
