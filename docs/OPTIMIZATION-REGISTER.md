# Optimization register

| Opportunity | Expected benefit | Regression risk | Proof required | Decision |
|---|---|---|---|---|
| Native SwiftUI instead of Electron/WebView | Avoid duplicated browser process family and reduce idle RSS | More macOS-specific code | Build/launch plus measured release RSS under 120 MiB | Validated locally |
| One long-lived UI process; CLI workers on demand | Avoid idle provider/model pools | First prompt has process startup latency | Idle process tree and authenticated two-provider smoke | Validated locally |
| System SQLite WAL | Fast bounded organization/search without service process | Migration/corruption defects | Reopen, transaction, FK, injection, ordering, owner-only mode, and bounded transcript tests | Validated locally |
| Mach memory sampling | No periodic shell process or Activity Monitor dependency | Available-memory interpretation differs from pressure score | Boundary tests plus comparison with `memory_pressure -Q` during QA | Safe now |
| Codex immutable SQLite + bounded rollout supplement | Existing active/archived tasks without provider locks or sidecar writes | Immutable view can omit live WAL rows | Sidecar hash/mtime fixture, rollout-only merge, hard DB/entry caps, targeted pre-resume revalidation | Validated locally |
| Metadata-index all canonical Claude Code parents | Immediate organization without a second transcript corpus | Format drift or repeated large scans | Direct-parent UUID validation, bounded head/tail parse, size/mtime cache, lazy transcript reader | Validated locally |
| Metadata-index all Codex tasks (active + archived) | One complete local task inventory | Live SQLite/WAL drift | Immutable/no-lock SQLite, bounded rollout supplement, provider-scoped identity, error-free targeted tombstones | Validated locally |
| Combined history window: 10,000 metadata rows | Preserve both independently capped 5,000-session provider pools in one UI | Worst-case metadata allocation | Separate 5,000-row ingest cap, 10,000-row combined list cap, visible omitted count | Validated locally |
| Obsidian metadata/backlink projection | Durable human-readable connective tissue | Plugins/sync can export notes; symlink/collision risk | Explicit vault connection, app-only subtree, opaque IDs, atomic contained writes, no transcript bodies | Validated locally |
| Parallel Codex + Claude editing same workspace | Maximum apparent throughput | Conflicting edits, memory spike, duplicate token use | Isolated worktrees and deterministic integration review | Reject for v1 |
| Sequential cross-provider paired review | Independent quality gate using both pools | Extra quota and latency | User-visible workflow, bounded queue, and authenticated providers | Validated locally; owner usability pass remains |
| Recent transcript window: 200 messages / 8 MiB | Prevent long chats from recreating desktop memory exhaustion | Older content is not rendered in the first milestone | Store-level newest-window test and live visible-list trimming | Validated locally |
| Queue: 16 prompts / 2 MiB aggregate; prompts 256 KiB each | Bound rapid-input memory while preserving provider throughput | Excess work waits for explicit retry | Admission review plus deterministic prompt checkpointing | Validated locally |
| Per-task canonical skill snapshots | Accurate task context across selection and relaunch without retaining skill bodies | Schema migration and stale labels | v1→v2 migration, Codable/SQLite round trip, canonical bounds, and UI restore tests | Validated locally |
| EOF-gated provider completion | Preserve final JSONL and diagnostics from fast-exiting CLIs | A missing EOF could delay completion | Deterministic immediate-exit fake-provider test plus authenticated turns | Validated locally |
| Embedded terminal/editor | Fewer app switches | Large privilege and UI/memory surface | Threat model and native PTY/editor benchmark | Defer |
| Local model fallback | Offline operation | Multi-GB model memory defeats first goal | Separate hardware/model benchmark | Reject for this milestone |
