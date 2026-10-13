use crate::app::{App, Item};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

pub fn trunc(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(n.saturating_sub(3)).collect();
        t.push_str("...");
        t
    }
}

pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(8);
    let mut out = vec![];
    for para in text.split('\n') {
        let mut cur = String::new();
        for word in para.split(' ') {
            let mut word = word.to_string();
            while word.chars().count() > width {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
                out.push(word.chars().take(width).collect());
                word = word.chars().skip(width).collect();
            }
            let need = cur.chars().count() + word.chars().count() + usize::from(!cur.is_empty());
            if need > width && !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            if !cur.is_empty() {
                cur.push(' ');
            }
            cur.push_str(&word);
        }
        out.push(cur);
    }
    out
}

fn glyph(c: char) -> [&'static str; 5] {
    match c {
        'M' => ["█   █", "██ ██", "█ █ █", "█   █", "█   █"],
        'A' => [" ███ ", "█   █", "█████", "█   █", "█   █"],
        'L' => ["█    ", "█    ", "█    ", "█    ", "█████"],
        'Y' => ["█   █", " █ █ ", "  █  ", "  █  ", "  █  "],
        'U' => ["█   █", "█   █", "█   █", "█   █", " ███ "],
        'T' => ["█████", "  █  ", "  █  ", "  █  ", "  █  "],
        'K' => ["█   █", "█  █ ", "███  ", "█  █ ", "█   █"],
        _ => ["     "; 5],
    }
}

fn logo() -> Vec<String> {
    let mut rows = vec![String::new(); 5];
    for c in "MALYUTKA".chars() {
        for (i, g) in glyph(c).iter().enumerate() {
            rows[i].push_str(g);
            rows[i].push(' ');
        }
    }
    rows
}

pub fn banner(app: &App, width: usize) -> Vec<Line<'static>> {
    let s = &app.skin;
    let w = width.clamp(40, 100);
    let bd = Style::default().fg(s.border);
    let mut out: Vec<Line> = vec![];
    if width >= 95 {
        let grad = [
            s.title,
            s.accent,
            Color::Rgb(0xe0, 0xa0, 0x20),
            Color::Rgb(0xd8, 0x90, 0x28),
            s.border,
        ];
        for (i, r) in logo().into_iter().enumerate() {
            out.push(Line::from(Span::styled(r, Style::default().fg(grad[i]))));
        }
    }
    let title = format!(" MALYUTKA // 9M14 v{} ", env!("CARGO_PKG_VERSION"));
    let fill = w.saturating_sub(title.chars().count() + 3);
    out.push(Line::from(vec![
        Span::styled("╭─", bd),
        Span::styled(
            title,
            Style::default().fg(s.title).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("{}╮", "─".repeat(fill)), bd),
    ]));
    let mut row = |k: &str, v: String| {
        let body = format!(" {:<9}{}", k, trunc(&v, w.saturating_sub(14)));
        let pad = w.saturating_sub(body.chars().count() + 2);
        out.push(Line::from(vec![
            Span::styled("│", bd),
            Span::styled(format!(" {:<9}", k), Style::default().fg(s.dim)),
            Span::styled(trunc(&v, w.saturating_sub(14)), Style::default().fg(s.text)),
            Span::raw(" ".repeat(pad)),
            Span::styled("│", bd),
        ]));
    };
    let or = |v: &str| {
        if v.is_empty() {
            "(config/env default)".to_string()
        } else {
            v.to_string()
        }
    };
    row("PROVIDER", or(&app.cfg.provider));
    row("MODEL", or(&app.cfg.model));
    row(
        "SHELL",
        if app.cfg.allow_shell {
            "allowed (sandboxed)".into()
        } else {
            "off".into()
        },
    );
    for (k, v) in &app.doctor {
        row(&k.to_uppercase(), v.clone());
    }
    row("SKIN", app.skin.name.to_string());
    out.push(Line::from(Span::styled(
        format!("╰{}╯", "─".repeat(w.saturating_sub(2))),
        bd,
    )));
    out.push(Line::from(Span::styled(
        "  Type a task, or /help for commands. Guidance is gated: capability · journal · policy · sandbox.",
        Style::default().fg(s.dim),
    )));
    out.push(Line::raw(""));
    out
}

