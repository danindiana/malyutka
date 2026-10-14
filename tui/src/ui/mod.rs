pub mod transcript;

use crate::app::App;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, Paragraph};
use ratatui::Frame;

const BRAILLE: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

pub fn input_height(app: &App) -> u16 {
    (app.input.split('\n').count().min(6) as u16) + 1
}

pub fn spinner_line(app: &App) -> Line<'static> {
    let s = &app.skin;
    let frame = BRAILLE[app.tick % BRAILLE.len()];
    let face = s.faces[(app.tick / 8) % s.faces.len()];
    let verb = s.verbs[(app.tick / 24) % s.verbs.len()];
    let secs = app.started.elapsed().as_secs();
    Line::from(Span::styled(
        format!(
            "  {} {} {} {}... {} ({}s)",
            s.wings.0, frame, face, verb, s.wings.1, secs
        ),
        Style::default().fg(s.accent),
    ))
}

/// Status bar text by width tier: full >= 76, compact 52..75, minimal < 52.
pub fn status_text(app: &App, width: usize) -> String {
    let model = if app.cfg.model.is_empty() {
        "default"
    } else {
        &app.cfg.model
    };
    let model = transcript::trunc(model, 26);
    let nproc = app.procs.iter().filter(|p| p.running).count();
    let turns = if app.turns.is_empty() {
        String::new()
    } else {
        format!(" ↺{}", app.turns.len())
    };
    let state = if app.busy() {
        format!("step {}", app.step)
    } else {
        "idle".to_string()
    } + &turns
        + &(if nproc > 0 {
            format!(" ⚙{nproc}")
        } else {
            String::new()
        });
    let el = if app.busy() {
        format!("{}s", app.started.elapsed().as_secs())
    } else {
        String::new()
    };
    if width >= 76 {
        let prov = if app.cfg.provider.is_empty() {
            "default"
        } else {
            &app.cfg.provider
        };
        let shell = if app.cfg.allow_shell {
            "shell:on"
        } else {
            "shell:off"
        };
        let mut s = format!(
            " ☤ {model} │ {prov} │ {state} │ ✓{} ✗{} ?{} │ {shell}",
            app.allow, app.deny, app.ask
        );
        if !el.is_empty() {
            s.push_str(&format!(" │ {el}"));
        }
        if !app.run_id.is_empty() {
            s.push_str(&format!(" │ {}", app.run_id));
        }
        s
    } else if width >= 52 {
        format!(
            " ☤ {model} │ {state} │ ✓{} ✗{} ?{}",
            app.allow, app.deny, app.ask
        )
    } else {
        format!(" ☤ {model} │ {state}")
    }
}

