# Malyutka documentation

| Doc | What it is |
|---|---|
| [`hermes-gap-analysis.md`](hermes-gap-analysis.md) | Prioritised list of Hermes-agent features Malyutka lacks, and where each lands |
| [`../ARCHITECTURE.md`](../ARCHITECTURE.md) | Authority pipeline and the invariant table (I1–I12, P) |
| [`../spec/`](../spec/README.md) | Specifications for work in flight |
| [`../todo/`](../todo/README.md) | Prioritised backlog and explicit non-goals |

## Diagrams (`diagrams/`, regenerate with `diagrams/render.sh`)

| # | Diagram | Question it answers |
|---|---|---|
| 01 | authority pipeline | What stands between a model's proposal and an effect? |
| 02 | sandbox view | What can a sandboxed command see? |
| 03 | process lifetime | Who owns which process and when does it die? |
| 04 | journal states | How does an action move through the write-ahead journal? |
| 05 | journal integrity | How are torn and corrupt journals told apart? |
| 06 | verification | How are defences tested, and how are the tests tested? |
| 07 | roadmap | What is done, in flight and planned? |
| 08 | rationale | Why is the harness shaped like this? |
| 09 | architecture | Which modules and processes exist? |
| 10 | workflow | What happens in one agent turn? |
| 11 | disk handling | Who may touch which files? |
| 12 | I/O paths | Every byte in and out of the harness |
| 13 | catch-22s | Which constraints pull against each other, and how are they resolved? |
| 14 | lessons learned | Which failures shaped the current design? |
| 15 | Hermes gap map | What do we have, what are we building, what is deferred? |
| 16 | TUI integration | How does the Rust TUI talk to the harness? |
| 17 | web egress | What happens between a web call and the text the model sees? |
