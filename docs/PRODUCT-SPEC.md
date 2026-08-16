# Cross-Tool Continuity Command Center — product specification

- Working application title: **Local Command Center**
- Recommended public brand: **Threadbraid by Openly Useful**, pending owner and
  formal legal clearance
- Current verified milestone: **local history federation plus continuity
  foundation**

## Product promise

One calm native place to find, resume, hand off, and supervise coding-agent
work across providers while preserving lineage, explicit authority, and local
custody. The app is an organizer, continuity layer, and process governor around
the official subscription CLIs, not a replacement inference stack.

The brand promise is **continuity with custody**: switch agents without
re-explaining the project, merging provider histories, copying credentials, or
turning an external projection into canonical truth.

## Scope and delivery state

The verified baseline and approved end-state are intentionally distinct.

### Verified baseline

- Native SwiftUI/AppKit application with owner-only SQLite.
- Read-only Codex and Claude Code history indexing with bounded lazy transcript
  views.
- Direct launch and UUID-safe provider-native resume after exact workspace
  approval and source revalidation.
- Direct, Pickup Swarm, and paired-review workflows with memory-aware
  admission.
- Optional write-only Obsidian metadata projection.
- Continuity domain models, schema-v4 persistence, transactional v3-to-v4
  migration, CRUD, and compare-and-swap writer leases with deterministic test
  evidence; independent contract and migration review remains required.

### Approved end-state

- Separate immutable provider branches and deterministic bounded
  capsule-and-delta handoffs.
- One writer per workstream and technically read-only reviewers.
- A built-in provenance-bearing Knowledge Core with FTS5 retrieval, bounded
  cited context assembly, freshness, sensitivity, verification, and
  supersession.
- Provider-neutral adapters; optional, authority-scoped desktop control and
  private remote transport behind independent security boundaries.
- A reviewed package catalog for current open-source, free, or low-cost
  companions, with explicit approval and rollback.
- Idempotent external projections that never become canonical truth.

See [`docs/PROJECT-CONTEXT.md`](PROJECT-CONTEXT.md) for current scope,
delivery state, and blockers. Dependency order and execution evidence live in
local-only working artifacts (`PROJECT_HANDOFF.md` and `.claude/orchestration/`)
that are intentionally excluded from this repository.

## Primary layout for the verified local-history milestone

```text
┌──────────────────────┬──────────────────────────┬──────────────────────────────────────┐
│ COMMAND CENTER       │ Sessions                 │ Selected conversation                │
│                      │                          │                                      │
│ Inbox            3   │ ● Needs input  Title     │ Title             Codex · running    │
│ Pinned           2   │   repo · 12m             │ workspace/path                       │
│ Ready for review 1   │ ● Running      Title     │ [pickup-swarm] [code-review]          │
│                      │   repo · now             │                                      │
│ PROJECTS             │ ● Ready        Title     │ user / assistant / tool transcript    │
│ ▾ Gloatroom       4  │   repo · 1h              │ rendered as inert selectable text     │
│   Open tools         │                          │                                      │
│ ▸ Career Aide     1  │                          │                                      │
│                      │                          │                                      │
│ SKILLS           86  │                          │ ┌──────────────────────────────────┐ │
│ RUNTIME              │                          │ │ Ask or direct work…              │ │
│ 29% free · 1/3       │                          │ └──────────────────────────────────┘ │
│ Balanced             │                          │ Codex · Workspace write · Direct  Send│
└──────────────────────┴──────────────────────────┴──────────────────────────────────────┘
```

This is a macOS source-list and mail-style three-column structure, not three
custom card grids. The hierarchy remains visible while a conversation is open.

## Information architecture

### Sidebar destinations

- **Inbox:** `needsInput`, `running`, `queued`, and failed work requiring action.
- **Pinned:** owner-pinned conversations across workspaces.
- **Ready for review:** completed provider work that has not been accepted.
- **Local history:** every canonical locally materialized Codex and Claude Code
  parent session, grouped by provider-recorded project, including archived and
  tombstoned sources with distinct provider symbol plus spoken text.
- **Projects:** user-selected workspace roots with their conversations.
- **Skills:** searchable metadata from provider-native/local skill catalogs.
- **Runtime:** current memory policy, free headroom, active/queued workers, and
  provider authentication availability, history coverage, refresh health, and
  explicit Obsidian metadata-graph connection.

### Provider history contract

- SQLite stores bounded metadata only and keys identity by provider, surface,
  and canonical UUID. Missing sources become tombstones only after an
  authoritative complete scan or bounded, error-free targeted revalidation;
  they are never deleted.
- Provider JSONL stays cold/authoritative. Selection reads only the newest 50
  visible user/assistant messages within 2 MiB and renders within the existing
  200-message/8-MiB ceiling.
