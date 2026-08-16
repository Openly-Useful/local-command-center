import Darwin
import Foundation
import SQLite3
import XCTest
@testable import CommandCenterCore

final class SQLiteStoreTests: XCTestCase {
    func testConfigurationPersistenceAndReopen() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let workspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Local",
            rootPath: "/tmp/local-project",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let conversation = Conversation(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceID: workspace.id,
            title: "Persist me",
            provider: .codex,
            workflow: .implementation,
            permissionMode: .workspaceWrite,
            status: .running,
            providerSessionID: "session-1",
            skillIDs: ["pickup-swarm", "engineering:code-review"],
            createdAt: Date(timeIntervalSince1970: 102),
            updatedAt: Date(timeIntervalSince1970: 103)
        )

        do {
            let store = try SQLiteStore(databaseURL: location.database)
            let configuration = try await store.configuration()
            XCTAssertEqual(configuration.schemaVersion, 4)
            XCTAssertEqual(configuration.journalMode.lowercased(), "wal")
            XCTAssertTrue(configuration.foreignKeysEnabled)
            XCTAssertEqual(configuration.busyTimeoutMilliseconds, 5_000)

            try await store.upsertWorkspace(workspace)
            try await store.insertConversation(conversation)
            let message = try await store.appendMessage(
                conversationID: conversation.id,
                role: .user,
                content: "hello",
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 104)
            )
            XCTAssertEqual(message.sequence, 0)
        }

        let reopened = try SQLiteStore(databaseURL: location.database)
        let loadedWorkspace = try await reopened.workspace(id: workspace.id)
        let loadedConversation = try await reopened.conversation(id: conversation.id)
        let loadedMessages = try await reopened.listMessages(conversationID: conversation.id)

        XCTAssertEqual(loadedWorkspace, workspace)
        XCTAssertEqual(loadedConversation?.id, conversation.id)
        XCTAssertEqual(loadedConversation?.providerSessionID, "session-1")
        XCTAssertEqual(
            loadedConversation?.skillIDs,
            ["engineering:code-review", "pickup-swarm"]
        )
        XCTAssertEqual(loadedMessages.map(\.content), ["hello"])
    }

    func testVersionOneDatabaseMigratesThroughVersionTwoToLatestWithoutDataLoss() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let workspaceID = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
        let conversationID = UUID(uuidString: "62000000-0000-0000-0000-000000000001")!
        let messageID = UUID(uuidString: "63000000-0000-0000-0000-000000000001")!
        try createVersionOneDatabase(
            at: location.database,
            workspaceID: workspaceID,
            conversationID: conversationID,
            messageID: messageID
        )

        do {
            let migrated = try SQLiteStore(databaseURL: location.database)
            let configuration = try await migrated.configuration()
            let storedConversation = try await migrated.conversation(id: conversationID)
            let conversation = try XCTUnwrap(storedConversation)
            let migratedMessages = try await migrated
                .listMessages(conversationID: conversationID)
                .map(\.content)
            XCTAssertEqual(configuration.schemaVersion, 4)
            XCTAssertEqual(conversation.title, "preserved v1 conversation")
            XCTAssertEqual(conversation.providerSessionID, "legacy-session")
            XCTAssertEqual(conversation.skillIDs, [])
            XCTAssertEqual(migratedMessages, ["preserved v1 message"])

            var updated = conversation
            updated.skillIDs = ["pickup-swarm", " engineering:code-review "]
            updated.updatedAt = Date(timeIntervalSince1970: 250)
            try await migrated.updateConversation(updated)
        }

        let reopened = try SQLiteStore(databaseURL: location.database)
        let persisted = try await reopened.conversation(id: conversationID)
        XCTAssertEqual(
            persisted?.skillIDs,
            ["engineering:code-review", "pickup-swarm"]
        )
        XCTAssertEqual(try permissionBits(at: location.database), 0o600)
    }

    func testVersionTwoDatabaseMigratesToLatestWithoutDataLoss() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let workspaceID = UUID(uuidString: "64000000-0000-0000-0000-000000000001")!
        let conversationID = UUID(uuidString: "65000000-0000-0000-0000-000000000001")!
        let messageID = UUID(uuidString: "66000000-0000-0000-0000-000000000001")!
        try createVersionOneDatabase(
            at: location.database,
            workspaceID: workspaceID,
            conversationID: conversationID,
            messageID: messageID
        )
        try promoteVersionOneDatabaseToVersionTwo(at: location.database)

        let migrated = try SQLiteStore(databaseURL: location.database)
        let configuration = try await migrated.configuration()
        let storedConversation = try await migrated.conversation(id: conversationID)
        let conversation = try XCTUnwrap(storedConversation)
        let messages = try await migrated
            .listMessages(conversationID: conversationID)
            .map(\.content)
        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(conversation.title, "preserved v1 conversation")
        XCTAssertEqual(conversation.skillIDs, ["preserved-v2-skill"])
        XCTAssertEqual(messages, ["preserved v1 message"])

        let external = try await migrated.externalSession(forConversationID: conversationID)
        XCTAssertNil(external, "v2 databases have no external links to invent")
    }

    private func promoteVersionOneDatabaseToVersionTwo(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        ALTER TABLE conversations ADD COLUMN skill_ids TEXT NOT NULL DEFAULT '[]'
            CHECK(length(CAST(skill_ids AS BLOB)) <= 32768);
        UPDATE conversations SET skill_ids = '["preserved-v2-skill"]';
        PRAGMA user_version = 2;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail("Failed to promote fixture to v2: \(message)")
            throw POSIXError(.EIO)
        }
    }

    func testDeterministicWorkspaceConversationAndMessageOrdering() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let date = Date(timeIntervalSince1970: 500)

        let zulu = Workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "zulu",
            rootPath: "/zulu",
            createdAt: date,
            updatedAt: date
        )
        let alphaUpper = Workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Alpha",
            rootPath: "/alpha-upper",
            createdAt: date,
            updatedAt: date
        )
        let alphaLower = Workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "alpha",
            rootPath: "/alpha-lower",
            createdAt: date,
            updatedAt: date
        )
        for workspace in [zulu, alphaLower, alphaUpper] {
            try await store.upsertWorkspace(workspace)
        }

        let orderedWorkspaceIDs = try await store.listWorkspaces().map(\.id)
        XCTAssertEqual(orderedWorkspaceIDs, [alphaUpper.id, alphaLower.id, zulu.id])

        let older = Conversation(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            workspaceID: alphaUpper.id,
            title: "older",
            provider: .codex,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let tieB = Conversation(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
            workspaceID: alphaUpper.id,
            title: "tie-b",
            provider: .claude,
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let tieA = Conversation(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            workspaceID: alphaUpper.id,
            title: "tie-a",
            provider: .codex,
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        for conversation in [older, tieB, tieA] {
            try await store.insertConversation(conversation)
        }
        let orderedConversationIDs = try await store
            .listConversations(workspaceID: alphaUpper.id)
            .map(\.id)
        XCTAssertEqual(orderedConversationIDs, [tieA.id, tieB.id, older.id])

        let second = Message(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            conversationID: tieA.id,
            role: .assistant,
            content: "second",
            sequence: 1,
            createdAt: date
        )
        let first = Message(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            conversationID: tieA.id,
            role: .user,
            content: "first",
            sequence: 0,
            createdAt: date
        )
        try await store.insertMessage(second)
        try await store.insertMessage(first)
        let orderedMessageContent = try await store
            .listMessages(conversationID: tieA.id)
            .map(\.content)
        XCTAssertEqual(orderedMessageContent, ["first", "second"])
        let messagesAfterZero = try await store
            .listMessages(conversationID: tieA.id, afterSequence: 0)
            .map(\.content)
        XCTAssertEqual(messagesAfterZero, ["second"])
    }

    func testRecentTranscriptReturnsNewestChronologicalWindowWithinAggregateBudget() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let workspace = Workspace(name: "transcript", rootPath: "/transcript")
        let conversation = Conversation(
            workspaceID: workspace.id,
            title: "bounded",
            provider: .codex
        )
        try await store.upsertWorkspace(workspace)
        try await store.insertConversation(conversation)
        for content in ["old-000", "middle", "new-one", "new-two"] {
            _ = try await store.appendMessage(
                conversationID: conversation.id,
                role: .assistant,
                content: content
            )
        }

        let recent = try await store.listRecentMessages(
            conversationID: conversation.id,
            limit: 4,
            maximumAggregateBytes: 14
        )
        XCTAssertEqual(recent.map(\.content), ["new-one", "new-two"])
        XCTAssertLessThanOrEqual(recent.reduce(0) { $0 + $1.content.utf8.count }, 14)

        let newestOnly = try await store.listRecentMessages(
            conversationID: conversation.id,
            limit: 1,
            maximumAggregateBytes: 100
        )
        XCTAssertEqual(newestOnly.map(\.content), ["new-two"])
    }

    func testForeignKeysRejectOrphansAndCascadeDeletes() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let missingWorkspaceID = UUID()
        let orphan = Conversation(
            workspaceID: missingWorkspaceID,
            title: "orphan",
            provider: .codex
        )

        do {
            try await store.insertConversation(orphan)
            XCTFail("Expected a foreign-key constraint error")
        } catch let error as SQLiteStoreError {
            guard case let .sqlite(code, _) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertEqual(code & 0xFF, SQLITE_CONSTRAINT)
        }

        let workspace = Workspace(name: "cascade", rootPath: "/cascade")
        let conversation = Conversation(
            workspaceID: workspace.id,
            title: "cascade",
            provider: .claude
        )
        try await store.upsertWorkspace(workspace)
        try await store.insertConversation(conversation)
        let message = try await store.appendMessage(
            conversationID: conversation.id,
            role: .assistant,
            content: "cascade"
        )

        try await store.deleteWorkspace(id: workspace.id)
        let deletedConversation = try await store.conversation(id: conversation.id)
        let deletedMessage = try await store.message(id: message.id)
        XCTAssertNil(deletedConversation)
        XCTAssertNil(deletedMessage)
    }

    func testPreparedBindingsPreserveInjectionTextAndEmbeddedNulls() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let hostile = "x'); DROP TABLE workspaces; --\u{0}still text"
        let workspace = Workspace(name: hostile, rootPath: "/safe/'quoted' path")
        let conversation = Conversation(
            workspaceID: workspace.id,
            title: hostile,
            provider: .codex,
            providerSessionID: hostile,
            skillIDs: ["skill'); DROP TABLE conversations; --"]
        )

        try await store.upsertWorkspace(workspace)
        try await store.insertConversation(conversation)
        let message = try await store.appendMessage(
            conversationID: conversation.id,
            role: .user,
            content: hostile
        )

        let storedWorkspace = try await store.workspace(id: workspace.id)
        let storedConversation = try await store.conversation(id: conversation.id)
        let storedMessage = try await store.message(id: message.id)
        let workspaceCount = try await store.listWorkspaces().count
        XCTAssertEqual(storedWorkspace?.name, hostile)
        XCTAssertEqual(storedConversation?.title, hostile)
        XCTAssertEqual(
            storedConversation?.skillIDs,
            ["skill'); DROP TABLE conversations; --"]
        )
        XCTAssertEqual(storedMessage?.content, hostile)
        XCTAssertEqual(workspaceCount, 1)
    }

    func testDirectoryAndDatabaseAreOwnerOnly() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        try await store.upsertWorkspace(Workspace(name: "permissions", rootPath: "/permissions"))

        XCTAssertEqual(try permissionBits(at: location.database.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissionBits(at: location.database), 0o600)

        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: location.database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                XCTAssertEqual(try permissionBits(at: sidecar), 0o600)
            }
        }
    }

    func testDatabaseLeafSymlinkIsRejectedWithoutTouchingTarget() throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = FileManager.default
        let parent = location.database.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = location.root.appendingPathComponent("unrelated.sqlite")
        let sentinel = Data("unrelated-data".utf8)
        try sentinel.write(to: target)
        try manager.createSymbolicLink(at: location.database, withDestinationURL: target)

        XCTAssertThrowsError(try SQLiteStore(databaseURL: location.database))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }

    func testDatabaseParentSymlinkIsRejectedWithoutCreatingTargetDatabase() throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let manager = FileManager.default
        try manager.createDirectory(at: location.root, withIntermediateDirectories: true)
        let redirected = location.root.appendingPathComponent("redirected", isDirectory: true)
        try manager.createDirectory(at: redirected, withIntermediateDirectories: true)
        let linkedParent = location.database.deletingLastPathComponent()
        try manager.createSymbolicLink(at: linkedParent, withDestinationURL: redirected)

        XCTAssertThrowsError(try SQLiteStore(databaseURL: location.database))
        XCTAssertFalse(manager.fileExists(atPath: redirected.appendingPathComponent("command-center.sqlite").path))
    }

    func testLimitsAreBoundedAndInvalidRangesFail() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)

        for index in 0...SQLiteStore.maximumWorkspaceListCount {
            try await store.upsertWorkspace(
                Workspace(name: "workspace-\(index)", rootPath: "/workspace-\(index)")
            )
        }
        let bounded = try await store.listWorkspaces(limit: Int.max)
        XCTAssertEqual(bounded.count, SQLiteStore.maximumWorkspaceListCount)

        do {
            _ = try await store.listWorkspaces(limit: -1)
            XCTFail("Expected invalid limit")
        } catch {
            XCTAssertEqual(error as? SQLiteStoreError, .invalidLimit(-1))
        }
        do {
            _ = try await store.listConversations(offset: -1)
            XCTFail("Expected invalid offset")
        } catch {
            XCTAssertEqual(error as? SQLiteStoreError, .invalidLimit(-1))
        }
    }

    func testMessageSizeBoundAndConversationUpdateCRUD() async throws {
        let location = makeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let store = try SQLiteStore(databaseURL: location.database)
        let workspace = Workspace(name: "crud", rootPath: "/crud")
        let originalTimestamp = Date(timeIntervalSince1970: 1_234)
        var conversation = Conversation(
            workspaceID: workspace.id,
            title: "before",
            provider: .codex,
            createdAt: originalTimestamp,
            updatedAt: originalTimestamp
        )
        try await store.upsertWorkspace(workspace)
        try await store.insertConversation(conversation)

        conversation.title = "after"
        conversation.status = .completed
        conversation.skillIDs = ["z-skill", " a-skill ", "z-skill"]
        conversation.updatedAt = Date(timeIntervalSince1970: 9_999)
        try await store.updateConversation(conversation)
        let updatedConversation = try await store.conversation(id: conversation.id)
        XCTAssertEqual(updatedConversation, conversation)

        let oversized = String(
            repeating: "a",
            count: SQLiteStore.maximumMessageBytes + 1
        )
        do {
            _ = try await store.appendMessage(
                conversationID: conversation.id,
                role: .user,
                content: oversized
            )
            XCTFail("Expected message-size rejection")
        } catch let error as SQLiteStoreError {
            guard case let .messageTooLarge(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actual, SQLiteStore.maximumMessageBytes + 1)
            XCTAssertEqual(maximum, SQLiteStore.maximumMessageBytes)
        }
    }

    private func makeDatabaseLocation() -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-center-tests-\(UUID().uuidString)", isDirectory: true)
        let database = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("command-center.sqlite", isDirectory: false)
        return (root, database)
    }

    private func createVersionOneDatabase(
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
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close_v2(database) }

        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            root_path TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            provider TEXT NOT NULL,
            workflow TEXT NOT NULL,
            permission_mode TEXT NOT NULL,
            status TEXT NOT NULL,
            provider_session_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX conversations_workspace_updated
            ON conversations(workspace_id, updated_at DESC, created_at DESC, id ASC);
        CREATE TABLE messages (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK(sequence >= 0),
            created_at REAL NOT NULL,
            UNIQUE(conversation_id, sequence)
        );
        CREATE INDEX messages_conversation_sequence
            ON messages(conversation_id, sequence ASC, id ASC);
        INSERT INTO workspaces VALUES (
            '\(workspaceID.uuidString)', 'preserved v1 workspace', '/preserved-v1', 100, 101
        );
        INSERT INTO conversations VALUES (
            '\(conversationID.uuidString)', '\(workspaceID.uuidString)',
            'preserved v1 conversation', 'codex', 'interactive', 'readOnly', 'completed',
            'legacy-session', 102, 103
        );
        INSERT INTO messages VALUES (
            '\(messageID.uuidString)', '\(conversationID.uuidString)', 'assistant',
            'preserved v1 message', 0, 104
        );
        PRAGMA user_version = 1;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail("Failed to create v1 fixture: \(message)")
            throw POSIXError(.EIO)
        }
    }

    private func permissionBits(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard url.path.withCString({ stat($0, &metadata) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & mode_t(0o777)
    }
}
