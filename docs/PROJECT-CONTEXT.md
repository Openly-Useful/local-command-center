# Cross-Tool Continuity Command Center — current project context

Status date: 2026-08-16

## Identity

This repository is the native macOS controller for the **Cross-Tool Continuity
Command Center** initiative. It is not the Project Status product or release
initiative. Project Status is an adjacent, separate repository and must not be
used as context for this product.

The current application and repository name, **Local Command Center**, remains
the engineering working title. The recommended public product brand is
**Threadbraid by Openly Useful**, pending owner acceptance and formal trademark
clearance. No bundle identifier, application-support path, executable, or
repository rename is implied by that recommendation.

## Product definition

Threadbraid is a single-user, native macOS agent-continuity workspace for
already authenticated coding-agent CLIs. It lets a developer find, resume,
hand off, and supervise work across Codex and Claude Code while preserving
provider lineage, explicit permission boundaries, and local custody.

The product is not:

- a hosted inference service;
- a credential broker;
- a universal chat client;
- a transcript-merging or cloud-sync service;
- a replacement for Codex, Claude Code, or their official CLIs; or
- a multi-user team SaaS product in the current scope.

## Verified baseline

The current native baseline is commit `1af46240d05353973d334988c8c12b54b866aa1a`
on `feat/cross-tool-continuity` and `v0.1.0`. At the 2026-08-16 handoff
checkpoint, `swift test --disable-sandbox` executed 93 tests with one
intentional live-provider skip and no failures.

Verified native behavior includes:

- SwiftUI/AppKit UI with owner-only SQLite state;
- direct launching and UUID-safe resume through authenticated Codex and Claude
  CLIs;
- read-only provider-history federation and bounded lazy transcript views;
- explicit workspace approval and source revalidation;
- direct, Pickup Swarm, and paired-review workflows;
- memory-aware admission of new work; and
- an optional, write-only Obsidian metadata projection.

The first continuity foundation is present: domain models, schema-v4
persistence, transactional v3-to-v4 migration, continuity CRUD, and
compare-and-swap writer leases. The independent contract and migration review
has since completed and been accepted (see
[`ADR-004`](ADR-004-bridge-canonical-project.md)); provider session adapters,
a deterministic bridge slice with reviewer denial, and expanded
fresh/v1/v2/v3/interruption migration coverage now carry current deterministic
test evidence (164 tests, one intentional live-provider skip, zero failures).

## Approved product direction

The complete product direction adds:

1. Separate immutable provider branches with deterministic capsule-and-delta
   handoffs between providers.
2. Exactly one writer per workstream and technically read-only reviewers.
3. A local provenance-bearing Knowledge Core with FTS5 retrieval, bounded cited
   context assembly, freshness, verification, sensitivity, and supersession.
4. Provider-neutral adapters that preserve each CLI's safe start and resume
   behavior.
5. Optional, authority-scoped Cua Driver integration behind explicit policy,
   telemetry, permission, audit, revocation, and kill-switch controls.
6. Optional private remote transport that remains separate from desktop
   control and never turns the native core into a public listener.
7. A reviewed package catalog for current open-source, free, or low-cost
   companion options, with explicit install approval and rollback receipts.
8. Idempotent external projections for GitHub, Linear, Forgejo, Plane, and
   related adapters; external tools never become canonical truth.

SQLite remains operational truth. Stable-ID Markdown and canonical JSON are
portable projections. Obsidian, SilverBullet, Logseq, and TriliumNext remain
optional clients.

## Delivery state

| Area | State |
|---|---|
| Native session organization and resume | Verified baseline |
| Continuity models, schema v4, CRUD, and writer leases | Independently reviewed and accepted (ADR-004); seal and append-only enforcement tested |
| Provider adapter contract | Implemented with fake-backed tests; same-provider fork honestly unsupported |
| Deterministic native capsule and cross-provider handoff | Capsule validation and a deterministic bridge handoff slice implemented; full native integration in progress |
| Full reviewer authority enforcement | Authority service enforced at dispatch and bridge writes; reviewer UI enforcement planned |
| Knowledge Core and automatic context | Planned |
| Knowledge projections and native inspection UI | Planned |
| Cua Driver boundary and adapter | Blocked on security design and owner actions |
| Private remote transport | Blocked on selection and deployment authority |
| Package catalog and guided installer | Planned; no install authority implied |
| GitHub/Linear and open-source tracker projections | Blocked on verified identifiers and write authority |
| Final migration, provider E2E, accessibility, performance, and release acceptance | Planned |

## History and handoff

- The local-history federation milestone established the native, local-only
  application and privacy boundary.
- The portable `conductor-swarm` component established the bounded continuity
  contract and validation model.
- A first native continuity baseline was committed and pushed by a concurrent
  actor during handoff preparation. Its source-control provenance and branch
  protection remain owner-review items.
- The 2026-08-16 Claude handoff reconciled the full native scope, the portable
  component, the Knowledge Core direction, Cua and remote boundaries, package
  selection, external projections, and 13 dependency-ordered workstreams.
- `PROJECT_HANDOFF.md` and `.claude/orchestration/` contain the current local
  execution handoff. They are machine-local working artifacts, intentionally
  excluded from this repository, and their claims must be revalidated before
  edits.

## Immediate continuation

The protected continuity foundation checkpoint is complete: repository state
was revalidated, the continuity model and v4 migration were independently
audited and accepted, provider adapters landed in non-overlapping files with
fake-backed tests, and the deterministic bridge slice passes idempotency,
privacy-rejection, and reviewer-denial tests. The next checkpoint is full
native integration: bridge-backed handoff wiring throughout the application,
the continuity and review UI, and then the Knowledge Core.

No commit, push, installation, daemon start, telemetry or permission change,
external tracker write, deployment, live database migration, or release is
authorized by this context document.
