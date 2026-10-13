# Non-goals (for now)

| Hermes feature | Why not |
|---|---|
| Messaging gateway (20+ platforms) | Breadth over depth; each platform is an unauthenticated input channel that would need its own policy story. |
| Browser automation, vision, TTS, image generation | Large attack surface and heavy dependencies; no isolation story yet (M3 first). |
| Honcho user modelling | External service, outside the local-first trust model. |
| Cloud sandboxes (Modal, Daytona, Vercel) | Remote realm needs its own confinement proof; Docker/SSH come first. |
| RL training (Atropos) | Research tooling; trajectory export (P2) covers the data side. |
| Plugin loader | Invariant I4 (plugins cannot modify the kernel) is vacuous only because plugins don't exist; revisit with a kernel-safe design. |
