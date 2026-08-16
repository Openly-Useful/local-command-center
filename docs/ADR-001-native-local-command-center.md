# ADR-001: Native, process-on-demand Local Command Center

**Status:** Accepted

**Date:** 2026-08-13
**Deciders:** Owner and Codex root integrator

## Context

The target Mac has 16 GB physical memory and reported 29% free memory during
baseline collection. The user's captured failure showed ChatGPT at 13.52 GB,
Claude at 2.43 GB, and Chrome at 5.33 GB. A currently running native SwiftUI
Project Ambient process measured about 13 MiB RSS, providing direct evidence
that a native process can avoid the browser/Electron floor.

The product must organize chats, preserve a CLI-native workflow, use the user's
existing ChatGPT/Codex and Claude subscriptions, expose skills and swarms, and
remain entirely local on one Mac for the first milestone.

## Decision

Build a macOS 14+ SwiftPM application using SwiftUI/AppKit, Foundation Process,
Darwin system metrics, and system SQLite3 in WAL mode. Keep exactly one idle app
process. Start Codex or Claude only when a queued job is admitted by the memory
governor. Use provider-native session identifiers and streaming protocols.

Codex existing-session metadata is obtained through its local stdio app-server.
Claude sessions created here receive explicit UUIDs and resume through the CLI.
The adapter boundary absorbs provider protocol drift.

## Options considered

| Option | Idle memory | Capability | Operational complexity | Decision |
|---|---:|---|---|---|
| Electron desktop shell | High; duplicates Chromium | Rich web ecosystem | High runtime floor and renderer failure modes | Rejected |
| Local Node server + browser/PWA | Medium to high when a browser is required | Fast prototype | Keeps the user's browser-memory problem | Rejected |
| Hermes workspace and backend | Multiple Python/Node processes | Broadest existing feature set | Provider/runtime duplication and heavier install | Rejected as substrate |
| Tauri/system WebView | Lower than Electron, still a WebView process family | Cross-platform | Cross-platform value is unnecessary for Mac-only v1 | Deferred |
| Native SwiftUI + CLI workers | Lowest measured floor | Native organization and full CLI throughput | More adapter/UI code | Accepted |

## Consequences

- The app follows macOS windowing, keyboard, accessibility, materials, and
  lifecycle behavior without emulation.
- Provider throughput remains the official CLI's throughput; the UI adds no
  inference proxy or token-consuming model layer.
- App-created Claude sessions are fully organized immediately. Importing
  unrelated historical Claude sessions remains a later, explicit privacy task.
- Codex app-server instability is contained to one adapter and cannot corrupt
  the local conversation database.
- Cross-platform support is intentionally deferred until local Mac usability is
  proven.

## Performance policy

- Sample host memory with Mach APIs; do not poll by spawning shell commands.
- Reserve headroom before starting new jobs; never suspend or kill active jobs.
- Use SQLite WAL, bounded queries, and lazy SwiftUI lists.
- Store streamed events incrementally instead of retaining entire process logs.
- Offer focus, balanced, and throughput policies, with balanced as default.
