# Cron / scheduler

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-002, background process

## What
Scheduled unattended runs with delivery of results.

## Why / Hermes reference
Hermes: `cronjob` tool.

## Invariant and design notes
Unattended runs have no approver: they must run with `--approvals:deny` or a pre-agreed allowlist (catch-22 #3).
