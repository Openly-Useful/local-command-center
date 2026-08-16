# ADR-002: Local provider-history federation and Obsidian graph projection

**Status:** Accepted

**Date:** 2026-08-13

**Deciders:** Owner and Codex root integrator

## Context

The owner wants every locally materialized Codex and Claude session visible,
grouped, searchable, mirrored after provider-app changes, and resumable through
its original authenticated subscription CLI. The local evidence is materially
larger than the first milestone: 311 Codex threads (114 open and 197 archived),
20 canonical Claude Code parent sessions, and 171 Claude child-agent transcripts.
Provider transcript files total roughly 1.2 GiB when archived Codex rollouts are
included. One local Obsidian vault is configured.

Consumer ChatGPT and Claude.ai chats are not equivalent to Codex or Claude Code
sessions. No documented local read-and-resume interface for arbitrary consumer
web chats is present, so claiming seamless continuation for them would be false.

## Decision

Add a provider-neutral metadata index in owner-only SQLite while leaving provider
stores authoritative. Index every canonical Codex thread and Claude Code parent
session by `(provider, surface, UUID)`, preserve Codex thread-spawn parent
relationships, and tombstone missing sources rather than deleting history.
Because lock-free Codex observations can omit live WAL state, absence becomes a
tombstone only after a complete targeted identity search; capped/error scans
remain indeterminate and block continuation without mutating the provider.
Claude `agent-*` child logs remain bounded transcript activity rather than
standalone resumable sessions in this milestone.

Load transcript text lazily from provider JSONL only when a session is selected,
with a newest 50-message/2-MiB provider-source window feeding the existing
200-message/8-MiB render bound. Never duplicate the full transcript corpus into
SQLite or Obsidian. Refresh on launch, foreground, explicit refresh, and provider
exit, plus one non-overlapping 30-second foreground reconciliation. Directory
metadata and file size/mtime/digest prevent unchanged rescans. FSEvents remains a
later wake-up optimization only if measured scans exceed 50 ms p95, 10 MiB
transient allocation, or roughly 2,000 sessions.

Resume always revalidates the source and launches the original provider CLI
with the canonical UUID. A
provider-recorded cwd is metadata, not authorization: the user must explicitly
approve an existing project root before any read-only or write-capable turn.

Project an optional deterministic knowledge graph into one owner-selected
Obsidian vault under `Command Center/`. SQLite remains operational truth. The
projection contains app-managed metadata and wikilinks only by default; existing
vault notes are never read or modified. Transcript projection is a separate
future opt-in because Obsidian Sync or plugins may export vault content.
The connection disclosure explicitly names provider-derived titles (which may
come from first-prompt text), project folder labels, statuses, and timestamps.

## Options considered

| Option | Memory/storage | Fidelity | Risk | Decision |
|---|---:|---|---|---|
| Copy all transcripts into SQLite and Markdown | High; 2–3 copies of ~1.2 GiB | High snapshot fidelity | Recreates storage pressure; stale copies | Rejected |
| Treat Obsidian as operational database | Low app schema work | Human-readable | Plugins/sync, weak transactions, note collisions | Rejected |
| Provider metadata index + lazy source reads | Low | Provider-authoritative | Adapter drift contained | Accepted |
| Scrape consumer desktop/web caches | Unknown | Unreliable | Credentials, format drift, account risk | Rejected |
| FSEvents-only synchronization | Low idle CPU | Fast wake-ups | Dropped events still require reconciliation | Deferred |

## Privacy and safety boundaries

- Never read or copy credentials, Keychain data, arbitrary consumer web caches,
  global prompt-pickers, or unrelated Obsidian notes.
- Never write, delete, rename, truncate, archive, or repair provider stores.
- Bound every line, scan, string, transcript page, query, and rendered window.
- Treat prompts, titles, paths, JSON, Markdown, and links as untrusted inert text.
- Do not log transcript bodies. Source paths stay in owner-only SQLite and are
  omitted from Obsidian Markdown.
- Mark unsupported consumer chats `BLOCKED_PROVIDER_CAPABILITY` instead of
  inventing a mirror.

## Consequences and rollback

- The unified list can show provider logos/text, archived/stale state, projects,
  and resumability without retaining all bodies.
- External changes appear after bounded eventual reconciliation, not as a cloud
  two-way sync promise.
- Disabling federation cancels refresh and leaves provider stores untouched.
  Schema additions are additive and current app-owned conversations keep working.
- Disconnecting Obsidian stops projection and deletes nothing. Any later reset is
  a separately confirmed recoverable operation on the app-owned subtree only.
