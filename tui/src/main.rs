mod app;
mod commands;
mod events;
mod ollama;
mod runner;
mod skin;
mod ui;

use app::{App, Config, Item, Picker};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use runner::Msg;
use skin::Skin;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

const HELP: &str = "malyutka-tui — Hermes-style terminal UI for the Malyutka (9M14) harness

USAGE: malyutka-tui [OPTIONS]

  --malyutka-bin <path>   malyutka executable (default: $MALYUTKA_BIN, ./malyutka, then PATH)
  --skin <name>           default | warsaw | nato | mono
  --provider <name>       mock | openai | ollama | vllm
  --model <name>
  --base-url <url>
  --ollama [url]          use local Ollama (default $OLLAMA_HOST or 127.0.0.1:11434)
  --allow-shell           allow the sandboxed shell tool
  -h, --help";

fn parse_args() -> Result<(Config, String), String> {
    let mut cfg = Config {
        bin: std::env::var("MALYUTKA_BIN").unwrap_or_default(),
        provider: String::new(),
        model: String::new(),
        base_url: String::new(),
        allow_shell: false,
        verbose: false,
        statusbar: true,
    };
    let mut skin = "default".to_string();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut val = |n: &str| it.next().ok_or(format!("{n} needs a value"));
        match a.as_str() {
            "-h" | "--help" => {
                println!("{HELP}");
                std::process::exit(0);
            }
            "--malyutka-bin" => cfg.bin = val("--malyutka-bin")?,
            "--skin" => skin = val("--skin")?,
            "--provider" => cfg.provider = val("--provider")?,
            "--model" => cfg.model = val("--model")?,
            "--base-url" => cfg.base_url = val("--base-url")?,
            "--allow-shell" => cfg.allow_shell = true,
            "--ollama" => {
                cfg.provider = "ollama".into();
                cfg.base_url = ollama::default_base();
            }
            other => return Err(format!("unknown option {other}\n\n{HELP}")),
        }
    }
    if cfg.bin.is_empty() {
        cfg.bin = if std::path::Path::new("./malyutka").is_file() {
            "./malyutka".into()
        } else {
            "malyutka".into()
        };
    }
    Ok((cfg, skin))
}

fn doctor_info(bin: &str) -> Vec<(String, String)> {
    runner::capture(bin, &["doctor"])
        .lines()
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .filter(|(k, _)| matches!(k.as_str(), "malyutka" | "sandbox" | "journal"))
        .map(|(k, v)| {
            (
                if k == "malyutka" {
                    "version".to_string()
                } else {
                    k
                },
                v,
            )
        })
        .collect()
}

fn state_dir() -> std::path::PathBuf {
    if let Ok(d) = std::env::var("MALYUTKA_STATE_DIR") {
        return d.into();
    }
    if let Ok(d) = std::env::var("XDG_STATE_HOME") {
        return std::path::Path::new(&d).join("malyutka");
    }
    std::path::Path::new(&std::env::var("HOME").unwrap_or_default()).join(".local/state/malyutka")
}

fn start_run(app: &mut App, task: String, tx: &Sender<Msg>) {
    let mut args = vec!["run".to_string(), "--json".to_string()];
    for (k, v) in [
        ("provider", &app.cfg.provider),
        ("model", &app.cfg.model),
        ("base-url", &app.cfg.base_url),
    ] {
        if !v.is_empty() {
            args.push(format!("--{k}:{v}"));
        }
    }
    if app.cfg.allow_shell {
        args.push("--allow-shell".into());
    }
    // A leading '-' would be parsed as an option by the harness.
    args.push(if task.starts_with('-') {
        format!("Task: {task}")
    } else {
        task
    });
    app.reset_run_state();
    match runner::spawn(&app.cfg.bin, &args, tx.clone()) {
        Ok(h) => app.run = Some(h),
        Err(e) => app.items.push(Item::Err(format!(
            "cannot start {}: {e} (use --malyutka-bin)",
            app.cfg.bin
        ))),
    }
}

