import CommandCenterCore
import Foundation
import SQLite3
import XCTest
@testable import CommandCenter

final class LocalHistorySourceTests: XCTestCase {
    func testClaudeCacheExclusionsAndChangedRefresh() async throws {
        let fixture = try TemporaryHistoryFixture()
        let project = fixture.root.appendingPathComponent("claude/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "11111111-1111-4111-8111-111111111111"
        let source = project.appendingPathComponent("\(id).jsonl")
        try fixture.writeLines([
            #"{"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","uuid":"21111111-1111-4111-8111-111111111111","timestamp":"2026-01-02T00:00:00Z","message":{"content":"first visible"}}"#,
            #"{"type":"ai-title","sessionId":"11111111-1111-4111-8111-111111111111","aiTitle":"AI title"}"#,
            #"{"type":"custom-title","sessionId":"11111111-1111-4111-8111-111111111111","customTitle":"Custom title"}"#,
        ], to: source)
        try fixture.writeLines([#"{"type":"user"}"#], to: project.appendingPathComponent("agent-\(id).jsonl"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try fixture.writeLines([#"{"type":"user"}"#], to: project.appendingPathComponent("nested/\(id).jsonl"))

        let adapter = ClaudeLocalHistorySource(projectsRootURL: fixture.root.appendingPathComponent("claude"))
        let first = await adapter.scan()
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions[0].title, "Custom title")
        XCTAssertGreaterThan(first.metrics.bytesRead, 0)

        let unchanged = await adapter.scan()
        XCTAssertEqual(unchanged.metrics.filesRead, 0)
        XCTAssertEqual(unchanged.metrics.bytesRead, 0)
        XCTAssertEqual(unchanged.sessions[0].id, first.sessions[0].id)
        XCTAssertEqual(unchanged.sessions[0].contentDigest, first.sessions[0].contentDigest)

        try fixture.appendLine(
            #"{"type":"last-prompt","sessionId":"11111111-1111-4111-8111-111111111111","lastPrompt":"changed"}"#,
            to: source
        )
        let changed = await adapter.scan()
        XCTAssertEqual(changed.metrics.filesRead, 1)
        XCTAssertGreaterThan(changed.metrics.bytesRead, 0)
        XCTAssertNotEqual(changed.sessions[0].contentDigest, first.sessions[0].contentDigest)
    }

    func testTranscriptReaderEnforcesContainmentAndNewestBounds() async throws {
        let fixture = try TemporaryHistoryFixture()
        let root = fixture.root.appendingPathComponent("claude", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "31111111-1111-4111-8111-111111111111"
        let source = project.appendingPathComponent("\(id).jsonl")
        var lines: [String] = []
        for index in 0..<70 {
            let recordID = String(format: "41111111-1111-4111-8111-%012d", index)
            let minute = String(format: "%02d", index / 60)
            let second = String(format: "%02d", index % 60)
            let object: [String: Any] = [
                "type": "user",
                "sessionId": id,
                "uuid": recordID,
                "timestamp": "2026-01-02T00:\(minute):\(second)Z",
                "message": ["content": "message-\(index)"],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try fixture.writeLines(lines, to: source)
        let session = try fixture.session(id: id, provider: .claude, surface: .claudeCode, source: source)
        let transcript = await LocalTranscriptReader(
            codexRolloutRoots: [], claudeProjectsRoot: root
        ).read(session: session, limits: .init(messageCount: 50, readBytes: 2 * 1_048_576))
        XCTAssertEqual(transcript.rows.count, 50)
        XCTAssertEqual(transcript.rows.first?.text, "message-20")
        XCTAssertEqual(transcript.rows.last?.text, "message-69")
        XCTAssertTrue(transcript.wasTruncated)

        let outside = fixture.root.appendingPathComponent("outside/\(id).jsonl")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.writeLines(lines, to: outside)
        let tampered = try fixture.session(id: id, provider: .claude, surface: .claudeCode, source: outside)
        let rejected = await LocalTranscriptReader(
            codexRolloutRoots: [], claudeProjectsRoot: root
        ).read(session: tampered)
        XCTAssertTrue(rejected.rows.isEmpty)
        XCTAssertEqual(rejected.bytesRead, 0)
    }

    func testTranscriptReaderAcceptsTimestampPrefixedCodexRollout() async throws {
        let fixture = try TemporaryHistoryFixture()
        let rolloutRoot = fixture.root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutRoot, withIntermediateDirectories: true)
        let id = "41111111-1111-4111-8111-111111111111"
        let source = rolloutRoot.appendingPathComponent(
            "rollout-2026-08-13T17-00-00-\(id).jsonl"
        )
        let record: [String: Any] = [
            "timestamp": "2026-08-13T17:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "id": "provider-record-1",
                "content": [["type": "output_text", "text": "visible Codex response"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try fixture.writeLines([String(decoding: data, as: UTF8.self)], to: source)

        let session = try fixture.session(
            id: id,
            provider: .codex,
            surface: .codex,
            source: source
        )
        let transcript = await LocalTranscriptReader(
            codexRolloutRoots: [rolloutRoot],
            claudeProjectsRoot: fixture.root.appendingPathComponent("claude")
        ).read(session: session)

        XCTAssertEqual(transcript.rows.map(\.text), ["visible Codex response"])
        XCTAssertEqual(transcript.rows.first?.providerRecordID, "provider-record-1")
        XCTAssertGreaterThan(transcript.bytesRead, 0)
        XCTAssertTrue(transcript.diagnostics.isEmpty)
    }

    func testTranscriptFallbackIdentityKeepsDuplicateIdlessRowsUnique() async throws {
        let fixture = try TemporaryHistoryFixture()
        let rolloutRoot = fixture.root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutRoot, withIntermediateDirectories: true)
        let id = "42111111-1111-4111-8111-111111111111"
        let source = rolloutRoot.appendingPathComponent("\(id).jsonl")
        let record: [String: Any] = [
            "timestamp": "2026-08-13T17:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "same visible response"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self)
        try fixture.writeLines([line, line], to: source)
        let session = try fixture.session(
            id: id, provider: .codex, surface: .codex, source: source
        )

        let transcript = await LocalTranscriptReader(
            codexRolloutRoots: [rolloutRoot],
            claudeProjectsRoot: fixture.root.appendingPathComponent("claude")
        ).read(session: session)

        XCTAssertEqual(transcript.rows.count, 2)
        XCTAssertEqual(Set(transcript.rows.map(\.id)).count, 2)
        XCTAssertTrue(transcript.rows.allSatisfy { $0.providerRecordID == nil })
    }

    func testCodexRevalidationFindsRelocationAndProvesCompleteAbsence() async throws {
        let fixture = try TemporaryHistoryFixture()
        let active = fixture.root.appendingPathComponent("active", isDirectory: true)
        let archived = fixture.root.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "43111111-1111-4111-8111-111111111111"
        let original = active.appendingPathComponent("\(id).jsonl")
        try fixture.writeLines([], to: original)
        let staleSession = try fixture.session(
            id: id, provider: .codex, surface: .codex, source: original
        )
        let relocated = archived.appendingPathComponent(
            "rollout-2026-08-13T17-00-00-\(id).jsonl"
        )
        try FileManager.default.moveItem(at: original, to: relocated)
        let adapter = CodexLocalHistorySource(
            databaseURL: fixture.root.appendingPathComponent("missing.sqlite"),
            rolloutRootURLs: [active, archived]
        )

        let available = await adapter.revalidate(session: staleSession)
        XCTAssertEqual(available.state, .available)
        XCTAssertTrue(available.permitsResume)
        XCTAssertEqual(available.refreshedSession?.sourcePath, relocated.path)

        try FileManager.default.removeItem(at: relocated)
        let unavailable = await adapter.revalidate(session: staleSession)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertFalse(unavailable.permitsResume)
        XCTAssertNil(unavailable.refreshedSession)
    }

    func testClaudeRevalidationFindsDirectParentRelocationAndAbsence() async throws {
        let fixture = try TemporaryHistoryFixture()
        let root = fixture.root.appendingPathComponent("claude", isDirectory: true)
        let firstProject = root.appendingPathComponent("first", isDirectory: true)
        let secondProject = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        let id = "44111111-1111-4111-8111-111111111111"
        let original = firstProject.appendingPathComponent("\(id).jsonl")
        try fixture.writeLines([], to: original)
        let staleSession = try fixture.session(
            id: id, provider: .claude, surface: .claudeCode, source: original
        )
        let relocated = secondProject.appendingPathComponent("\(id).jsonl")
        try FileManager.default.moveItem(at: original, to: relocated)
        let adapter = ClaudeLocalHistorySource(projectsRootURL: root)

        let available = await adapter.revalidate(session: staleSession)
        XCTAssertEqual(available.state, .available)
        XCTAssertTrue(available.permitsResume)
        XCTAssertEqual(available.refreshedSession?.sourcePath, relocated.path)

        try FileManager.default.removeItem(at: relocated)
        let unavailable = await adapter.revalidate(session: staleSession)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertFalse(unavailable.permitsResume)
    }

    func testCodexReadOnlyMetadataStableIdentityAndParent() async throws {
        let fixture = try TemporaryHistoryFixture()
        let database = fixture.root.appendingPathComponent("state.sqlite")
        let rollouts = fixture.root.appendingPathComponent("rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let parent = "51111111-1111-4111-8111-111111111111"
        let child = "61111111-1111-4111-8111-111111111111"
        let rollout = rollouts.appendingPathComponent("\(child).jsonl")
        try fixture.writeLines([], to: rollout)
        try fixture.makeCodexDatabase(database, rollout: rollout, child: child, parent: parent)

        let walURL = URL(fileURLWithPath: database.path + "-wal")
        let shmURL = URL(fileURLWithPath: database.path + "-shm")
        let walSentinel = Data("provider-wal-sentinel".utf8)
        let shmSentinel = Data("provider-shm-sentinel".utf8)
        try walSentinel.write(to: walURL)
        try shmSentinel.write(to: shmURL)
        let databaseBefore = try fixture.fileSnapshot(database)
        let walBefore = try fixture.fileSnapshot(walURL)
        let shmBefore = try fixture.fileSnapshot(shmURL)

        let adapter = CodexLocalHistorySource(databaseURL: database, rolloutRootURLs: [rollouts])
        let first = await adapter.scan()
        let second = await adapter.scan()
        XCTAssertFalse(first.authoritative)
        XCTAssertTrue(first.diagnostics.contains { $0.code == "codex-immutable-state-view" })
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions[0].providerSessionID, child)
        XCTAssertEqual(first.sessions[0].parentProviderSessionID, parent)
        XCTAssertTrue(first.sessions[0].isSidechain)
        XCTAssertEqual(first.sessions[0].id, second.sessions[0].id)
        XCTAssertEqual(first.metrics.bytesRead, 0)
        XCTAssertEqual(first.metrics.filesRead, 0)
        XCTAssertEqual(try fixture.fileSnapshot(database), databaseBefore)
        XCTAssertEqual(try fixture.fileSnapshot(walURL), walBefore)
        XCTAssertEqual(try fixture.fileSnapshot(shmURL), shmBefore)
    }

    func testClaudeAndCodexSessionCapsAreNewestFirstAndNonAuthoritative() async throws {
        XCTAssertEqual(ClaudeLocalHistorySource.maximumAcceptedSessionCount, 5_000)
        XCTAssertEqual(CodexLocalHistorySource.maximumAcceptedSessionCount, 5_000)

        let fixture = try TemporaryHistoryFixture()
        let claudeRoot = fixture.root.appendingPathComponent("claude", isDirectory: true)
        let project = claudeRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claudeIDs = [
            "71111111-1111-4111-8111-111111111111",
            "71111111-1111-4111-8111-111111111112",
            "71111111-1111-4111-8111-111111111113",
        ]
        for (index, id) in claudeIDs.enumerated() {
            let url = project.appendingPathComponent("\(id).jsonl")
            try fixture.writeLines([
                "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"timestamp\":\"2026-01-0\(index + 1)T00:00:00Z\",\"message\":{\"content\":\"fixture\"}}",
            ], to: url)
            try fixture.setModifiedAt(
                Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                for: url
            )
        }
        let claude = ClaudeLocalHistorySource(
            projectsRootURL: claudeRoot,
            maximumAcceptedSessions: 2
        )
        let claudeSnapshot = await claude.scan()
        XCTAssertEqual(claudeSnapshot.sessions.map(\.providerSessionID), Array(claudeIDs.reversed().prefix(2)))
        XCTAssertEqual(claudeSnapshot.sessions.count, 2)
        let cachedClaudeSessionCount = await claude.cacheEntryCount()
        XCTAssertEqual(cachedClaudeSessionCount, 2)
        XCTAssertFalse(claudeSnapshot.authoritative)
        XCTAssertTrue(claudeSnapshot.diagnostics.contains { $0.code == "claude-session-limit-reached" })

        let database = fixture.root.appendingPathComponent("capped-state.sqlite")
        let codexIDs = [
            "81111111-1111-4111-8111-111111111111",
            "81111111-1111-4111-8111-111111111112",
            "81111111-1111-4111-8111-111111111113",
        ]
        let codexRolloutRoot = fixture.root.appendingPathComponent(
            "codex-rollouts", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexRolloutRoot,
            withIntermediateDirectories: true
        )
        var codexRows: [(id: String, rollout: URL, updatedAtMilliseconds: Int64)] = []
        for (index, id) in codexIDs.enumerated() {
            let rollout = codexRolloutRoot.appendingPathComponent("\(id).jsonl")
            try fixture.writeLines([], to: rollout)
            let timestamp = Int64(1_700_000_000 + index)
            try fixture.setModifiedAt(Date(timeIntervalSince1970: Double(timestamp)), for: rollout)
            codexRows.append(
                (id: id, rollout: rollout, updatedAtMilliseconds: timestamp * 1_000)
            )
        }
        try fixture.makeCodexDatabase(database, rows: codexRows)
        let codex = CodexLocalHistorySource(
            databaseURL: database,
            rolloutRootURLs: [codexRolloutRoot],
            maximumAcceptedSessions: 2,
            maximumDatabaseRows: 2
        )
        let codexSnapshot = await codex.scan()
        XCTAssertEqual(codexSnapshot.sessions.map(\.providerSessionID), Array(codexIDs.reversed().prefix(2)))
        XCTAssertEqual(codexSnapshot.sessions.count, 2)
        XCTAssertFalse(codexSnapshot.authoritative)
        XCTAssertTrue(codexSnapshot.diagnostics.contains { $0.code == "codex-session-limit-reached" })
        XCTAssertTrue(codexSnapshot.diagnostics.contains {
            $0.code == "codex-database-row-limit-reached"
        })
        XCTAssertEqual(codexSnapshot.metrics.rowsConsidered, 2)
    }

    func testCodexImmutableDatabaseMergesRolloutOnlySession() async throws {
        let fixture = try TemporaryHistoryFixture()
        let database = fixture.root.appendingPathComponent("state.sqlite")
        let rollouts = fixture.root.appendingPathComponent("rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let databaseID = "91111111-1111-4111-8111-111111111111"
        let rolloutOnlyID = "91111111-1111-4111-8111-111111111112"
        let databaseRollout = rollouts.appendingPathComponent("\(databaseID).jsonl")
        try fixture.writeLines([], to: databaseRollout)
        try fixture.makeCodexDatabase(
            database,
            rows: [(databaseID, databaseRollout, 1_000)]
        )

        let liveRollout = rollouts.appendingPathComponent(
            "rollout-2026-08-13T17-00-00-\(rolloutOnlyID).jsonl"
        )
        let metadata: [String: Any] = [
            "timestamp": "2026-08-13T17:00:00Z",
            "type": "session_meta",
            "payload": [
                "id": rolloutOnlyID,
                "cwd": fixture.root.path,
            ],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try fixture.writeLines([String(decoding: metadataData, as: UTF8.self)], to: liveRollout)

        let snapshot = await CodexLocalHistorySource(
            databaseURL: database,
            rolloutRootURLs: [rollouts]
        ).scan()
        XCTAssertEqual(
            Set(snapshot.sessions.map(\.providerSessionID)),
            Set([databaseID, rolloutOnlyID])
        )
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == "codex-rollout-supplement" })
        XCTAssertEqual(snapshot.metrics.filesRead, 1)
        XCTAssertGreaterThan(snapshot.metrics.bytesRead, 0)
        XCTAssertFalse(snapshot.authoritative)
    }

    func testCodexRejectsOversizedSQLiteTextBeforeConversionAndContinues() async throws {
        let fixture = try TemporaryHistoryFixture()
        let database = fixture.root.appendingPathComponent("oversized.sqlite")
        let validID = "a1111111-1111-4111-8111-111111111111"
        let oversizedID = "a1111111-1111-4111-8111-111111111112"
        let rolloutRoot = fixture.root.appendingPathComponent("rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutRoot, withIntermediateDirectories: true)
        let validRollout = rolloutRoot.appendingPathComponent("\(validID).jsonl")
        try fixture.writeLines([], to: validRollout)
        let oversizedPath = "/" + String(
            repeating: "x",
            count: ExternalSession.maximumPathBytes + 1
        )
        try fixture.makeCodexDatabase(
            database,
            rawRows: [
                (id: oversizedID, rolloutPath: oversizedPath, updatedAtMilliseconds: 2_000),
                (id: validID, rolloutPath: validRollout.path, updatedAtMilliseconds: 1_000),
            ]
        )

        let snapshot = await CodexLocalHistorySource(
            databaseURL: database,
            rolloutRootURLs: [rolloutRoot]
        ).scan()
        XCTAssertEqual(snapshot.sessions.map(\.providerSessionID), [validID])
        XCTAssertEqual(snapshot.metrics.rowsConsidered, 2)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == "codex-invalid-rollout-path" })
    }

    func testCodexDatabaseRejectsOutsideSymlinkAndMismatchedRolloutPaths() async throws {
        let fixture = try TemporaryHistoryFixture()
        let database = fixture.root.appendingPathComponent("untrusted.sqlite")
        let trustedRoot = fixture.root.appendingPathComponent("trusted", isDirectory: true)
        let outsideRoot = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let validID = "b1111111-1111-4111-8111-111111111111"
        let outsideID = "b1111111-1111-4111-8111-111111111112"
        let symlinkID = "b1111111-1111-4111-8111-111111111113"
        let mismatchedRowID = "b1111111-1111-4111-8111-111111111114"
        let mismatchedFilenameID = "b1111111-1111-4111-8111-111111111115"
        let valid = trustedRoot.appendingPathComponent("\(validID).jsonl")
        let outside = outsideRoot.appendingPathComponent("\(outsideID).jsonl")
        let symlinkTarget = outsideRoot.appendingPathComponent("target.jsonl")
        let symlink = trustedRoot.appendingPathComponent("\(symlinkID).jsonl")
        let mismatched = trustedRoot.appendingPathComponent("\(mismatchedFilenameID).jsonl")
        try fixture.writeLines([], to: valid)
        try fixture.writeLines([], to: outside)
        try fixture.writeLines([], to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)
        try fixture.writeLines([], to: mismatched)
        try fixture.makeCodexDatabase(
            database,
            rawRows: [
                (validID, valid.path, 4_000),
                (outsideID, outside.path, 3_000),
                (symlinkID, symlink.path, 2_000),
                (mismatchedRowID, mismatched.path, 1_000),
            ]
        )

        let snapshot = await CodexLocalHistorySource(
            databaseURL: database,
            rolloutRootURLs: [trustedRoot]
        ).scan()
        let IDs = Set(snapshot.sessions.map(\.providerSessionID))
        XCTAssertTrue(IDs.contains(validID))
        // A trusted rollout supplement may surface the file under its own
        // identity, but never under the mismatched DB-controlled identity.
        XCTAssertTrue(IDs.contains(mismatchedFilenameID))
        XCTAssertFalse(IDs.contains(outsideID))
        XCTAssertFalse(IDs.contains(symlinkID))
        XCTAssertFalse(IDs.contains(mismatchedRowID))
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == "codex-untrusted-rollout-path" })
        XCTAssertGreaterThanOrEqual(snapshot.metrics.skippedEntries, 3)
    }

    func testClaudeDirectoryEnumerationHasHardEntryCeiling() async throws {
        let fixture = try TemporaryHistoryFixture()
        let root = fixture.root.appendingPathComponent("claude", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "c1111111-1111-4111-8111-111111111111"
        try fixture.writeLines([
            "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"message\":{\"content\":\"fixture\"}}",
        ], to: project.appendingPathComponent("\(id).jsonl"))

        let snapshot = await ClaudeLocalHistorySource(
            projectsRootURL: root,
            maximumDirectoryEntries: 1
        ).scan()

        XCTAssertFalse(snapshot.authoritative)
        XCTAssertEqual(snapshot.metrics.filesRead, 0)
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.code == "claude-directory-entry-limit-reached"
        })
    }

    func testCodexRolloutCeilingCountsEveryFilesystemEntry() async throws {
        let fixture = try TemporaryHistoryFixture()
        let root = fixture.root.appendingPathComponent("rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture.writeLines([], to: root.appendingPathComponent("first.txt"))
        try fixture.writeLines([], to: root.appendingPathComponent("second.txt"))
        let snapshot = await CodexLocalHistorySource(
            databaseURL: fixture.root.appendingPathComponent("missing.sqlite"),
            rolloutRootURLs: [root],
            maximumRevalidationEntries: 1
        ).scan()

        XCTAssertFalse(snapshot.authoritative)
        XCTAssertEqual(snapshot.metrics.filesConsidered, 0)
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.code == "codex-rollout-entry-limit-reached"
        })
    }
}

private final class TemporaryHistoryFixture {
    struct FileSnapshot: Equatable {
        var data: Data
        var size: Int64
        var modifiedAt: Date
    }

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeLines(_ lines: [String], to url: URL) throws {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }

    func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func setModifiedAt(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func fileSnapshot(_ url: URL) throws -> FileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileSnapshot(
            data: try Data(contentsOf: url),
            size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    func session(
        id: String,
        provider: ProviderKind,
        surface: ExternalSessionSurface,
        source: URL
    ) throws -> ExternalSession {
        let metadata = LocalHistoryUtilities.fileMetadata(source)
        return try ExternalSession(
            id: LocalHistoryUtilities.stableSessionID(provider: provider, sessionID: id),
            provider: provider,
            surface: surface,
            providerSessionID: id,
            title: "Fixture",
            preview: "",
            providerStatus: "available",
            canResume: true,
            canReadTranscript: true,
            sourcePath: source.path,
            sourceByteCount: metadata.size,
            sourceModifiedAt: metadata.modifiedAt,
            firstSeenAt: metadata.modifiedAt,
            lastSeenAt: metadata.modifiedAt
        )
    }

    func makeCodexDatabase(_ url: URL, rollout: URL, child: String, parent: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close_v2(database) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER,
          updated_at INTEGER, source TEXT, cwd TEXT, title TEXT, archived INTEGER,
          archived_at INTEGER, first_user_message TEXT, created_at_ms INTEGER,
          updated_at_ms INTEGER, thread_source TEXT, preview TEXT, recency_at INTEGER,
          recency_at_ms INTEGER, name TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
        INSERT INTO threads VALUES ('\(child)', '\(rollout.path)', 1, 2, 'cli', '/tmp',
          'Title', 0, NULL, 'First', 1000, 2000, 'cli', 'Preview', 2, 2000, 'Name');
        INSERT INTO thread_spawn_edges VALUES ('\(parent)', '\(child)');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2)
        }
    }

    func makeCodexDatabase(
        _ url: URL,
        rows: [(id: String, rollout: URL, updatedAtMilliseconds: Int64)]
    ) throws {
        try makeCodexDatabase(
            url,
            rawRows: rows.map {
                (id: $0.id, rolloutPath: $0.rollout.path, updatedAtMilliseconds: $0.updatedAtMilliseconds)
            }
        )
    }

    func makeCodexDatabase(
        _ url: URL,
        rawRows: [(id: String, rolloutPath: String, updatedAtMilliseconds: Int64)]
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw NSError(domain: "fixture", code: 3) }
        defer { sqlite3_close_v2(database) }
        let schema = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER,
          updated_at INTEGER, source TEXT, cwd TEXT, title TEXT, archived INTEGER,
          archived_at INTEGER, first_user_message TEXT, created_at_ms INTEGER,
          updated_at_ms INTEGER, thread_source TEXT, preview TEXT, recency_at INTEGER,
          recency_at_ms INTEGER, name TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 4)
        }
        for row in rawRows {
            let sql = """
            INSERT INTO threads VALUES ('\(row.id)', '\(row.rolloutPath)', 1,
              \(row.updatedAtMilliseconds / 1_000), 'cli', '/tmp', 'Title', 0,
              NULL, 'First', 1000, \(row.updatedAtMilliseconds), 'cli', 'Preview',
              \(row.updatedAtMilliseconds / 1_000), \(row.updatedAtMilliseconds), 'Name');
            """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "fixture", code: 5)
            }
        }
    }
}
