import Foundation
import SQLite3
import XCTest
@testable import CommandCenterCore

final class ContinuityStoreTests: XCTestCase {
    func testContinuityModelsAreCanonicalBoundedAndCodable() throws {
        let time = date(100)
        let project = try ContinuityProject(
            id: uuid(1),
            workspaceID: uuid(2),
            name: "  Re\u{301}sume\u{301} continuity  ",
            summary: "  App-authored local summary.  ",
            createdAt: time,
            updatedAt: time
        )
        let link = try ContinuitySessionLink(
            id: uuid(3),
            projectID: project.id,
            conversationID: uuid(4),
            kind: .primary,
            createdAt: time,
            updatedAt: time
        )
        let handoff = try ContinuityHandoff(
            id: uuid(5),
            projectID: project.id,
            sourceSessionLinkID: link.id,
            title: "  Review handoff  ",
            summary: "  Run the focused tests before accepting.  ",
            state: .ready,
            createdAt: time,
            updatedAt: time
        )
        let event = try ContinuityEvent(
            id: uuid(6),
            projectID: project.id,
            sessionLinkID: link.id,
            handoffID: handoff.id,
            kind: .handoffCreated,
            detail: "  Handoff prepared.  ",
            occurredAt: time
        )
        let transaction = try ContinuitySyncTransaction(
            id: uuid(7),
            projectID: project.id,
            kind: .manual,
            state: .succeeded,
            attempt: 1,
            startedAt: date(101),
            completedAt: date(102),
            createdAt: time,
            updatedAt: date(102),
            revision: 2
        )

        let payload = try JSONEncoder().encode([project, project])
        XCTAssertEqual(try JSONDecoder().decode([ContinuityProject].self, from: payload), [project, project])
        XCTAssertEqual(project.name, "Résumé continuity")
        XCTAssertEqual(project.summary, "App-authored local summary.")
        XCTAssertEqual(handoff.title, "Review handoff")
        XCTAssertEqual(handoff.summary, "Run the focused tests before accepting.")
        XCTAssertEqual(event.detail, "Handoff prepared.")
        XCTAssertEqual(transaction.completedAt, date(102))

        XCTAssertThrowsError(try ContinuitySessionLink(projectID: project.id))
        XCTAssertThrowsError(
            try ContinuityProject(workspaceID: uuid(8), name: "bad\u{0}name")
        )
        XCTAssertThrowsError(
            try ContinuityHandoff(
                projectID: project.id,
                sourceSessionLinkID: link.id,
                title: "Handoff",
                summary: String(repeating: "x", count: ContinuityHandoff.maximumSummaryBytes + 1)
            )
        )
        XCTAssertThrowsError(
            try ContinuitySyncTransaction(
                projectID: project.id,
                kind: .automatic,
                state: .succeeded
            )
        )
    }

    func testContinuityCRUDAndCASWriterLease() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let workspace = Workspace(
            id: uuid(10),
            name: "continuity",
            rootPath: "/continuity",
            createdAt: date(10),
            updatedAt: date(10)
        )
        let conversation = Conversation(
            id: uuid(11),
            workspaceID: workspace.id,
            title: "app conversation",
            provider: .codex,
            createdAt: date(11),
            updatedAt: date(11)
        )
        let external = try makeExternalSession(id: uuid(12))
        try await store.upsertWorkspace(workspace)
        try await store.insertConversation(conversation)
        try await store.upsertExternalSessions([external])

        let project = try ContinuityProject(
            id: uuid(13),
            workspaceID: workspace.id,
            name: "Continuity",
            summary: "Local only",
            createdAt: date(20),
            updatedAt: date(21)
        )
        let conversationLink = try ContinuitySessionLink(
            id: uuid(14),
            projectID: project.id,
            conversationID: conversation.id,
            kind: .primary,
            createdAt: date(22),
            updatedAt: date(22)
        )
        let externalLink = try ContinuitySessionLink(
            id: uuid(15),
            projectID: project.id,
            externalSessionID: external.id,
            kind: .successor,
            createdAt: date(23),
            updatedAt: date(23)
        )
        let handoff = try ContinuityHandoff(
            id: uuid(16),
            projectID: project.id,
            sourceSessionLinkID: conversationLink.id,
            destinationSessionLinkID: externalLink.id,
            title: "Implementation handoff",
            summary: "Check changed files and focused test output.",
            state: .ready,
            createdAt: date(24),
            updatedAt: date(25)
        )
        let event = try ContinuityEvent(
            id: uuid(17),
            projectID: project.id,
            sessionLinkID: conversationLink.id,
            handoffID: handoff.id,
            kind: .handoffCreated,
            detail: "Implementation handoff is ready.",
            occurredAt: date(26)
        )
        let transaction = try ContinuitySyncTransaction(
            id: uuid(18),
            projectID: project.id,
            kind: .automatic,
            state: .pending,
            attempt: 1,
            createdAt: date(27),
            updatedAt: date(27)
        )

