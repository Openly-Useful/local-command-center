import Darwin
import Foundation
import SQLite3

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

public enum SQLiteStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDatabaseURL
    case fileSystem(operation: String, code: Int32)
    case sqlite(code: Int32, message: String)
    case unsupportedSchemaVersion(Int32)
    case invalidLimit(Int)
    case textTooLarge(actualBytes: Int)
    case messageTooLarge(actualBytes: Int, maximumBytes: Int)
    case skillIDsTooLarge(actualBytes: Int, maximumBytes: Int)
    case corruptRow(String)
    case notFound(String)
    case invalidContinuityRelationship(String)

    public var description: String {
        switch self {
        case .invalidDatabaseURL:
            "The SQLite database URL must be a local file URL."
        case let .fileSystem(operation, code):
            "File-system operation \(operation) failed with errno \(code)."
        case let .sqlite(code, message):
            "SQLite error \(code): \(message)"
        case let .unsupportedSchemaVersion(version):
            "Unsupported SQLite schema version \(version)."
        case let .invalidLimit(limit):
            "A list limit cannot be negative (received \(limit))."
        case let .textTooLarge(actualBytes):
            "A text value is too large for SQLite binding (\(actualBytes) bytes)."
        case let .messageTooLarge(actualBytes, maximumBytes):
            "Message is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case let .skillIDsTooLarge(actualBytes, maximumBytes):
            "Encoded skill IDs are \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case let .corruptRow(detail):
            "The SQLite database contains an invalid row: \(detail)"
        case let .notFound(kind):
            "The requested \(kind) does not exist."
        case let .invalidContinuityRelationship(detail):
            "The requested continuity relationship is invalid: \(detail)."
        }
    }
}

public struct SQLiteStoreConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int32
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let busyTimeoutMilliseconds: Int32
}