fn run_command(app: &mut App, line: &str) {
    let (cmd, arg) = line
        .split_once(' ')
        .map_or((line, ""), |(c, a)| (c, a.trim()));
    match cmd {
        "/help" => {
            let t: Vec<String> = commands::COMMANDS
                .iter()
                .map(|(c, d)| format!("{c:<11} {d}"))
                .collect();
            app.note(t.join("\n"));
            app.note("keys: Enter send · Alt+Enter/Ctrl+J newline · Tab complete · PgUp/PgDn scroll · Ctrl+C clear/stop/quit");
        }
        "/new" | "/clear" => {
            app.items.clear();
            app.scroll = 0;
        }
        "/model" | "/models" if arg.is_empty() => open_picker(app),
        "/model" => {
            app.cfg.model = arg.to_string();
            app.note(format!(
                "model = {}",
                if arg.is_empty() { "(default)" } else { arg }
            ));
        }
        "/provider" => {
            app.cfg.provider = arg.to_string();
            app.note(format!(
                "provider = {}",
                if arg.is_empty() { "(default)" } else { arg }
            ));
        }
        "/baseurl" => {
            app.cfg.base_url = arg.to_string();
            app.note(format!("base-url = {arg}"));
        }
        "/shell" => {
            app.cfg.allow_shell = !app.cfg.allow_shell;
            app.note(format!(
                "shell {}",
                if app.cfg.allow_shell {
                    "allowed (sandboxed)"
                } else {
                    "off"
                }
            ));
        }
        "/skin" => match Skin::by_name(arg) {
            Some(s) => app.skin = s,
            None => app.note(format!("skins: {}", skin::NAMES.join(", "))),
        },
        "/verbose" => {
            app.cfg.verbose = !app.cfg.verbose;
            app.note(format!("verbose {}", app.cfg.verbose));
        }
        "/statusbar" | "/sb" => app.cfg.statusbar = !app.cfg.statusbar,
        "/history" => {
            let mut v: Vec<_> = std::fs::read_dir(state_dir().join("sessions"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.file_name())))
                .collect();
            v.sort();
            let names: Vec<String> = v
                .iter()
                .rev()
                .take(10)
                .map(|(_, n)| n.to_string_lossy().trim_end_matches(".json").to_string())
                .collect();
            app.note(if names.is_empty() {
                "no sessions".into()
            } else {
                names.join("\n")
            });
        }
        "/journal" => {
            let o = runner::capture(&app.cfg.bin, &["journal"]);
            app.note(o.trim_end().to_string());
        }
        "/doctor" => {
            let o = runner::capture(&app.cfg.bin, &["doctor"]);
            app.note(o.trim_end().to_string());
        }
        "/stop" => stop(app),
        "/quit" | "/exit" => app.quit = true,
        _ => app.note(format!("unknown command {cmd} — try /help")),
    }
}

fn ollama_base(app: &App) -> String {
    if app.cfg.provider == "ollama" && !app.cfg.base_url.is_empty() {
        app.cfg.base_url.clone()
    } else {
        ollama::default_base()
    }
}

fn open_picker(app: &mut App) {
    let base = ollama_base(app);
    match ollama::list_models(&base) {
        Ok(models) if models.is_empty() => app
            .items
            .push(Item::Warn("Ollama has no chat models".into())),
        Ok(models) => {
            let sel = models
                .iter()
                .position(|m| m.name == app.cfg.model)
                .unwrap_or(0);
            app.picker = Some(Picker {
                models,
                filter: String::new(),
                sel,
            });
        }
        Err(e) => app.items.push(Item::Err(e)),
    }
}

fn pick_key(app: &mut App, k: KeyEvent) {
    let Some(p) = app.picker.as_mut() else { return };
    let n = p.visible().len();
    match k.code {
        KeyCode::Esc => app.picker = None,
        KeyCode::Up => p.sel = p.sel.saturating_sub(1),
        KeyCode::Down => p.sel = (p.sel + 1).min(n.saturating_sub(1)),
        KeyCode::PageUp => p.sel = p.sel.saturating_sub(10),
        KeyCode::PageDown => p.sel = (p.sel + 10).min(n.saturating_sub(1)),
        KeyCode::Backspace => {
            p.filter.pop();
            p.sel = 0;
        }
        KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => app.picker = None,
        KeyCode::Char(c) => {
            p.filter.push(c);
            p.sel = 0;
        }
        KeyCode::Enter => {
            let name = p.visible().get(p.sel).map(|m| m.name.clone());
            app.picker = None;
            if let Some(name) = name {
                let base = ollama_base(app);
                app.cfg.provider = "ollama".into();
                app.cfg.base_url = base.clone();
                app.cfg.model = name.clone();
                app.note(format!("model = {name} (ollama @ {base})"));
            }
        }
        _ => {}
    }
}

fn stop(app: &mut App) {
    if let Some(h) = &app.run {
        app.stopped = true;
        h.kill();
    } else {
        app.note("nothing running");
    }
}

fn submit(app: &mut App, tx: &Sender<Msg>) {
    let text = app.input.trim().to_string();
    if text.is_empty() {
        return;
    }
    app.history.push(text.clone());
    app.clear_input();
    app.scroll = 0;
    if text.starts_with('/') {
        run_command(app, &text);
    } else if app.busy() {
        app.note("a task is running — wait for it or /stop");
        app.set_input(text);
    } else {
        app.items.push(Item::User(text.clone()));
        start_run(app, text, tx);
    }
}

