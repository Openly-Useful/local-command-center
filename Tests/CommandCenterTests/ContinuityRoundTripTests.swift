import CommandCenterCore
import Foundation
import XCTest
@testable import CommandCenter

/// One full fake-adapter Claude -> Codex -> Claude continuity round trip at
/// the service layer: adapter dispatch and checkpoint, bridge handoff in each
/// direction, seal on acknowledgment, reviewer denial, and lineage integrity.
/// No real provider CLI is launched.
private struct RoundTripExecutor: ProviderSessionExecuting {
    let script: [ProviderStreamEvent]

    func execute(
        _ plan: ProviderLaunchPlan,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) throws -> ProviderSessionHandle {
        for event in script { onEvent(event) }
        return ProviderSessionHandle(isRunning: { false }, onStop: {})
    }
}

private final class RoundTripRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [ProviderSessionEventEnvelope] = []

    func append(_ envelope: ProviderSessionEventEnvelope) {
        lock.lock()
        envelopes.append(envelope)
        lock.unlock()
    }

    func snapshot() -> [ProviderSessionEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return envelopes
    }
}

final class ContinuityRoundTripTests: XCTestCase {
    private let fixtureExecutableURL = URL(fileURLWithPath: "/usr/bin/true")
    private let claudeSessionID = "6c000000-0000-4000-8000-00000000000a"
    private let codexSessionID = "6c000000-0000-4000-8000-00000000000b"

    func testFullFakeAdapterClaudeToCodexAndBackRoundTrip() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claude = ClaudeSessionAdapter(executableURL: fixtureExecutableURL)
        let codex = CodexSessionAdapter(executableURL: fixtureExecutableURL)
        let bridge = ProjectBridge(store: fixture.store, role: .writer)
        let request = ProviderSessionRequest(
            workspaceURL: fixture.workspaceURL,
            prompt: "continue the continuity foundation"
        )

        // 1. Claude turn through the fake executor produces an ordered stream
        //    ending in a clean exit, from which a checkpoint is derived.
        let claudeRecorder = RoundTripRecorder()
        _ = try claude.dispatch(
            try claude.startPlan(request),
            executor: RoundTripExecutor(script: [
                .sessionID(claudeSessionID),
                .text("Implementation finished; ready for review."),
                .exited(0),
            ])
        ) { claudeRecorder.append($0) }
        let claudeEnvelopes = claudeRecorder.snapshot()
        XCTAssertEqual(claudeEnvelopes.map(\.sequence), [0, 1, 2])
        let claudeCheckpoint = try claude.checkpoint(from: claudeEnvelopes)
        XCTAssertEqual(claudeCheckpoint.provider, .claude)
        XCTAssertEqual(claudeCheckpoint.providerSessionID, claudeSessionID)

        // 2. Cross-provider movement must be a handoff, never a fork.
        XCTAssertThrowsError(try codex.forkPlan(
            request,
            from: ProviderSessionLineage(
                provider: .claude,
                providerSessionID: claudeCheckpoint.providerSessionID
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderSessionAdapterError,
                .crossProviderForkRejected(source: .claude, requested: .codex)
            )
        }

        // 3. Outbound bridge handoff Claude -> Codex, then destination
        //    acknowledgment seals it.
        let digestA = String(repeating: "a", count: 64)
        let outbound = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.claudeLinkID,
            destinationSessionLinkID: fixture.codexLinkID,
            title: "Implementation handoff",
            summary: "Review the finished implementation with read-only access.",
            capsuleDigest: digestA,
            now: date(10)
        )
        XCTAssertFalse(outbound.wasAlreadyRecorded)
        var acknowledged = outbound.handoff
        acknowledged.state = .acknowledged
        acknowledged.updatedAt = date(11)
        try await fixture.store.upsertContinuityHandoff(acknowledged)
        var sealedRewrite = acknowledged
        sealedRewrite.summary = "Rewritten after the seal."
        do {
            try await fixture.store.upsertContinuityHandoff(sealedRewrite)
            XCTFail("The acknowledged outbound handoff must be sealed")
        } catch {}

        // 4. Codex destination turn resumes its own provider-native session
        //    and produces the return checkpoint.
        let resumePlan = try codex.resumePlan(request, providerSessionID: codexSessionID)
        XCTAssertTrue(resumePlan.arguments.contains("resume"))
        XCTAssertTrue(resumePlan.arguments.contains(codexSessionID))
        let codexRecorder = RoundTripRecorder()
        _ = try codex.dispatch(resumePlan, executor: RoundTripExecutor(script: [
            .sessionID(codexSessionID),
            .batch([.text("Review complete."), .activity("Turn completed")]),
            .exited(0),
        ])) { codexRecorder.append($0) }
        let codexCheckpoint = try codex.checkpoint(from: codexRecorder.snapshot())
        XCTAssertEqual(codexCheckpoint.provider, .codex)
        XCTAssertEqual(codexCheckpoint.providerSessionID, codexSessionID)
        XCTAssertEqual(codexCheckpoint.lastEventSequence, 3)

