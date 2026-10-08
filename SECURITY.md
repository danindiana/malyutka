# Security policy

Malyutka executes commands proposed by a language model. Its security claims
are therefore specific and testable, and reports that falsify them are the
most valuable contribution you can make.

## What Malyutka claims

With `--allow-shell` (the default sandboxed realm), a model-issued command:

- sees only allowlisted system directories, read-only, plus the workspace;
  not `/home`, `/root`, `/run`, `/var`, `/mnt`, `/media`, `/srv`, `/sys`;
- has no network, no host Unix sockets, no inherited file descriptors, no
  harness environment variables (credentials);
- cannot outlive the harness, its timeout, or its own command (PID
  namespace + `--die-with-parent`);
- cannot redirect the workspace bind (it is bound from a validated fd);
- runs only after its intent, decision and start are durably journaled.

If confinement was requested and cannot be provided, the run is refused. It
never falls back to the host. Each claim is pinned by a test in
`tests/test_adversarial.nim`, `tests/test_invariants.nim` or
`tests/integration.sh`; see `ARCHITECTURE.md` for the invariant table.

## What Malyutka does not claim

- **`--unconfined-host` is a waiver**, not a security mode: commands run with
  your full authority. Processes that deliberately detach (`setsid`, double
  fork) can outlive their command.
- **Journal checksums detect accident and casual tampering**, not an
  adversary running as your uid.
- **Workspace contents are visible to the model**, and therefore to the
  provider. `/etc` is readable.
- A hard link *you* place in the workspace pointing outside it is writable
  through.
- Model output is untrusted data. Malyutka does not try to detect prompt
  injection; it limits what an injected instruction can do.

## Reporting

Please use GitHub's private vulnerability reporting (**Security → Report a
vulnerability**) rather than a public issue. Include the Malyutka version,
`./malyutka doctor` output, your kernel and distribution, and ideally a
failing test. A test that fails is the most useful form of report.