fn on_key(app: &mut App, k: KeyEvent, tx: &Sender<Msg>) {
    if k.kind != KeyEventKind::Press {
        return;
    }
    if app.picker.is_some() {
        return pick_key(app, k);
    }
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
    let alt = k
        .modifiers
        .intersects(KeyModifiers::ALT | KeyModifiers::SHIFT);
    if !matches!(k.code, KeyCode::Char('c')) || !ctrl {
        app.ctrl_c_at = None;
    }
    let sug = app.suggestions();
    match k.code {
        KeyCode::Char('c') if ctrl => {
            if !app.input.is_empty() {
                app.clear_input();
            } else if app.busy() {
                stop(app);
            } else if app
                .ctrl_c_at
                .is_some_and(|t| t.elapsed() < Duration::from_secs(2))
            {
                app.quit = true;
            } else {
                app.ctrl_c_at = Some(Instant::now());
                app.note("press Ctrl+C again to exit");
            }
        }
        KeyCode::Char('d') if ctrl => {
            if app.input.is_empty() {
                app.quit = true;
            } else {
                app.delete();
            }
        }
        KeyCode::Char('j') if ctrl => app.insert('\n'),
        KeyCode::Char('u') if ctrl => app.clear_input(),
        KeyCode::Char('w') if ctrl => app.delete_word(),
        KeyCode::Char('a') if ctrl => app.cursor = 0,
        KeyCode::Char('e') if ctrl => app.cursor = app.input.chars().count(),
        KeyCode::Char(c) if !ctrl => app.insert(c),
        KeyCode::Enter if alt => app.insert('\n'),
        KeyCode::Enter => {
            if app.input.ends_with('\\') {
                app.backspace();
                app.insert('\n');
            } else if !sug.is_empty() && !sug.iter().any(|(c, _)| *c == app.input) {
                complete(app, &sug);
            } else {
                submit(app, tx);
            }
        }
        KeyCode::Tab if !sug.is_empty() => complete(app, &sug),
        KeyCode::Backspace => app.backspace(),
        KeyCode::Delete => app.delete(),
        KeyCode::Left => app.cursor = app.cursor.saturating_sub(1),
        KeyCode::Right => app.cursor = (app.cursor + 1).min(app.input.chars().count()),
        KeyCode::Home => app.cursor = 0,
        KeyCode::End => app.cursor = app.input.chars().count(),
        KeyCode::Up => {
            if !sug.is_empty() {
                app.sel = app.sel.saturating_sub(1);
            } else if !app.input.contains('\n') {
                app.history_prev();
            }
        }
        KeyCode::Down => {
            if !sug.is_empty() {
                app.sel = (app.sel + 1).min(sug.len() - 1);
            } else if !app.input.contains('\n') {
                app.history_next();
            }
        }
        KeyCode::PageUp => app.scroll += 10,
        KeyCode::PageDown => app.scroll = app.scroll.saturating_sub(10),
        _ => {}
    }
}

fn complete(app: &mut App, sug: &[(&'static str, &'static str)]) {
    let c = sug[app.sel.min(sug.len() - 1)].0;
    app.set_input(format!("{c} "));
    app.sel = 0;
}

fn run_loop(
    term: &mut ratatui::DefaultTerminal,
    app: &mut App,
    rx: Receiver<Msg>,
    tx: Sender<Msg>,
) -> std::io::Result<()> {
    while !app.quit {
        app.tick = app.tick.wrapping_add(1);
        term.draw(|f| ui::draw(f, app))?;
        if event::poll(Duration::from_millis(120))? {
            match event::read()? {
                Event::Key(k) => on_key(app, k, &tx),
                Event::Paste(s) => s
                    .chars()
                    .for_each(|c| app.insert(if c == '\r' { '\n' } else { c })),
                _ => {}
            }
        }
        while let Ok(m) = rx.try_recv() {
            let was_bottom = app.scroll == 0;
            app.on_msg(m);
            if was_bottom {
                app.scroll = 0;
            }
        }
    }
    if let Some(h) = &app.run {
        h.kill();
    }
    Ok(())
}

fn main() {
    let (cfg, skin_name) = match parse_args() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let skin = Skin::by_name(&skin_name).unwrap_or_else(|| {
        eprintln!(
            "unknown skin {skin_name}; available: {}",
            skin::NAMES.join(", ")
        );
        std::process::exit(2);
    });
    let doctor = doctor_info(&cfg.bin);
    let mut app = App::new(cfg, skin, doctor);
    let (tx, rx) = mpsc::channel();
    let mut term = ratatui::init();
    let _ = crossterm::execute!(std::io::stdout(), crossterm::event::EnableBracketedPaste);
    let res = run_loop(&mut term, &mut app, rx, tx);
    let _ = crossterm::execute!(std::io::stdout(), crossterm::event::DisableBracketedPaste);
    ratatui::restore();
    if let Err(e) = res {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
    println!("Goodbye! ☤");
    if !app.run_id.is_empty() {
        println!("Last run: {}", app.run_id);
    }
}
