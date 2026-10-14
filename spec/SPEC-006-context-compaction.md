# SPEC-006 — Context compaction

**Status:** implemented in 0.6.0 · **Invariant:** I10 (partial → enforced) · **Roadmap:** M5-lite

## Goals
Long sessions keep working: when the transcript nears the model's context window the harness
summarises the oldest part, keeps the recent part verbatim, and makes the loss observable.

## Non-goals
Exact tokenisation (no tokenizer dependency); semantic retrieval; lossless compression.

## Mechanism
- `--context-window:N` (config `contextWindow`; CLI default 32768, `0` disables). Estimate = characters / 4
  per message plus 4 overhead (`compact.estimateTokens`).
- Before every provider call: if the estimate exceeds **75 %** of the window, compact. Target after
  compaction: ≤ **50 %**.
- **Cut points** are the only places the transcript may be split, so the result always passes
  `validateTranscript`: before a `user` message, or before an `assistant` message that follows a `tool`
  message (between agent steps). Never between an assistant `toolCalls` and its tool replies.
- The cut is the earliest candidate whose kept suffix fits the target; if none fits, the latest candidate.
  System message and the kept suffix stay verbatim.
- The dropped prefix is rendered (tool outputs truncated, input capped) and summarised by the **same
  provider** with a fixed prompt and no tools. The summary (≤ 4000 chars) replaces the prefix as one
  `user` message starting with `[compacted summary of earlier turns]`, labelled untrusted data.
- `run --compress` compacts the loaded history once before the first call regardless of the threshold.

## Observability (invariant I10)
- Dropped messages are appended to `sessions/<run>.archive.jsonl` (0600, `O_APPEND|O_NOFOLLOW`) **before**
  they are removed from the prompt. If the archive cannot be written, nothing is compacted.
- `context.compacted {dropped, kept, tokensBefore, tokensAfter}` event; the session checkpoint follows.
- The archive is never read back into a prompt.

## Failure policy
- Summariser error, empty summary, no cut point, a result that is not smaller, or an invalid transcript ⇒
  `context.compaction_failed {reason}` and the run continues uncompacted.
- If the estimate is still **above 100 %** of the window ⇒ `agent.halt reason=context`, run result
  `hrContext`, exit 4. The harness never silently truncates.

## Tests and mutants
Cut points never split a call/reply pair (fuzz over generated transcripts), monotone shrink, archive holds
exactly the dropped messages, failure paths, forced compression, halt at 100 %.
**Not mutant-tested (defence in depth):** the post-compaction `validateTranscript` guard — it cannot trigger while cut points are correct.
**Mutants:** allow a cut between a call and its reply; skip the archive write; compact even when the archive
fails; drop silently on summariser failure; no halt above 100 %.
