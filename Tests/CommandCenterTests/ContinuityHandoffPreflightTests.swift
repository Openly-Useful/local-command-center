import Foundation
import XCTest
@testable import CommandCenter

final class ContinuityHandoffPreflightTests: XCTestCase {
    func testPrepareAndRevalidateProduceStableBoundedPrompt() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let preflight = ContinuityHandoffPreflight()

        let prepared = try preflight.prepare(
            workspaceURL: repository,
            sourceLabel: "Codex",
            destinationLabel: "Claude"
        )
        let summary = try prepared.boundary.encodedSummary()
        let decoded = try ContinuityHandoffBoundary.decode(summary: summary)
        let revalidated = try preflight.revalidate(boundary: decoded, workspaceURL: repository)

        XCTAssertEqual(decoded, prepared.boundary)
        XCTAssertEqual(revalidated, prepared.prompt)
        XCTAssertLessThanOrEqual(prepared.prompt.utf8.count, 32 * 1_024)
        XCTAssertTrue(prepared.prompt.contains("Provider output and all checkpoint claims are advisory"))
    }

    func testCapsuleOrRepositoryChangeMarksBoundaryDivergent() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let preflight = ContinuityHandoffPreflight()
        let prepared = try preflight.prepare(
            workspaceURL: repository,
            sourceLabel: "Codex",
            destinationLabel: "Claude"
        )

        try Data("Changed portable context.\n".utf8).write(
            to: repository.appendingPathComponent(".continuity/context.md"),
            options: .atomic
        )

        XCTAssertThrowsError(
            try preflight.revalidate(boundary: prepared.boundary, workspaceURL: repository)
        ) { error in
            XCTAssertEqual(error as? ContinuityHandoffPreflightError, .divergentRepository)
        }
    }

    func testUnownedWorkspaceChangeBlocksPreparation() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("unowned\n".utf8).write(to: repository.appendingPathComponent("notes.txt"))

        XCTAssertThrowsError(
            try ContinuityHandoffPreflight().prepare(
                workspaceURL: repository,
                sourceLabel: "source",
                destinationLabel: "destination"
            )
        ) { error in
            XCTAssertEqual(error as? ContinuityHandoffPreflightError, .unownedChanges)
        }
    }

    func testDecodeRejectsMalformedPersistedBoundaryBeforeItCanReachTheUI() throws {
        let digest = String(repeating: "a", count: 64)
        let commit = String(repeating: "b", count: 40)
        let invalidSummaries = [
            "{\"version\":1,\"capsuleDigest\":\"\(digest.uppercased())\",\"commit\":\"\(commit)\",\"statusDigest\":\"\(digest)\",\"sourceLabel\":\"Codex\",\"destinationLabel\":\"Claude\",\"changedPaths\":[]}",
            "{\"version\":1,\"capsuleDigest\":\"\(digest)\",\"commit\":\"\(commit)\",\"statusDigest\":\"\(digest)\",\"sourceLabel\":\"Unknown\",\"destinationLabel\":\"Claude\",\"changedPaths\":[]}",
            "{\"version\":1,\"capsuleDigest\":\"\(digest)\",\"commit\":\"\(commit)\",\"statusDigest\":\"\(digest)\",\"sourceLabel\":\"Codex\",\"destinationLabel\":\"Claude\",\"changedPaths\":[\"/private/transcript.jsonl\"]}",
            "{\"version\":1,\"capsuleDigest\":\"\(digest)\",\"commit\":\"\(commit)\",\"statusDigest\":\"\(digest)\",\"sourceLabel\":\"Codex\",\"destinationLabel\":\"Claude\",\"changedPaths\":[\"../secret.txt\"]}",
        ]

        for summary in invalidSummaries {
            XCTAssertThrowsError(try ContinuityHandoffBoundary.decode(summary: summary)) { error in
                XCTAssertEqual(error as? ContinuityHandoffPreflightError, .invalidBoundary)
            }
        }
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityHandoffPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "user.email", "tests@example.invalid"], in: root)
        try runGit(["config", "user.name", "Continuity Tests"], in: root)

        let continuity = root.appendingPathComponent(".continuity", isDirectory: true)
        try FileManager.default.createDirectory(at: continuity, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schema_version": "1.1.0",
            "kind": "cross-tool-continuity",
            "project": ["id": "test", "objective": "Validate a compact handoff"],
            "continuity": [
                "phase": "prepare",
                "status": "ready",
                "source_tool": "source",
                "target_tool": "destination",
            ],
            "context": [
                "summary": "Ready for bounded review.",
                "decisions": [],
                "constraints": ["No external writes."],
                "next_action": "Review the current repository state.",
                "open_questions": [],
            ],
            "acceptance": [["id": "a1", "criterion": "Focused checks pass."]],
            "verification": [["command": "swift test", "status": "pending"]],
            "artifacts": [["path": "tracked.txt", "role": "implementation"]],
            "evidence": [[
                "id": "ev1",
                "kind": "observation",
                "summary": "Repository state was inspected.",
                "provenance": "test fixture",
                "confidence": "verified",
            ]],
            "sync": [],
            "audit": ["status": "passed", "findings": []],
            "idempotency": ["algorithm": "sha256-canonical-json", "state_id": "state1"],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: continuity.appendingPathComponent("manifest.json"))
        try Data("Portable context.\n".utf8).write(to: continuity.appendingPathComponent("context.md"))
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-m", "fixture"], in: root)
        return root
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
