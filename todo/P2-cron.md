# Cron / scheduler

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-002, SPEC-008 (process tool, delivered)

## What
Scheduled unattended runs with delivery of results.

## Why / Hermes reference
Hermes: `cronjob` tool.

## Invariant and design notes
Unattended runs have no approver: they must run with `--approvals:deny` or a pre-agreed allowlist (catch-22 #3).