public actor SQLiteStore {
    public static let schemaVersion: Int32 = 4
    public static let maximumWorkspaceListCount = 500
    public static let maximumConversationListCount = 500
    public static let maximumMessageListCount = 2_000
    public static let maximumMessageBytes = 1_048_576
    public static let maximumTranscriptMessageCount = 200
    public static let maximumTranscriptBytes = 8 * 1_048_576
    public static let maximumSkillIDsStorageBytes = 32 * 1_024
    public static let defaultExternalSessionListCount = 1_000
    public static let maximumExternalSessionBatchCount = 5_000
    public static let maximumExternalSessionListCount = 10_000
    public static let maximumSeenExternalSessionIDCount = 10_000
    public static let maximumContinuityProjectListCount = 500
    public static let maximumContinuitySessionLinkListCount = 2_000
    public static let maximumContinuityHandoffListCount = 2_000
    public static let maximumContinuityEventListCount = 5_000
    public static let maximumContinuitySyncTransactionListCount = 2_000
    public static let maximumContinuityWriterLeaseDuration: TimeInterval = 300

    private enum Binding {
        case text(String)
        case double(Double)
        case int64(Int64)
        case null
    }

    private let databaseURL: URL
    private let busyTimeoutMilliseconds: Int32
    private let connection: SQLiteConnection
    private var database: OpaquePointer? { connection.handle }

    public init(databaseURL: URL, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard databaseURL.isFileURL, !databaseURL.path.isEmpty else {
            throw SQLiteStoreError.invalidDatabaseURL
        }

        let requestedDatabaseURL = databaseURL.standardizedFileURL
        try Self.prepareOwnerOnlyLocation(for: requestedDatabaseURL)
        let resolvedDirectory = try Self.realPath(
            requestedDatabaseURL.deletingLastPathComponent()
        )
        self.databaseURL = resolvedDirectory.appendingPathComponent(
            requestedDatabaseURL.lastPathComponent,
            isDirectory: false
        )
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        try Self.validateDatabasePath(self.databaseURL)

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
        let openResult = sqlite3_open_v2(self.databaseURL.path, &connection, flags, nil)
        guard openResult == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate SQLite connection"
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw SQLiteStoreError.sqlite(code: openResult, message: message)
        }
        let ownedConnection = SQLiteConnection(handle: connection)
        do {
            try Self.configureAndMigrate(
                connection,
                databaseURL: self.databaseURL,
                busyTimeoutMilliseconds: self.busyTimeoutMilliseconds
            )
            self.connection = ownedConnection
        } catch {
            throw error
        }
    }

    public func configuration() throws -> SQLiteStoreConfiguration {
        SQLiteStoreConfiguration(
            schemaVersion: try pragmaInt32("PRAGMA user_version"),
            journalMode: try pragmaString("PRAGMA journal_mode"),
            foreignKeysEnabled: try pragmaInt32("PRAGMA foreign_keys") == 1,
            busyTimeoutMilliseconds: try pragmaInt32("PRAGMA busy_timeout")
        )
    }

    public func upsertWorkspace(_ workspace: Workspace) throws {
        try update(
            """
            INSERT INTO workspaces (id, name, root_path, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                root_path = excluded.root_path,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(workspace.id.uuidString),
                .text(workspace.name),
                .text(workspace.rootPath),
                .double(workspace.createdAt.timeIntervalSince1970),
                .double(workspace.updatedAt.timeIntervalSince1970),
            ]
        )
        try hardenDatabaseArtifacts()
    }

    public func workspace(id: UUID) throws -> Workspace? {
        let statement = try prepare(
            "SELECT id, name, root_path, created_at, updated_at FROM workspaces WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeWorkspace(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listWorkspaces(limit: Int = 200, offset: Int = 0) throws -> [Workspace] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumWorkspaceListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement = try prepare(
            """
            SELECT id, name, root_path, created_at, updated_at
            FROM workspaces
            ORDER BY name COLLATE NOCASE ASC, name ASC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.int64(Int64(bounded)), .int64(Int64(boundedOffset))], to: statement)

        var results: [Workspace] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeWorkspace(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteWorkspace(id: UUID) throws {
        try update("DELETE FROM workspaces WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    public func insertConversation(_ conversation: Conversation) throws {
        try update(
            """
            INSERT INTO conversations (
                id, workspace_id, title, provider, workflow, permission_mode, status,
                provider_session_id, skill_ids, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: try conversationBindings(conversation)
        )
        try hardenDatabaseArtifacts()
    }

    public func updateConversation(_ conversation: Conversation) throws {
        try update(
            """
            UPDATE conversations SET
                workspace_id = ?, title = ?, provider = ?, workflow = ?,
                permission_mode = ?, status = ?, provider_session_id = ?, skill_ids = ?,
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(conversation.workspaceID.uuidString),
                .text(conversation.title),
                .text(conversation.provider.rawValue),
                .text(conversation.workflow.rawValue),
                .text(conversation.permissionMode.rawValue),
                .text(conversation.status.rawValue),
                conversation.providerSessionID.map(Binding.text) ?? .null,
                .text(try encodeSkillIDs(conversation.skillIDs)),
                .double(conversation.updatedAt.timeIntervalSince1970),
                .text(conversation.id.uuidString),
            ]
        )
        guard sqlite3_changes(database) == 1 else {
            throw SQLiteStoreError.notFound("conversation")
        }
        try hardenDatabaseArtifacts()
    }

    public func conversation(id: UUID) throws -> Conversation? {
        let statement = try prepare(
            """
            SELECT id, workspace_id, title, provider, workflow, permission_mode, status,
                   provider_session_id, skill_ids, created_at, updated_at
            FROM conversations WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeConversation(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listConversations(
        workspaceID: UUID? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [Conversation] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumConversationListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement: OpaquePointer
        let bindings: [Binding]

        if let workspaceID {
            statement = try prepare(
                """
                SELECT id, workspace_id, title, provider, workflow, permission_mode, status,
                       provider_session_id, skill_ids, created_at, updated_at
                FROM conversations
                WHERE workspace_id = ?
                ORDER BY updated_at DESC, created_at DESC, id ASC
                LIMIT ? OFFSET ?
                """
            )
            bindings = [
                .text(workspaceID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset)),
            ]
        } else {
            statement = try prepare(
                """
                SELECT id, workspace_id, title, provider, workflow, permission_mode, status,
                       provider_session_id, skill_ids, created_at, updated_at
                FROM conversations
                ORDER BY updated_at DESC, created_at DESC, id ASC
                LIMIT ? OFFSET ?
                """
            )
            bindings = [.int64(Int64(bounded)), .int64(Int64(boundedOffset))]
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var results: [Conversation] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeConversation(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteConversation(id: UUID) throws {
        try update("DELETE FROM conversations WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    // MARK: - Continuity metadata

    /// Creates or refreshes a bounded, app-owned continuity project. Its workspace
    /// anchor is immutable after creation so a project cannot silently cross an
    /// approved filesystem boundary.
    public func upsertContinuityProject(_ project: ContinuityProject) throws {
        if let existing = try continuityProject(id: project.id), existing.workspaceID != project.workspaceID {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a project cannot change its workspace anchor"
            )
        }
        try update(
            """
            INSERT INTO continuity_projects (
                id, workspace_id, name, summary, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                summary = excluded.summary,
                updated_at = excluded.updated_at
            """,
            bindings: continuityProjectBindings(project)
        )
        try hardenDatabaseArtifacts()
    }

    public func continuityProject(id: UUID) throws -> ContinuityProject? {
        let statement = try prepare(
            """
            SELECT id, workspace_id, name, summary, created_at, updated_at
            FROM continuity_projects WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeContinuityProject(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listContinuityProjects(
        workspaceID: UUID? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [ContinuityProject] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumContinuityProjectListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement: OpaquePointer
        let bindings: [Binding]
        if let workspaceID {
            statement = try prepare(
                """
                SELECT id, workspace_id, name, summary, created_at, updated_at
                FROM continuity_projects
                WHERE workspace_id = ?
                ORDER BY updated_at DESC, created_at DESC, id ASC
                LIMIT ? OFFSET ?
                """
            )
            bindings = [
                .text(workspaceID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset)),
            ]
        } else {
            statement = try prepare(
                """
                SELECT id, workspace_id, name, summary, created_at, updated_at
                FROM continuity_projects
                ORDER BY updated_at DESC, created_at DESC, id ASC
                LIMIT ? OFFSET ?
                """
            )
            bindings = [.int64(Int64(bounded)), .int64(Int64(boundedOffset))]
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var results: [ContinuityProject] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeContinuityProject(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteContinuityProject(id: UUID) throws {
        try update("DELETE FROM continuity_projects WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    /// Registers one session source in a continuity project. Each link points to
    /// exactly one opaque local UUID; provider identities remain in the existing
    /// external-session index and are never copied into continuity rows.
    public func upsertContinuitySessionLink(_ link: ContinuitySessionLink) throws {
        try validateContinuitySessionLinkReferences(link)
        if let existing = try continuitySessionLink(id: link.id),
           existing.projectID != link.projectID
                || existing.conversationID != link.conversationID
                || existing.externalSessionID != link.externalSessionID {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a session link cannot change its project or source"
            )
        }
        try update(
            """
            INSERT INTO continuity_session_links (
                id, project_id, conversation_id, external_session_id, kind, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                updated_at = excluded.updated_at
            """,
            bindings: continuitySessionLinkBindings(link)
        )
        try hardenDatabaseArtifacts()
    }

    public func continuitySessionLink(id: UUID) throws -> ContinuitySessionLink? {
        let statement = try prepare(
            """
            SELECT id, project_id, conversation_id, external_session_id, kind, created_at, updated_at
            FROM continuity_session_links WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeContinuitySessionLink(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listContinuitySessionLinks(
        projectID: UUID,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [ContinuitySessionLink] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumContinuitySessionLinkListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement = try prepare(
            """
            SELECT id, project_id, conversation_id, external_session_id, kind, created_at, updated_at
            FROM continuity_session_links
            WHERE project_id = ?
            ORDER BY updated_at DESC, created_at DESC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [.text(projectID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset))],
            to: statement
        )

        var results: [ContinuitySessionLink] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeContinuitySessionLink(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteContinuitySessionLink(id: UUID) throws {
        try update("DELETE FROM continuity_session_links WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    public func upsertContinuityHandoff(_ handoff: ContinuityHandoff) throws {
        try validateContinuityHandoffReferences(handoff)
        if let existing = try continuityHandoff(id: handoff.id),
           existing.projectID != handoff.projectID
                || existing.sourceSessionLinkID != handoff.sourceSessionLinkID {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a handoff cannot change its project or source session"
            )
        }
        try update(
            """
            INSERT INTO continuity_handoffs (
                id, project_id, source_session_link_id, destination_session_link_id,
                title, summary, state, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                destination_session_link_id = excluded.destination_session_link_id,
                title = excluded.title,
                summary = excluded.summary,
                state = excluded.state,
                updated_at = excluded.updated_at
            """,
            bindings: continuityHandoffBindings(handoff)
        )
        try hardenDatabaseArtifacts()
    }

    public func continuityHandoff(id: UUID) throws -> ContinuityHandoff? {
        let statement = try prepare(
            """
            SELECT id, project_id, source_session_link_id, destination_session_link_id,
                   title, summary, state, created_at, updated_at
            FROM continuity_handoffs WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeContinuityHandoff(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listContinuityHandoffs(
        projectID: UUID,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [ContinuityHandoff] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumContinuityHandoffListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement = try prepare(
            """
            SELECT id, project_id, source_session_link_id, destination_session_link_id,
                   title, summary, state, created_at, updated_at
            FROM continuity_handoffs
            WHERE project_id = ?
            ORDER BY updated_at DESC, created_at DESC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [.text(projectID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset))],
            to: statement
        )

        var results: [ContinuityHandoff] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeContinuityHandoff(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteContinuityHandoff(id: UUID) throws {
        try update("DELETE FROM continuity_handoffs WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    /// Events are immutable local audit metadata. Inserting an event never
    /// updates a project, session source, or provider-owned record.
    public func insertContinuityEvent(_ event: ContinuityEvent) throws {
        try validateContinuityEventReferences(event)
        try update(
            """
            INSERT INTO continuity_events (
                id, project_id, session_link_id, handoff_id, kind, detail, occurred_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: continuityEventBindings(event)
        )
        try hardenDatabaseArtifacts()
    }

    public func continuityEvent(id: UUID) throws -> ContinuityEvent? {
        let statement = try prepare(
            """
            SELECT id, project_id, session_link_id, handoff_id, kind, detail, occurred_at
            FROM continuity_events WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeContinuityEvent(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listContinuityEvents(
        projectID: UUID,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [ContinuityEvent] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumContinuityEventListCount)
        let boundedOffset = try validatedOffset(offset)
        let statement = try prepare(
            """
            SELECT id, project_id, session_link_id, handoff_id, kind, detail, occurred_at
            FROM continuity_events
            WHERE project_id = ?
            ORDER BY occurred_at DESC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [.text(projectID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset))],
            to: statement
        )

        var results: [ContinuityEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeContinuityEvent(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteContinuityEvent(id: UUID) throws {
        try update("DELETE FROM continuity_events WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    public func upsertContinuitySyncTransaction(_ transaction: ContinuitySyncTransaction) throws {
        if let existing = try continuitySyncTransaction(id: transaction.id),
           existing.projectID != transaction.projectID {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a sync transaction cannot change its project"
            )
        }
        try update(
            """
            INSERT INTO continuity_sync_transactions (
                id, project_id, kind, state, attempt, started_at, completed_at,
                created_at, updated_at, revision, writer_token, writer_lease_expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                state = excluded.state,
                attempt = excluded.attempt,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at,
                updated_at = excluded.updated_at
            WHERE continuity_sync_transactions.writer_token IS NULL
            """,
            bindings: continuitySyncTransactionBindings(transaction)
        )
        guard sqlite3_changes(database) == 1 else {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a sync transaction with an active writer lease cannot be upserted"
            )
        }
        try hardenDatabaseArtifacts()
    }

    public func continuitySyncTransaction(id: UUID) throws -> ContinuitySyncTransaction? {
        let statement = try prepare(
            """
            SELECT id, project_id, kind, state, attempt, started_at, completed_at,
                   created_at, updated_at, revision
            FROM continuity_sync_transactions WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeContinuitySyncTransaction(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listContinuitySyncTransactions(
        projectID: UUID,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [ContinuitySyncTransaction] {
        let bounded = try boundedLimit(
            limit,
            maximum: Self.maximumContinuitySyncTransactionListCount
        )
        let boundedOffset = try validatedOffset(offset)
        let statement = try prepare(
            """
            SELECT id, project_id, kind, state, attempt, started_at, completed_at,
                   created_at, updated_at, revision
            FROM continuity_sync_transactions
            WHERE project_id = ?
            ORDER BY updated_at DESC, created_at DESC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [.text(projectID.uuidString), .int64(Int64(bounded)), .int64(Int64(boundedOffset))],
            to: statement
        )

        var results: [ContinuitySyncTransaction] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeContinuitySyncTransaction(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteContinuitySyncTransaction(id: UUID) throws {
        try update("DELETE FROM continuity_sync_transactions WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    /// Acquires or renews an opaque writer lease using a single SQL compare-and-
    /// swap. A second process cannot take a non-expired lease owned by another
    /// writer, and no provider identity is used as the owner token.
    public func acquireContinuitySyncWriterLease(
        transactionID: UUID,
        ownerID: UUID,
        now: Date = Date(),
        duration: TimeInterval = 60
    ) throws -> ContinuityWriterLease? {
        try validateContinuityLease(now: now, duration: duration)
        let expiresAt = now.addingTimeInterval(duration)
        try update(
            """
            UPDATE continuity_sync_transactions
            SET writer_token = ?,
                writer_lease_expires_at = ?,
                state = CASE WHEN state = 'pending' THEN 'running' ELSE state END,
                started_at = COALESCE(started_at, ?),
                updated_at = MAX(updated_at, ?),
                revision = revision + 1
            WHERE id = ?
              AND state IN ('pending', 'running')
              AND (
                  writer_token IS NULL
                  OR writer_token = ?
                  OR writer_lease_expires_at <= ?
              )
            """,
            bindings: [
                .text(ownerID.uuidString),
                .double(expiresAt.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
                .text(transactionID.uuidString),
                .text(ownerID.uuidString),
                .double(now.timeIntervalSince1970),
            ]
        )
        guard sqlite3_changes(database) == 1 else { return nil }
        let statement = try prepare(
            """
            SELECT revision FROM continuity_sync_transactions
            WHERE id = ? AND writer_token = ? AND writer_lease_expires_at = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [
                .text(transactionID.uuidString),
                .text(ownerID.uuidString),
                .double(expiresAt.timeIntervalSince1970),
            ],
            to: statement
        )
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.corruptRow("continuity writer lease was lost before it could be read")
        }
        let revision = sqlite3_column_int64(statement, 0)
        do {
            let lease = try ContinuityWriterLease(
                transactionID: transactionID,
                ownerID: ownerID,
                expiresAt: expiresAt,
                revision: revision
            )
            try hardenDatabaseArtifacts()
            return lease
        } catch {
            throw SQLiteStoreError.corruptRow("continuity writer lease has an invalid revision")
        }
    }

    @discardableResult
    public func releaseContinuitySyncWriterLease(
        transactionID: UUID,
        ownerID: UUID,
        at timestamp: Date = Date()
    ) throws -> Bool {
        try validateContinuityDate(timestamp, field: "leaseReleaseAt")
        try update(
            """
            UPDATE continuity_sync_transactions
            SET writer_token = NULL,
                writer_lease_expires_at = NULL,
                updated_at = MAX(updated_at, ?),
                revision = revision + 1
            WHERE id = ? AND writer_token = ?
            """,
            bindings: [
                .double(timestamp.timeIntervalSince1970),
                .text(transactionID.uuidString),
                .text(ownerID.uuidString),
            ]
        )
        let released = sqlite3_changes(database) == 1
        if released { try hardenDatabaseArtifacts() }
        return released
    }

    /// Finalizes a running sync only when the caller still owns an unexpired
    /// lease. Returning false signals a lost or expired compare-and-swap lease.
    @discardableResult
    public func completeContinuitySyncTransaction(
        transactionID: UUID,
        ownerID: UUID,
        state: ContinuitySyncState,
        at timestamp: Date = Date()
    ) throws -> Bool {
        guard state.isTerminal else {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "only a terminal sync state can complete a transaction"
            )
        }
        try validateContinuityDate(timestamp, field: "syncCompletionAt")
        try update(
            """
            UPDATE continuity_sync_transactions
            SET state = ?,
                completed_at = ?,
                updated_at = MAX(updated_at, ?),
                writer_token = NULL,
                writer_lease_expires_at = NULL,
                revision = revision + 1
            WHERE id = ?
              AND state = 'running'
              AND writer_token = ?
              AND writer_lease_expires_at > ?
            """,
            bindings: [
                .text(state.rawValue),
                .double(timestamp.timeIntervalSince1970),
                .double(timestamp.timeIntervalSince1970),
                .text(transactionID.uuidString),
                .text(ownerID.uuidString),
                .double(timestamp.timeIntervalSince1970),
            ]
        )
        let completed = sqlite3_changes(database) == 1
        if completed { try hardenDatabaseArtifacts() }
        return completed
    }

    // MARK: - External session metadata

    /// Adds or refreshes provider metadata without copying transcript bodies.
    /// The provider/surface/session identity retains its first local UUID across rescans.
    public func upsertExternalSessions(_ sessions: [ExternalSession]) throws {
        guard !sessions.isEmpty else { return }
        guard sessions.count <= Self.maximumExternalSessionBatchCount else {
            throw SQLiteStoreError.invalidLimit(sessions.count)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for session in sessions {
                try update(
                    """
                    INSERT INTO external_sessions (
                        id, provider, surface, provider_session_id, workspace_path,
                        title, preview, provider_status, can_resume, can_read_transcript,
                        source_path, source_byte_count, source_modified_at, first_seen_at,
                        last_seen_at, parent_provider_session_id, is_sidechain,
                        content_digest, missing_since
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(provider, surface, provider_session_id) DO UPDATE SET
                        workspace_path = excluded.workspace_path,
                        title = excluded.title,
                        preview = excluded.preview,
                        provider_status = excluded.provider_status,
                        can_resume = excluded.can_resume,
                        can_read_transcript = excluded.can_read_transcript,
                        source_path = excluded.source_path,
                        source_byte_count = excluded.source_byte_count,
                        source_modified_at = excluded.source_modified_at,
                        first_seen_at = MIN(external_sessions.first_seen_at, excluded.first_seen_at),
                        last_seen_at = MAX(external_sessions.last_seen_at, excluded.last_seen_at),
                        parent_provider_session_id = excluded.parent_provider_session_id,
                        is_sidechain = excluded.is_sidechain,
                        content_digest = excluded.content_digest,
                        missing_since = NULL
                    WHERE external_sessions.workspace_path IS NOT excluded.workspace_path
                        OR external_sessions.title IS NOT excluded.title
                        OR external_sessions.preview IS NOT excluded.preview
                        OR external_sessions.provider_status IS NOT excluded.provider_status
                        OR external_sessions.can_resume IS NOT excluded.can_resume
                        OR external_sessions.can_read_transcript IS NOT excluded.can_read_transcript
                        OR external_sessions.source_path IS NOT excluded.source_path
                        OR external_sessions.source_byte_count IS NOT excluded.source_byte_count
                        OR external_sessions.source_modified_at IS NOT excluded.source_modified_at
                        OR external_sessions.first_seen_at > excluded.first_seen_at
                        OR external_sessions.last_seen_at < excluded.last_seen_at
                        OR external_sessions.parent_provider_session_id IS NOT excluded.parent_provider_session_id
                        OR external_sessions.is_sidechain IS NOT excluded.is_sidechain
                        OR external_sessions.content_digest IS NOT excluded.content_digest
                        OR external_sessions.missing_since IS NOT NULL
                    """,
                    bindings: externalSessionBindings(session)
                )
            }
            try execute("COMMIT")
            try hardenDatabaseArtifacts()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func externalSession(id: UUID) throws -> ExternalSession? {
        let statement = try prepare(
            "\(Self.externalSessionColumns) WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        return try stepExternalSession(statement)
    }

    public func externalSession(
        provider: ProviderKind,
        surface: ExternalSessionSurface,
        providerSessionID: String
    ) throws -> ExternalSession? {
        let canonicalID = try ExternalSession.canonicalProviderSessionID(providerSessionID)
        let statement = try prepare(
            """
            \(Self.externalSessionColumns)
            WHERE provider = ? AND surface = ? AND provider_session_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            [.text(provider.rawValue), .text(surface.rawValue), .text(canonicalID)],
            to: statement
        )
        return try stepExternalSession(statement)
    }

    public func listExternalSessions(
        provider: ProviderKind? = nil,
        workspacePath: String? = nil,
        includeMissing: Bool = false,
        limit: Int = SQLiteStore.defaultExternalSessionListCount,
        offset: Int = 0
    ) throws -> [ExternalSession] {
        let boundedLimit = try boundedLimit(
            limit,
            maximum: Self.maximumExternalSessionListCount
        )
        let boundedOffset = try validatedOffset(offset)
        let canonicalWorkspace = try workspacePath.map {
            try ExternalSession.canonicalWorkspacePath($0)
        }
        var predicates: [String] = []
        var bindings: [Binding] = []
        if let provider {
            predicates.append("provider = ?")
            bindings.append(.text(provider.rawValue))
        }
        if let canonicalWorkspace {
            predicates.append("workspace_path = ?")
            bindings.append(.text(canonicalWorkspace))
        }
        if !includeMissing {
            predicates.append("missing_since IS NULL")
        }
        let whereClause = predicates.isEmpty ? "" : " WHERE \(predicates.joined(separator: " AND "))"
        let statement = try prepare(
            """
            \(Self.externalSessionColumns)\(whereClause)
            ORDER BY last_seen_at DESC, source_modified_at DESC, id ASC
            LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindings.append(.int64(Int64(boundedLimit)))
        bindings.append(.int64(Int64(boundedOffset)))
        try bind(bindings, to: statement)

        var results: [ExternalSession] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeExternalSession(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    /// Counts indexed metadata without materializing provider-owned titles,
    /// previews, or paths. The UI uses this to disclose when its deliberately
    /// bounded in-memory window omits older indexed sessions.
    public func externalSessionCount(includeMissing: Bool = false) throws -> Int {
        let predicate = includeMissing ? "" : " WHERE missing_since IS NULL"
        let statement = try prepare("SELECT COUNT(*) FROM external_sessions\(predicate)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, count <= Int64(Int.max) else { throw sqliteError() }
        return Int(count)
    }

    /// Applies one complete provider/surface observation set. Unseen identities become
    /// tombstones; seen identities are resurrected without modifying their scan metadata.
    public func markExternalSessionsMissing(
        provider: ProviderKind,
        surface: ExternalSessionSurface,
        seenProviderSessionIDs: [String],
        at timestamp: Date
    ) throws {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw ExternalSessionValidationError.invalidDate(field: "missingSince")
        }
        guard seenProviderSessionIDs.count <= Self.maximumSeenExternalSessionIDCount else {
            throw SQLiteStoreError.invalidLimit(seenProviderSessionIDs.count)
        }
        let canonicalIDs = try Array(
            Set(seenProviderSessionIDs.map(ExternalSession.canonicalProviderSessionID))
        ).sorted()

        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                """
                CREATE TEMP TABLE IF NOT EXISTS seen_external_session_ids (
                    provider_session_id TEXT PRIMARY KEY NOT NULL
                ) WITHOUT ROWID
                """
            )
            try update("DELETE FROM seen_external_session_ids")
            let insertion = try prepare(
                "INSERT INTO seen_external_session_ids (provider_session_id) VALUES (?)"
            )
            defer { sqlite3_finalize(insertion) }
            for providerSessionID in canonicalIDs {
                sqlite3_reset(insertion)
                sqlite3_clear_bindings(insertion)
                try bind([.text(providerSessionID)], to: insertion)
                let result = sqlite3_step(insertion)
                guard result == SQLITE_DONE else { throw sqliteError(code: result) }
            }
            try update(
                """
                UPDATE external_sessions
                SET missing_since = CASE
                    WHEN EXISTS (
                        SELECT 1 FROM seen_external_session_ids AS seen
                        WHERE seen.provider_session_id = external_sessions.provider_session_id
                    ) THEN NULL
                    ELSE COALESCE(missing_since, ?)
                END
                WHERE provider = ? AND surface = ?
                  AND (
                    (EXISTS (
                        SELECT 1 FROM seen_external_session_ids AS seen
                        WHERE seen.provider_session_id = external_sessions.provider_session_id
                    ) AND missing_since IS NOT NULL)
                    OR
                    (NOT EXISTS (
                        SELECT 1 FROM seen_external_session_ids AS seen
                        WHERE seen.provider_session_id = external_sessions.provider_session_id
                    ) AND missing_since IS NULL)
                  )
                """,
                bindings: [
                    .double(timestamp.timeIntervalSince1970),
                    .text(provider.rawValue),
                    .text(surface.rawValue),
                ]
            )
            try update("DELETE FROM seen_external_session_ids")
            try execute("COMMIT")
            try hardenDatabaseArtifacts()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Tombstones one provider session only after its source adapter has
    /// completed a bounded, error-free identity revalidation. This avoids
    /// treating absence from a lock-free snapshot as deletion.
    public func markExternalSessionMissing(id: UUID, at timestamp: Date) throws {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw ExternalSessionValidationError.invalidDate(field: "missingSince")
        }
        try update(
            """
            UPDATE external_sessions
            SET missing_since = COALESCE(missing_since, ?)
            WHERE id = ? AND missing_since IS NULL
            """,
            bindings: [
                .double(timestamp.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
        try hardenDatabaseArtifacts()
    }

    public func linkConversation(conversationID: UUID, externalSessionID: UUID) throws {
        try update(
            """
            INSERT INTO conversation_external_links (conversation_id, external_session_id)
            VALUES (?, ?)
            ON CONFLICT(conversation_id) DO UPDATE SET
                external_session_id = excluded.external_session_id
            """,
            bindings: [.text(conversationID.uuidString), .text(externalSessionID.uuidString)]
        )
        try hardenDatabaseArtifacts()
    }

    public func unlinkConversation(conversationID: UUID) throws {
        try update(
            "DELETE FROM conversation_external_links WHERE conversation_id = ?",
            bindings: [.text(conversationID.uuidString)]
        )
        try hardenDatabaseArtifacts()
    }

    public func externalSession(forConversationID conversationID: UUID) throws -> ExternalSession? {
        let statement = try prepare(
            """
            \(Self.externalSessionColumns)
            JOIN conversation_external_links AS links ON links.external_session_id = external_sessions.id
            WHERE links.conversation_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(conversationID.uuidString)], to: statement)
        return try stepExternalSession(statement)
    }

    public func conversationID(forExternalSessionID externalSessionID: UUID) throws -> UUID? {
        let statement = try prepare(
            "SELECT conversation_id FROM conversation_external_links WHERE external_session_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(externalSessionID.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try requiredUUID(statement, column: 0, name: "link.conversation_id")
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func insertMessage(_ message: Message) throws {
        try validateMessageSize(message.content)
        try update(
            """
            INSERT INTO messages (id, conversation_id, role, content, sequence, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: messageBindings(message)
        )
        try hardenDatabaseArtifacts()
    }

    @discardableResult
    public func appendMessage(
        conversationID: UUID,
        role: MessageRole,
        content: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> Message {
        try validateMessageSize(content)
        try execute("BEGIN IMMEDIATE")
        do {
            let nextSequence = try nextMessageSequence(conversationID: conversationID)
            let message = Message(
                id: id,
                conversationID: conversationID,
                role: role,
                content: content,
                sequence: nextSequence,
                createdAt: createdAt
            )
            try update(
                """
                INSERT INTO messages (id, conversation_id, role, content, sequence, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: messageBindings(message)
            )
            try update(
                "UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                bindings: [.double(createdAt.timeIntervalSince1970), .text(conversationID.uuidString)]
            )
            try execute("COMMIT")
            try hardenDatabaseArtifacts()
            return message
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func message(id: UUID) throws -> Message? {
        let statement = try prepare(
            "SELECT id, conversation_id, role, content, sequence, created_at FROM messages WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeMessage(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listMessages(
        conversationID: UUID,
        limit: Int = 500,
        afterSequence: Int64? = nil
    ) throws -> [Message] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumMessageListCount)
        let statement: OpaquePointer
        let bindings: [Binding]
        if let afterSequence {
            statement = try prepare(
                """
                SELECT id, conversation_id, role, content, sequence, created_at
                FROM messages
                WHERE conversation_id = ? AND sequence > ?
                ORDER BY sequence ASC, id ASC
                LIMIT ?
                """
            )
            bindings = [
                .text(conversationID.uuidString), .int64(afterSequence), .int64(Int64(bounded)),
            ]
        } else {
            statement = try prepare(
                """
                SELECT id, conversation_id, role, content, sequence, created_at
                FROM messages
                WHERE conversation_id = ?
                ORDER BY sequence ASC, id ASC
                LIMIT ?
                """
            )
            bindings = [.text(conversationID.uuidString), .int64(Int64(bounded))]
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var results: [Message] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try decodeMessage(statement))
            case SQLITE_DONE:
                return results
            default:
                throw sqliteError()
            }
        }
    }

    /// Loads the newest contiguous transcript window without ever retaining more
    /// than the requested aggregate UTF-8 content budget. Results are returned
    /// in chronological order for direct rendering.
    public func listRecentMessages(
        conversationID: UUID,
        limit: Int = SQLiteStore.maximumTranscriptMessageCount,
        maximumAggregateBytes: Int = SQLiteStore.maximumTranscriptBytes
    ) throws -> [Message] {
        let bounded = try boundedLimit(limit, maximum: Self.maximumMessageListCount)
        guard maximumAggregateBytes >= 0 else {
            throw SQLiteStoreError.invalidLimit(maximumAggregateBytes)
        }
        guard bounded > 0, maximumAggregateBytes > 0 else { return [] }

        let statement = try prepare(
            """
            SELECT id, conversation_id, role, content, sequence, created_at,
                   length(CAST(content AS BLOB))
            FROM messages
            WHERE conversation_id = ?
            ORDER BY sequence DESC, id DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(conversationID.uuidString), .int64(Int64(bounded))], to: statement)

        var newestFirst: [Message] = []
        var retainedBytes = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let rowBytes64 = sqlite3_column_int64(statement, 6)
                guard rowBytes64 >= 0, rowBytes64 <= Int64(Int.max) else {
                    throw SQLiteStoreError.corruptRow("message.content has an invalid byte length")
                }
                let rowBytes = Int(rowBytes64)
                guard rowBytes <= maximumAggregateBytes - retainedBytes else {
                    return Array(newestFirst.reversed())
                }
                newestFirst.append(try decodeMessage(statement))
                retainedBytes += rowBytes
            case SQLITE_DONE:
                return Array(newestFirst.reversed())
            default:
                throw sqliteError()
            }
        }
    }

    public func deleteMessage(id: UUID) throws {
        try update("DELETE FROM messages WHERE id = ?", bindings: [.text(id.uuidString)])
        try hardenDatabaseArtifacts()
    }

    // MARK: - Setup

    private static func prepareOwnerOnlyLocation(for databaseURL: URL) throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try validateDatabasePath(databaseURL)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw SQLiteStoreError.fileSystem(operation: "create database directory", code: errno)
        }
        // Revalidate after creation so an existing redirected ancestor is never
        // accepted merely because FileManager could traverse it.
        try validateDatabasePath(databaseURL)
        try setPermissions(0o700, for: directoryURL, allowMissing: false)
    }

    private static func validateDatabasePath(_ databaseURL: URL) throws {
        let components = databaseURL.standardizedFileURL.pathComponents
        guard components.first == "/", components.count >= 2 else {
            throw SQLiteStoreError.invalidDatabaseURL
        }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst().dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            let result = current.path.withCString { lstat($0, &metadata) }
            if result != 0 {
                if errno == ENOENT { break }
                throw SQLiteStoreError.fileSystem(
                    operation: "inspect database directory",
                    code: errno
                )
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK), isAllowedSystemRootAlias(current.path) {
                continue
            }
            guard kind == mode_t(S_IFDIR) else {
                throw SQLiteStoreError.fileSystem(
                    operation: "reject redirected database directory",
                    code: kind == mode_t(S_IFLNK) ? ELOOP : ENOTDIR
                )
            }
        }

        for candidate in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ] {
            try validateRegularLeafIfPresent(candidate)
        }
    }

    private static func realPath(_ directoryURL: URL) throws -> URL {
        let pointer = directoryURL.path.withCString { realpath($0, nil) }
        guard let pointer else {
            throw SQLiteStoreError.fileSystem(
                operation: "resolve database directory",
                code: errno
            )
        }
        defer { free(pointer) }
        // Do not call `standardizedFileURL` here: Foundation rewrites the
        // physical `/private/var` path back to the `/var` compatibility
        // symlink, which SQLite's NOFOLLOW mode correctly rejects.
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private static func isAllowedSystemRootAlias(_ path: String) -> Bool {
        // macOS exposes these root-level compatibility aliases as symlinks.
        // No deeper symlink is trusted for app-owned database storage.
        ["/var", "/tmp", "/etc"].contains(path)
    }

    private static func validateRegularLeafIfPresent(_ url: URL) throws {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        if result != 0 {
            if errno == ENOENT { return }
            throw SQLiteStoreError.fileSystem(operation: "inspect database artifact", code: errno)
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) else {
            throw SQLiteStoreError.fileSystem(
                operation: "reject redirected database artifact",
                code: kind == mode_t(S_IFLNK) ? ELOOP : EINVAL
            )
        }
    }

    private static func setPermissions(
        _ mode: mode_t,
        for url: URL,
        allowMissing: Bool
    ) throws {
        var metadata = stat()
        let inspectResult = url.path.withCString { lstat($0, &metadata) }
        if inspectResult != 0 {
            if allowMissing, errno == ENOENT { return }
            throw SQLiteStoreError.fileSystem(operation: "inspect \(url.lastPathComponent)", code: errno)
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        let expectedKind = url.hasDirectoryPath ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard kind == expectedKind else {
            throw SQLiteStoreError.fileSystem(
                operation: "reject redirected \(url.lastPathComponent)",
                code: kind == mode_t(S_IFLNK) ? ELOOP : EINVAL
            )
        }

        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            | (expectedKind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
        let descriptor = url.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            if allowMissing, errno == ENOENT { return }
            throw SQLiteStoreError.fileSystem(operation: "open \(url.lastPathComponent)", code: errno)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else {
            throw SQLiteStoreError.fileSystem(operation: "chmod \(url.lastPathComponent)", code: errno)
        }
    }

    private func hardenDatabaseArtifacts() throws {
        try Self.setPermissions(0o600, for: databaseURL, allowMissing: false)
        try Self.setPermissions(
            0o600,
            for: URL(fileURLWithPath: databaseURL.path + "-wal"),
            allowMissing: true
        )
        try Self.setPermissions(
            0o600,
            for: URL(fileURLWithPath: databaseURL.path + "-shm"),
            allowMissing: true
        )
    }

    private static func configureAndMigrate(
        _ connection: OpaquePointer,
        databaseURL: URL,
        busyTimeoutMilliseconds: Int32
    ) throws {
        sqlite3_extended_result_codes(connection, 1)
        guard sqlite3_busy_timeout(connection, busyTimeoutMilliseconds) == SQLITE_OK else {
            throw sqliteError(for: connection)
        }
        try execute("PRAGMA foreign_keys = ON", on: connection)
        try execute("PRAGMA journal_mode = WAL", on: connection)
        try execute("PRAGMA synchronous = NORMAL", on: connection)

        var currentVersion = try pragmaInt32("PRAGMA user_version", on: connection)
        if currentVersion == 0 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
                try execute(
                    """
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
                        skill_ids TEXT NOT NULL DEFAULT '[]'
                            CHECK(length(CAST(skill_ids AS BLOB)) <= 32768),
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
                    \(Self.createExternalSessionSchemaSQL)
                    \(Self.createContinuitySchemaSQL)
                    PRAGMA user_version = 4;
                    """,
                    on: connection
                )
                try execute("COMMIT", on: connection)
                currentVersion = 4
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }

        if currentVersion == 1 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
                try execute(
                    """
                    ALTER TABLE conversations ADD COLUMN skill_ids TEXT NOT NULL DEFAULT '[]'
                        CHECK(length(CAST(skill_ids AS BLOB)) <= 32768);
                    PRAGMA user_version = 2;
                    """,
                    on: connection
                )
                try execute("COMMIT", on: connection)
                currentVersion = 2
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }

        if currentVersion == 2 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
                try execute(Self.createExternalSessionSchemaSQL, on: connection)
                try execute("PRAGMA user_version = 3", on: connection)
                try execute("COMMIT", on: connection)
                currentVersion = 3
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }

        if currentVersion == 3 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
                try execute(Self.createContinuitySchemaSQL, on: connection)
                try execute("PRAGMA user_version = 4", on: connection)
                try execute("COMMIT", on: connection)
                currentVersion = 4
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }

        guard currentVersion == Self.schemaVersion else {
            throw SQLiteStoreError.unsupportedSchemaVersion(currentVersion)
        }

        try setPermissions(0o600, for: databaseURL, allowMissing: false)
        try setPermissions(
            0o600,
            for: URL(fileURLWithPath: databaseURL.path + "-wal"),
            allowMissing: true
        )
        try setPermissions(
            0o600,
            for: URL(fileURLWithPath: databaseURL.path + "-shm"),
            allowMissing: true
        )
    }

    private static let createExternalSessionSchemaSQL = """
    CREATE TABLE external_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        provider TEXT NOT NULL,
        surface TEXT NOT NULL,
        provider_session_id TEXT NOT NULL
            CHECK(length(CAST(provider_session_id AS BLOB)) BETWEEN 1 AND 1024),
        workspace_path TEXT
            CHECK(workspace_path IS NULL OR length(CAST(workspace_path AS BLOB)) <= 16384),
        title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) <= 1024),
        preview TEXT NOT NULL CHECK(length(CAST(preview AS BLOB)) <= 4096),
        provider_status TEXT NOT NULL
            CHECK(length(CAST(provider_status AS BLOB)) <= 1024),
        can_resume INTEGER NOT NULL CHECK(can_resume IN (0, 1)),
        can_read_transcript INTEGER NOT NULL CHECK(can_read_transcript IN (0, 1)),
        source_path TEXT NOT NULL
            CHECK(length(CAST(source_path AS BLOB)) BETWEEN 1 AND 16384),
        source_byte_count INTEGER NOT NULL CHECK(source_byte_count >= 0),
        source_modified_at REAL NOT NULL,
        first_seen_at REAL NOT NULL,
        last_seen_at REAL NOT NULL,
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
    """

    private static let createContinuitySchemaSQL = """
    CREATE TABLE continuity_projects (
        id TEXT PRIMARY KEY NOT NULL,
        workspace_id TEXT NOT NULL
            REFERENCES workspaces(id) ON DELETE CASCADE,
        name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 512),
        summary TEXT
            CHECK(summary IS NULL OR length(CAST(summary AS BLOB)) <= 16384),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX continuity_projects_workspace_updated
        ON continuity_projects(workspace_id, updated_at DESC, created_at DESC, id ASC);

    CREATE TABLE continuity_session_links (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL
            REFERENCES continuity_projects(id) ON DELETE CASCADE,
        conversation_id TEXT
            REFERENCES conversations(id) ON DELETE CASCADE,
        external_session_id TEXT
            REFERENCES external_sessions(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK(kind IN ('primary', 'context', 'successor')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK(
            (conversation_id IS NOT NULL AND external_session_id IS NULL)
            OR (conversation_id IS NULL AND external_session_id IS NOT NULL)
        ),
        UNIQUE(project_id, conversation_id),
        UNIQUE(project_id, external_session_id)
    );
    CREATE INDEX continuity_session_links_project_updated
        ON continuity_session_links(project_id, updated_at DESC, created_at DESC, id ASC);

    CREATE TABLE continuity_handoffs (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL
            REFERENCES continuity_projects(id) ON DELETE CASCADE,
        source_session_link_id TEXT NOT NULL
            REFERENCES continuity_session_links(id) ON DELETE CASCADE,
        destination_session_link_id TEXT
            REFERENCES continuity_session_links(id) ON DELETE SET NULL,
        title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) BETWEEN 1 AND 512),
        summary TEXT NOT NULL CHECK(length(CAST(summary AS BLOB)) BETWEEN 1 AND 16384),
        state TEXT NOT NULL CHECK(state IN ('draft', 'ready', 'acknowledged', 'superseded')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX continuity_handoffs_project_updated
        ON continuity_handoffs(project_id, updated_at DESC, created_at DESC, id ASC);

    CREATE TABLE continuity_events (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL
            REFERENCES continuity_projects(id) ON DELETE CASCADE,
        session_link_id TEXT
            REFERENCES continuity_session_links(id) ON DELETE SET NULL,
        handoff_id TEXT
            REFERENCES continuity_handoffs(id) ON DELETE SET NULL,
        kind TEXT NOT NULL CHECK(kind IN (
            'projectCreated', 'sessionLinked', 'handoffCreated', 'handoffStateChanged',
            'syncStarted', 'syncCompleted', 'syncFailed', 'note'
        )),
        detail TEXT NOT NULL CHECK(length(CAST(detail AS BLOB)) BETWEEN 1 AND 4096),
        occurred_at REAL NOT NULL
    );
    CREATE INDEX continuity_events_project_occurred
        ON continuity_events(project_id, occurred_at DESC, id ASC);

    CREATE TABLE continuity_sync_transactions (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL
            REFERENCES continuity_projects(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK(kind IN ('manual', 'automatic', 'recovery')),
        state TEXT NOT NULL CHECK(state IN ('pending', 'running', 'succeeded', 'failed')),
        attempt INTEGER NOT NULL CHECK(attempt >= 0),
        started_at REAL,
        completed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
        writer_token TEXT
            CHECK(writer_token IS NULL OR length(CAST(writer_token AS BLOB)) = 36),
        writer_lease_expires_at REAL,
        CHECK(
            (state IN ('pending', 'running') AND completed_at IS NULL)
            OR (state IN ('succeeded', 'failed') AND completed_at IS NOT NULL)
        ),
        CHECK(
            (writer_token IS NULL AND writer_lease_expires_at IS NULL)
            OR (writer_token IS NOT NULL AND writer_lease_expires_at IS NOT NULL)
        )
    );
    CREATE INDEX continuity_sync_transactions_project_updated
        ON continuity_sync_transactions(project_id, updated_at DESC, created_at DESC, id ASC);
    """

    private static func execute(_ sql: String, on connection: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.sqlite(code: result, message: message)
        }
    }

    private static func pragmaInt32(_ sql: String, on connection: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw sqliteError(for: connection, code: prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw sqliteError(for: connection, code: stepResult)
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func sqliteError(
        for connection: OpaquePointer,
        code: Int32? = nil
    ) -> SQLiteStoreError {
        .sqlite(
            code: code ?? sqlite3_extended_errcode(connection),
            message: String(cString: sqlite3_errmsg(connection))
        )
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String) throws {
        guard let database else {
            throw SQLiteStoreError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw SQLiteStoreError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(code: result)
        }
        return statement
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                let byteCount = text.utf8.count
                guard byteCount <= Int(Int32.max) else {
                    throw SQLiteStoreError.textTooLarge(actualBytes: byteCount)
                }
                result = text.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        Int32(byteCount),
                        Self.sqliteTransient
                    )
                }
            case let .double(number):
                result = sqlite3_bind_double(statement, index, number)
            case let .int64(number):
                result = sqlite3_bind_int64(statement, index, number)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw sqliteError(code: result)
            }
        }
    }

    private func update(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(code: result)
        }
    }

    private func pragmaInt32(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return sqlite3_column_int(statement, 0)
    }

    private func pragmaString(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return try requiredText(statement, column: 0, name: "pragma")
    }

    private func sqliteError(code: Int32? = nil) -> SQLiteStoreError {
        let actualCode = code ?? database.map(sqlite3_extended_errcode) ?? SQLITE_MISUSE
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return .sqlite(code: actualCode, message: message)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let externalSessionColumns = """
    SELECT external_sessions.id,
           external_sessions.provider,
           external_sessions.surface,
           external_sessions.provider_session_id,
           external_sessions.workspace_path,
           external_sessions.title,
           external_sessions.preview,
           external_sessions.provider_status,
           external_sessions.can_resume,
           external_sessions.can_read_transcript,
           external_sessions.source_path,
           external_sessions.source_byte_count,
           external_sessions.source_modified_at,
           external_sessions.first_seen_at,
           external_sessions.last_seen_at,
           external_sessions.parent_provider_session_id,
           external_sessions.is_sidechain,
           external_sessions.content_digest,
           external_sessions.missing_since
    FROM external_sessions
    """

    // MARK: - Validation and decoding

    private func boundedLimit(_ requested: Int, maximum: Int) throws -> Int {
        guard requested >= 0 else { throw SQLiteStoreError.invalidLimit(requested) }
        return min(requested, maximum)
    }

    private func validatedOffset(_ offset: Int) throws -> Int {
        guard offset >= 0 else { throw SQLiteStoreError.invalidLimit(offset) }
        return offset
    }

    private func validateMessageSize(_ content: String) throws {
        let actual = content.utf8.count
        guard actual <= Self.maximumMessageBytes else {
            throw SQLiteStoreError.messageTooLarge(
                actualBytes: actual,
                maximumBytes: Self.maximumMessageBytes
            )
        }
    }

    private func conversationBindings(_ conversation: Conversation) throws -> [Binding] {
        [
            .text(conversation.id.uuidString),
            .text(conversation.workspaceID.uuidString),
            .text(conversation.title),
            .text(conversation.provider.rawValue),
            .text(conversation.workflow.rawValue),
            .text(conversation.permissionMode.rawValue),
            .text(conversation.status.rawValue),
            conversation.providerSessionID.map(Binding.text) ?? .null,
            .text(try encodeSkillIDs(conversation.skillIDs)),
            .double(conversation.createdAt.timeIntervalSince1970),
            .double(conversation.updatedAt.timeIntervalSince1970),
        ]
    }

    private func encodeSkillIDs(_ skillIDs: [String]) throws -> String {
        let canonical = Conversation.canonicalSkillIDs(skillIDs)
        let data = try JSONEncoder().encode(canonical)
        guard data.count <= Self.maximumSkillIDsStorageBytes else {
            throw SQLiteStoreError.skillIDsTooLarge(
                actualBytes: data.count,
                maximumBytes: Self.maximumSkillIDsStorageBytes
            )
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw SQLiteStoreError.corruptRow("skill IDs could not be encoded as UTF-8")
        }
        return encoded
    }

    private func decodeSkillIDs(_ encoded: String) throws -> [String] {
        let byteCount = encoded.utf8.count
        guard byteCount <= Self.maximumSkillIDsStorageBytes else {
            throw SQLiteStoreError.corruptRow("conversation.skill_ids exceeds its storage bound")
        }
        guard let data = encoded.data(using: .utf8) else {
            throw SQLiteStoreError.corruptRow("conversation.skill_ids is not UTF-8")
        }
        let decoded: [String]
        do {
            decoded = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw SQLiteStoreError.corruptRow("conversation.skill_ids is not a JSON string array")
        }
        let canonical = Conversation.canonicalSkillIDs(decoded)
        guard decoded == canonical else {
            throw SQLiteStoreError.corruptRow("conversation.skill_ids is not canonical")
        }
        return canonical
    }

    private func messageBindings(_ message: Message) -> [Binding] {
        [
            .text(message.id.uuidString),
            .text(message.conversationID.uuidString),
            .text(message.role.rawValue),
            .text(message.content),
            .int64(message.sequence),
            .double(message.createdAt.timeIntervalSince1970),
        ]
    }

    private func externalSessionBindings(_ session: ExternalSession) -> [Binding] {
        [
            .text(session.id.uuidString),
            .text(session.provider.rawValue),
            .text(session.surface.rawValue),
            .text(session.providerSessionID),
            session.workspacePath.map(Binding.text) ?? .null,
            .text(session.title),
            .text(session.preview),
            .text(session.providerStatus),
            .int64(session.canResume ? 1 : 0),
            .int64(session.canReadTranscript ? 1 : 0),
            .text(session.sourcePath),
            .int64(session.sourceByteCount),
            .double(session.sourceModifiedAt.timeIntervalSince1970),
            .double(session.firstSeenAt.timeIntervalSince1970),
            .double(session.lastSeenAt.timeIntervalSince1970),
            session.parentProviderSessionID.map(Binding.text) ?? .null,
            .int64(session.isSidechain ? 1 : 0),
            session.contentDigest.map(Binding.text) ?? .null,
        ]
    }

    private func continuityProjectBindings(_ project: ContinuityProject) -> [Binding] {
        [
            .text(project.id.uuidString),
            .text(project.workspaceID.uuidString),
            .text(project.name),
            project.summary.map(Binding.text) ?? .null,
            .double(project.createdAt.timeIntervalSince1970),
            .double(project.updatedAt.timeIntervalSince1970),
        ]
    }

    private func continuitySessionLinkBindings(_ link: ContinuitySessionLink) -> [Binding] {
        [
            .text(link.id.uuidString),
            .text(link.projectID.uuidString),
            link.conversationID.map { .text($0.uuidString) } ?? .null,
            link.externalSessionID.map { .text($0.uuidString) } ?? .null,
            .text(link.kind.rawValue),
            .double(link.createdAt.timeIntervalSince1970),
            .double(link.updatedAt.timeIntervalSince1970),
        ]
    }

    private func continuityHandoffBindings(_ handoff: ContinuityHandoff) -> [Binding] {
        [
            .text(handoff.id.uuidString),
            .text(handoff.projectID.uuidString),
            .text(handoff.sourceSessionLinkID.uuidString),
            handoff.destinationSessionLinkID.map { .text($0.uuidString) } ?? .null,
            .text(handoff.title),
            .text(handoff.summary),
            .text(handoff.state.rawValue),
            .double(handoff.createdAt.timeIntervalSince1970),
            .double(handoff.updatedAt.timeIntervalSince1970),
        ]
    }

    private func continuityEventBindings(_ event: ContinuityEvent) -> [Binding] {
        [
            .text(event.id.uuidString),
            .text(event.projectID.uuidString),
            event.sessionLinkID.map { .text($0.uuidString) } ?? .null,
            event.handoffID.map { .text($0.uuidString) } ?? .null,
            .text(event.kind.rawValue),
            .text(event.detail),
            .double(event.occurredAt.timeIntervalSince1970),
        ]
    }

    private func continuitySyncTransactionBindings(
        _ transaction: ContinuitySyncTransaction
    ) -> [Binding] {
        [
            .text(transaction.id.uuidString),
            .text(transaction.projectID.uuidString),
            .text(transaction.kind.rawValue),
            .text(transaction.state.rawValue),
            .int64(Int64(transaction.attempt)),
            transaction.startedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            transaction.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .double(transaction.createdAt.timeIntervalSince1970),
            .double(transaction.updatedAt.timeIntervalSince1970),
            .int64(transaction.revision),
        ]
    }

    private func validateContinuitySessionLinkReferences(_ link: ContinuitySessionLink) throws {
        guard let project = try continuityProject(id: link.projectID) else {
            throw SQLiteStoreError.notFound("continuity project")
        }
        if let conversationID = link.conversationID {
            guard let conversation = try conversation(id: conversationID) else {
                throw SQLiteStoreError.notFound("conversation")
            }
            guard conversation.workspaceID == project.workspaceID else {
                throw SQLiteStoreError.invalidContinuityRelationship(
                    "an app conversation must belong to the project's workspace"
                )
            }
        }
        if let externalSessionID = link.externalSessionID,
           try externalSession(id: externalSessionID) == nil {
            throw SQLiteStoreError.notFound("external session")
        }
    }

    private func validateContinuityHandoffReferences(_ handoff: ContinuityHandoff) throws {
        guard try continuityProject(id: handoff.projectID) != nil else {
            throw SQLiteStoreError.notFound("continuity project")
        }
        guard let source = try continuitySessionLink(id: handoff.sourceSessionLinkID) else {
            throw SQLiteStoreError.notFound("source continuity session link")
        }
        guard source.projectID == handoff.projectID else {
            throw SQLiteStoreError.invalidContinuityRelationship(
                "a handoff source must belong to its project"
            )
        }
        if let destinationID = handoff.destinationSessionLinkID {
            guard let destination = try continuitySessionLink(id: destinationID) else {
                throw SQLiteStoreError.notFound("destination continuity session link")
            }
            guard destination.projectID == handoff.projectID else {
                throw SQLiteStoreError.invalidContinuityRelationship(
                    "a handoff destination must belong to its project"
                )
            }
        }
    }

    private func validateContinuityEventReferences(_ event: ContinuityEvent) throws {
        guard try continuityProject(id: event.projectID) != nil else {
            throw SQLiteStoreError.notFound("continuity project")
        }
        if let sessionLinkID = event.sessionLinkID {
            guard let link = try continuitySessionLink(id: sessionLinkID) else {
                throw SQLiteStoreError.notFound("continuity session link")
            }
            guard link.projectID == event.projectID else {
                throw SQLiteStoreError.invalidContinuityRelationship(
                    "an event session link must belong to its project"
                )
            }
        }
        if let handoffID = event.handoffID {
            guard let handoff = try continuityHandoff(id: handoffID) else {
                throw SQLiteStoreError.notFound("continuity handoff")
            }
            guard handoff.projectID == event.projectID else {
                throw SQLiteStoreError.invalidContinuityRelationship(
                    "an event handoff must belong to its project"
                )
            }
        }
    }

    private func validateContinuityLease(now: Date, duration: TimeInterval) throws {
        try validateContinuityDate(now, field: "leaseNow")
        guard duration.isFinite, duration >= 1, duration <= Self.maximumContinuityWriterLeaseDuration else {
            throw ContinuityValidationError.invalidLeaseDuration(duration)
        }
    }

    private func validateContinuityDate(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ContinuityValidationError.invalidDate(field: field)
        }
    }

    private func nextMessageSequence(conversationID: UUID) throws -> Int64 {
        let statement = try prepare(
            "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE conversation_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(conversationID.uuidString)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func decodeWorkspace(_ statement: OpaquePointer) throws -> Workspace {
        Workspace(
            id: try requiredUUID(statement, column: 0, name: "workspace.id"),
            name: try requiredText(statement, column: 1, name: "workspace.name"),
            rootPath: try requiredText(statement, column: 2, name: "workspace.root_path"),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    private func decodeConversation(_ statement: OpaquePointer) throws -> Conversation {
        let providerText = try requiredText(statement, column: 3, name: "conversation.provider")
        let workflowText = try requiredText(statement, column: 4, name: "conversation.workflow")
        let permissionText = try requiredText(statement, column: 5, name: "conversation.permission_mode")
        let statusText = try requiredText(statement, column: 6, name: "conversation.status")
        guard
            let provider = ProviderKind(rawValue: providerText),
            let workflow = WorkflowKind(rawValue: workflowText),
            let permissionMode = PermissionMode(rawValue: permissionText),
            let status = ConversationStatus(rawValue: statusText)
        else {
            throw SQLiteStoreError.corruptRow("conversation contains an unknown enum value")
        }

        return Conversation(
            id: try requiredUUID(statement, column: 0, name: "conversation.id"),
            workspaceID: try requiredUUID(statement, column: 1, name: "conversation.workspace_id"),
            title: try requiredText(statement, column: 2, name: "conversation.title"),
            provider: provider,
            workflow: workflow,
            permissionMode: permissionMode,
            status: status,
            providerSessionID: optionalText(statement, column: 7),
            skillIDs: try decodeSkillIDs(
                requiredText(statement, column: 8, name: "conversation.skill_ids")
            ),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    private func decodeContinuityProject(_ statement: OpaquePointer) throws -> ContinuityProject {
        do {
            return try ContinuityProject(
                id: try requiredUUID(statement, column: 0, name: "continuity_project.id"),
                workspaceID: try requiredUUID(
                    statement,
                    column: 1,
                    name: "continuity_project.workspace_id"
                ),
                name: try requiredText(statement, column: 2, name: "continuity_project.name"),
                summary: optionalText(statement, column: 3),
                createdAt: try finiteDate(
                    statement,
                    column: 4,
                    name: "continuity_project.created_at"
                ),
                updatedAt: try finiteDate(
                    statement,
                    column: 5,
                    name: "continuity_project.updated_at"
                )
            )
        } catch let error as ContinuityValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func decodeContinuitySessionLink(
        _ statement: OpaquePointer
    ) throws -> ContinuitySessionLink {
        let kindText = try requiredText(statement, column: 4, name: "continuity_session_link.kind")
        guard let kind = ContinuitySessionLinkKind(rawValue: kindText) else {
            throw SQLiteStoreError.corruptRow("continuity_session_link.kind is unknown")
        }
        do {
            return try ContinuitySessionLink(
                id: try requiredUUID(statement, column: 0, name: "continuity_session_link.id"),
                projectID: try requiredUUID(
                    statement,
                    column: 1,
                    name: "continuity_session_link.project_id"
                ),
                conversationID: try optionalUUID(
                    statement,
                    column: 2,
                    name: "continuity_session_link.conversation_id"
                ),
                externalSessionID: try optionalUUID(
                    statement,
                    column: 3,
                    name: "continuity_session_link.external_session_id"
                ),
                kind: kind,
                createdAt: try finiteDate(
                    statement,
                    column: 5,
                    name: "continuity_session_link.created_at"
                ),
                updatedAt: try finiteDate(
                    statement,
                    column: 6,
                    name: "continuity_session_link.updated_at"
                )
            )
        } catch let error as ContinuityValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func decodeContinuityHandoff(_ statement: OpaquePointer) throws -> ContinuityHandoff {
        let stateText = try requiredText(statement, column: 6, name: "continuity_handoff.state")
        guard let state = ContinuityHandoffState(rawValue: stateText) else {
            throw SQLiteStoreError.corruptRow("continuity_handoff.state is unknown")
        }
        do {
            return try ContinuityHandoff(
                id: try requiredUUID(statement, column: 0, name: "continuity_handoff.id"),
                projectID: try requiredUUID(statement, column: 1, name: "continuity_handoff.project_id"),
                sourceSessionLinkID: try requiredUUID(
                    statement,
                    column: 2,
                    name: "continuity_handoff.source_session_link_id"
                ),
                destinationSessionLinkID: try optionalUUID(
                    statement,
                    column: 3,
                    name: "continuity_handoff.destination_session_link_id"
                ),
                title: try requiredText(statement, column: 4, name: "continuity_handoff.title"),
                summary: try requiredText(statement, column: 5, name: "continuity_handoff.summary"),
                state: state,
                createdAt: try finiteDate(
                    statement,
                    column: 7,
                    name: "continuity_handoff.created_at"
                ),
                updatedAt: try finiteDate(
                    statement,
                    column: 8,
                    name: "continuity_handoff.updated_at"
                )
            )
        } catch let error as ContinuityValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func decodeContinuityEvent(_ statement: OpaquePointer) throws -> ContinuityEvent {
        let kindText = try requiredText(statement, column: 4, name: "continuity_event.kind")
        guard let kind = ContinuityEventKind(rawValue: kindText) else {
            throw SQLiteStoreError.corruptRow("continuity_event.kind is unknown")
        }
        do {
            return try ContinuityEvent(
                id: try requiredUUID(statement, column: 0, name: "continuity_event.id"),
                projectID: try requiredUUID(statement, column: 1, name: "continuity_event.project_id"),
                sessionLinkID: try optionalUUID(
                    statement,
                    column: 2,
                    name: "continuity_event.session_link_id"
                ),
                handoffID: try optionalUUID(
                    statement,
                    column: 3,
                    name: "continuity_event.handoff_id"
                ),
                kind: kind,
                detail: try requiredText(statement, column: 5, name: "continuity_event.detail"),
                occurredAt: try finiteDate(
                    statement,
                    column: 6,
                    name: "continuity_event.occurred_at"
                )
            )
        } catch let error as ContinuityValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func decodeContinuitySyncTransaction(
        _ statement: OpaquePointer
    ) throws -> ContinuitySyncTransaction {
        let kindText = try requiredText(statement, column: 2, name: "continuity_sync_transaction.kind")
        let stateText = try requiredText(statement, column: 3, name: "continuity_sync_transaction.state")
        guard let kind = ContinuitySyncKind(rawValue: kindText) else {
            throw SQLiteStoreError.corruptRow("continuity_sync_transaction.kind is unknown")
        }
        guard let state = ContinuitySyncState(rawValue: stateText) else {
            throw SQLiteStoreError.corruptRow("continuity_sync_transaction.state is unknown")
        }
        let attempt64 = sqlite3_column_int64(statement, 4)
        guard attempt64 >= 0, attempt64 <= Int64(Int.max) else {
            throw SQLiteStoreError.corruptRow("continuity_sync_transaction.attempt is invalid")
        }
        let revision = sqlite3_column_int64(statement, 9)
        guard revision >= 0 else {
            throw SQLiteStoreError.corruptRow("continuity_sync_transaction.revision is negative")
        }
        do {
            return try ContinuitySyncTransaction(
                id: try requiredUUID(statement, column: 0, name: "continuity_sync_transaction.id"),
                projectID: try requiredUUID(
                    statement,
                    column: 1,
                    name: "continuity_sync_transaction.project_id"
                ),
                kind: kind,
                state: state,
                attempt: Int(attempt64),
                startedAt: try optionalFiniteDate(
                    statement,
                    column: 5,
                    name: "continuity_sync_transaction.started_at"
                ),
                completedAt: try optionalFiniteDate(
                    statement,
                    column: 6,
                    name: "continuity_sync_transaction.completed_at"
                ),
                createdAt: try finiteDate(
                    statement,
                    column: 7,
                    name: "continuity_sync_transaction.created_at"
                ),
                updatedAt: try finiteDate(
                    statement,
                    column: 8,
                    name: "continuity_sync_transaction.updated_at"
                ),
                revision: revision
            )
        } catch let error as ContinuityValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func decodeMessage(_ statement: OpaquePointer) throws -> Message {
        let roleText = try requiredText(statement, column: 2, name: "message.role")
        guard let role = MessageRole(rawValue: roleText) else {
            throw SQLiteStoreError.corruptRow("message contains an unknown role")
        }
        return Message(
            id: try requiredUUID(statement, column: 0, name: "message.id"),
            conversationID: try requiredUUID(statement, column: 1, name: "message.conversation_id"),
            role: role,
            content: try requiredText(statement, column: 3, name: "message.content"),
            sequence: sqlite3_column_int64(statement, 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func stepExternalSession(_ statement: OpaquePointer) throws -> ExternalSession? {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeExternalSession(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    private func decodeExternalSession(_ statement: OpaquePointer) throws -> ExternalSession {
        let providerText = try requiredText(statement, column: 1, name: "external_session.provider")
        let surfaceText = try requiredText(statement, column: 2, name: "external_session.surface")
        guard let provider = ProviderKind(rawValue: providerText) else {
            throw SQLiteStoreError.corruptRow("external_session.provider is unknown")
        }
        guard let surface = ExternalSessionSurface(rawValue: surfaceText) else {
            throw SQLiteStoreError.corruptRow("external_session.surface is unknown")
        }
        let sourceByteCount = sqlite3_column_int64(statement, 11)
        guard sourceByteCount >= 0 else {
            throw SQLiteStoreError.corruptRow("external_session.source_byte_count is negative")
        }

        do {
            return try ExternalSession(
                id: try requiredUUID(statement, column: 0, name: "external_session.id"),
                provider: provider,
                surface: surface,
                providerSessionID: try requiredText(
                    statement,
                    column: 3,
                    name: "external_session.provider_session_id"
                ),
                workspacePath: optionalText(statement, column: 4),
                title: try requiredText(statement, column: 5, name: "external_session.title"),
                preview: try requiredText(statement, column: 6, name: "external_session.preview"),
                providerStatus: try requiredText(
                    statement,
                    column: 7,
                    name: "external_session.provider_status"
                ),
                canResume: try requiredBoolean(
                    statement,
                    column: 8,
                    name: "external_session.can_resume"
                ),
                canReadTranscript: try requiredBoolean(
                    statement,
                    column: 9,
                    name: "external_session.can_read_transcript"
                ),
                sourcePath: try requiredText(
                    statement,
                    column: 10,
                    name: "external_session.source_path"
                ),
                sourceByteCount: sourceByteCount,
                sourceModifiedAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 12)
                ),
                firstSeenAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 13)
                ),
                lastSeenAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 14)
                ),
                parentProviderSessionID: optionalText(statement, column: 15),
                isSidechain: try requiredBoolean(
                    statement,
                    column: 16,
                    name: "external_session.is_sidechain"
                ),
                contentDigest: optionalText(statement, column: 17),
                missingSince: optionalDate(statement, column: 18)
            )
        } catch let error as ExternalSessionValidationError {
            throw SQLiteStoreError.corruptRow(error.description)
        }
    }

    private func requiredUUID(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> UUID {
        let value = try requiredText(statement, column: column, name: name)
        guard let uuid = UUID(uuidString: value) else {
            throw SQLiteStoreError.corruptRow("\(name) is not a UUID")
        }
        return uuid
    }

    private func optionalUUID(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> UUID? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = try requiredText(statement, column: column, name: name)
        guard let uuid = UUID(uuidString: value) else {
            throw SQLiteStoreError.corruptRow("\(name) is not a UUID")
        }
        return uuid
    }

    private func requiredBoolean(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> Bool {
        let value = sqlite3_column_int64(statement, column)
        guard value == 0 || value == 1 else {
            throw SQLiteStoreError.corruptRow("\(name) is not a Boolean")
        }
        return value == 1
    }

    private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func finiteDate(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> Date {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            throw SQLiteStoreError.corruptRow("\(name) is null")
        }
        let timestamp = sqlite3_column_double(statement, column)
        guard timestamp.isFinite else {
            throw SQLiteStoreError.corruptRow("\(name) is not finite")
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func optionalFiniteDate(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return try finiteDate(statement, column: column, name: name)
    }

    private func requiredText(
        _ statement: OpaquePointer,
        column: Int32,
        name: String
    ) throws -> String {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else {
            throw SQLiteStoreError.corruptRow("\(name) is null")
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: byteCount),
            as: UTF8.self
        )
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: byteCount),
            as: UTF8.self
        )
    }
}
