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

Options: `--malyutka-bin --skin --provider --model --base-url --allow-files --allow-memory --personality --ollama [uses $OLLAMA_HOST or 127.0.0.1:11434] --allow-shell`.

**Local models:** `/model` (or `/models`) opens a filterable picker of the models Ollama has installed (`GET /api/tags`; embedding models hidden). Enter sets provider `ollama`, the base URL and the model for subsequent runs. `/model <name>` sets one directly.
Skins (15): `default` (Hermes gold), `warsaw`, `nato`, `mono`, `ares`, `poseidon`, `slate`, `sisyphus`, `charizard`, `dracula`, `nord`, `gruvbox`, `solarized`, `matrix`, and the light `daylight`. `/skin` or F2 opens a selector with live preview (Enter applies, Esc restores); `/skin <name>` or `--skin <name>` sets one directly.

Keys: Enter send · Alt+Enter / Ctrl+J / trailing `\` newline · Tab complete ·
Up/Down history · PgUp/PgDn scroll · Ctrl+C clear → stop run → (twice) quit · Ctrl+D quit.

Commands: `/help /new /clear /undo /retry /sessions /resume /memory /personality /tools /model /models /provider /baseurl /shell /skin /verbose
/statusbar /history /journal /doctor /stop /quit`.

**Multi-turn:** each prompt is a new `malyutka run`, resumed from the previous one with `--resume:<run id>`
(harness 0.5.0+), so the model keeps the conversation. `/new` starts fresh, `/undo` drops the last turn
(and resumes from the one before), `/retry` re-runs its prompt, `/resume <id>` continues any saved session.
The TUI never writes session files; undo is just "resume the earlier run again".

**Approvals:** runs use `--approvals:stdin`. An ASK opens a modal (once / session / always / deny, with the
harness's countdown; unanswered = deny). **Tools:** `--allow-files`, `--allow-memory`, `--allow-shell`
(toggle in-app with `/tools files|shell|memory`); patches show a red/green diff, `todo` shows a checklist.