- Continuation uses the original provider UUID and authenticated CLI only after
  exact project-folder approval. The source is revalidated immediately before
  every linked CLI launch. A historical cwd is metadata, not permission.
- Automatic mirroring is eventual and read-only: launch, foreground, 30 seconds
  while active, 120 seconds while inactive, provider exit, and manual refresh.
  Scans are coalesced and unchanged Claude files are not reparsed.
- Consumer ChatGPT/Claude.ai chats without an official local read/resume surface
  are `BLOCKED_PROVIDER_CAPABILITY`; caches and credential stores are never scraped.

### Obsidian contract

Obsidian is an optional human-readable connective graph, not operational state.
The user explicitly connects one registered vault. Command Center then writes
deterministic metadata/backlink notes only below `Command Center/`, omits full
paths and transcripts, rejects symlink escapes/unmanaged collisions, and never
reads or changes existing notes. Before connection, the UI discloses that the
projection includes provider-derived titles (potentially first-prompt text),
project folder labels, statuses, and timestamps, and that vault sync/plugins may
export them. Disconnect retains generated notes and deletes nothing.

### Session list

Each row has one status dot, one title, and one secondary line containing the
workspace and relative time. Provider, branch, skills, tokens, and permissions
belong in detail—not repeated in every row.

### Conversation detail

- Header: title, workspace, provider, status, stop/resume controls.
- Context rail: selected skills, workflow, permission mode, branch when known.
- Transcript: lazy message stack with user/assistant/tool roles and selectable
  monospaced tool output. Unknown provider events remain inspectable but quiet.
- Composer: multi-line prompt, provider pool, workflow, permission, skill picker,
  and a visible admission result (`Run now`, `Queue`, or `Waiting for memory`).

## Workflows

| Workflow | Dispatch | Definition |
|---|---|---|
| Direct | One chosen provider | Normal partnered chat/coding turn |
| Pickup swarm | One coordinator with explicit recovery contract | Audit current state, define done, delegate only independent work, verify |
| Paired review | Primary provider, then the other provider | Implementation output is handed to a fresh reviewer; no concurrent file ownership |

“Both providers at once” is not the default. Parallel agents are admitted only
when tasks are independent and memory headroom supports both. Paired review is
sequential by design, avoiding duplicate edits and excess context burn.

## Resource interaction

- The footer reports measured available memory and app RSS, not an invented
  performance score.
- Balanced mode reserves 20% of physical memory and admits up to two workers
  when estimated headroom allows.
- Focus mode reserves 25% and favors one or two interactive workers.
- Throughput mode reserves 12.5% and permits up to four workers to drain when the Mac
  has real headroom.
- A running job is never killed automatically. When pressure rises, only new
  dispatch pauses and the UI explains why.
- Provider cost estimates are updated conservatively from observed child RSS in
  later milestones; v1 starts with explicit static estimates.

## Interaction rules

- `⌘N`: new conversation in the selected workspace.
- `⌘K`: command palette/search.
- `⌘Return`: dispatch current composer text.
- `⌘.`: cancel the selected app-owned provider process.
- `⌘1/2/3`: Inbox, Pinned, Ready for review.
- Drag or context menu moves a conversation between project organization states;
  provider-native session data is not rewritten.
- Destructive actions require a native confirmation and initially affect only
  the Command Center index. Provider session deletion is not part of v1.

## Visual language

- Native window/sidebar materials and system typography for Mac fidelity.
- Monospaced digits and metadata for the CLI bridge.
- Accent semantics: blue running, amber needs input, mint ready for review,
  coral failed, neutral queued/idle. Every color has a text label and symbol.
- No animated background, glass-card wall, purple AI gradient, or permanently
  moving activity indicator. Motion is limited to state transitions and obeys
  Reduce Motion.

## Accessibility

- All status dots have spoken labels; color is never the only distinction.
- Source-list rows and session rows expose stable selection and keyboard focus.
- Transcript messages use headings/labels and selectable text.
- Composer controls have explicit accessibility names and logical tab order.
- Minimum hit target is 28×28 points for desktop controls; primary dispatch and
  destructive controls are at least 36 points high.
- Full Keyboard Access, VoiceOver, Increase Contrast, Reduce Motion, 200% text,
  and narrow-window reflow are acceptance checks.

## Deliberate non-copies from the references

- Do not reproduce Codex or Claude branding, proprietary icons, exact spacing,
  or their sidebar chrome.
- Do not mirror the screenshot's long undifferentiated ungrouped list; search,
  status inboxes, and project structure are first-class.
- Do not reproduce Hermes' broad gateway, memory editor, terminal, or theme
  surface in v1. Those increase privilege and memory before chat organization is
  proven.
