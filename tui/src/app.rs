use crate::events::{exit_meaning, Event};
use crate::runner::{Handle, Msg};
use crate::skin::Skin;
use std::time::Instant;

pub enum Item {
    User(String),
    Agent(String),
    Tool {
        name: String,
        args: String,
        verdict: Option<String>,
        result: Option<String>,
        ok: Option<bool>,
        t0: Instant,
        secs: Option<f32>,
    },
    Note(String),
    Warn(String),
    Err(String),
}

#[derive(Clone)]
pub struct Config {
    pub bin: String,
    pub provider: String,
    pub model: String,
    pub base_url: String,
    pub allow_shell: bool,
    pub verbose: bool,
    pub statusbar: bool,
}

pub struct Picker {
    pub models: Vec<crate::ollama::Model>,
    pub filter: String,
    pub sel: usize,
}

impl Picker {
    pub fn visible(&self) -> Vec<&crate::ollama::Model> {
        let f = self.filter.to_lowercase();
        self.models
            .iter()
            .filter(|m| m.name.to_lowercase().contains(&f))
            .collect()
    }
}

pub struct App {
    pub picker: Option<Picker>,
    pub cfg: Config,
    pub skin: Skin,
    pub items: Vec<Item>,
    pub input: String,
    pub cursor: usize, // char index
    pub history: Vec<String>,
    pub hist_pos: Option<usize>,
    pub sel: usize, // slash popup selection
    pub scroll: usize,
    pub run: Option<Handle>,
    pub started: Instant,
    pub step: u32,
    pub run_id: String,
    pub allow: u32,
    pub deny: u32,
    pub ask: u32,
    pub final_seen: bool,
    pub stopped: bool,
    pub doctor: Vec<(String, String)>,
    pub tick: usize,
    pub quit: bool,
    pub ctrl_c_at: Option<Instant>,
}

impl App {
    pub fn new(cfg: Config, skin: Skin, doctor: Vec<(String, String)>) -> App {
        App {
            picker: None,
            cfg,
            skin,
            items: vec![],
            input: String::new(),
            cursor: 0,
            history: vec![],
            hist_pos: None,
            sel: 0,
            scroll: 0,
            run: None,
            started: Instant::now(),
            step: 0,
            run_id: String::new(),
            allow: 0,
            deny: 0,
            ask: 0,
            final_seen: false,
            stopped: false,
            doctor,
            tick: 0,
            quit: false,
            ctrl_c_at: None,
        }
    }

    pub fn busy(&self) -> bool {
        self.run.is_some()
    }

    pub fn note(&mut self, s: impl Into<String>) {
        self.items.push(Item::Note(s.into()));
    }

    pub fn reset_run_state(&mut self) {
        self.step = 0;
        self.run_id.clear();
        self.final_seen = false;
        self.stopped = false;
        self.started = Instant::now();
    }

    pub fn on_msg(&mut self, m: Msg) {
        match m {
            Msg::Ev(e) => self.on_event(e),
            Msg::Stderr(l) => {
                if let Some(t) = l.strip_prefix("FINAL:") {
                    if !self.final_seen {
                        self.final_seen = true;
                        self.items.push(Item::Agent(t.trim().to_string()));
                    }
                } else if self.cfg.verbose && !l.trim().is_empty() {
                    self.items.push(Item::Note(l));
                }
            }
            Msg::Exit(code) => {
                self.run = None;
                match code {
                    Some(0) => {}
                    Some(c) if self.stopped => {
                        self.items.push(Item::Warn(format!("stopped (exit {c})")))
                    }
                    Some(c) => self
                        .items
                        .push(Item::Err(format!("exit {c}: {}", exit_meaning(c)))),
                    None => self
                        .items
                        .push(Item::Warn("run terminated by signal".into())),
                }
            }
        }
    }

