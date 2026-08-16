import CommandCenterCore
import Foundation
import XCTest
@testable import CommandCenter

final class ProjectBridgeTests: XCTestCase {
    private let capsuleDigest = String(repeating: "a", count: 64)

    func testReviewerIsDeniedBeforeAnyRowIsCreated() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reviewer = ProjectBridge(store: fixture.store, role: .reviewer)

        do {
            _ = try await reviewer.recordHandoff(
                projectID: fixture.projectID,
                sourceSessionLinkID: fixture.sourceLinkID,
                destinationSessionLinkID: fixture.destinationLinkID,
                title: "Reviewer handoff",
                summary: "Reviewers cannot write canonical state.",
                capsuleDigest: capsuleDigest,
                now: date(10)
            )
            XCTFail("A reviewer must not record a handoff")
        } catch {
            XCTAssertEqual(
                error as? ReviewAuthorityError,
                .reviewerDenied(.recordHandoff)
            )
        }

        let handoffs = try await fixture.store.listContinuityHandoffs(projectID: fixture.projectID)
        let events = try await fixture.store.listContinuityEvents(projectID: fixture.projectID)
        XCTAssertTrue(handoffs.isEmpty)
        XCTAssertTrue(events.isEmpty)

        XCTAssertFalse(ReviewAuthorityService.permits(.reviewer, .dispatchWriteCapableWork))
        XCTAssertFalse(ReviewAuthorityService.permits(.reviewer, .acquireWorkstreamLease))
        XCTAssertTrue(ReviewAuthorityService.permits(.reviewer, .prepareReadOnlyReview))
        XCTAssertEqual(
            ReviewAuthorityService.effectivePermission(for: .reviewer, requested: .workspaceWrite),
            .readOnly,
            "A reviewer can never escalate to workspace-write"
        )
        XCTAssertEqual(
            ReviewAuthorityService.effectivePermission(for: .writer, requested: .workspaceWrite),
            .workspaceWrite
        )
    }

    func testDuplicateRecordingConvergesWithoutDuplicateEvents() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = ProjectBridge(store: fixture.store, role: .writer)

        let first = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Deterministic handoff",
            summary: "Same input converges on the same canonical row.",
            capsuleDigest: capsuleDigest,
            now: date(20)
        )
        let second = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Deterministic handoff",
            summary: "Same input converges on the same canonical row.",
            capsuleDigest: capsuleDigest,
            now: date(30)
        )

        XCTAssertFalse(first.wasAlreadyRecorded)
        XCTAssertTrue(second.wasAlreadyRecorded)
        XCTAssertEqual(first.handoff.id, second.handoff.id)
        XCTAssertEqual(second.handoff, first.handoff, "Replay must not mutate the stored handoff")

        let handoffs = try await fixture.store.listContinuityHandoffs(projectID: fixture.projectID)
        let events = try await fixture.store.listContinuityEvents(projectID: fixture.projectID)
        XCTAssertEqual(handoffs.count, 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(handoffs.first?.state, .ready)

        // Changed content is a distinct successor handoff, never a rewrite.
        let successor = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Deterministic handoff",
            summary: "Corrected direction supersedes the earlier summary.",
            capsuleDigest: capsuleDigest,
            now: date(40)
        )
        XCTAssertFalse(successor.wasAlreadyRecorded)
        XCTAssertNotEqual(successor.handoff.id, first.handoff.id)
        let afterSuccessor = try await fixture.store.listContinuityHandoffs(projectID: fixture.projectID)
        XCTAssertEqual(afterSuccessor.count, 2)
    }

    func testBridgeWritesAreSerializedThroughTheWorkstreamLease() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = ProjectBridge(store: fixture.store, role: .writer)
        let title = "Contended handoff"
        let summary = "Exactly one writer may own this workstream."
        let workstreamID = ProjectBridge.workstreamID(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: title,
            summary: summary,
            capsuleDigest: capsuleDigest
        )
        let foreignOwner = UUID()
        let foreignLease = try await fixture.store.acquireContinuityWorkstreamWriterLease(
            projectID: fixture.projectID,
            workstreamID: workstreamID,
            ownerID: foreignOwner,
            now: date(50),
            duration: 60
        )
        XCTAssertNotNil(foreignLease)

        do {
            _ = try await bridge.recordHandoff(
                projectID: fixture.projectID,
                sourceSessionLinkID: fixture.sourceLinkID,
                destinationSessionLinkID: fixture.destinationLinkID,
                title: title,
                summary: summary,
                capsuleDigest: capsuleDigest,
                now: date(51)
            )
            XCTFail("A held lease must exclude the bridge writer")
        } catch {
            XCTAssertEqual(error as? ProjectBridgeError, .writerLeaseUnavailable)
        }

        let released = try await fixture.store.releaseContinuityWorkstreamWriterLease(
            projectID: fixture.projectID,
            workstreamID: workstreamID,
            ownerID: foreignOwner,
            at: date(52)
        )
        XCTAssertTrue(released)
        let receipt = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: title,
            summary: summary,
            capsuleDigest: capsuleDigest,
            now: date(53)
        )
        XCTAssertFalse(receipt.wasAlreadyRecorded)
        let active = try await fixture.store.hasActiveContinuityWorkstreamWriterLease(
            projectID: fixture.projectID,
            workstreamID: workstreamID,
            at: date(54)
        )
        XCTAssertFalse(active, "The bridge releases its lease after the write")
    }

    func testHandoffConnectsImmutableTipsAndSealsAfterAcknowledgment() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = ProjectBridge(store: fixture.store, role: .writer)
        let receipt = try await bridge.recordHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Immutable tips",
            summary: "Provider branches stay immutable on both sides.",
            capsuleDigest: capsuleDigest,
            now: date(60)
        )

        // The source tip cannot be re-anchored to another session.
        let movedTip = try ContinuitySessionLink(
            id: fixture.sourceLinkID,
            projectID: fixture.projectID,
            externalSessionID: fixture.externalSessionID,
            kind: .primary,
            createdAt: date(2),
            updatedAt: date(61)
        )
        do {
            try await fixture.store.upsertContinuitySessionLink(movedTip)
            XCTFail("A session link tip must be immutable")
        } catch {}

        var acknowledged = receipt.handoff
        acknowledged.state = .acknowledged
        acknowledged.updatedAt = date(62)
        try await fixture.store.upsertContinuityHandoff(acknowledged)

        var rewrite = acknowledged
        rewrite.summary = "Rewritten after acknowledgment."
        rewrite.updatedAt = date(63)
        do {
            try await fixture.store.upsertContinuityHandoff(rewrite)
            XCTFail("An acknowledged handoff is sealed")
        } catch {}
    }

    func testMachineLocalAndSecretShapedContentIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = ProjectBridge(store: fixture.store, role: .writer)

        for prohibited in [
            "Details live in /Users/someone/project/notes.md",
            "Socket endpoint tcp://127.0.0.1:8021 stays open",
            "Continue with token = abc123 later",
            "Use sk-abcdefgh12345678 for the follow-up",
            "Local daemon pid: 4242 still runs",
        ] {
            do {
                _ = try await bridge.recordHandoff(
                    projectID: fixture.projectID,
                    sourceSessionLinkID: fixture.sourceLinkID,
                    destinationSessionLinkID: fixture.destinationLinkID,
                    title: "Privacy screen",
                    summary: prohibited,
                    capsuleDigest: capsuleDigest,
                    now: date(70)
                )
                XCTFail("Expected rejection for: \(prohibited)")
            } catch let error as ProjectBridgeError {
                guard case .prohibitedContent = error else {
                    return XCTFail("Expected prohibitedContent, received \(error)")
                }
            }
        }

        do {
            _ = try await bridge.recordHandoff(
                projectID: fixture.projectID,
                sourceSessionLinkID: fixture.sourceLinkID,
                destinationSessionLinkID: fixture.destinationLinkID,
                title: "Privacy screen",
                summary: "Digest must be canonical.",
                capsuleDigest: String(repeating: "A", count: 64),
                now: date(71)
            )
            XCTFail("Uppercase digests are not canonical")
        } catch {
            XCTAssertEqual(error as? ProjectBridgeError, .invalidCapsuleDigest)
        }

        let handoffs = try await fixture.store.listContinuityHandoffs(projectID: fixture.projectID)
        let events = try await fixture.store.listContinuityEvents(projectID: fixture.projectID)
        XCTAssertTrue(handoffs.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testBoundaryHandoffUsesFormatValidationAndStaysIdempotent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = ProjectBridge(store: fixture.store, role: .writer)
        // Repository-relative paths that would trip the free-text screen are
        // legitimate boundary content; the machine format is the contract here.
        let boundary = ContinuityHandoffBoundary(
            capsuleDigest: String(repeating: "d", count: 64),
            commit: String(repeating: "e", count: 40),
            statusDigest: String(repeating: "f", count: 64),
            sourceLabel: "Claude",
            destinationLabel: "Codex",
            changedPaths: ["docs/tmp/notes.md", "Sources/users/README.md"]
        )

        let first = try await bridge.recordBoundaryHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Boundary handoff",
            boundary: boundary,
            now: date(80)
        )
        let replay = try await bridge.recordBoundaryHandoff(
            projectID: fixture.projectID,
            sourceSessionLinkID: fixture.sourceLinkID,
            destinationSessionLinkID: fixture.destinationLinkID,
            title: "Boundary handoff",
            boundary: boundary,
            now: date(81)
        )
        XCTAssertFalse(first.wasAlreadyRecorded)
        XCTAssertTrue(replay.wasAlreadyRecorded)
        XCTAssertEqual(replay.handoff, first.handoff)
        let decoded = try ContinuityHandoffBoundary.decode(summary: first.handoff.summary)
        XCTAssertEqual(decoded, boundary)

        let reviewer = ProjectBridge(store: fixture.store, role: .reviewer)
        do {
            _ = try await reviewer.recordBoundaryHandoff(
                projectID: fixture.projectID,
                sourceSessionLinkID: fixture.sourceLinkID,
                destinationSessionLinkID: fixture.destinationLinkID,
                title: "Reviewer boundary",
                boundary: boundary,
                now: date(82)
            )
            XCTFail("The boundary path must deny reviewers too")
        } catch {
            XCTAssertEqual(
                error as? ReviewAuthorityError,
                .reviewerDenied(.recordHandoff)
            )
        }
    }

    private struct Fixture {
        let root: URL
        let store: SQLiteStore
        let projectID: UUID
        let sourceLinkID: UUID
        let destinationLinkID: UUID
        let externalSessionID: UUID
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("store.sqlite"))
        let now = date(1)
        let workspaceID = uuid(1)
        let projectID = uuid(2)
        let conversationID = uuid(3)
        let externalSessionID = uuid(4)
        let sourceLinkID = uuid(5)
        let destinationLinkID = uuid(6)

        try await store.upsertWorkspace(Workspace(
            id: workspaceID, name: "Bridge tests", rootPath: root.path,
            createdAt: now, updatedAt: now
        ))
        try await store.insertConversation(Conversation(
            id: conversationID, workspaceID: workspaceID,
            title: "bridge source", provider: .claude,
            createdAt: now, updatedAt: now
        ))
        try await store.upsertExternalSessions([try ExternalSession(
            id: externalSessionID,
            provider: .codex,
            surface: .codex,
            providerSessionID: "bridge-destination",
            workspacePath: root.path,
            title: "Destination session",
            preview: "Metadata only",
            providerStatus: "completed",
            canResume: true,
            canReadTranscript: true,
            sourcePath: "/private/bridge.jsonl",
            sourceByteCount: 32,
            sourceModifiedAt: now,
            firstSeenAt: now,
            lastSeenAt: now
        )])
        try await store.upsertContinuityProject(try ContinuityProject(
            id: projectID, workspaceID: workspaceID, name: "Bridge tests",
            createdAt: now, updatedAt: now
        ))
        try await store.upsertContinuitySessionLink(try ContinuitySessionLink(
            id: sourceLinkID, projectID: projectID, conversationID: conversationID,
            kind: .primary, createdAt: date(2), updatedAt: date(2)
        ))
        try await store.upsertContinuitySessionLink(try ContinuitySessionLink(
            id: destinationLinkID, projectID: projectID, externalSessionID: externalSessionID,
            kind: .successor, createdAt: date(3), updatedAt: date(3)
        ))
        return Fixture(
            root: root,
            store: store,
            projectID: projectID,
            sourceLinkID: sourceLinkID,
            destinationLinkID: destinationLinkID,
            externalSessionID: externalSessionID
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0x83, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
