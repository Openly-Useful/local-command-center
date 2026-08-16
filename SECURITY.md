# Security policy and repository threat model

## Overview

Local Command Center is a single-user native macOS application. Its privileged
surface is not a public network service; it is the ability to launch already
authenticated coding-agent CLIs inside a user-selected workspace. The primary
assets are local source files, provider subscriptions and session identifiers,
conversation content, the local SQLite database, and the integrity of launched
process arguments.

## Trust boundaries and assumptions

- The macOS user and paths selected through the native open panel are trusted
  operator inputs.
- Chat prompts, provider JSONL output, repository names, branch names, skill
  metadata, and imported thread metadata are untrusted display data.
- Codex and Claude executables are resolved from known local paths but remain
  external processes whose output must be parsed defensively.
- Provider credential stores are outside the app boundary. The app may ask the
  CLI for a boolean/auth-method status but must never read or copy tokens.
- The app has the current user's filesystem authority. Provider permissions and
  workspace roots are therefore visible, explicit safety boundaries rather than
  a claim of OS sandbox isolation.
- The app binds no TCP/UDP socket and performs no cloud sync. Local history
  federation reads only provider-owned session metadata/transcript files; it
  never reads provider credential stores or consumer web-app caches.

## Attack surface and invariants

- **Process launch:** use `Process.executableURL` and an argument array. Never
  invoke `/bin/sh -c`; never combine prompt or path text into a command string.
- **Workspace scope:** normalize and validate an existing directory before
  dispatch. History discovery may index a provider-recorded workspace path, but
  that path grants no provider access; resume remains disabled until the owner
  has explicitly approved an existing workspace root.
- **Provider history:** open Codex state SQLite through SQLite's immutable,
  no-lock path and supplement it with bounded Claude/Codex JSONL enumeration.
  Provider stores remain authoritative and
  must never be written, renamed, truncated, deleted, or locked by the app.
  Canonical identity is provider plus UUID; never coalesce providers by ID or
  body text. Malformed, partial, replaced, or oversized records must degrade to
  a stale/diagnostic state rather than crash or broaden a scan.
- **Stream parsing:** bound individual JSONL lines and retained output, strip
  terminal control sequences, tolerate unknown event shapes, and treat rendered
  strings as inert text. Drain both pipes through EOF before marking a provider
  process complete so the final bounded event cannot be lost at exit.
- **SQLite:** use prepared statements, bound parameters, transactions, foreign
  keys, a busy timeout, and schema versioning. Database and directory modes are
  owner-only. Reject redirected parent/leaf paths, open the physical path with
  SQLite `NOFOLLOW`, and permission artifacts through no-follow descriptors.
- **Concurrency:** cap queued and active work; memory pressure may block new
  dispatch but may not silently terminate active user work.
- **Skills:** list metadata only. Never execute a skill file, install a skill,
  or expand its instructions in the app process. Persist only canonical,
  bounded skill identifiers on each app-owned task.
- **Lifecycle:** cancellation targets only a child process created by this app.
  Never use a name-wide kill command for provider processes.
- **Obsidian projection:** require a user-selected vault and constrain every
  real write target beneath an app-owned `Command Center/` subtree. Never read
  or modify existing notes, follow vault links, or assume vault plugins/sync are
  private. Before connection, disclose that metadata includes provider-derived
  task titles (potentially sourced from a first prompt), project labels, status,
  and timestamps. Transcript projection is a separate future opt-in.

## Severity calibration

- **Critical:** prompt/path injection reaches a shell; arbitrary unrelated local
  files are modified without the selected workspace/write mode; credentials are
  exfiltrated or logged.
- **High:** one conversation can execute or cancel another conversation's
  process; imported output produces code execution; a remote origin can dispatch
  work.
- **Medium:** malformed provider output crashes the app repeatedly; database
  corruption loses all session organization; memory admission allows an
  avoidable system-wide pressure failure.
- **Low:** stale provider status, cosmetic state mismatch, bounded log loss, or
  a keyboard/accessibility defect without privilege impact.

Security reports for this local prototype should include the exact app version,
provider CLI versions, selected permission mode, and a minimal reproduction.