    pub fn on_event(&mut self, e: Event) {
        match e.kind.as_str() {
            "run.start" => self.run_id = e.s("run"),
            "step.start" => {
                self.step = e.payload.get("step").and_then(|v| v.as_u64()).unwrap_or(0) as u32
            }
            "tool.proposed" => {
                let args = e
                    .payload
                    .get("args")
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                self.items.push(Item::Tool {
                    name: e.s("name"),
                    args,
                    verdict: None,
                    result: None,
                    ok: None,
                    t0: Instant::now(),
                    secs: None,
                });
            }
            "policy.decision" => {
                let v = e.s("verdict");
                match v.as_str() {
                    "ALLOW" => self.allow += 1,
                    "DENY" => self.deny += 1,
                    "ASK" => self.ask += 1,
                    _ => {}
                }
                if let Some(Item::Tool { verdict, .. }) = self
                    .items
                    .iter_mut()
                    .rev()
                    .find(|i| matches!(i, Item::Tool { verdict: None, .. }))
                {
                    *verdict = Some(v.clone());
                }
                if v == "DENY" {
                    let why = e.s("reason");
                    let pol = e.s("policy");
                    self.items
                        .push(Item::Warn(format!("denied by {pol}: {why}")));
                }
            }
            "tool.result" => {
                let code = e
                    .payload
                    .get("exitCode")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                let mut s = format!("exit={code}");
                if e.payload.get("truncated").and_then(|v| v.as_bool()) == Some(true) {
                    s.push_str(" TRUNC");
                }
                if e.payload.get("timedOut").and_then(|v| v.as_bool()) == Some(true) {
                    s.push_str(" TIMEOUT");
                }
                self.finish_tool(s, code == 0);
            }
            "tool.cancelled" => {
                let s = format!("cancelled: {}", e.s("reason"));
                self.finish_tool(s, false);
            }
            "journal.unknown_outcome" => self.items.push(Item::Warn(format!(
                "unknown outcome from run {}: {} — use /journal",
                e.s("run"),
                e.s("tool")
            ))),
            "journal.owner_unknown" => self.items.push(Item::Warn(format!(
                "owner status unknown for {} ({}) — use /journal",
                e.s("action"),
                e.s("tool")
            ))),
            "journal.degraded" => self.items.push(Item::Warn(format!(
                "outcome not journaled: {}",
                e.s("reason")
            ))),
            "confinement.waived" => self
                .items
                .push(Item::Warn("CONFINEMENT WAIVED: shell runs on host".into())),
            "confinement.failed" => self.items.push(Item::Err(e.s("reason"))),
            "agent.final" => {
                if !self.final_seen {
                    self.final_seen = true;
                    self.items.push(Item::Agent(e.s("text")));
                }
            }
            "agent.halt" => self
                .items
                .push(Item::Warn(format!("halted: {}", e.s("reason")))),
            _ => {
                if self.cfg.verbose {
                    self.items
                        .push(Item::Note(format!("{} {}", e.kind, e.payload)));
                }
            }
        }
    }

    fn finish_tool(&mut self, text: String, good: bool) {
        if let Some(Item::Tool {
            result,
            ok,
            t0,
            secs,
            ..
        }) = self
            .items
            .iter_mut()
            .rev()
            .find(|i| matches!(i, Item::Tool { result: None, .. }))
        {
            *result = Some(text);
            *ok = Some(good);
            *secs = Some(t0.elapsed().as_secs_f32());
        }
    }

