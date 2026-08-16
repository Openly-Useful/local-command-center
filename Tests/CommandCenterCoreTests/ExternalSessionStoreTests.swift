import Foundation
import SQLite3
import XCTest
@testable import CommandCenterCore

final class ExternalSessionStoreTests: XCTestCase {
    func testFreshSchemaAndMetadataRoundTrip() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let session = try makeSession(
            id: uuid(1),
            providerSessionID: " codex-session ",
            workspacePath: "/tmp/project/../project",
            title: "Résumé",
            preview: "Preview 🧠",
            parentProviderSessionID: "parent-1",
            isSidechain: true,
            contentDigest: "sha256:abc"
        )

        try await store.upsertExternalSessions([session])
        let configuration = try await store.configuration()
        let loadedByID = try await store.externalSession(id: session.id)
        let loadedByIdentity = try await store.externalSession(
            provider: .codex,
            surface: .codex,
            providerSessionID: "codex-session"
        )
        let indexedCount = try await store.externalSessionCount(includeMissing: true)

        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(loadedByID, session)
        XCTAssertEqual(loadedByIdentity, session)
        XCTAssertEqual(indexedCount, 1)
        XCTAssertEqual(loadedByID?.workspacePath, "/tmp/project")
        XCTAssertEqual(SQLiteStore.defaultExternalSessionListCount, 1_000)
        XCTAssertGreaterThanOrEqual(SQLiteStore.maximumExternalSessionListCount, 5_000)
    }

    func testVersionTwoMigrationPreservesConversationAndMessages() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let workspaceID = uuid(11)
        let conversationID = uuid(12)
        let messageID = uuid(13)
        try createVersionTwoDatabase(
            at: location.database,
            workspaceID: workspaceID,
            conversationID: conversationID,
            messageID: messageID
        )

        let migrated = try SQLiteStore(databaseURL: location.database)
        let configuration = try await migrated.configuration()
        let conversation = try await migrated.conversation(id: conversationID)
        let messages = try await migrated.listMessages(conversationID: conversationID)
        let external = try makeSession(id: uuid(14), providerSessionID: "after-migration")
        try await migrated.upsertExternalSessions([external])
        let migratedExternal = try await migrated.externalSession(id: external.id)

        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(conversation?.title, "v2 conversation")
        XCTAssertEqual(conversation?.skillIDs, ["pickup-swarm"])
        XCTAssertEqual(messages.map(\.id), [messageID])
        XCTAssertEqual(migratedExternal?.id, external.id)
    }

    func testUpsertIsIdempotentByProviderSurfaceAndSessionIdentity() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let original = try makeSession(
            id: uuid(21),
            providerSessionID: "stable",
            title: "Original",
            preview: "before",
            firstSeenAt: date(10),
            lastSeenAt: date(20)
        )
        let refresh = try makeSession(
            id: uuid(22),
            providerSessionID: "stable",
            title: "Refreshed",
            preview: "after",
            firstSeenAt: date(15),
            lastSeenAt: date(30)
        )

        try await storeContext.store.upsertExternalSessions([original, refresh])
        let loaded = try await storeContext.store.externalSession(
            provider: .codex,
            surface: .codex,
            providerSessionID: "stable"
        )
        let all = try await storeContext.store.listExternalSessions(includeMissing: true)

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(loaded?.id, original.id)
        XCTAssertEqual(loaded?.title, "Refreshed")
        XCTAssertEqual(loaded?.preview, "after")
        XCTAssertEqual(loaded?.firstSeenAt, date(10))
        XCTAssertEqual(loaded?.lastSeenAt, date(30))
    }

    func testProviderAndSurfaceScopeIdentity() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let codex = try makeSession(
            id: uuid(31), provider: .codex, surface: .codex, providerSessionID: "shared"
        )
        let claude = try makeSession(
            id: uuid(32), provider: .claude, surface: .claudeCode, providerSessionID: "shared"
        )
        let crossSurface = try makeSession(
            id: uuid(33), provider: .codex, surface: .claudeCode, providerSessionID: "shared"
        )

        try await storeContext.store.upsertExternalSessions([codex, claude, crossSurface])
        let sessions = try await storeContext.store.listExternalSessions(includeMissing: true)
        XCTAssertEqual(Set(sessions.map(\.id)), Set([codex.id, claude.id, crossSurface.id]))
    }

    func testMissingTombstoneAndResurrection() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let seen = try makeSession(id: uuid(41), providerSessionID: "seen")
        let missing = try makeSession(id: uuid(42), providerSessionID: "missing")
        try await storeContext.store.upsertExternalSessions([seen, missing])

        try await storeContext.store.markExternalSessionsMissing(
            provider: .codex,
            surface: .codex,
            seenProviderSessionIDs: ["seen"],
            at: date(100)
        )
        let visibleAfterMissing = try await storeContext.store
            .listExternalSessions()
            .map(\.providerSessionID)
        let allAfterMissing = try await storeContext.store.listExternalSessions(includeMissing: true)
        let missingAfterMark = try await storeContext.store.externalSession(id: missing.id)
        XCTAssertEqual(visibleAfterMissing, ["seen"])
        XCTAssertEqual(allAfterMissing.count, 2)
        XCTAssertEqual(missingAfterMark?.missingSince, date(100))

        try await storeContext.store.markExternalSessionsMissing(
            provider: .codex,
            surface: .codex,
            seenProviderSessionIDs: ["seen", "missing"],
            at: date(200)
        )
        let seenAgain = try await storeContext.store.externalSession(id: missing.id)
        XCTAssertNil(seenAgain?.missingSince)

        try await storeContext.store.markExternalSessionsMissing(
            provider: .codex,
            surface: .codex,
            seenProviderSessionIDs: ["seen"],
            at: date(300)
        )
        var rediscovered = missing
        rediscovered = try makeSession(
            id: uuid(99),
            providerSessionID: "missing",
            title: "Rediscovered",
            lastSeenAt: date(400)
        )
        try await storeContext.store.upsertExternalSessions([rediscovered])
        let resurrected = try await storeContext.store.externalSession(id: missing.id)
        XCTAssertEqual(resurrected?.id, missing.id)
        XCTAssertEqual(resurrected?.title, "Rediscovered")
        XCTAssertNil(resurrected?.missingSince)
    }

    func testTargetedMissingMarkTouchesOnlyTheRevalidatedIdentity() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let missing = try makeSession(id: uuid(43), providerSessionID: "targeted-missing")
        let untouched = try makeSession(id: uuid(44), providerSessionID: "untouched")
        try await storeContext.store.upsertExternalSessions([missing, untouched])

        try await storeContext.store.markExternalSessionMissing(id: missing.id, at: date(500))
        try await storeContext.store.markExternalSessionMissing(id: missing.id, at: date(600))

        let markedMissing = try await storeContext.store.externalSession(id: missing.id)
        let stillAvailable = try await storeContext.store.externalSession(id: untouched.id)
        XCTAssertEqual(markedMissing?.missingSince, date(500))
        XCTAssertNil(stillAvailable?.missingSince)
    }

    func testDeterministicPagingFiltersAndBounds() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let workspace = "/tmp/paged"
        let sessions = try (0..<5).map { index in
            try makeSession(
                id: uuid(50 + index),
                providerSessionID: "page-\(index)",
                workspacePath: workspace,
                sourceModifiedAt: date(100),
                lastSeenAt: index < 3 ? date(200) : date(300)
            )
        }
        try await storeContext.store.upsertExternalSessions(Array(sessions.reversed()))

        let all = try await storeContext.store.listExternalSessions(
            provider: .codex,
            workspacePath: "/tmp/other/../paged",
            limit: Int.max
        )
        let firstPage = try await storeContext.store.listExternalSessions(limit: 2, offset: 0)
        let secondPage = try await storeContext.store.listExternalSessions(limit: 2, offset: 2)

        XCTAssertEqual(all.map(\.id), [uuid(53), uuid(54), uuid(50), uuid(51), uuid(52)])
        XCTAssertEqual(firstPage.map(\.id), [uuid(53), uuid(54)])
        XCTAssertEqual(secondPage.map(\.id), [uuid(50), uuid(51)])
        XCTAssertLessThanOrEqual(all.count, SQLiteStore.maximumExternalSessionListCount)
    }

    func testUpsertRejectsAnUnboundedProviderBatchBeforeWriting() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let session = try makeSession(providerSessionID: "bounded")
        let oversized = Array(
            repeating: session,
            count: SQLiteStore.maximumExternalSessionBatchCount + 1
        )

        await XCTAssertThrowsAsyncError {
            try await storeContext.store.upsertExternalSessions(oversized)
        }
        let persisted = try await storeContext.store.listExternalSessions(includeMissing: true)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testValidationPreservesUnicodeAndRejectsControlsAndOversize() throws {
        let unicode = try makeSession(
            providerSessionID: "séssion",
            title: " タイトル 🧠 ",
            preview: "Prévisualisation",
            providerStatus: "待機中"
        )
        XCTAssertEqual(unicode.providerSessionID, "séssion")
        XCTAssertEqual(unicode.title, "タイトル 🧠")
        XCTAssertNil(try makeSession(workspacePath: "   ").workspacePath)

        XCTAssertThrowsError(try makeSession(providerSessionID: "bad\u{0}id"))
        XCTAssertThrowsError(try makeSession(title: "\nlooks harmless after trimming"))
        XCTAssertThrowsError(
            try makeSession(title: String(repeating: "a", count: ExternalSession.maximumTitleBytes + 1))
        )
        XCTAssertThrowsError(
            try makeSession(preview: String(repeating: "p", count: ExternalSession.maximumPreviewBytes + 1))
        )
        XCTAssertThrowsError(
            try makeSession(sourcePath: "/tmp/bad\npath")
        )
    }

    func testLinkUniquenessForeignKeysAndCascade() async throws {
        let storeContext = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeContext.root) }
        let workspace = Workspace(name: "links", rootPath: "/links")
        let firstConversation = Conversation(
            id: uuid(71), workspaceID: workspace.id, title: "one", provider: .codex
        )
        let secondConversation = Conversation(
            id: uuid(72), workspaceID: workspace.id, title: "two", provider: .codex
        )
        let firstExternal = try makeSession(id: uuid(73), providerSessionID: "external-one")
        let secondExternal = try makeSession(id: uuid(74), providerSessionID: "external-two")
        try await storeContext.store.upsertWorkspace(workspace)
        try await storeContext.store.insertConversation(firstConversation)
        try await storeContext.store.insertConversation(secondConversation)
        try await storeContext.store.upsertExternalSessions([firstExternal, secondExternal])

        try await storeContext.store.linkConversation(
            conversationID: firstConversation.id,
            externalSessionID: firstExternal.id
        )
        let linkedExternal = try await storeContext.store.externalSession(
            forConversationID: firstConversation.id
        )
        let linkedConversationID = try await storeContext.store.conversationID(
            forExternalSessionID: firstExternal.id
        )
        XCTAssertEqual(linkedExternal?.id, firstExternal.id)
        XCTAssertEqual(linkedConversationID, firstConversation.id)

        try await storeContext.store.unlinkConversation(conversationID: firstConversation.id)
        let linkAfterExplicitUnlink = try await storeContext.store.conversationID(
            forExternalSessionID: firstExternal.id
        )
        XCTAssertNil(linkAfterExplicitUnlink)
        try await storeContext.store.linkConversation(
            conversationID: firstConversation.id,
            externalSessionID: firstExternal.id
        )

        try await storeContext.store.linkConversation(
            conversationID: firstConversation.id,
            externalSessionID: secondExternal.id
        )
        let releasedFirstLink = try await storeContext.store.conversationID(
            forExternalSessionID: firstExternal.id
        )
        let replacementLink = try await storeContext.store.conversationID(
            forExternalSessionID: secondExternal.id
        )
        XCTAssertNil(releasedFirstLink)
        XCTAssertEqual(replacementLink, firstConversation.id)

        await XCTAssertThrowsAsyncError {
            try await storeContext.store.linkConversation(
                conversationID: secondConversation.id,
                externalSessionID: secondExternal.id
            )
        }
        await XCTAssertThrowsAsyncError {
            try await storeContext.store.linkConversation(
                conversationID: UUID(),
                externalSessionID: firstExternal.id
            )
        }
        await XCTAssertThrowsAsyncError {
            try await storeContext.store.linkConversation(
                conversationID: secondConversation.id,
                externalSessionID: UUID()
            )
        }

        try await storeContext.store.deleteConversation(id: firstConversation.id)
        let linkAfterCascade = try await storeContext.store.conversationID(
            forExternalSessionID: secondExternal.id
        )
        XCTAssertNil(linkAfterCascade)
    }

    private func makeSession(
        id: UUID = UUID(),
        provider: ProviderKind = .codex,
        surface: ExternalSessionSurface = .codex,
        providerSessionID: String = "session",
        workspacePath: String? = "/tmp/workspace",
        title: String = "Title",
        preview: String = "Preview",
        providerStatus: String = "ready",
        canResume: Bool = true,
        canReadTranscript: Bool = true,
        sourcePath: String = "/tmp/source.jsonl",
        sourceByteCount: Int64 = 100,
        sourceModifiedAt: Date = Date(timeIntervalSince1970: 100),
        firstSeenAt: Date = Date(timeIntervalSince1970: 101),
        lastSeenAt: Date = Date(timeIntervalSince1970: 102),
        parentProviderSessionID: String? = nil,
        isSidechain: Bool = false,
        contentDigest: String? = nil,
        missingSince: Date? = nil
    ) throws -> ExternalSession {
        try ExternalSession(
            id: id,
            provider: provider,
            surface: surface,
            providerSessionID: providerSessionID,
            workspacePath: workspacePath,
            title: title,
            preview: preview,
            providerStatus: providerStatus,
            canResume: canResume,
            canReadTranscript: canReadTranscript,
            sourcePath: sourcePath,
            sourceByteCount: sourceByteCount,
            sourceModifiedAt: sourceModifiedAt,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            parentProviderSessionID: parentProviderSessionID,
            isSidechain: isSidechain,
            contentDigest: contentDigest,
            missingSince: missingSince
        )
    }

    private func makeStore() throws -> (root: URL, store: SQLiteStore) {
        let location = makeDatabaseLocation()
        return (location.root, try SQLiteStore(databaseURL: location.database))
    }

    private func makeDatabaseLocation() -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-session-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("private/index.sqlite"))
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "70000000-0000-0000-0000-%012d", number))!
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func createVersionTwoDatabase(
        at databaseURL: URL,
        workspaceID: UUID,
        conversationID: UUID,
        messageID: UUID
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, root_path TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            title TEXT NOT NULL, provider TEXT NOT NULL, workflow TEXT NOT NULL,
            permission_mode TEXT NOT NULL, status TEXT NOT NULL, provider_session_id TEXT,
            skill_ids TEXT NOT NULL DEFAULT '[]'
                CHECK(length(CAST(skill_ids AS BLOB)) <= 32768),
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE INDEX conversations_workspace_updated
            ON conversations(workspace_id, updated_at DESC, created_at DESC, id ASC);
        CREATE TABLE messages (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL, content TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK(sequence >= 0), created_at REAL NOT NULL,
            UNIQUE(conversation_id, sequence)
        );
        CREATE INDEX messages_conversation_sequence
            ON messages(conversation_id, sequence ASC, id ASC);
        INSERT INTO workspaces VALUES (
            '\(workspaceID.uuidString)', 'v2 workspace', '/v2', 100, 101
        );
        INSERT INTO conversations VALUES (
            '\(conversationID.uuidString)', '\(workspaceID.uuidString)', 'v2 conversation',
            'codex', 'interactive', 'readOnly', 'completed', 'legacy-v2',
            '["pickup-swarm"]', 102, 103
        );
        INSERT INTO messages VALUES (
            '\(messageID.uuidString)', '\(conversationID.uuidString)', 'assistant',
            'v2 message', 0, 104
        );
        PRAGMA user_version = 2;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail("Failed to create v2 fixture: \(message)")
            throw POSIXError(.EIO)
        }
    }
}

private func XCTAssertThrowsAsyncError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
