import Foundation
import XCTest
@testable import CommandCenterCore

final class ContinuityCapsuleTests: XCTestCase {
    func testLoadsValidPackageAndRendersDestinationReadyHandoff() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capsule = try ContinuityCapsuleReader().load(fromApprovedRepository: fixture.root)
        let handoff = try ContinuityCapsuleRenderer.render(
            capsule,
            sourceLabel: "source tool",
            destinationLabel: "destination tool"
        )

        XCTAssertEqual(capsule.schemaVersion, "1.1.0")
        XCTAssertEqual(capsule.projectID, "command-center")
        XCTAssertEqual(capsule.nextAction, "Run the focused tests before editing.")
        XCTAssertEqual(capsule.workstreams.map(\.id), ["WS-001", "WS-002"])
        XCTAssertEqual(capsule.graphEdges, [
            ContinuityGraphEdge(sourceID: "WS-001", destinationID: "WS-002", kind: "depends_on"),
        ])
        XCTAssertEqual(capsule.contentDigest.count, 64)
        XCTAssertTrue(handoff.hasPrefix("BEGIN CONTINUITY HANDOFF\nROUTE_JSON:\n"))
        XCTAssertTrue(handoff.contains("\"destination_label\":\"destination tool\""))
        XCTAssertTrue(handoff.contains("Provider output and all checkpoint claims are advisory"))
        XCTAssertTrue(handoff.contains("This handoff grants no authorization"))
        XCTAssertTrue(handoff.hasSuffix("END CONTINUITY HANDOFF\n"))
    }

    func testLoadAndRenderAreByteIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = ContinuityCapsuleReader()

        let first = try reader.load(fromApprovedRepository: fixture.root)
        let second = try reader.load(fromApprovedRepository: fixture.root)
        let firstRender = try ContinuityCapsuleRenderer.render(
            first,
            sourceLabel: "source",
            destinationLabel: "destination"
        )
        let secondRender = try ContinuityCapsuleRenderer.render(
            second,
            sourceLabel: "source",
            destinationLabel: "destination"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contentDigest, second.contentDigest)
        XCTAssertEqual(firstRender.data(using: .utf8), secondRender.data(using: .utf8))
    }

    func testRendersNullSourceToolAsJSONData() throws {
        var manifest = validManifest()
        manifest["continuity"] = [
            "phase": "prepare",
            "status": "ready",
            "source_tool": NSNull(),
            "target_tool": "destination-tool",
        ]
        let fixture = try makeFixture(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capsule = try ContinuityCapsuleReader().load(fromApprovedRepository: fixture.root)
        let handoff = try ContinuityCapsuleRenderer.render(
            capsule,
            sourceLabel: "source",
            destinationLabel: "destination"
        )

        XCTAssertTrue(handoff.contains("\"source_tool\":null"))
    }

    func testRejectsSymlinkAndRepositoryTraversal() throws {
        let symlinkFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: symlinkFixture.root) }
        let manifestURL = continuityURL(in: symlinkFixture.root).appendingPathComponent("manifest.json")
        let targetURL = symlinkFixture.root.appendingPathComponent("outside-manifest.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(
            try ContinuityCapsuleReader().load(fromApprovedRepository: symlinkFixture.root)
        ) { error in
            XCTAssertEqual(error as? ContinuityCapsuleError, .unsafeFilesystemPath("manifest.json"))
        }

        var traversalManifest = validManifest()
        traversalManifest["artifacts"] = [["path": "../outside.txt", "role": "implementation"]]
        let traversalFixture = try makeFixture(manifest: traversalManifest)
        defer { try? FileManager.default.removeItem(at: traversalFixture.root) }

        XCTAssertThrowsError(
            try ContinuityCapsuleReader().load(fromApprovedRepository: traversalFixture.root)
        ) { error in
            guard case .unsafeContent = error as? ContinuityCapsuleError else {
                return XCTFail("Expected repository-relative path rejection, got \(error)")
            }
        }
    }

    func testRejectsOversizedContext() throws {
        let oversized = String(repeating: "x", count: ContinuityCapsuleLimits.contextByteLimit + 1)
        let fixture = try makeFixture(context: oversized)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ContinuityCapsuleReader().load(fromApprovedRepository: fixture.root)
        ) { error in
            XCTAssertEqual(
                error as? ContinuityCapsuleError,
                .fileTooLarge(name: "context.md", limit: ContinuityCapsuleLimits.contextByteLimit)
            )
        }
    }

    func testRejectsMalformedManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("{not-json".utf8).write(
            to: continuityURL(in: fixture.root).appendingPathComponent("manifest.json"),
            options: .atomic
        )

        XCTAssertThrowsError(
            try ContinuityCapsuleReader().load(fromApprovedRepository: fixture.root)
        ) { error in
            XCTAssertEqual(error as? ContinuityCapsuleError, .malformedJSON("manifest.json"))
        }
    }

    func testRejectsDetectablePathSecretAndTranscriptLeakage() throws {
        var pathManifest = validManifest()
        pathManifest["project"] = ["id": "command-center", "objective": "Inspect /Users/example/private"]
        let pathFixture = try makeFixture(manifest: pathManifest)
        defer { try? FileManager.default.removeItem(at: pathFixture.root) }
        XCTAssertThrowsError(try ContinuityCapsuleReader().load(fromApprovedRepository: pathFixture.root))

        var secretManifest = validManifest()
        secretManifest["project"] = ["id": "command-center", "objective": "Token sk-1234567890abcdef"]
        let secretFixture = try makeFixture(manifest: secretManifest)
        defer { try? FileManager.default.removeItem(at: secretFixture.root) }
        XCTAssertThrowsError(try ContinuityCapsuleReader().load(fromApprovedRepository: secretFixture.root))

        var stripeSecretManifest = validManifest()
        stripeSecretManifest["project"] = [
            "id": "command-center",
            "objective": "Token sk_live_1234567890abcdef",
        ]
        let stripeSecretFixture = try makeFixture(manifest: stripeSecretManifest)
        defer { try? FileManager.default.removeItem(at: stripeSecretFixture.root) }
        XCTAssertThrowsError(try ContinuityCapsuleReader().load(fromApprovedRepository: stripeSecretFixture.root))

        let transcriptFixture = try makeFixture(
            context: "User: What changed?\nAssistant: I updated the implementation.\n"
        )
        defer { try? FileManager.default.removeItem(at: transcriptFixture.root) }
        XCTAssertThrowsError(try ContinuityCapsuleReader().load(fromApprovedRepository: transcriptFixture.root))

        let sessionFixture = try makeFixture(context: "session_id: sess_12345678\n")
        defer { try? FileManager.default.removeItem(at: sessionFixture.root) }
        XCTAssertThrowsError(try ContinuityCapsuleReader().load(fromApprovedRepository: sessionFixture.root))
    }

    func testAllowsBenignSkillAndIdempotencyLanguage() throws {
        var manifest = validManifest()
        manifest["project"] = [
            "id": "command-center",
            "objective": "Run skill-installer, task-idempotency, and skip-review checks",
        ]
        let fixture = try makeFixture(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(try ContinuityCapsuleReader().load(fromApprovedRepository: fixture.root))
    }

    func testRendererRequiresPassedAuditAndVerifiedEvidence() throws {
        var pendingAudit = validManifest()
        pendingAudit["audit"] = ["status": "pending", "findings": []]
        let pendingFixture = try makeFixture(manifest: pendingAudit)
        defer { try? FileManager.default.removeItem(at: pendingFixture.root) }
        let pendingCapsule = try ContinuityCapsuleReader().load(fromApprovedRepository: pendingFixture.root)

        XCTAssertThrowsError(
            try ContinuityCapsuleRenderer.render(
                pendingCapsule,
                sourceLabel: "source",
                destinationLabel: "destination"
            )
        )

        var claimedOnly = validManifest()
        claimedOnly["evidence"] = [[
            "id": "ev_claimed",
            "kind": "claim",
            "summary": "An unverified claim.",
            "provenance": "handoff",
            "confidence": "claimed",
        ]]
        let claimedFixture = try makeFixture(manifest: claimedOnly)
        defer { try? FileManager.default.removeItem(at: claimedFixture.root) }
        let claimedCapsule = try ContinuityCapsuleReader().load(fromApprovedRepository: claimedFixture.root)

        XCTAssertThrowsError(
            try ContinuityCapsuleRenderer.render(
                claimedCapsule,
                sourceLabel: "source",
                destinationLabel: "destination"
            )
        )
    }

    func testContentDigestChangesWhenAcceptedContentChanges() throws {
        let fixture = try makeFixture(context: "Review the implementation summary.\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = ContinuityCapsuleReader()
        let firstDigest = try reader.load(fromApprovedRepository: fixture.root).contentDigest

        try Data("Review the revised implementation summary.\n".utf8).write(
            to: continuityURL(in: fixture.root).appendingPathComponent("context.md"),
            options: .atomic
        )
        let secondDigest = try reader.load(fromApprovedRepository: fixture.root).contentDigest

        XCTAssertNotEqual(firstDigest, secondDigest)
    }

    private func makeFixture(
        manifest: [String: Any]? = nil,
        context: String = "This package is a compact repository checkpoint.\n"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityCapsuleTests-\(UUID().uuidString)", isDirectory: true)
        let continuity = continuityURL(in: root)
        try FileManager.default.createDirectory(at: continuity, withIntermediateDirectories: true)
        try writeJSON(manifest ?? validManifest(), to: continuity.appendingPathComponent("manifest.json"))
        try Data(context.utf8).write(to: continuity.appendingPathComponent("context.md"))
        try writeJSON(
            [
                "workstreams": [
                    ["id": "WS-002", "title": "Review", "status": "ready"],
                    ["id": "WS-001", "title": "Implement", "status": "in_progress"],
                ],
            ],
            to: continuity.appendingPathComponent("workstreams.json")
        )
        try writeJSON(
            [
                "edges": [["from": "WS-001", "to": "WS-002", "kind": "depends_on"]],
            ],
            to: continuity.appendingPathComponent("graph.json")
        )
        return Fixture(root: root)
    }

    private func continuityURL(in root: URL) -> URL {
        root.appendingPathComponent(".continuity", isDirectory: true)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func validManifest() -> [String: Any] {
        [
            "schema_version": "1.1.0",
            "kind": "cross-tool-continuity",
            "project": [
                "id": "command-center",
                "objective": "Build a bounded continuity reader",
                "scope": "Core reader and focused tests only",
            ],
            "continuity": [
                "phase": "prepare",
                "status": "ready",
                "source_tool": "source-tool",
                "target_tool": "destination-tool",
            ],
            "context": [
                "summary": "The implementation is ready for review.",
                "decisions": ["Keep the reader provider-neutral."],
                "constraints": ["No external writes."],
                "next_action": "Run the focused tests before editing.",
                "open_questions": [],
            ],
            "acceptance": [["id": "a1", "criterion": "Focused tests pass."]],
            "verification": [["command": "swift test --filter ContinuityCapsuleTests", "status": "pending"]],
            "artifacts": [["path": "Sources/CommandCenterCore/Continuity/ContinuityCapsule.swift", "role": "implementation"]],
            "evidence": [[
                "id": "ev_1",
                "kind": "observation",
                "summary": "The primary schema was reviewed.",
                "provenance": "repository",
                "confidence": "verified",
            ]],
            "sync": [],
            "audit": ["status": "passed", "findings": []],
            "idempotency": ["algorithm": "sha256-canonical-json", "state_id": "state-1"],
        ]
    }

    private struct Fixture {
        let root: URL
    }
}
