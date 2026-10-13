//! Skins mirror the Hermes skin-engine palette slots.
use ratatui::style::Color;

#[derive(Clone, Debug)]
pub struct Skin {
    pub name: &'static str,
    pub desc: &'static str,
    pub bg: Color,
    pub border: Color,
    pub title: Color,
    pub accent: Color,
    pub dim: Color,
    pub text: Color,
    pub ok: Color,
    pub error: Color,
    pub warn: Color,
    pub prompt: Color,
    pub menu_sel: Color,
    pub bar_bg: Color,
    pub menu_bg: Color,
    pub tool_prefix: &'static str,
    pub prompt_symbol: &'static str,
    pub label: &'static str,
    pub wings: (&'static str, &'static str),
    pub faces: &'static [&'static str],
    pub verbs: &'static [&'static str],
}

const FACES: &[&str] = &[
    "(｡◕‿◕｡)",
    "(◕‿◕✿)",
    "(✿◠‿◠)",
    "(◕ᴗ◕✿)",
    "(≧◡≦)",
    "(⊙_⊙)",
    "(◔_◔)",
];
const VERBS: &[&str] = &[
    "pondering",
    "contemplating",
    "cogitating",
    "deliberating",
    "reasoning",
    "computing",
    "formulating",
    "guiding",
];
const RADIO_FACES: &[&str] = &["[◉]", "[◎]", "[●]", "[○]"];
const RADIO_VERBS: &[&str] = &[
    "transmitting",
    "tracking",
    "plotting",
    "guiding",
    "computing",
];
const WAR_FACES: &[&str] = &["(⚔)", "(⛨)", "(▲)", "(⌁)", "(<>)"];
const WAR_VERBS: &[&str] = &["forging", "marching", "plotting", "striking", "advancing"];
const SEA_FACES: &[&str] = &["(≋)", "(~)", "(≈)", "(◠‿◠)", "(○)"];
const SEA_VERBS: &[&str] = &["drifting", "surging", "charting", "sounding", "tiding"];
const ROCK_FACES: &[&str] = &["(◉_◉)", "(▁_▁)", "(◔_◔)", "(•_•)"];
const ROCK_VERBS: &[&str] = &["pushing", "climbing", "persisting", "rolling", "enduring"];
const FIRE_FACES: &[&str] = &["(♨)", "(✹)", "(🔥)", "(▲)", "(◉)"];
const FIRE_VERBS: &[&str] = &["igniting", "soaring", "blazing", "scorching", "flaring"];
const GLITCH_FACES: &[&str] = &["[0]", "[1]", "[▓]", "[░]", "[▒]"];
const GLITCH_VERBS: &[&str] = &["decoding", "jacking in", "tracing", "compiling", "parsing"];

pub const NAMES: &[&str] = &[
    "default",
    "warsaw",
    "nato",
    "mono",
    "ares",
    "poseidon",
    "slate",
    "sisyphus",
    "charizard",
    "dracula",
    "nord",
    "gruvbox",
    "solarized",
    "matrix",
    "daylight",
];

const fn c(h: u32) -> Color {
    Color::Rgb((h >> 16) as u8, (h >> 8) as u8, h as u8)
}

/// Palette order: bg, border, title, accent, dim, text, ok, error, warn, menu_sel, bar_bg, menu_bg
fn pal(name: &'static str, desc: &'static str, p: [u32; 12]) -> Skin {
    Skin {
        name,
        desc,
        bg: c(p[0]),
        border: c(p[1]),
        title: c(p[2]),
        accent: c(p[3]),
        dim: c(p[4]),
        text: c(p[5]),
        ok: c(p[6]),
        error: c(p[7]),
        warn: c(p[8]),
        prompt: c(p[5]),
        menu_sel: c(p[9]),
        bar_bg: c(p[10]),
        menu_bg: c(p[11]),
        tool_prefix: "┊",
        prompt_symbol: "❯",
        label: " ☤ Malyutka ",
        wings: ("⟪", "⟫"),
        faces: FACES,
        verbs: VERBS,
    }
}