        try await store.upsertContinuityProject(project)
        try await store.upsertContinuitySessionLink(conversationLink)
        try await store.upsertContinuitySessionLink(externalLink)
        try await store.upsertContinuityHandoff(handoff)
        try await store.insertContinuityEvent(event)
        try await store.upsertContinuitySyncTransaction(transaction)

        let loadedProject = try await store.continuityProject(id: project.id)
        let projectIDs = try await store.listContinuityProjects(workspaceID: workspace.id).map(\.id)
        let loadedConversationLink = try await store.continuitySessionLink(id: conversationLink.id)
        let linkIDs = try await store.listContinuitySessionLinks(projectID: project.id).map(\.id)
        let loadedHandoff = try await store.continuityHandoff(id: handoff.id)
        let handoffs = try await store.listContinuityHandoffs(projectID: project.id)
        let loadedEvent = try await store.continuityEvent(id: event.id)
        let events = try await store.listContinuityEvents(projectID: project.id)
        let loadedTransaction = try await store.continuitySyncTransaction(id: transaction.id)

        XCTAssertEqual(loadedProject, project)
        XCTAssertEqual(
            projectIDs,
            [project.id]
        )
        XCTAssertEqual(loadedConversationLink, conversationLink)
        XCTAssertEqual(
            linkIDs,
            [externalLink.id, conversationLink.id]
        )
        XCTAssertEqual(loadedHandoff, handoff)
        XCTAssertEqual(handoffs, [handoff])
        XCTAssertEqual(loadedEvent, event)
        XCTAssertEqual(events, [event])
        XCTAssertEqual(loadedTransaction, transaction)

