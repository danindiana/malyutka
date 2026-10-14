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
        preview: String,
    },
    Todo(Vec<(String, String)>), // (status, text)
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
    pub allow_files: bool,
    pub allow_memory: bool,
    pub allow_process: bool,
    pub allow_skills: bool,
    pub allow_mcp: bool,
    pub allow_web: bool,
    pub personality: String,
    pub context_window: Option<u64>,
    pub compress_next: bool,
    pub verbose: bool,
    pub statusbar: bool,
}

pub struct Approval {
    pub action: String,
    pub tool: String,
    pub args: String,
    pub reason: String,
    pub policy: String,
    pub deadline: Instant,
}

pub struct Turn {
    pub run_id: String,
    pub prompt: String,
    pub item_start: usize,
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

pub struct SkinPick {
    pub skins: Vec<Skin>,
    pub sel: usize,
    pub orig: Skin,
}

pub struct BgProc {
    pub id: String,
    pub command: String,
    pub running: bool,
    pub code: Option<i64>,
}

pub struct App {
    pub procs: Vec<BgProc>,
    pub mcp: Vec<(String, String)>, // (server, state)
    pub approval: Option<Approval>,
    pub session: Option<String>,
    pub turns: Vec<Turn>,
    pub cur_prompt: Option<(String, usize)>,
    pub skin_pick: Option<SkinPick>,
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
            procs: vec![],
            mcp: vec![],
            approval: None,
            session: None,
            turns: vec![],
            cur_prompt: None,
            skin_pick: None,
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

    /// Command line for `malyutka run`. The TUI always uses the stdin approval
    /// channel so ASKs become a modal instead of a silent denial.
    pub fn run_args(&self, task: &str) -> Vec<String> {
        let mut args = vec![
            "run".to_string(),
            "--json".to_string(),
            "--approvals:stdin".to_string(),
        ];
        for (k, v) in [
            ("provider", &self.cfg.provider),
            ("model", &self.cfg.model),
            ("base-url", &self.cfg.base_url),
            ("personality", &self.cfg.personality),
        ] {
            if !v.is_empty() {
                args.push(format!("--{k}:{v}"));
            }
        }
        for (on, flag) in [
            (self.cfg.allow_shell, "--allow-shell"),
            (self.cfg.allow_files, "--allow-files"),
            (self.cfg.allow_memory, "--allow-memory"),
            (self.cfg.allow_process, "--allow-process"),
            (self.cfg.allow_skills, "--skills"),
            (self.cfg.allow_mcp, "--mcp"),
            (self.cfg.allow_web, "--web"),
        ] {
            if on {
                args.push(flag.to_string());
            }
        }
        if let Some(n) = self.cfg.context_window {
            args.push(format!("--context-window:{n}"));
        }
        if let Some(id) = &self.session {
            args.push(format!("--resume:{id}"));
            if self.cfg.compress_next {
                args.push("--compress".to_string());
            }
        }
        // A leading '-' would be parsed as an option by the harness.
        args.push(if task.starts_with('-') {
            format!("Task: {task}")
        } else {
            task.to_string()
        });
        args
    }

    /// Drops the last completed turn (transcript items and resume point).
    /// Returns its prompt. The TUI never edits session files: the previous
    /// run is simply resumed again.
    pub fn undo_turn(&mut self) -> Option<String> {
        let t = self.turns.pop()?;
        self.items.truncate(t.item_start);
        self.session = self.turns.last().map(|t| t.run_id.clone());
        self.scroll = 0;
        Some(t.prompt)
    }

