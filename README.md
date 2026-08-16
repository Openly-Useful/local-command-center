# Local Command Center (working title)

**Recommended public brand: Threadbraid by Openly Useful**, pending owner
acceptance and formal legal clearance.

Open-source native macOS agent-continuity workspace for coordinating local
Codex and Claude Code sessions. The public build is intentionally local-only:
provider credentials, raw transcripts, local session identifiers, and
machine-specific paths never enter the repository or the portable continuity
package.

A native, local-only macOS workspace for organizing coding-agent chats and
routing work through the authenticated Codex and Claude subscription CLIs.
Codex is a product of OpenAI and Claude Code is a product of Anthropic; this
independent project is not affiliated with or endorsed by either company.

The local milestone intentionally avoids Electron, WebViews, a local HTTP
server, background model pools, and cloud synchronization. One Swift process
owns the UI and local SQLite state; provider processes exist only while work is
running.

The verified local-history milestone is the product foundation. The approved
direction adds deterministic cross-provider handoffs, one-writer/read-only
reviewer enforcement, a provenance-bearing local Knowledge Core, and optional
bounded adapters without weakening the local privacy boundary. See
[`docs/PROJECT-CONTEXT.md`](docs/PROJECT-CONTEXT.md),
[`docs/PRODUCT-SPEC.md`](docs/PRODUCT-SPEC.md), and
[`docs/BRAND-STRATEGY.md`](docs/BRAND-STRATEGY.md).

## Open-source release boundary

This repository contains the public application source and reproducible tests.
It does not broker consumer subscriptions, create web Projects, scrape browser
state, or synchronize provider-owned transcript stores. Local transport and
provider session lineage remain protected runtime state on the host machine.

## Local history federation milestone

- Native project, pinned, inbox, and recent chat organization.
- Local SQLite persistence with a versioned schema and task-scoped skill snapshots.
- Automatic read-only indexing of locally materialized Codex and Claude Code
  sessions, grouped by project with accessible provider badges.
- Lazy recent transcript windows (50 messages / 2 MiB) from provider-owned
  JSONL; provider files remain authoritative and are never rewritten.
- UUID-safe continuation through the already authenticated Codex and Claude
  subscription CLIs after one exact project-folder approval and a fresh,
  bounded source revalidation before each linked launch.
- Launch, foreground, provider-exit, manual, and coalesced periodic refresh.
- Optional deterministic metadata/backlink projection to a registered Obsidian
  vault under an app-owned `Command Center/` subtree.
- Direct, pickup-swarm, and paired-review dispatch modes.
- Visible skills, permission mode, provider, queue, and memory pressure.
- Adaptive concurrency that preserves headroom without slowing active work.

## Build and run

```sh
./script/build_and_run.sh
```

If a managed execution environment blocks SwiftPM's own nested sandbox, use
`COMMAND_CENTER_DISABLE_SWIFTPM_SANDBOX=1 ./script/build_and_run.sh`; the built
application's runtime and privacy model are unchanged.

Useful gates:

```sh
swift test
./script/build_and_run.sh --verify
./script/build_and_run.sh --profile
```

Operational state remains under `~/Library/Application Support/Local Command Center/`.
No provider credentials are copied into the application database.

## First use

1. Open `dist/Command Center.app`.
2. Select **Local history** to browse locally materialized Codex and Claude Code
   sessions. Select one and use **Approve project and continue…** once per exact
   project root; archived Codex sessions remain visibly labeled.
3. Or select **Add project…** and choose one repository folder, then create a
   new task. Choose Codex or Claude, keep **Read only** for questions and
   reviews, and use **Workspace write** only for changes you want the provider
   to make inside that selected folder.
4. Choose **Direct**, **Pickup swarm**, or **Paired review**, select any installed
   skills, and press `⌘Return`.
5. Watch the persistent goal card and bottom status bar; `⌘.` stops the selected
   app-owned provider process.

The app renders only bounded transcript windows to keep long-running histories
from exhausting memory. External transcript bodies are not duplicated into
SQLite or Obsidian. After the explicit in-app disclosure, the metadata-only
Obsidian projection contains opaque IDs, provider-derived task titles (which may
come from a first prompt), project folder labels/backlinks, status, and
timestamps. Obsidian Sync or plugins may export that metadata. Command Center
never reads or modifies existing notes.

Consumer-only ChatGPT and Claude.ai web chats are `BLOCKED_PROVIDER_CAPABILITY`
unless an official local read-and-resume surface materializes them. Command
Center intentionally does not scrape desktop caches, browser data, or tokens.

Automatically launched paired reviews stay classified as background work for
admission priority and display, while their provider prompt remains a focused
direct code review. Final stdout/stderr bytes are drained before a provider turn
is marked complete, so fast-exiting CLIs cannot silently lose their last event.
