# Local Command Center engineering contract

This repository is a local-only native macOS product. It organizes coding-agent
sessions and launches the already authenticated Codex and Claude CLIs. It is not
a hosted service and must not read, copy, or reimplement provider credentials.

## Product invariants

- Keep the idle runtime native and dependency-light: SwiftUI/AppKit, Foundation,
  Darwin, and the system SQLite library only.
- Do not add Electron, a WebView, Node/Python daemons, containers, local models,
  analytics, telemetry upload, cloud sync, or a listening network socket.
- Invoke providers with `Foundation.Process`, an absolute resolved executable,
  and an argument array. Never interpolate a prompt, path, skill, or identifier
  into a shell command.
- Bind every conversation to one user-selected workspace root. Normalize paths
  and never grant a provider an implicit additional directory.
- Default to conservative permissions. Any write-capable provider mode must be
  visible in the composer before dispatch.
- The scheduler may delay new work under memory pressure, but must not kill an
  in-flight provider merely to improve a metric. Interactive work outranks
  background review.
- The owner has explicitly authorized local indexing of Codex and Claude Code
  history. Read only provider-owned session metadata and transcript JSONL; never
  write, rename, truncate, delete, or lock provider stores. Never read provider
  credential stores, Keychain items, unrelated application data, or consumer
  web-chat caches. Keep provider files authoritative and load transcript bodies
  lazily under strict byte/message bounds instead of duplicating the corpus.
  Revalidate the exact provider UUID/source immediately before every linked CLI
  launch; capped or errored checks must block as indeterminate, never guess.
- Treat the app-owned database path as untrusted filesystem state. Reject
  symlinked parents/leaves and open/chmod database artifacts with no-follow
  semantics.
- Obsidian integration is an app-owned projection only. Write solely below a
  user-selected, real-path-contained `Command Center/` vault subtree. Never read,
  modify, follow links from, or execute content in existing vault notes. Default
  to metadata and backlinks; transcript export requires a separate explicit opt-in.
- Render provider output as text. Strip terminal control sequences and never
  interpret output as commands, markup with executable behavior, or file paths
  to open automatically.
- No commit, push, remote deployment, publication, account mutation, provider
  logout/login, or skill installation without a separate exact authorization.

## Verification

- Run `swift test` after core changes.
- Run `./script/build_and_run.sh --verify` for an app milestone.
- Run `./script/build_and_run.sh --profile` for idle resident-memory evidence.
- Review every material diff for security, performance, correctness, and
  maintainability before calling it ready for local use.
