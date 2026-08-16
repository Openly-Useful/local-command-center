# Recovery ledger

Baseline: 2026-08-13, America/New_York. Discovery was read-only.

| Workflow or candidate | Last verified state | Remaining intent | Blocked or unknown | Evidence | Confidence | Next safe action |
|---|---|---|---|---|---|---|
| Project Status Initiative | Distribution-ready skill/plugin work with a large uncommitted integration diff | Different product: evidence-backed readiness dashboard | Publisher and deployment gates; repository purpose does not match chat orchestration | `../project-status-initiative`, its `AGENTS.md`, release checks, and worktree status | High | Keep isolated and untouched |
| Project Ambient native app | SwiftPM/SwiftUI app runs locally at roughly 13 MiB RSS and stages a 2.4 MiB app bundle | Demonstrates the right native process shape | Its source and product scope are unrelated; handoff history identifies multiple snapshots | Read-only `Package.swift`, app sources, staged bundle, and live `ps` sample | High | Reuse architectural lessons only |
| Hermes Agent / workspace | Rich sessions, memory, skills, delegation, and terminal experience | Inspiration for local session search and progressive skills | Available workspaces add Python + Node/React/xterm and are API/backend oriented; not a minimal Mac-only substrate | Official Hermes documentation and public repositories | High | Copy interaction principles, not runtime |
| Codex CLI | Version 0.147.0; authenticated via ChatGPT; app-server v2 lists local thread metadata and offers read/start/fork/turn APIs | Existing-session organization and native streaming | App-server is experimental and can drift | Local help, generated JSON schemas, bounded metadata-only JSON-RPC probe | High | Wrap behind a versioned adapter with a fallback |
| Claude Code | Version 2.1.223; first-party Claude subscription authentication; stream-json and explicit session IDs available | New/resumable Claude conversations and background-agent visibility | No stable machine-readable full-history list was found | Local help and auth-status checks | High | Own IDs for app-created sessions; do not scrape credentials/history |
| Local Command Center | Native release app builds and runs locally; Codex and Claude read-only marker turns passed through the production adapter; SQLite, memory admission, bounded transcripts, session organization, task-scoped skills, persistent goal/status UI, and provider history linking are implemented | Owner usability pass on real daily projects | Full Claude history import and provider-internal token metering are intentionally deferred | This repository, deterministic suite, opt-in live provider smoke, release profile, and independent code review | High | Use the live app for one real project and capture friction before widening scope |

## Observable first-milestone completion

1. A staged native `.app` builds, opens, and remains alive.
2. Idle app RSS is measured and remains below 120 MiB on this 16-GB Mac.
3. Projects and conversations persist across relaunch in local SQLite.
4. The UI displays Codex and Claude availability without exposing credentials.
5. A user can create, organize, dispatch, cancel, and resume an app-owned chat.
6. Direct, pickup-swarm, and paired-review workflows are visible and deterministic.
7. Memory pressure governs only new dispatch; active work is not killed.
8. Tests, threat model, and independent code review report no unresolved critical
   or high-severity defect for local use.

## First-milestone evidence — 2026-08-13

- Release `.app` staged and opened from `dist/Command Center.app`.
- Final release RSS measured 54,592 KiB (about 53.3 MiB), below the 120 MiB
  acceptance ceiling.
- No TCP or UDP listeners were present in the Command Center process.
- Final deterministic strict-release suite: 37 tests, 0 failures, with the one
  authenticated live smoke intentionally skipped during ordinary runs.
- Subscription-backed smoke: Codex and Claude each returned their exact marker
  through `ProviderProcessRunner` in read-only mode in 15.309 seconds.
- Strict-concurrency release build with warnings as errors passed.
- Final bundle passed ad-hoc signature verification and plist validation; its
  running process exposed no TCP/UDP listeners and had no idle child process.
- Independent focused rereview found no unresolved P0, P1, or P2 defects in the
  final provider-stream, paired-review, and task-skill changes.
- All external publication, deployment, commit, push, marketplace, entity, and
  account-state actions remained out of scope and were not performed.