        let owner = uuid(19)
        let otherOwner = uuid(20)
        let acquiredLease = try await store.acquireContinuitySyncWriterLease(
            transactionID: transaction.id,
            ownerID: owner,
            now: date(30),
            duration: 60
        )
        let lease = try XCTUnwrap(acquiredLease)
        XCTAssertEqual(lease.ownerID, owner)
        XCTAssertEqual(lease.expiresAt, date(90))
        XCTAssertEqual(lease.revision, 1)
        let deniedLease = try await store.acquireContinuitySyncWriterLease(
            transactionID: transaction.id,
            ownerID: otherOwner,
            now: date(31),
            duration: 60
        )
        let rejectedCompletion = try await store.completeContinuitySyncTransaction(
            transactionID: transaction.id,
            ownerID: otherOwner,
            state: .succeeded,
            at: date(32)
        )
        let acceptedCompletion = try await store.completeContinuitySyncTransaction(
            transactionID: transaction.id,
            ownerID: owner,
            state: .succeeded,
            at: date(32)
        )
        let completedTransaction = try await store.continuitySyncTransaction(id: transaction.id)
        let completed = try XCTUnwrap(completedTransaction)
        XCTAssertNil(deniedLease)
        XCTAssertFalse(rejectedCompletion)
        XCTAssertTrue(acceptedCompletion)
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.startedAt, date(30))
        XCTAssertEqual(completed.completedAt, date(32))
        XCTAssertEqual(completed.revision, 2)
    }

    func testVersionThreeMigrationPreservesExistingProviderLinksAndCreatesContinuityTables() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let workspaceID = uuid(30)
        let conversationID = uuid(31)
        let externalID = uuid(32)
        try createVersionThreeDatabase(
            at: location.database,
            workspaceID: workspaceID,
            conversationID: conversationID,
            externalID: externalID
        )

        let store = try SQLiteStore(databaseURL: location.database)
        let configuration = try await store.configuration()
        let conversation = try await store.conversation(id: conversationID)
        let external = try await store.externalSession(forConversationID: conversationID)
        let project = try ContinuityProject(
            id: uuid(33),
            workspaceID: workspaceID,
            name: "Migrated continuity",
            createdAt: date(200),
            updatedAt: date(200)
        )
        try await store.upsertContinuityProject(project)

        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(conversation?.title, "v3 conversation")
        XCTAssertEqual(external?.id, externalID)
        let migratedProject = try await store.continuityProject(id: project.id)
        XCTAssertEqual(migratedProject, project)
    }

    private func makeExternalSession(id: UUID) throws -> ExternalSession {
        try ExternalSession(
            id: id,
            provider: .claude,
            surface: .claudeCode,
            providerSessionID: "continuity-external",
            workspacePath: "/continuity",
            title: "Provider session",
            preview: "Metadata only",
            providerStatus: "completed",
            canResume: true,
            canReadTranscript: true,
            sourcePath: "/private/continuity.jsonl",
            sourceByteCount: 64,
            sourceModifiedAt: date(10),
            firstSeenAt: date(11),
            lastSeenAt: date(12)
        )
    }

    private func createVersionThreeDatabase(
        at databaseURL: URL,
        workspaceID: UUID,
        conversationID: UUID,
        externalID: UUID
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
        CREATE TABLE external_sessions (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL, surface TEXT NOT NULL,
            provider_session_id TEXT NOT NULL
                CHECK(length(CAST(provider_session_id AS BLOB)) BETWEEN 1 AND 1024),
            workspace_path TEXT
                CHECK(workspace_path IS NULL OR length(CAST(workspace_path AS BLOB)) <= 16384),
            title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) <= 1024),
            preview TEXT NOT NULL CHECK(length(CAST(preview AS BLOB)) <= 4096),
            provider_status TEXT NOT NULL CHECK(length(CAST(provider_status AS BLOB)) <= 1024),
            can_resume INTEGER NOT NULL CHECK(can_resume IN (0, 1)),
            can_read_transcript INTEGER NOT NULL CHECK(can_read_transcript IN (0, 1)),
            source_path TEXT NOT NULL
                CHECK(length(CAST(source_path AS BLOB)) BETWEEN 1 AND 16384),
            source_byte_count INTEGER NOT NULL CHECK(source_byte_count >= 0),
            source_modified_at REAL NOT NULL, first_seen_at REAL NOT NULL, last_seen_at REAL NOT NULL,
            parent_provider_session_id TEXT
                CHECK(parent_provider_session_id IS NULL OR
                      length(CAST(parent_provider_session_id AS BLOB)) <= 1024),
            is_sidechain INTEGER NOT NULL CHECK(is_sidechain IN (0, 1)),
            content_digest TEXT
                CHECK(content_digest IS NULL OR length(CAST(content_digest AS BLOB)) <= 1024),
            missing_since REAL,
            UNIQUE(provider, surface, provider_session_id)
        );
        CREATE INDEX external_sessions_provider_surface_updated
            ON external_sessions(provider, surface, last_seen_at DESC, id ASC);
        CREATE INDEX external_sessions_workspace_updated
            ON external_sessions(workspace_path, last_seen_at DESC, id ASC);
        CREATE TABLE conversation_external_links (
            conversation_id TEXT PRIMARY KEY NOT NULL
                REFERENCES conversations(id) ON DELETE CASCADE,
            external_session_id TEXT NOT NULL UNIQUE
                REFERENCES external_sessions(id) ON DELETE CASCADE
        );
        INSERT INTO workspaces VALUES (
            '\(workspaceID.uuidString)', 'v3 workspace', '/v3', 100, 101
        );
        INSERT INTO conversations VALUES (
            '\(conversationID.uuidString)', '\(workspaceID.uuidString)', 'v3 conversation',
            'codex', 'interactive', 'readOnly', 'completed', 'v3-provider-session', '[]', 102, 103
        );
        INSERT INTO external_sessions VALUES (
            '\(externalID.uuidString)', 'codex', 'codex', 'v3-external-session', '/v3',
            'v3 external', 'preview', 'completed', 1, 1, '/private/v3.jsonl', 10,
            104, 105, 106, NULL, 0, NULL, NULL
        );
        INSERT INTO conversation_external_links VALUES (
            '\(conversationID.uuidString)', '\(externalID.uuidString)'
        );
        PRAGMA user_version = 3;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail("Failed to create v3 fixture: \(message)")
            throw POSIXError(.EIO)
        }
    }

    private func makeDatabaseLocation() -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-store-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("private/index.sqlite"))
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "81000000-0000-0000-0000-%012d", number))!
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