fn tool_emoji(name: &str) -> &'static str {
    match name {
        "shell" => "💻",
        "echo" => "💬",
        _ => "⚡",
    }
}

pub fn build(app: &App, width: usize) -> Vec<Line<'static>> {
    let s = &app.skin;
    let mut out = banner(app, width);
    let body_w = width.saturating_sub(4);
    for it in &app.items {
        match it {
            Item::User(t) => {
                for (i, l) in wrap(t, body_w).into_iter().enumerate() {
                    let sym = if i == 0 {
                        format!("{} ", s.prompt_symbol)
                    } else {
                        "  ".into()
                    };
                    out.push(Line::from(vec![
                        Span::styled(
                            sym,
                            Style::default().fg(s.accent).add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(
                            l,
                            Style::default().fg(s.prompt).add_modifier(Modifier::BOLD),
                        ),
                    ]));
                }
                out.push(Line::raw(""));
            }
            Item::Agent(t) => {
                let label = s.label;
                let fill = width.saturating_sub(label.chars().count() + 2);
                out.push(Line::from(vec![
                    Span::styled("─", Style::default().fg(s.title)),
                    Span::styled(
                        label,
                        Style::default().fg(s.title).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled("─".repeat(fill), Style::default().fg(s.title)),
                ]));
                for l in wrap(t, body_w) {
                    out.push(Line::from(Span::styled(
                        format!("  {l}"),
                        Style::default().fg(s.text),
                    )));
                }
                out.push(Line::raw(""));
            }
            Item::Tool {
                name,
                args,
                verdict,
                result,
                ok,
                secs,
                ..
            } => {
                let (vtxt, vcol) = match verdict.as_deref() {
                    Some("ALLOW") => ("ALLOW", s.ok),
                    Some("DENY") => ("DENY", s.error),
                    Some("ASK") => ("ASK", s.warn),
                    _ => ("…", s.dim),
                };
                let tail = match (result, secs) {
                    (Some(r), Some(t)) => format!("  {r} {t:.1}s"),
                    _ => String::new(),
                };
                let head = format!("{} {} {:<8} ", s.tool_prefix, tool_emoji(name), name);
                let room = width.saturating_sub(head.chars().count() + tail.chars().count() + 9);
                let tail_col = match ok {
                    Some(true) => s.ok,
                    Some(false) => s.error,
                    None => s.dim,
                };
                out.push(Line::from(vec![
                    Span::styled(head, Style::default().fg(s.dim)),
                    Span::styled(trunc(args, room), Style::default().fg(s.text)),
                    Span::styled(format!(" [{vtxt}]"), Style::default().fg(vcol)),
                    Span::styled(tail, Style::default().fg(tail_col)),
                ]));
            }
            Item::Note(t) => {
                for l in wrap(t, body_w) {
                    out.push(Line::from(Span::styled(
                        format!("  {l}"),
                        Style::default().fg(s.dim),
                    )));
                }
            }
            Item::Warn(t) => {
                for (i, l) in wrap(t, body_w).into_iter().enumerate() {
                    let p = if i == 0 { "⚠ " } else { "  " };
                    out.push(Line::from(Span::styled(
                        format!("{p}{l}"),
                        Style::default().fg(s.warn),
                    )));
                }
            }
            Item::Err(t) => {
                for (i, l) in wrap(t, body_w).into_iter().enumerate() {
                    let p = if i == 0 { "✗ " } else { "  " };
                    out.push(Line::from(Span::styled(
                        format!("{p}{l}"),
                        Style::default().fg(s.error),
                    )));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wraps_and_truncates() {
        assert_eq!(wrap("aaa bbb ccc", 7), vec!["aaa bbb", "ccc"]);
        assert_eq!(wrap("a\n\nb", 10), vec!["a", "", "b"]);
        assert_eq!(wrap("abcdefghijkl", 8).len(), 2);
        assert_eq!(trunc("abcdefghij", 6), "abc...");
        assert_eq!(trunc("abc", 6), "abc");
    }
    #[test]
    fn logo_is_five_rows() {
        assert_eq!(logo().len(), 5);
    }
}
