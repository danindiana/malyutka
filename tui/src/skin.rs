//! Skins mirror the Hermes skin-engine palette slots.
use ratatui::style::Color;

#[derive(Clone, Debug)]
pub struct Skin {
    pub name: &'static str,
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

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::Rgb(r, g, b)
}

pub const NAMES: &[&str] = &["default", "warsaw", "nato", "mono"];

impl Skin {
    pub fn by_name(name: &str) -> Option<Skin> {
        let base = Skin {
            name: "default",
            bg: rgb(0x1a, 0x1a, 0x2e),
            border: rgb(0xCD, 0x7F, 0x32),
            title: rgb(0xFF, 0xD7, 0x00),
            accent: rgb(0xFF, 0xBF, 0x00),
            dim: rgb(0x8A, 0x7A, 0x4A),
            text: rgb(0xFF, 0xF8, 0xDC),
            ok: rgb(0x4c, 0xaf, 0x50),
            error: rgb(0xef, 0x53, 0x50),
            warn: rgb(0xff, 0xa7, 0x26),
            prompt: rgb(0xFF, 0xF8, 0xDC),
            menu_sel: rgb(0x33, 0x33, 0x55),
            tool_prefix: "┊",
            prompt_symbol: "❯",
            label: " ☤ Malyutka ",
            wings: ("⟪", "⟫"),
            faces: FACES,
            verbs: VERBS,
        };
        Some(match name {
            "default" => base,
            "warsaw" => Skin {
                name: "warsaw",
                bg: rgb(0x08, 0x12, 0x0a),
                border: rgb(0x2e, 0x9e, 0x4a),
                title: rgb(0x7f, 0xff, 0x8a),
                accent: rgb(0x4c, 0xe0, 0x66),
                dim: rgb(0x3a, 0x6e, 0x45),
                text: rgb(0xb8, 0xf5, 0xc0),
                prompt: rgb(0xb8, 0xf5, 0xc0),
                menu_sel: rgb(0x1c, 0x3a, 0x24),
                label: " ◈ 9M14 ",
                faces: RADIO_FACES,
                verbs: RADIO_VERBS,
                ..base
            },
            "nato" => Skin {
                name: "nato",
                bg: rgb(0x16, 0x10, 0x06),
                border: rgb(0xb8, 0x86, 0x0b),
                title: rgb(0xff, 0xc1, 0x07),
                accent: rgb(0xff, 0xa0, 0x00),
                dim: rgb(0x8a, 0x6a, 0x2a),
                text: rgb(0xff, 0xe0, 0xa0),
                prompt: rgb(0xff, 0xe0, 0xa0),
                menu_sel: rgb(0x3a, 0x2a, 0x10),
                label: " ◈ 9M14 ",
                faces: RADIO_FACES,
                verbs: RADIO_VERBS,
                ..base
            },
            "mono" => Skin {
                name: "mono",
                bg: rgb(0x1f, 0x1f, 0x1f),
                border: rgb(0x5e, 0x5e, 0x5e),
                title: rgb(0xe6, 0xed, 0xf3),
                accent: rgb(0xaa, 0xaa, 0xaa),
                dim: rgb(0x77, 0x77, 0x77),
                text: rgb(0xd0, 0xd0, 0xd0),
                prompt: rgb(0xe6, 0xed, 0xf3),
                menu_sel: rgb(0x46, 0x46, 0x46),
                ..base
            },
            _ => return None,
        })
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
    }
}
