//! Spawns `malyutka run --json` and forwards its output as messages.
use crate::events::{parse_line, Event};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub enum Msg {
    Ev(Event),
    Stderr(String),
    Exit(Option<i32>),
}

pub struct Handle {
    child: Arc<Mutex<Child>>,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
}

impl Handle {
    /// Writes one line to the harness (the approval control channel).
    pub fn send_line(&self, line: &str) -> bool {
        match self.stdin.lock() {
            Ok(mut g) => match g.as_mut() {
                Some(w) => writeln!(w, "{line}").and_then(|_| w.flush()).is_ok(),
                None => false,
            },
            Err(_) => false,
        }
    }

    pub fn kill(&self) {
        if let Ok(mut c) = self.child.lock() {
            let _ = c.kill();
        }
    }
}

pub fn spawn(bin: &str, args: &[String], tx: Sender<Msg>) -> std::io::Result<Handle> {
    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdin = Arc::new(Mutex::new(child.stdin.take()));
    let out = child.stdout.take().expect("piped stdout");
    let err = child.stderr.take().expect("piped stderr");
    let child = Arc::new(Mutex::new(child));

    let t1 = tx.clone();
    let h_out = thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Some(ev) = parse_line(&line) {
                let _ = t1.send(Msg::Ev(ev));
            }
        }
    });
    let t2 = tx.clone();
    let h_err = thread::spawn(move || {
        for line in BufReader::new(err).lines().map_while(Result::ok) {
            let _ = t2.send(Msg::Stderr(line));
        }
    });
    let c2 = Arc::clone(&child);
    let stdin2 = Arc::clone(&stdin);
    thread::spawn(move || {
        let code = loop {
            let st = c2.lock().ok().and_then(|mut c| c.try_wait().ok().flatten());
            if let Some(st) = st {
                break st.code();
            }
            thread::sleep(Duration::from_millis(40));
        };
        // Closing stdin tells a still-waiting approver "EOF" (= deny).
        if let Ok(mut g) = stdin2.lock() {
            g.take();
        }
        // Drain readers so no output is lost behind the Exit message.
        let _ = h_out.join();
        let _ = h_err.join();
        let _ = tx.send(Msg::Exit(code));
    });
    Ok(Handle { child, stdin })
}

/// Run a short command to completion and return stdout (used for doctor/journal).
pub fn capture(bin: &str, args: &[&str]) -> String {
    match Command::new(bin).args(args).stdin(Stdio::null()).output() {
        Ok(o) => {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            s
        }
        Err(e) => format!("cannot run {bin}: {e}"),
    }
}
