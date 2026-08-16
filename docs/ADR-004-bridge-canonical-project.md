# ADR-004: Bridge-owned canonical continuity contract

**Status:** Accepted

**Date:** 2026-08-16

**Deciders:** Owner direction; WS-001 independent contract review

## Context

The continuity feature branch introduced domain models, v4 persistence, writer
leases, capsule validation, and handoff preflight before an independent
contract review existed. WS-001 requires the canonical model contract to be
audited against the product decisions rather than accepted from test counts:
the bridge owns the canonical project, provider sessions stay separate
immutable branches, cross-provider movement is a handoff and never a fork,
canonical history is append-only with supersession instead of rewriting,
exactly one writer exists per workstream, and reviewers are technically
read-only.

## Decision

The continuity contract is anchored in `CommandCenterCore` models plus
store-level enforcement, with the following audited properties:

1. **Bridge-owned project.** `ContinuityProject` is app-owned, anchored to one
   approved workspace, and its workspace anchor is immutable after creation
   (store-enforced). A continuity project grants no filesystem authority;
   workspace approval remains a separate explicit boundary.
2. **Opaque local identity.** Continuity rows reference only local UUIDs
   (`conversationID` or `externalSessionID`, exactly one per link, enforced in
   the model, in DDL CHECK constraints, and by reference validation). Raw
   provider session identifiers, provider paths, and transcript bodies never
   enter serializable continuity models.
3. **Provider separation and handoff-not-fork.** Provider identity lives on
   the linked session records, never coalesced across providers.
   Cross-provider movement is expressed exclusively as `ContinuityHandoff`
   between session links. Fork remains a same-provider operation of the
   provider adapter layer (WS-003) and is rejected across providers there.
4. **Append-only audit.** `ContinuityEvent` is immutable (all stored
   properties are constants; the store exposes insert and read only). Sync
   history advances by revision; corrections supersede rather than rewrite.
5. **Sealed handoffs.** A handoff is editable in `draft` and `ready`. Once
   `acknowledged` it is sealed: title, summary, destination, and creation time
   are frozen and the only legal transition is to `superseded`. A `superseded`
   handoff is terminal and fully frozen. Acknowledgment is only reachable from
   `ready` (store-enforced transition matrix).
6. **Bounded canonical text.** Every continuity text field is NFC-normalized,
   trimmed, control-character-free, and byte-bounded (name 512 B, title 512 B,
   summary 16 KiB, event detail 4 KiB), mirrored by DDL CHECK constraints.
   Continuity fields are deliberately single-line; multi-line portable context
   belongs to the separately validated 32 KiB continuity capsule.
7. **One writer, read-only review.** Writer ownership is a store-level CAS
   lease (`ContinuityWriterLease` for sync transactions,
   `ContinuityWorkstreamWriterLease` per workstream) with bounded duration
   (1–300 s), monotonic revisions, expiry, and a fail-closed reconciliation
   marker that survives reopen and clears only with digest-validated audit
   evidence. Reviewer permission produces no writer transaction
   (lease-gate-enforced and view-model-enforced).

## Review findings routed to WS-002

The independent audit accepted the model layer and identified two
store-enforcement gaps, both closed under WS-002 ownership:

- `upsertContinuityHandoff` previously allowed rewriting an `acknowledged` or
  `superseded` handoff and moving state backwards; a transition matrix now
  enforces seal semantics.
- Unused `deleteContinuityEvent` and `deleteContinuityHandoff` APIs
  contradicted the append-only decision and were removed. Project and
  session-link deletion remain as explicit owner data-management operations
  whose cascades are covered by foreign-key tests; narrowing them further is a
  WS-012 acceptance question.

## Consequences

- Model invariants are characterized in
  `Tests/CommandCenterCoreTests/ContinuityModelsTests.swift`; persistence,
  migration, seal, and lease behavior in the WS-002 store suites.
- Handoff supersession requires creating a successor handoff rather than
  editing history, which the UI must surface as lineage (WS-005).
- The capsule codec, preflight, and lease gate consume this contract
  unchanged; WS-004 bridge work builds on immutable session-link tips plus the
  workstream lease and must not introduce any bypass of the seal or lease
  rules.