        // 5. Inbound bridge handoff Codex -> Claude on the same immutable tips
        //    with swapped roles.
        let digestB = String(repeating: "b", count: 64)
        let inbound = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.codexLinkID,
            destinationSessionLinkID: fixture.claudeLinkID,
            title: "Review findings handoff",
            summary: "Apply the review findings in the original session.",
            capsuleDigest: digestB,
            now: date(20)
        )
        XCTAssertFalse(inbound.wasAlreadyRecorded)
        XCTAssertNotEqual(inbound.handoff.id, outbound.handoff.id)

        // 6. A reviewer cannot write canonical state on the same project.
        let reviewer = ProjectBridge(store: fixture.store, role: .reviewer)
        do {
            _ = try await reviewer.recordHandoff(
                projectID: fixture.projectID,
                sourceSessionLinkID: fixture.codexLinkID,
                destinationSessionLinkID: fixture.claudeLinkID,
                title: "Reviewer write",
                summary: "Must be denied.",
                capsuleDigest: digestB,
                now: date(21)
            )
            XCTFail("Reviewer writes must be denied")
        } catch {
            XCTAssertEqual(
                error as? ReviewAuthorityError,
                .reviewerDenied(.recordHandoff)
            )
        }

        // 7. Lineage integrity: both directions exist, provider branches stay
        //    separate immutable tips, every lease was released, and the audit
        //    trail has exactly one event per recorded handoff.
        let handoffs = try await fixture.store.listContinuityHandoffs(projectID: fixture.projectID)
        XCTAssertEqual(handoffs.count, 2)
        XCTAssertEqual(
            Set(handoffs.map(\.state)),
            Set([.acknowledged, .ready])
        )
        let events = try await fixture.store.listContinuityEvents(projectID: fixture.projectID)
        XCTAssertEqual(events.filter { $0.kind == .handoffCreated }.count, 2)
        for handoff in handoffs {
            let leaseActive = try await fixture.store.hasActiveContinuityWorkstreamWriterLease(
                projectID: fixture.projectID,
                workstreamID: handoff.id,
                at: date(30)
            )
            XCTAssertFalse(leaseActive, "Bridge leases must not outlive their write")
        }
        let claudeTip = try await fixture.store.continuitySessionLink(id: fixture.claudeLinkID)
        let codexTip = try await fixture.store.continuitySessionLink(id: fixture.codexLinkID)
        XCTAssertEqual(claudeTip?.conversationID, fixture.claudeConversationID)
        XCTAssertNil(claudeTip?.externalSessionID)
        XCTAssertEqual(codexTip?.externalSessionID, fixture.codexExternalID)
        XCTAssertNil(codexTip?.conversationID)
    }

    private struct Fixture {
        let root: URL
        let workspaceURL: URL
        let store: SQLiteStore
        let projectID: UUID
        let claudeConversationID: UUID
        let codexExternalID: UUID
        let claudeLinkID: UUID
        let codexLinkID: UUID
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("store.sqlite"))
        let now = date(1)
        let workspaceID = uuid(1)
        let projectID = uuid(2)
        let claudeConversationID = uuid(3)
        let codexExternalID = uuid(4)
        let claudeLinkID = uuid(5)
        let codexLinkID = uuid(6)

        try await store.upsertWorkspace(Workspace(
            id: workspaceID, name: "Round trip", rootPath: workspaceURL.path,
            createdAt: now, updatedAt: now
        ))
        try await store.insertConversation(Conversation(
            id: claudeConversationID, workspaceID: workspaceID,
            title: "claude implementation", provider: .claude,
            createdAt: now, updatedAt: now
        ))
        try await store.upsertExternalSessions([try ExternalSession(
            id: codexExternalID,
            provider: .codex,
            surface: .codex,
            providerSessionID: codexSessionID,
            workspacePath: workspaceURL.path,
            title: "Codex review session",
            preview: "Metadata only",
            providerStatus: "completed",
            canResume: true,
            canReadTranscript: true,
            sourcePath: "/private/round-trip.jsonl",
            sourceByteCount: 32,
            sourceModifiedAt: now,
            firstSeenAt: now,
            lastSeenAt: now
        )])
        try await store.upsertContinuityProject(try ContinuityProject(
            id: projectID, workspaceID: workspaceID, name: "Round trip",
            createdAt: now, updatedAt: now
        ))
        try await store.upsertContinuitySessionLink(try ContinuitySessionLink(
            id: claudeLinkID, projectID: projectID, conversationID: claudeConversationID,
            kind: .primary, createdAt: date(2), updatedAt: date(2)
        ))
        try await store.upsertContinuitySessionLink(try ContinuitySessionLink(
            id: codexLinkID, projectID: projectID, externalSessionID: codexExternalID,
            kind: .successor, createdAt: date(3), updatedAt: date(3)
        ))
        return Fixture(
            root: root,
            workspaceURL: workspaceURL,
            store: store,
            projectID: projectID,
            claudeConversationID: claudeConversationID,
            codexExternalID: codexExternalID,
            claudeLinkID: claudeLinkID,
            codexLinkID: codexLinkID
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_710_000_000 + seconds)
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0x84, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