impl Skin {
    pub fn by_name(name: &str) -> Option<Skin> {
        let (ok, er, wa) = (0x4caf50, 0xef5350, 0xffa726);
        Some(match name {
            "default" => pal(
                "default",
                "Classic Hermes gold on midnight",
                [
                    0x1a1a2e, 0xCD7F32, 0xFFD700, 0xFFBF00, 0x8A7A4A, 0xFFF8DC, ok, er, wa,
                    0x333355, 0x10101e, 0x1a1a2e,
                ],
            ),
            "warsaw" => Skin {
                label: " ◈ 9M14 ",
                faces: RADIO_FACES,
                verbs: RADIO_VERBS,
                ..pal(
                    "warsaw",
                    "Phosphor-green radio console",
                    [
                        0x08120a, 0x2e9e4a, 0x7fff8a, 0x4ce066, 0x3a6e45, 0xb8f5c0, 0x4ce066,
                        0xff6b6b, 0xe6d84a, 0x1c3a24, 0x050d07, 0x0c1a0f,
                    ],
                )
            },
            "nato" => Skin {
                label: " ◈ 9M14 ",
                faces: RADIO_FACES,
                verbs: RADIO_VERBS,
                ..pal(
                    "nato",
                    "Amber cockpit display",
                    [
                        0x161006, 0xb8860b, 0xffc107, 0xffa000, 0x8a6a2a, 0xffe0a0, 0xa5d65a,
                        0xff6b4a, 0xffc107, 0x3a2a10, 0x0e0a03, 0x1e1608,
                    ],
                )
            },
            "mono" => pal(
                "mono",
                "Greyscale, no colour",
                [
                    0x1f1f1f, 0x5e5e5e, 0xe6edf3, 0xaaaaaa, 0x777777, 0xd0d0d0, 0xb0b0b0, 0xe0e0e0,
                    0xc0c0c0, 0x464646, 0x161616, 0x262626,
                ],
            ),
            "ares" => Skin {
                tool_prefix: "╎",
                prompt_symbol: "⚔",
                label: " ⚔ Malyutka ",
                wings: ("⟪⚔", "⚔⟫"),
                faces: WAR_FACES,
                verbs: WAR_VERBS,
                ..pal(
                    "ares",
                    "Crimson and bronze war room",
                    [
                        0x1c0c0c, 0xA93333, 0xC7A96B, 0xDD4A3A, 0x8a5a4a, 0xf0dcc8, 0x7fb069,
                        0xff5a4a, 0xe8a23a, 0x5C221D, 0x2A1212, 0x241010,
                    ],
                )
            },
            "poseidon" => Skin {
                tool_prefix: "│",
                prompt_symbol: "♆",
                label: " ♆ Malyutka ",
                wings: ("≋", "≋"),
                faces: SEA_FACES,
                verbs: SEA_VERBS,
                ..pal(
                    "poseidon",
                    "Deep-sea blues",
                    [
                        0x0a1a30, 0x2A6FB9, 0xA9DFFF, 0x5DB8F5, 0x4a7aa0, 0xdcefff, 0x4fd1a5,
                        0xff7a7a, 0xf5c04a, 0x254D73, 0x0F2440, 0x0c2038,
                    ],
                )
            },
            "slate" => pal(
                "slate",
                "Cool slate and royal blue",
                [
                    0x10151f, 0x4169e1, 0x7eb8f6, 0x8EA8FF, 0x5a6a8a, 0xd6deee, 0x5fd3a0, 0xff7b8a,
                    0xf0b45a, 0x324867, 0x151C2F, 0x131a2a,
                ],
            ),
            "sisyphus" => Skin {
                tool_prefix: "│",
                prompt_symbol: "◉",
                label: " ◉ Malyutka ",
                faces: ROCK_FACES,
                verbs: ROCK_VERBS,
                ..pal(
                    "sisyphus",
                    "Stoic silver on charcoal",
                    [
                        0x181818, 0xB7B7B7, 0xF5F5F5, 0xE7E7E7, 0x808080, 0xe0e0e0, 0xa8d8a8,
                        0xe89a9a, 0xe8d08a, 0x585858, 0x202020, 0x202020,
                    ],
                )
            },
            "charizard" => Skin {
                tool_prefix: "│",
                prompt_symbol: "✹",
                label: " ✹ Malyutka ",
                faces: FIRE_FACES,
                verbs: FIRE_VERBS,
                ..pal(
                    "charizard",
                    "Ember orange on soot",
                    [
                        0x0B0503, 0xC75B1D, 0xFFD39A, 0xF29C38, 0x9a6a4a, 0xffe6cc, 0x9ccc65,
                        0xff5a3a, 0xffb74d, 0x4A1B07, 0x2B160E, 0x1a0c06,
                    ],
                )
            },
            "dracula" => pal(
                "dracula",
                "Dracula: purple, pink and cyan",
                [
                    0x282a36, 0xbd93f9, 0xff79c6, 0x8be9fd, 0x6272a4, 0xf8f8f2, 0x50fa7b, 0xff5555,
                    0xf1fa8c, 0x44475a, 0x21222c, 0x2f3142,
                ],
            ),
            "nord" => pal(
                "nord",
                "Nord: arctic blue-grey",
                [
                    0x2e3440, 0x5e81ac, 0x88c0d0, 0x81a1c1, 0x616e88, 0xeceff4, 0xa3be8c, 0xbf616a,
                    0xebcb8b, 0x434c5e, 0x242933, 0x3b4252,
                ],
            ),
            "gruvbox" => pal(
                "gruvbox",
                "Gruvbox dark: warm retro",
                [
                    0x282828, 0xd79921, 0xfabd2f, 0xfe8019, 0x928374, 0xebdbb2, 0xb8bb26, 0xfb4934,
                    0xfabd2f, 0x504945, 0x1d2021, 0x32302f,
                ],
            ),
            "solarized" => pal(
                "solarized",
                "Solarized dark",
                [
                    0x002b36, 0x268bd2, 0xb58900, 0x2aa198, 0x586e75, 0x93a1a1, 0x859900, 0xdc322f,
                    0xcb4b16, 0x073642, 0x00212b, 0x073642,
                ],
            ),
            "matrix" => Skin {
                label: " ▓ 9M14 ",
                prompt_symbol: "$",
                faces: GLITCH_FACES,
                verbs: GLITCH_VERBS,
                wings: ("░▒", "▒░"),
                ..pal(
                    "matrix",
                    "Green rain on black",
                    [
                        0x000000, 0x008f11, 0x00ff41, 0x39ff14, 0x03a021, 0x7dff9a, 0x00ff41,
                        0xff3030, 0xd7ff3a, 0x003b00, 0x000a00, 0x001400,
                    ],
                )
            },
            "daylight" => pal(
                "daylight",
                "Light theme for bright terminals",
                [
                    0xF8FAFC, 0x2563EB, 0x0F172A, 0x1D4ED8, 0x64748B, 0x111827, 0x15803D, 0xB91C1C,
                    0xB45309, 0xDBEAFE, 0xE5EDF8, 0xEEF3FA,
                ],
            ),
            _ => return None,
        })
    }

    pub fn all() -> Vec<Skin> {
        NAMES.iter().filter_map(|n| Skin::by_name(n)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_names_resolve() {
        for n in NAMES {
            assert_eq!(Skin::by_name(n).unwrap().name, *n);
        }
        assert!(Skin::by_name("nope").is_none());
        assert_eq!(Skin::all().len(), NAMES.len());
    }
    #[test]
    fn names_unique_and_readable() {
        let all = Skin::all();
        for (i, a) in all.iter().enumerate() {
            assert!(all[i + 1..].iter().all(|b| b.name != a.name));
            assert_ne!(a.text, a.bg, "{} text must differ from bg", a.name);
            assert_ne!(a.dim, a.bg, "{} dim must differ from bg", a.name);
            assert!(!a.faces.is_empty() && !a.verbs.is_empty());
        }
    }
}
