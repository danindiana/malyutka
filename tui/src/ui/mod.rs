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
    let state = if app.busy() {
        format!("step {}", app.step)
    } else {
        "idle".to_string()
    };
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
            Paragraph::new(txt).style(Style::default().fg(s.dim).bg(Color::Rgb(0x10, 0x10, 0x20))),
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
    fn narrow_terminal_does_not_panic() {
        let mut a = app();
        a.set_input("/s".into());
        render(&a, 30, 10);
        render(&a, 10, 4);
        render(&a, 24, 8);
    }
}