fn draw_picker(f: &mut Frame, app: &App, p: &crate::app::Picker, area: Rect) {
    let s = &app.skin;
    let vis = p.visible();
    let w = area.width.min(76);
    let h = (vis.len().min(14) as u16 + 4).min(area.height);
    let r = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, r);
    let block = Block::bordered()
        .border_type(ratatui::widgets::BorderType::Rounded)
        .border_style(Style::default().fg(s.border))
        .title(Span::styled(
            " Select model · ollama ",
            Style::default().fg(s.title).add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(s.bg));
    let inner = block.inner(r);
    f.render_widget(block, r);
    let rows = inner.height.saturating_sub(2) as usize;
    let sel = p.sel.min(vis.len().saturating_sub(1));
    let top = sel.saturating_sub(rows.saturating_sub(1));
    let mut lines = vec![Line::from(vec![
        Span::styled("filter ❯ ", Style::default().fg(s.accent)),
        Span::styled(p.filter.clone(), Style::default().fg(s.prompt)),
    ])];
    for (i, m) in vis.iter().enumerate().skip(top).take(rows) {
        let bg = if i == sel { s.menu_sel } else { s.bg };
        let cur = if m.name == app.cfg.model { "●" } else { " " };
        let name_w = (inner.width as usize).saturating_sub(18);
        lines.push(Line::from(vec![
            Span::styled(format!(" {cur} "), Style::default().fg(s.ok).bg(bg)),
            Span::styled(
                format!("{:<w$}", transcript::trunc(&m.name, name_w), w = name_w),
                Style::default().fg(s.text).bg(bg),
            ),
            Span::styled(
                format!("{:>6} {:>5.1}G", m.params, m.size_gb),
                Style::default().fg(s.dim).bg(bg),
            ),
        ]));
    }
    if vis.is_empty() {
        lines.push(Line::styled("  no matches", Style::default().fg(s.dim)));
    }
    lines.push(Line::styled(
        " ↑↓ move · type to filter · Enter select · Esc cancel",
        Style::default().fg(s.dim),
    ));
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_approval(f: &mut Frame, app: &App, a: &crate::app::Approval, area: Rect) {
    let s = &app.skin;
    let w = area.width.min(78);
    let secs = a
        .deadline
        .saturating_duration_since(std::time::Instant::now())
        .as_secs();
    let args = transcript::wrap(
        &transcript::trunc(&a.args, 300),
        w.saturating_sub(6) as usize,
    );
    let h = (args.len() as u16 + 9).min(area.height);
    let r = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, r);
    let block = Block::bordered()
        .border_type(ratatui::widgets::BorderType::Double)
        .border_style(Style::default().fg(s.warn))
        .title(Span::styled(
            " ⚠ Approval required ",
            Style::default().fg(s.warn).add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(s.menu_bg));
    let inner = block.inner(r);
    f.render_widget(block, r);
    let mut lines = vec![
        Line::from(vec![
            Span::styled(" tool   ", Style::default().fg(s.dim)),
            Span::styled(
                a.tool.clone(),
                Style::default().fg(s.title).add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(vec![
            Span::styled(" why    ", Style::default().fg(s.dim)),
            Span::styled(
                format!("{} (asked by {})", a.reason, a.policy),
                Style::default().fg(s.text),
            ),
        ]),
        Line::styled(" args", Style::default().fg(s.dim)),
    ];
    for l in args {
        lines.push(Line::styled(format!("   {l}"), Style::default().fg(s.text)));
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(vec![
        Span::styled(
            " [o]",
            Style::default().fg(s.ok).add_modifier(Modifier::BOLD),
        ),
        Span::styled(" once  ", Style::default().fg(s.text)),
        Span::styled(
            "[s]",
            Style::default().fg(s.accent).add_modifier(Modifier::BOLD),
        ),
        Span::styled(" session  ", Style::default().fg(s.text)),
        Span::styled(
            "[a]",
            Style::default().fg(s.accent).add_modifier(Modifier::BOLD),
        ),
        Span::styled(" always  ", Style::default().fg(s.text)),
        Span::styled(
            "[d]",
            Style::default().fg(s.error).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" deny   auto-deny in {secs}s"),
            Style::default().fg(s.dim),
        ),
    ]));
    lines.push(Line::styled(
        " or pre-approve a class of actions: malyutka mandate --grant … (/mandates)",
        Style::default().fg(s.dim),
    ));
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_skin_pick(f: &mut Frame, app: &App, p: &crate::app::SkinPick, area: Rect) {
    let s = &app.skin;
    let w = area.width.min(64);
    let h = (p.skins.len() as u16 + 3).min(area.height);
    let r = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, r);
    let block = Block::bordered()
        .border_type(ratatui::widgets::BorderType::Rounded)
        .border_style(Style::default().fg(s.border))
        .title(Span::styled(
            " Select skin (live preview) ",
            Style::default().fg(s.title).add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(s.menu_bg));
    let inner = block.inner(r);
    f.render_widget(block, r);
    let rows = inner.height.saturating_sub(1) as usize;
    let top = p.sel.saturating_sub(rows.saturating_sub(1));
    let mut lines = vec![];
    for (i, k) in p.skins.iter().enumerate().skip(top).take(rows) {
        let bg = if i == p.sel { s.menu_sel } else { s.menu_bg };
        let cur = if k.name == p.orig.name { "●" } else { " " };
        let sw = |col| Span::styled("██", Style::default().fg(col).bg(bg));
        lines.push(Line::from(vec![
            Span::styled(format!(" {cur} "), Style::default().fg(s.ok).bg(bg)),
            Span::styled(
                format!("{:<10}", k.name),
                Style::default().fg(s.title).bg(bg),
            ),
            sw(k.bg),
            sw(k.border),
            sw(k.title),
            sw(k.accent),
            sw(k.ok),
            sw(k.error),
            Span::styled(format!(" {}", k.desc), Style::default().fg(s.dim).bg(bg)),
        ]));
    }
    lines.push(Line::styled(
        " ↑↓ preview · Enter apply · Esc cancel",
        Style::default().fg(s.dim),
    ));
    f.render_widget(Paragraph::new(lines), inner);
}

pub fn draw(f: &mut Frame, app: &App) {
    let s = &app.skin;
    let area = f.area();
    if area.height < 8 || area.width < 20 {
        f.render_widget(Paragraph::new("terminal too small"), area);
        return;
    }
    f.render_widget(
        Block::default().style(Style::default().bg(s.bg).fg(s.text)),
        area,
    );
    let ih = input_height(app);
    let sb = u16::from(app.cfg.statusbar);
    let chunks = Layout::vertical([
        Constraint::Min(3),
        Constraint::Length(1), // spinner
        Constraint::Length(sb),
        Constraint::Length(ih),
    ])
    .split(area);

    // transcript, anchored to bottom with scrollback
    let lines = transcript::build(app, chunks[0].width as usize);
    let h = chunks[0].height as usize;
    let n = lines.len();
    let max_scroll = n.saturating_sub(h);
    let scroll = app.scroll.min(max_scroll);
    let start = n.saturating_sub(h + scroll);
    let end = (start + h).min(n);
    f.render_widget(Paragraph::new(lines[start..end].to_vec()), chunks[0]);
    if scroll > 0 {
        let tag = format!(" ↑ {scroll} lines up · PgDn ");
        let w = tag.chars().count() as u16;
        let r = Rect::new(
            chunks[0].right().saturating_sub(w),
            chunks[0].y,
            w.min(chunks[0].width),
            1,
        );
        f.render_widget(
            Paragraph::new(tag).style(Style::default().fg(s.bg).bg(s.accent)),
            r,
        );
    }

    if app.busy() {
        f.render_widget(Paragraph::new(spinner_line(app)), chunks[1]);
    }
    if sb == 1 {
        let txt = status_text(app, area.width as usize);
        f.render_widget(
            Paragraph::new(txt).style(Style::default().fg(s.dim).bg(s.bar_bg)),
            chunks[2],
        );
    }

    // input
    let ia = chunks[3];
    let rule = "─".repeat(ia.width as usize);
    f.render_widget(
        Paragraph::new(rule).style(Style::default().fg(s.border)),
        Rect::new(ia.x, ia.y, ia.width, 1),
    );
    let all: Vec<&str> = app.input.split('\n').collect();
    let skip = all.len().saturating_sub(5);
    let mut in_lines = vec![];
    for (i, l) in all.iter().enumerate().skip(skip) {
        let sym = if i == 0 {
            format!("{} ", s.prompt_symbol)
        } else {
            "  ".to_string()
        };
        in_lines.push(Line::from(vec![
            Span::styled(
                sym,
                Style::default().fg(s.accent).add_modifier(Modifier::BOLD),
            ),
            Span::styled(l.to_string(), Style::default().fg(s.prompt)),
        ]));
    }
    f.render_widget(
        Paragraph::new(in_lines),
        Rect::new(ia.x, ia.y + 1, ia.width, ia.height.saturating_sub(1)),
    );
    // cursor
    let before: String = app.input.chars().take(app.cursor).collect();
    let row = before.matches('\n').count();
    let col = before.rsplit('\n').next().unwrap_or("").chars().count();
    let row = row.saturating_sub(skip) as u16;
    f.set_cursor_position(Position::new(
        (ia.x + 2 + col as u16).min(ia.right().saturating_sub(1)),
        ia.y + 1 + row,
    ));

    if let Some(a) = &app.approval {
        draw_approval(f, app, a, area);
    }
    if let Some(p) = &app.skin_pick {
        draw_skin_pick(f, app, p, area);
    }
    if let Some(p) = &app.picker {
        draw_picker(f, app, p, area);
    }

    // slash popup
    let sug = app.suggestions();
    if !sug.is_empty() {
        let n = sug.len().min(8) as u16;
        let pw = area.width.min(64);
        let r = Rect::new(ia.x, ia.y.saturating_sub(n), pw, n);
        f.render_widget(Clear, r);
        let sel = app.sel.min(sug.len() - 1);
        let rows: Vec<Line> = sug
            .iter()
            .take(8)
            .enumerate()
            .map(|(i, (c, d))| {
                let bg = if i == sel {
                    s.menu_sel
                } else {
                    Color::Rgb(0x1a, 0x1a, 0x2e)
                };
                Line::from(vec![
                    Span::styled(format!(" {c:<11}"), Style::default().fg(s.title).bg(bg)),
                    Span::styled(
                        format!("{:<w$}", d, w = pw as usize - 12),
                        Style::default().fg(s.dim).bg(bg),
                    ),
                ])
            })
            .collect();
        f.render_widget(Paragraph::new(rows), r);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{App, Config, Item};
    use crate::skin::Skin;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn app() -> App {
        App::new(
            Config {
                bin: "m".into(),
                provider: "mock".into(),
                model: "qwen".into(),
                base_url: String::new(),
                allow_shell: true,
                allow_files: false,
                allow_memory: false,
                allow_process: false,
                personality: String::new(),
                context_window: None,
                compress_next: false,
                verbose: false,
                statusbar: true,
            },
            Skin::by_name("default").unwrap(),
            vec![("version".into(), "0.3.4".into())],
        )
    }

    fn render(a: &App, w: u16, h: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, a)).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h)
            .map(|y| {
                (0..w)
                    .map(|x| buf[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn renders_banner_and_tool_feed() {
        let mut a = app();
        a.items.push(Item::User("list files".into()));
        a.items.push(Item::Tool {
            name: "shell".into(),
            args: "{\"cmd\":\"ls\"}".into(),
            verdict: Some("ALLOW".into()),
            result: Some("exit=0".into()),
            ok: Some(true),
            t0: std::time::Instant::now(),
            secs: Some(0.3),
            preview: String::new(),
        });
        a.items.push(Item::Agent("done".into()));
        let s = render(&a, 100, 40);
        assert!(s.contains("MALYUTKA // 9M14"));
        assert!(s.contains("┊ 💻"));
        assert!(s.contains("shell"));
        assert!(s.contains("[ALLOW]"));
        assert!(s.contains("☤ Malyutka"));
        assert!(s.contains("❯ "));
    }

    #[test]
    fn status_tiers() {
        let a = app();
        assert!(status_text(&a, 80).contains("shell:on"));
        assert!(!status_text(&a, 60).contains("shell:on"));
        assert!(status_text(&a, 60).contains("✓0"));
        assert!(!status_text(&a, 40).contains("✓0"));
    }

    #[test]
    fn renders_model_picker() {
        let mut a = app();
        let m = |n: &str| crate::ollama::Model {
            name: n.into(),
            params: "27B".into(),
            size_gb: 17.0,
        };
        a.picker = Some(crate::app::Picker {
            models: vec![m("qwen3.5:27b"), m("gemma4:12b")],
            filter: String::new(),
            sel: 1,
        });
        let s = render(&a, 100, 30);
        assert!(s.contains("Select model"));
        assert!(s.contains("qwen3.5:27b") && s.contains("gemma4:12b"));
    }

    #[test]
    fn renders_skin_picker_for_every_skin() {
        for sk in Skin::all() {
            let mut a = app();
            a.skin = sk.clone();
            a.skin_pick = Some(crate::app::SkinPick {
                skins: Skin::all(),
                sel: 3,
                orig: sk,
            });
            let s = render(&a, 100, 30);
            assert!(s.contains("Select skin"));
            assert!(s.contains("ares") && s.contains("daylight"));
        }
    }

    #[test]
    fn narrow_terminal_does_not_panic() {
        let mut a = app();
        a.set_input("/s".into());
        render(&a, 30, 10);
        render(&a, 10, 4);
        render(&a, 24, 8);
    }

    #[test]
    fn renders_diff_preview_todo_and_approval_modal() {
        let mut a = app();
        a.items.push(Item::Tool {
            name: "patch".into(),
            args: "{}".into(),
            verdict: Some("ALLOW".into()),
            result: Some("exit=0".into()),
            ok: Some(true),
            t0: std::time::Instant::now(),
            secs: Some(0.1),
            preview: "--- f.txt\n- hello world\n+ hello malyutka".into(),
        });
        a.items.push(Item::Todo(vec![
            ("done".into(), "write it".into()),
            ("pending".into(), "test it".into()),
        ]));
        let s = render(&a, 100, 40);
        assert!(
            s.contains("--- f.txt")
                && s.contains("- hello world")
                && s.contains("+ hello malyutka")
        );
        assert!(s.contains("☑ write it") && s.contains("☐ test it"));
        a.approval = Some(crate::app::Approval {
            action: "A1".into(),
            tool: "shell".into(),
            args: "{\"command\":\"git push --force\"}".into(),
            reason: "force push".into(),
            policy: "approval.dangerous".into(),
            deadline: std::time::Instant::now() + std::time::Duration::from_secs(120),
        });
        let m = render(&a, 100, 40);
        assert!(m.contains("Approval required") && m.contains("force push"));
        assert!(m.contains("[o]") && m.contains("[d]") && m.contains("auto-deny in"));
        render(&a, 30, 10); // tiny terminal must not panic
    }

    #[test]
    fn status_bar_shows_resumed_turns() {
        let mut a = app();
        a.turns.push(crate::app::Turn {
            run_id: "R1".into(),
            prompt: "p".into(),
            item_start: 0,
        });
        assert!(status_text(&a, 80).contains("↺1"));
    }

    #[test]
    fn status_bar_counts_running_processes() {
        let mut a = app();
        assert!(!status_text(&a, 90).contains('⚙'));
        a.procs.push(crate::app::BgProc {
            id: "p1".into(),
            command: "x".into(),
            running: true,
            code: None,
        });
        a.procs.push(crate::app::BgProc {
            id: "p2".into(),
            command: "y".into(),
            running: false,
            code: Some(0),
        });
        assert!(status_text(&a, 90).contains("⚙1"));
    }
}