    pub fn answer_approval(&mut self, answer: &str) {
        if let Some(a) = self.approval.take() {
            let line = serde_json::json!({"action": a.action, "answer": answer}).to_string();
            let sent = self.run.as_ref().is_some_and(|h| h.send_line(&line));
            if !sent {
                self.items
                    .push(Item::Warn("could not reach the harness to answer".into()));
            }
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
                self.approval = None;
                for p in self.procs.iter_mut() {
                    p.running = false; // the harness kills background processes when a run ends
                }
                // A turn counts (and becomes the resume point) when it ended cleanly.
                if matches!(code, Some(0) | Some(4)) && !self.run_id.is_empty() {
                    if let Some((prompt, item_start)) = self.cur_prompt.take() {
                        self.turns.push(Turn {
                            run_id: self.run_id.clone(),
                            prompt,
                            item_start,
                        });
                        self.session = Some(self.run_id.clone());
                    }
                } else {
                    self.cur_prompt = None;
                }
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
                    preview: String::new(),
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
                let preview = e.s("preview");
                self.finish_tool(s, code == 0);
                if !preview.is_empty() {
                    if let Some(Item::Tool { preview: p, .. }) = self
                        .items
                        .iter_mut()
                        .rev()
                        .find(|i| matches!(i, Item::Tool { .. }))
                    {
                        *p = preview;
                    }
                }
            }
            "approval.request" => {
                let secs = e
                    .payload
                    .get("timeoutSec")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(300);
                self.approval = Some(Approval {
                    action: e.s("action"),
                    tool: e.s("tool"),
                    args: e
                        .payload
                        .get("args")
                        .map(|v| v.to_string())
                        .unwrap_or_default(),
                    reason: e.s("reason"),
                    policy: e.s("policy"),
                    deadline: Instant::now() + std::time::Duration::from_secs(secs),
                });
            }
            "approval.answer" => {
                if self
                    .approval
                    .as_ref()
                    .is_some_and(|a| a.action == e.s("action"))
                {
                    self.approval = None;
                }
                let ans = e.s("answer");
                let src = e.s("source");
                if src == "timeout" || src == "eof" {
                    self.items
                        .push(Item::Warn(format!("approval {ans} ({src})")));
                } else {
                    self.items
                        .push(Item::Note(format!("approval: {ans} ({src})")));
                }
            }
            "todo.update" => {
                let list: Vec<(String, String)> = e
                    .payload
                    .get("items")
                    .and_then(|v| v.as_array())
                    .map(|a| {
                        a.iter()
                            .map(|i| {
                                let g = |k: &str| {
                                    i.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string()
                                };
                                (g("status"), g("text"))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                match self
                    .items
                    .iter_mut()
                    .rev()
                    .find(|i| matches!(i, Item::Todo(_)))
                {
                    Some(Item::Todo(t)) => *t = list,
                    _ => self.items.push(Item::Todo(list)),
                }
            }
            "process.started" => {
                let id = e.s("process");
                let command = e.s("command");
                self.items
                    .push(Item::Note(format!("process {id} started: {command}")));
                self.procs.push(BgProc {
                    id,
                    command,
                    running: true,
                    code: None,
                });
            }
            "process.exited" => {
                let id = e.s("process");
                let code = e.payload.get("exitCode").and_then(|v| v.as_i64());
                if let Some(p) = self.procs.iter_mut().find(|p| p.id == id) {
                    p.running = false;
                    p.code = code;
                }
                self.items.push(Item::Note(format!(
                    "process {id} exited ({})",
                    code.map_or("?".to_string(), |c| c.to_string())
                )));
            }
            "process.reaped" => {
                for p in self.procs.iter_mut() {
                    p.running = false;
                }
                self.items.push(Item::Note(format!(
                    "{} background process(es) stopped with the run",
                    e.payload
                        .get("killed")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0)
                )));
            }
            "web.fetched" => {
                let n = |k: &str| e.payload.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
                self.items.push(Item::Note(format!(
                    "web: {} → HTTP {} ({} bytes{}{})",
                    e.s("host"),
                    n("status"),
                    n("bytes"),
                    if n("redirects") > 0 {
                        format!(", {} redirect(s)", n("redirects"))
                    } else {
                        String::new()
                    },
                    if e.payload.get("cached").and_then(|v| v.as_bool()) == Some(true) {
                        ", cached"
                    } else {
                        ""
                    }
                )));
            }
            "web.unavailable" => self.items.push(Item::Warn(format!(
                "web tools unavailable: {}",
                e.s("reason")
            ))),
            "mcp.connected" => {
                let server = e.s("server");
                let n = e.payload.get("tools").and_then(|v| v.as_u64()).unwrap_or(0);
                let sb = e
                    .payload
                    .get("sandbox")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                self.mcp.retain(|(s, _)| *s != server);
                self.mcp.push((
                    server.clone(),
                    format!("{n} tools, {}", if sb { "sandboxed" } else { "UNCONFINED" }),
                ));
                self.items.push(Item::Note(format!(
                    "mcp {server}: {n} tool(s) connected ({})",
                    if sb { "sandboxed" } else { "unconfined" }
                )));
            }
            "mcp.failed" => {
                let server = e.s("server");
                self.mcp.retain(|(s, _)| *s != server);
                self.mcp
                    .push((server.clone(), format!("failed: {}", e.s("reason"))));
                self.items.push(Item::Warn(format!(
                    "mcp {server} unavailable: {}",
                    e.s("reason")
                )));
            }
            "mcp.refused" => self.items.push(Item::Warn(format!(
                "mcp {}: tool '{}' refused: {}",
                e.s("server"),
                e.s("tool"),
                e.s("reason")
            ))),
            "confinement.limits" => self.items.push(Item::Note(format!(
                "limits applied: {} MB memory, {} tasks",
                e.payload
                    .get("memoryMb")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                e.payload.get("pids").and_then(|v| v.as_u64()).unwrap_or(0)
            ))),
            "confinement.degraded" => self.items.push(Item::Warn(format!(
                "resource limits NOT applied: {}",
                e.s("reason")
            ))),
            "context.compacted" => {
                let n = |k: &str| e.payload.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
                self.items.push(Item::Note(format!(
                    "context compacted: {} messages summarised and archived ({} → {} tokens)",
                    n("dropped"),
                    n("tokensBefore"),
                    n("tokensAfter")
                )));
            }
            "context.compaction_failed" => self.items.push(Item::Warn(format!(
                "context not compacted: {}",
                e.s("reason")
            ))),
            "mandate.used" => self.items.push(Item::Note(format!(
                "mandate {} used ({}/{})",
                e.s("mandate"),
                e.payload.get("used").and_then(|v| v.as_u64()).unwrap_or(0),
                e.payload
                    .get("maxActions")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0)
            ))),
            "mandate.miss" => {
                if self.cfg.verbose {
                    self.items.push(Item::Note(format!(
                        "no mandate covers {} ({} in a row)",
                        e.s("tool"),
                        e.payload
                            .get("streak")
                            .and_then(|v| v.as_u64())
                            .unwrap_or(0)
                    )));
                }
            }
            "mandate.suspended" => self
                .items
                .push(Item::Warn(format!("mandates suspended: {}", e.s("reason")))),
            "mandate.corrupt" | "mandate.error" => self.items.push(Item::Err(format!(
                "mandate log problem: {}",
                e.payload
                    .get("reason")
                    .map(|v| v.to_string())
                    .or_else(|| e.payload.get("problems").map(|v| v.to_string()))
                    .unwrap_or_default()
            ))),
            "mandate.status" => {
                let n = e
                    .payload
                    .get("mandates")
                    .and_then(|v| v.as_array())
                    .map_or(0, |a| a.len());
                if n > 0 {
                    self.items
                        .push(Item::Note(format!("{n} mandate(s) active (see /mandates)")));
                }
            }
            "memory.updated" => self.items.push(Item::Note(format!(
                "memory {} ({} bytes)",
                e.s("op"),
                e.payload.get("bytes").and_then(|v| v.as_u64()).unwrap_or(0)
            ))),
            "session.failed" => self
                .items
                .push(Item::Warn(format!("session not saved: {}", e.s("reason")))),
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
                allow_files: false,
                allow_memory: false,
                allow_process: false,
                allow_skills: false,
                allow_mcp: false,
                allow_web: false,
                personality: String::new(),
                context_window: None,
                compress_next: false,
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
    use crate::skin::Skin;

    fn app() -> App {
        App::new(
            Config {
                bin: "malyutka".into(),
                provider: String::new(),
                model: String::new(),
                base_url: String::new(),
                allow_shell: false,
                allow_files: false,
                allow_memory: false,
                allow_process: false,
                allow_skills: false,
                allow_mcp: false,
                allow_web: false,
                personality: String::new(),
                context_window: None,
                compress_next: false,
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

    #[test]
    fn run_args_include_resume_and_stdin_approvals() {
        let mut a = app();
        let base = a.run_args("hi");
        assert!(base.contains(&"--approvals:stdin".to_string()));
        assert!(!base.iter().any(|x| x.starts_with("--resume")));
        a.session = Some("9M14-abcd".into());
        a.cfg.allow_files = true;
        a.cfg.personality = "concise".into();
        let args = a.run_args("-weird task");
        assert!(args.contains(&"--resume:9M14-abcd".to_string()));
        assert!(args.contains(&"--allow-files".to_string()));
        assert!(args.contains(&"--personality:concise".to_string()));
        assert_eq!(args.last().unwrap(), "Task: -weird task");
    }

    #[test]
    fn turns_resume_undo_and_retry_bookkeeping() {
        let mut a = app();
        // turn 1
        a.items.push(Item::User("one".into()));
        a.cur_prompt = Some(("one".into(), 0));
        a.run_id = "R1".into();
        a.on_msg(Msg::Exit(Some(0)));
        assert_eq!(a.session.as_deref(), Some("R1"));
        // turn 2
        a.items.push(Item::Agent("a1".into()));
        a.items.push(Item::User("two".into()));
        a.cur_prompt = Some(("two".into(), 2));
        a.run_id = "R2".into();
        a.on_msg(Msg::Exit(Some(0)));
        assert_eq!(a.session.as_deref(), Some("R2"));
        assert_eq!(a.turns.len(), 2);
        // undo drops turn 2 and resumes from R1
        assert_eq!(a.undo_turn().as_deref(), Some("two"));
        assert_eq!(a.items.len(), 2);
        assert_eq!(a.session.as_deref(), Some("R1"));
        // undo again: back to a fresh session
        assert_eq!(a.undo_turn().as_deref(), Some("one"));
        assert!(a.session.is_none() && a.items.is_empty());
        assert!(a.undo_turn().is_none());
    }

    #[test]
    fn failed_runs_do_not_move_the_resume_point() {
        let mut a = app();
        a.session = Some("R0".into());
        a.cur_prompt = Some(("x".into(), 0));
        a.run_id = "R9".into();
        a.on_msg(Msg::Exit(Some(1)));
        assert_eq!(a.session.as_deref(), Some("R0"));
        assert!(a.turns.is_empty() && a.cur_prompt.is_none());
    }

    #[test]
    fn approval_request_and_answer_events() {
        let mut a = app();
        a.on_event(ev(
            "approval.request",
            serde_json::json!({"action":"A1","tool":"shell","args":{"command":"x"},"reason":"force push","policy":"approval.dangerous","timeoutSec":300}),
        ));
        let ap = a.approval.as_ref().unwrap();
        assert_eq!(ap.action, "A1");
        assert_eq!(ap.tool, "shell");
        // an answer for another action leaves the modal up
        a.on_event(ev(
            "approval.answer",
            serde_json::json!({"action":"OTHER","answer":"deny","source":"operator"}),
        ));
        assert!(a.approval.is_some());
        a.on_event(ev(
            "approval.answer",
            serde_json::json!({"action":"A1","answer":"deny","source":"timeout"}),
        ));
        assert!(a.approval.is_none());
        assert!(matches!(a.items.last(), Some(Item::Warn(s)) if s.contains("timeout")));
    }

    #[test]
    fn todo_updates_replace_in_place_and_preview_attaches_to_the_tool() {
        let mut a = app();
        a.on_event(ev(
            "todo.update",
            serde_json::json!({"items":[{"status":"pending","text":"a"}]}),
        ));
        a.on_event(ev("todo.update", serde_json::json!({"items":[{"status":"done","text":"a"},{"status":"pending","text":"b"}]})));
        assert_eq!(a.items.len(), 1);
        assert!(matches!(&a.items[0], Item::Todo(t) if t.len() == 2 && t[0].0 == "done"));
        a.on_event(ev(
            "tool.proposed",
            serde_json::json!({"name":"patch","args":{}}),
        ));
        a.on_event(ev(
            "tool.result",
            serde_json::json!({"exitCode":0,"preview":"--- f\n- old\n+ new"}),
        ));
        assert!(
            matches!(a.items.last(), Some(Item::Tool { preview, .. }) if preview.contains("+ new"))
        );
    }

    #[test]
    fn mandate_events_become_transcript_lines() {
        let mut a = app();
        a.on_event(ev(
            "mandate.status",
            serde_json::json!({"mandates":[{"mandate":"M-1"}]}),
        ));
        a.on_event(ev(
            "mandate.used",
            serde_json::json!({"mandate":"M-1","used":1,"maxActions":3}),
        ));
        a.on_event(ev(
            "mandate.suspended",
            serde_json::json!({"reason":"3 consecutive calls outside every latched mandate"}),
        ));
        a.on_event(ev(
            "mandate.corrupt",
            serde_json::json!({"problems":["bad crc"]}),
        ));
        let texts: Vec<String> = a
            .items
            .iter()
            .map(|i| match i {
                Item::Note(t) | Item::Warn(t) | Item::Err(t) => t.clone(),
                _ => String::new(),
            })
            .collect();
        assert!(texts[0].contains("1 mandate(s) active"));
        assert!(texts[1].contains("M-1 used (1/3)"));
        assert!(texts[2].contains("suspended"));
        assert!(texts[3].contains("bad crc"));
        // a miss is quiet unless verbose
        a.on_event(ev(
            "mandate.miss",
            serde_json::json!({"tool":"shell","streak":1}),
        ));
        assert_eq!(a.items.len(), 4);
        a.cfg.verbose = true;
        a.on_event(ev(
            "mandate.miss",
            serde_json::json!({"tool":"shell","streak":2}),
        ));
        assert_eq!(a.items.len(), 5);
    }

    #[test]
    fn compress_and_context_window_reach_the_command_line() {
        let mut a = app();
        assert!(!a
            .run_args("x")
            .iter()
            .any(|x| x.starts_with("--context-window")));
        a.cfg.context_window = Some(8192);
        a.cfg.compress_next = true;
        // --compress only makes sense with a session to compact
        assert!(!a.run_args("x").contains(&"--compress".to_string()));
        a.session = Some("R1".into());
        let args = a.run_args("x");
        assert!(args.contains(&"--context-window:8192".to_string()));
        assert!(args.contains(&"--compress".to_string()));
        assert!(args.contains(&"--resume:R1".to_string()));
    }

    #[test]
    fn compaction_events_are_visible() {
        let mut a = app();
        a.on_event(ev(
            "context.compacted",
            serde_json::json!({"dropped":12,"tokensBefore":9000,"tokensAfter":3000}),
        ));
        a.on_event(ev(
            "context.compaction_failed",
            serde_json::json!({"reason":"no progress"}),
        ));
        assert!(
            matches!(&a.items[0], Item::Note(t) if t.contains("12 messages") && t.contains("9000 → 3000"))
        );
        assert!(matches!(&a.items[1], Item::Warn(t) if t.contains("no progress")));
    }

    #[test]
    fn process_events_track_background_processes() {
        let mut a = app();
        a.on_event(ev(
            "process.started",
            serde_json::json!({"process":"p1","command":"sleep 60","pid":123}),
        ));
        a.on_event(ev(
            "process.started",
            serde_json::json!({"process":"p2","command":"make","pid":124}),
        ));
        assert_eq!(a.procs.iter().filter(|p| p.running).count(), 2);
        a.on_event(ev(
            "process.exited",
            serde_json::json!({"process":"p2","exitCode":0}),
        ));
        assert_eq!(a.procs.iter().filter(|p| p.running).count(), 1);
        assert_eq!(a.procs[1].code, Some(0));
        // a run ending stops everything, whether or not the harness said so
        a.on_msg(Msg::Exit(Some(0)));
        assert_eq!(a.procs.iter().filter(|p| p.running).count(), 0);
    }

    #[test]
    fn limit_events_and_process_flag() {
        let mut a = app();
        a.on_event(ev(
            "confinement.limits",
            serde_json::json!({"memoryMb":2048,"pids":512,"applied":true}),
        ));
        a.on_event(ev(
            "confinement.degraded",
            serde_json::json!({"reason":"no user bus"}),
        ));
        assert!(
            matches!(&a.items[0], Item::Note(t) if t.contains("2048 MB") && t.contains("512 tasks"))
        );
        assert!(
            matches!(&a.items[1], Item::Warn(t) if t.contains("NOT applied") && t.contains("no user bus"))
        );
        assert!(!a.run_args("x").contains(&"--allow-process".to_string()));
        a.cfg.allow_process = true;
        assert!(a.run_args("x").contains(&"--allow-process".to_string()));
    }

    #[test]
    fn mcp_events_and_flags() {
        let mut a = app();
        a.on_event(ev(
            "mcp.connected",
            serde_json::json!({"server":"notes","tools":3,"sandbox":true}),
        ));
        a.on_event(ev(
            "mcp.failed",
            serde_json::json!({"server":"bad","reason":"timed out"}),
        ));
        a.on_event(ev(
            "mcp.refused",
            serde_json::json!({"server":"notes","tool":"shell","reason":"name already registered"}),
        ));
        assert_eq!(a.mcp.len(), 2);
        assert!(a.mcp[0].1.contains("3 tools") && a.mcp[0].1.contains("sandboxed"));
        assert!(a.mcp[1].1.starts_with("failed"));
        assert!(
            matches!(&a.items[0], Item::Note(t) if t.contains("notes") && t.contains("3 tool"))
        );
        assert!(matches!(&a.items[1], Item::Warn(t) if t.contains("timed out")));
        assert!(matches!(&a.items[2], Item::Warn(t) if t.contains("refused")));
        // an unconfined server is called out
        a.on_event(ev(
            "mcp.connected",
            serde_json::json!({"server":"host","tools":1,"sandbox":false}),
        ));
        assert!(a
            .mcp
            .iter()
            .any(|(s, st)| s == "host" && st.contains("UNCONFINED")));
        assert!(!a.run_args("x").contains(&"--mcp".to_string()));
        a.cfg.allow_mcp = true;
        a.cfg.allow_skills = true;
        let args = a.run_args("x");
        assert!(args.contains(&"--mcp".to_string()) && args.contains(&"--skills".to_string()));
    }

    #[test]
    fn web_events_and_flag() {
        let mut a = app();
        a.on_event(ev("web.fetched", serde_json::json!({"host":"example.com","status":200,"bytes":577,"redirects":1,"cached":false})));
        a.on_event(ev("web.fetched", serde_json::json!({"host":"example.com","status":200,"bytes":10,"redirects":0,"cached":true})));
        a.on_event(ev(
            "web.unavailable",
            serde_json::json!({"reason":"helper not found"}),
        ));
        assert!(
            matches!(&a.items[0], Item::Note(t) if t.contains("example.com") && t.contains("HTTP 200") && t.contains("1 redirect"))
        );
        assert!(matches!(&a.items[1], Item::Note(t) if t.contains("cached")));
        assert!(matches!(&a.items[2], Item::Warn(t) if t.contains("helper not found")));
        assert!(!a.run_args("x").contains(&"--web".to_string()));
        a.cfg.allow_web = true;
        assert!(a.run_args("x").contains(&"--web".to_string()));
    }
}