    // ---- input editing ----
    fn byte_at(&self, ci: usize) -> usize {
        self.input
            .char_indices()
            .nth(ci)
            .map(|(i, _)| i)
            .unwrap_or(self.input.len())
    }
    pub fn insert(&mut self, c: char) {
        let b = self.byte_at(self.cursor);
        self.input.insert(b, c);
        self.cursor += 1;
        self.sel = 0;
        self.hist_pos = None;
    }
    pub fn backspace(&mut self) {
        if self.cursor > 0 {
            self.cursor -= 1;
            let b = self.byte_at(self.cursor);
            self.input.remove(b);
            self.sel = 0;
        }
    }
    pub fn delete(&mut self) {
        if self.cursor < self.input.chars().count() {
            let b = self.byte_at(self.cursor);
            self.input.remove(b);
        }
    }
    pub fn delete_word(&mut self) {
        while self.cursor > 0 && self.input.chars().nth(self.cursor - 1) == Some(' ') {
            self.backspace();
        }
        while self.cursor > 0 && self.input.chars().nth(self.cursor - 1) != Some(' ') {
            self.backspace();
        }
    }
    pub fn clear_input(&mut self) {
        self.input.clear();
        self.cursor = 0;
        self.sel = 0;
        self.hist_pos = None;
    }
    pub fn set_input(&mut self, s: String) {
        self.cursor = s.chars().count();
        self.input = s;
    }
    pub fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let p = match self.hist_pos {
            None => self.history.len() - 1,
            Some(0) => 0,
            Some(p) => p - 1,
        };
        self.hist_pos = Some(p);
        let s = self.history[p].clone();
        self.set_input(s);
    }
    pub fn history_next(&mut self) {
        match self.hist_pos {
            None => {}
            Some(p) if p + 1 < self.history.len() => {
                self.hist_pos = Some(p + 1);
                let s = self.history[p + 1].clone();
                self.set_input(s);
            }
            Some(_) => {
                self.hist_pos = None;
                self.clear_input();
            }
        }
    }

    /// Slash-command suggestions for the current input.
    pub fn suggestions(&self) -> Vec<(&'static str, &'static str)> {
        if self.input.starts_with('/') && !self.input.contains(' ') && !self.input.contains('\n') {
            crate::commands::matches(&self.input)
        } else {
            vec![]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skin::Skin;

    fn app() -> App {
        App::new(
            Config {
                bin: "malyutka".into(),
                provider: String::new(),
                model: String::new(),
                base_url: String::new(),
                allow_shell: false,
                verbose: false,
                statusbar: true,
            },
            Skin::by_name("default").unwrap(),
            vec![],
        )
    }

    fn ev(kind: &str, p: serde_json::Value) -> Event {
        Event {
            kind: kind.into(),
            payload: p,
        }
    }

    #[test]
    fn tool_lifecycle() {
        let mut a = app();
        a.on_event(ev(
            "tool.proposed",
            serde_json::json!({"name":"shell","args":{"cmd":"ls"}}),
        ));
        a.on_event(ev(
            "policy.decision",
            serde_json::json!({"verdict":"ALLOW"}),
        ));
        a.on_event(ev("tool.result", serde_json::json!({"exitCode":0})));
        assert_eq!(a.allow, 1);
        match &a.items[0] {
            Item::Tool {
                verdict,
                result,
                ok,
                ..
            } => {
                assert_eq!(verdict.as_deref(), Some("ALLOW"));
                assert_eq!(result.as_deref(), Some("exit=0"));
                assert_eq!(*ok, Some(true));
            }
            _ => panic!(),
        }
    }

    #[test]
    fn final_not_duplicated() {
        let mut a = app();
        a.on_event(ev("agent.final", serde_json::json!({"text":"hi"})));
        a.on_msg(Msg::Stderr("FINAL: hi".into()));
        assert_eq!(a.items.len(), 1);
    }

    #[test]
    fn deny_adds_warning_and_exit_error() {
        let mut a = app();
        a.on_event(ev(
            "tool.proposed",
            serde_json::json!({"name":"shell","args":{}}),
        ));
        a.on_event(ev(
            "policy.decision",
            serde_json::json!({"verdict":"DENY","policy":"p","reason":"r"}),
        ));
        a.on_msg(Msg::Exit(Some(4)));
        assert_eq!(a.deny, 1);
        assert!(matches!(a.items.last(), Some(Item::Err(s)) if s.contains("halted")));
    }

    #[test]
    fn editing_unicode() {
        let mut a = app();
        for c in "aé→b".chars() {
            a.insert(c);
        }
        a.backspace();
        a.backspace();
        assert_eq!(a.input, "aé");
        a.delete_word();
        assert_eq!(a.input, "");
    }
}

#[cfg(test)]
mod picker_tests {
    use super::*;
    use crate::ollama::Model;

    #[test]
    fn picker_filters_case_insensitively() {
        let m = |n: &str| Model {
            name: n.into(),
            params: String::new(),
            size_gb: 1.0,
        };
        let p = Picker {
            models: vec![m("Qwen3:9b"), m("gemma4:12b")],
            filter: "qwen".into(),
            sel: 0,
        };
        assert_eq!(p.visible().len(), 1);
    }
}
