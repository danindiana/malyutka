pub const COMMANDS: &[(&str, &str)] = &[
    ("/help", "list commands"),
    ("/new", "clear the transcript"),
    ("/clear", "clear the transcript"),
    ("/model", "pick a local Ollama model, or /model <name>"),
    ("/models", "pick from local Ollama models"),
    ("/provider", "set provider: mock|openai|ollama|vllm"),
    ("/baseurl", "set provider base URL"),
    ("/shell", "toggle --allow-shell for next runs"),
    ("/skin", "switch skin: default|warsaw|nato|mono"),
    ("/verbose", "toggle raw event/stderr lines"),
    ("/statusbar", "toggle the status bar"),
    ("/history", "recent sessions in the state dir"),
    ("/journal", "show `malyutka journal` (read-only)"),
    ("/doctor", "show `malyutka doctor`"),
    ("/stop", "interrupt the running task"),
    ("/quit", "exit"),
];

pub fn matches(prefix: &str) -> Vec<(&'static str, &'static str)> {
    COMMANDS
        .iter()
        .copied()
        .filter(|(n, _)| n.starts_with(prefix))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completes() {
        assert_eq!(matches("/sh")[0].0, "/shell");
        assert!(matches("/zzz").is_empty());
        assert_eq!(matches("/").len(), COMMANDS.len());
    }
}
