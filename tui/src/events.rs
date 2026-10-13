//! Parsing of the `malyutka run --json` JSONL stream.
use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub kind: String,
    pub payload: Value,
}

impl Event {
    pub fn s(&self, key: &str) -> String {
        self.payload
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    }
}

/// Returns None for blank or malformed lines (the stream may carry noise).
pub fn parse_line(line: &str) -> Option<Event> {
    let v: Value = serde_json::from_str(line.trim()).ok()?;
    let kind = v.get("kind")?.as_str()?.to_string();
    let payload = v.get("payload").cloned().unwrap_or(Value::Null);
    Some(Event { kind, payload })
}

pub fn exit_meaning(code: i32) -> &'static str {
    match code {
        0 => "answered",
        1 => "failure",
        2 => "usage error",
        3 => "confinement unavailable",
        4 => "halted",
        5 => "journal unavailable / unknown outcomes pending (see /journal)",
        6 => "journal corrupt",
        _ => "terminated",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_known_kinds() {
        let l = r#"{"ts":"t","kind":"tool.proposed","payload":{"id":"9M14-abcd-0003","name":"shell","args":{"cmd":"ls"}}}"#;
        let e = parse_line(l).unwrap();
        assert_eq!(e.kind, "tool.proposed");
        assert_eq!(e.s("name"), "shell");
        assert_eq!(e.s("missing"), "");
    }

    #[test]
    fn tolerates_noise() {
        assert!(parse_line("").is_none());
        assert!(parse_line("FINAL: hi").is_none());
        assert!(parse_line(r#"{"kind":5}"#).is_none());
        assert!(parse_line(r#"{"kind":"x"#).is_none());
        assert_eq!(parse_line(r#"{"kind":"x"}"#).unwrap().payload, Value::Null);
    }

    #[test]
    fn exit_codes() {
        assert_eq!(exit_meaning(4), "halted");
        assert_eq!(exit_meaning(99), "terminated");
    }
}
