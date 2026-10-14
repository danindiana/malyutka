pub const COMMANDS: &[(&str, &str)] = &[
    ("/help", "list commands"),
    ("/new", "clear the transcript and start a fresh session"),
    ("/clear", "clear the transcript"),
    ("/model", "pick a local Ollama model, or /model <name>"),
    ("/models", "pick from local Ollama models"),
    ("/provider", "set provider: mock|openai|ollama|vllm"),
    ("/baseurl", "set provider base URL"),
    ("/shell", "toggle --allow-shell for next runs"),
    ("/undo", "drop the last turn (resume from the one before)"),
    ("/retry", "undo the last turn and run its prompt again"),
    ("/sessions", "list saved sessions"),
    ("/resume", "show the resume point, or /resume <id>"),
    ("/memory", "show memory.md (read-only)"),
    (
        "/compress",
        "summarise + archive the conversation before the next prompt",
    ),
    ("/ctx", "show or set the context window in tokens"),
    ("/search", "ranked search over saved sessions"),
    (
        "/websetup",
        "start a local SearXNG (docker) so web_search works, no key",
    ),
    ("/mcp", "MCP servers seen in this session"),
    ("/ps", "background processes started by the agent"),
    ("/mandates", "list commitment-latch mandates (read-only)"),
    ("/personality", "concise|teacher|kawaii|terse-ops"),
    (
        "/tools",
        "toggle files|shell|memory|process|skills|mcp|web tools",
    ),
    ("/skin", "open the skin selector, or /skin <name>"),
    ("/skins", "open the skin selector"),
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
