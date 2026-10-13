# malyutka-tui

A [ratatui](https://ratatui.rs) front end for Malyutka, styled after the
[Hermes Agent](https://github.com/NousResearch/hermes-agent) terminal UI:
bordered banner, `┊` tool feed, kawaii spinner, status bar and a `❯` prompt
with slash-command completion.

It is a separate crate and changes nothing in the Nim core. Each task spawns
`malyutka run --json` and renders its JSONL event stream; it never writes the
journal or session files (`/journal` and `/doctor` just show the CLI's output).

```
cd tui && cargo build --release
./target/release/malyutka-tui --malyutka-bin ../malyutka --provider mock
```

Options: `--malyutka-bin --skin --provider --model --base-url --ollama [uses $OLLAMA_HOST or 127.0.0.1:11434] --allow-shell`.

**Local models:** `/model` (or `/models`) opens a filterable picker of the models Ollama has installed (`GET /api/tags`; embedding models hidden). Enter sets provider `ollama`, the base URL and the model for subsequent runs. `/model <name>` sets one directly.
Skins: `default` (Hermes gold), `warsaw`, `nato`, `mono` (`/skin <name>`).

Keys: Enter send · Alt+Enter / Ctrl+J / trailing `\` newline · Tab complete ·
Up/Down history · PgUp/PgDn scroll · Ctrl+C clear → stop run → (twice) quit · Ctrl+D quit.

Commands: `/help /new /clear /model /models /provider /baseurl /shell /skin /verbose
/statusbar /history /journal /doctor /stop /quit`.

Limitation: each prompt is a fresh run; resumable sessions arrive with milestone M4.
