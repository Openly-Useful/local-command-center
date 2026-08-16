import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum WorkflowKind: String, Codable, CaseIterable, Sendable {
    case interactive
    case implementation
    case backgroundReview
    case swarmWorker

    public var isInteractive: Bool {
        switch self {
        case .interactive, .implementation:
            true
        case .backgroundReview, .swarmWorker:
            false
        }
    }
}

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case readOnly
    case workspaceWrite
}

public enum ConversationStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case queued
    case running
    case waitingForInput
    case completed
    case failed
    case cancelled
}

public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Conversation: Codable, Equatable, Identifiable, Sendable {
    public static let maximumSkillIDCount = 32
    public static let maximumSkillIDBytes = 256

    public let id: UUID
    public let workspaceID: UUID
    public var title: String
    public var provider: ProviderKind
    public var workflow: WorkflowKind
    public var permissionMode: PermissionMode
    public var status: ConversationStatus
    public var providerSessionID: String?
    public var skillIDs: [String] {
        didSet {
            skillIDs = Self.canonicalSkillIDs(skillIDs)
        }
    }
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        title: String,
        provider: ProviderKind,
        workflow: WorkflowKind = .interactive,
        permissionMode: PermissionMode = .readOnly,
        status: ConversationStatus = .idle,
        providerSessionID: String? = nil,
        skillIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.provider = provider
        self.workflow = workflow
        self.permissionMode = permissionMode
        self.status = status
        self.providerSessionID = providerSessionID
        self.skillIDs = Self.canonicalSkillIDs(skillIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Produces the single persisted and dispatched representation of skill IDs.
    /// Invalid/control-bearing IDs are dropped, Unicode is normalized to NFC,
    /// duplicates are removed, and the deterministic result is strictly bounded.
    public static func canonicalSkillIDs(_ skillIDs: [String]) -> [String] {
        var normalized = Set<String>()
        for skillID in skillIDs {
            let candidate = skillID
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !candidate.isEmpty,
                candidate.utf8.count <= maximumSkillIDBytes,
                !candidate.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else { continue }
            normalized.insert(candidate)
        }
        return Array(normalized.sorted().prefix(maximumSkillIDCount))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case title
        case provider
        case workflow
        case permissionMode
        case status
        case providerSessionID
        case skillIDs
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            workspaceID: try container.decode(UUID.self, forKey: .workspaceID),
            title: try container.decode(String.self, forKey: .title),
            provider: try container.decode(ProviderKind.self, forKey: .provider),
            workflow: try container.decode(WorkflowKind.self, forKey: .workflow),
            permissionMode: try container.decode(PermissionMode.self, forKey: .permissionMode),
            status: try container.decode(ConversationStatus.self, forKey: .status),
            providerSessionID: try container.decodeIfPresent(String.self, forKey: .providerSessionID),
            skillIDs: try container.decodeIfPresent([String].self, forKey: .skillIDs) ?? [],
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct Message: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let role: MessageRole
    public let content: String
    public let sequence: Int64
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: MessageRole,
        content: String,
        sequence: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

// MARK: - Continuity

/// App-owned grouping for local continuity metadata. A continuity project is
/// deliberately anchored to an approved workspace; provider paths and
/// provider-native identifiers remain in the private SQLite index only.
public struct ContinuityProject: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameBytes = 512
    public static let maximumSummaryBytes = 16 * 1_024

    public let id: UUID
    public let workspaceID: UUID
    public var name: String
    /// A bounded, app-authored local summary. This must not contain a copied provider transcript.
    public var summary: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        name: String,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        try ContinuityValidation.validateDate(createdAt, field: "createdAt")
        try ContinuityValidation.validateDate(updatedAt, field: "updatedAt")
        self.id = id
        self.workspaceID = workspaceID
        self.name = try ContinuityValidation.requiredText(
            name,
            field: "name",
            maximumBytes: Self.maximumNameBytes
        )
        self.summary = try ContinuityValidation.optionalText(
            summary,
            field: "summary",
            maximumBytes: Self.maximumSummaryBytes
        )
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, summary, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            workspaceID: try values.decode(UUID.self, forKey: .workspaceID),
            name: try values.decode(String.self, forKey: .name),
            summary: try values.decodeIfPresent(String.self, forKey: .summary),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public enum ContinuitySessionLinkKind: String, Codable, CaseIterable, Sendable {
    case primary
    case context
    case successor
}

/// Registers exactly one app-owned or indexed session in a continuity project.
/// The linked IDs are opaque local UUIDs; raw provider session IDs are not part
/// of the serializable continuity model.
public struct ContinuitySessionLink: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let conversationID: UUID?
    public let externalSessionID: UUID?
    public var kind: ContinuitySessionLinkKind
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        conversationID: UUID? = nil,
        externalSessionID: UUID? = nil,
        kind: ContinuitySessionLinkKind = .context,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard (conversationID == nil) != (externalSessionID == nil) else {
            throw ContinuityValidationError.invalidSessionReference
        }
        try ContinuityValidation.validateDate(createdAt, field: "createdAt")
        try ContinuityValidation.validateDate(updatedAt, field: "updatedAt")
        self.id = id
        self.projectID = projectID
        self.conversationID = conversationID
        self.externalSessionID = externalSessionID
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, conversationID, externalSessionID, kind, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            projectID: try values.decode(UUID.self, forKey: .projectID),
            conversationID: try values.decodeIfPresent(UUID.self, forKey: .conversationID),
            externalSessionID: try values.decodeIfPresent(UUID.self, forKey: .externalSessionID),
            kind: try values.decode(ContinuitySessionLinkKind.self, forKey: .kind),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public enum ContinuityHandoffState: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case acknowledged
    case superseded
}

/// A compact, app-authored summary passed between linked sessions. It is not a
/// provider transcript cache and is deliberately size-bounded.
public struct ContinuityHandoff: Codable, Equatable, Identifiable, Sendable {
    public static let maximumTitleBytes = 512
    public static let maximumSummaryBytes = 16 * 1_024

    public let id: UUID
    public let projectID: UUID
    public let sourceSessionLinkID: UUID
    public var destinationSessionLinkID: UUID?
    public var title: String
    public var summary: String
    public var state: ContinuityHandoffState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID? = nil,
        title: String,
        summary: String,
        state: ContinuityHandoffState = .draft,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        try ContinuityValidation.validateDate(createdAt, field: "createdAt")
        try ContinuityValidation.validateDate(updatedAt, field: "updatedAt")
        self.id = id
        self.projectID = projectID
        self.sourceSessionLinkID = sourceSessionLinkID
        self.destinationSessionLinkID = destinationSessionLinkID
        self.title = try ContinuityValidation.requiredText(
            title,
            field: "title",
            maximumBytes: Self.maximumTitleBytes
        )
        self.summary = try ContinuityValidation.requiredText(
            summary,
            field: "summary",
            maximumBytes: Self.maximumSummaryBytes
        )
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, sourceSessionLinkID, destinationSessionLinkID
        case title, summary, state, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            projectID: try values.decode(UUID.self, forKey: .projectID),
            sourceSessionLinkID: try values.decode(UUID.self, forKey: .sourceSessionLinkID),
            destinationSessionLinkID: try values.decodeIfPresent(
                UUID.self,
                forKey: .destinationSessionLinkID
            ),
            title: try values.decode(String.self, forKey: .title),
            summary: try values.decode(String.self, forKey: .summary),
            state: try values.decode(ContinuityHandoffState.self, forKey: .state),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public enum ContinuityEventKind: String, Codable, CaseIterable, Sendable {
    case projectCreated
    case sessionLinked
    case handoffCreated
    case handoffStateChanged
    case syncStarted
    case syncCompleted
    case syncFailed
    case note
}

/// Immutable local audit metadata for a continuity project. Event detail is
/// restricted to a short description; no provider source fields are exposed.
public struct ContinuityEvent: Codable, Equatable, Identifiable, Sendable {
    public static let maximumDetailBytes = 4 * 1_024

    public let id: UUID
    public let projectID: UUID
    public let sessionLinkID: UUID?
    public let handoffID: UUID?
    public let kind: ContinuityEventKind
    public let detail: String
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sessionLinkID: UUID? = nil,
        handoffID: UUID? = nil,
        kind: ContinuityEventKind,
        detail: String,
        occurredAt: Date = Date()
    ) throws {
        try ContinuityValidation.validateDate(occurredAt, field: "occurredAt")
        self.id = id
        self.projectID = projectID
        self.sessionLinkID = sessionLinkID
        self.handoffID = handoffID
        self.kind = kind
        self.detail = try ContinuityValidation.requiredText(
            detail,
            field: "detail",
            maximumBytes: Self.maximumDetailBytes
        )
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, sessionLinkID, handoffID, kind, detail, occurredAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            projectID: try values.decode(UUID.self, forKey: .projectID),
            sessionLinkID: try values.decodeIfPresent(UUID.self, forKey: .sessionLinkID),
            handoffID: try values.decodeIfPresent(UUID.self, forKey: .handoffID),
            kind: try values.decode(ContinuityEventKind.self, forKey: .kind),
            detail: try values.decode(String.self, forKey: .detail),
            occurredAt: try values.decode(Date.self, forKey: .occurredAt)
        )
    }
}

public enum ContinuitySyncKind: String, Codable, CaseIterable, Sendable {
    case manual
    case automatic
    case recovery
}

public enum ContinuitySyncState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case failed

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed:
            true
        case .pending, .running:
            false
        }
    }
}

/// Public sync metadata intentionally excludes provider IDs, paths, and
/// cursors. Those implementation details, if ever needed, stay DB-private.
public struct ContinuitySyncTransaction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var kind: ContinuitySyncKind
    public var state: ContinuitySyncState
    public var attempt: Int
    public var startedAt: Date?
    public var completedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var revision: Int64

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        kind: ContinuitySyncKind,
        state: ContinuitySyncState = .pending,
        attempt: Int = 0,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int64 = 0
    ) throws {
        guard attempt >= 0 else { throw ContinuityValidationError.negativeAttempt(attempt) }
        guard revision >= 0 else { throw ContinuityValidationError.negativeRevision(revision) }
        try ContinuityValidation.validateDate(createdAt, field: "createdAt")
        try ContinuityValidation.validateDate(updatedAt, field: "updatedAt")
        if let startedAt { try ContinuityValidation.validateDate(startedAt, field: "startedAt") }
        if let completedAt { try ContinuityValidation.validateDate(completedAt, field: "completedAt") }
        guard state.isTerminal == (completedAt != nil) else {
            throw ContinuityValidationError.invalidSyncCompletion(state: state)
        }
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.state = state
        self.attempt = attempt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, kind, state, attempt, startedAt, completedAt
        case createdAt, updatedAt, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            projectID: try values.decode(UUID.self, forKey: .projectID),
            kind: try values.decode(ContinuitySyncKind.self, forKey: .kind),
            state: try values.decode(ContinuitySyncState.self, forKey: .state),
            attempt: try values.decode(Int.self, forKey: .attempt),
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt),
            completedAt: try values.decodeIfPresent(Date.self, forKey: .completedAt),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt),
            revision: try values.decode(Int64.self, forKey: .revision)
        )
    }
}

/// Opaque, local-only writer ownership returned by SQLite CAS acquisition.
public struct ContinuityWriterLease: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let ownerID: UUID
    public let expiresAt: Date
    public let revision: Int64

    public init(
        transactionID: UUID,
        ownerID: UUID,
        expiresAt: Date,
        revision: Int64
    ) throws {
        try ContinuityValidation.validateDate(expiresAt, field: "expiresAt")
        guard revision >= 0 else { throw ContinuityValidationError.negativeRevision(revision) }
        self.transactionID = transactionID
        self.ownerID = ownerID
        self.expiresAt = expiresAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID, ownerID, expiresAt, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transactionID: try values.decode(UUID.self, forKey: .transactionID),
            ownerID: try values.decode(UUID.self, forKey: .ownerID),
            expiresAt: try values.decode(Date.self, forKey: .expiresAt),
            revision: try values.decode(Int64.self, forKey: .revision)
        )
    }
}

/// Opaque, local-only ownership for one writable continuity workstream.
///
/// This is deliberately distinct from `ContinuityWriterLease`, which protects
/// tracker synchronization transactions. A provider execution lease is keyed
/// by the app's durable workstream identifier (Phase 1 uses a handoff ID).
public struct ContinuityWorkstreamWriterLease: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let workstreamID: UUID
    public let ownerID: UUID
    public let expiresAt: Date
    public let revision: Int64

    public init(
        projectID: UUID,
        workstreamID: UUID,
        ownerID: UUID,
        expiresAt: Date,
        revision: Int64
    ) throws {
        try ContinuityValidation.validateDate(expiresAt, field: "expiresAt")
        guard revision >= 0 else { throw ContinuityValidationError.negativeRevision(revision) }
        self.projectID = projectID
        self.workstreamID = workstreamID
        self.ownerID = ownerID
        self.expiresAt = expiresAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, workstreamID, ownerID, expiresAt, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: try values.decode(UUID.self, forKey: .projectID),
            workstreamID: try values.decode(UUID.self, forKey: .workstreamID),
            ownerID: try values.decode(UUID.self, forKey: .ownerID),
            expiresAt: try values.decode(Date.self, forKey: .expiresAt),
            revision: try values.decode(Int64.self, forKey: .revision)
        )
    }
}

/// Compact, validated evidence required before an operator can clear a
/// workstream's fail-closed reconciliation marker. It contains digests and an
/// audit reference only—never a local path, provider session ID, or transcript.
public struct ContinuityWorkstreamReconciliationEvidence: Codable, Equatable, Sendable {
    public let capsuleDigest: String
    public let workspaceDigest: String
    public let auditEvidenceID: String

    public init(capsuleDigest: String, workspaceDigest: String, auditEvidenceID: String) throws {
        self.capsuleDigest = try Self.digest(capsuleDigest, field: "capsuleDigest")
        self.workspaceDigest = try Self.digest(workspaceDigest, field: "workspaceDigest")
        self.auditEvidenceID = try Self.auditEvidenceID(auditEvidenceID)
    }

    var storageValue: String {
        "\(capsuleDigest)|\(workspaceDigest)|\(auditEvidenceID)"
    }

    private static func digest(_ value: String, field: String) throws -> String {
        let canonical = try ContinuityValidation.requiredText(value, field: field, maximumBytes: 64)
        let isSHA256 = canonical.count == 64 && canonical.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
        guard isSHA256 else { throw ContinuityValidationError.empty(field: "valid \(field)") }
        return canonical
    }

    /// Reconciliation evidence is an opaque ledger key, not a description or
    /// reference to provider-owned data. Keeping the accepted grammar narrow
    /// prevents paths, session identifiers, transcript references, and secret
    /// material from entering the local continuity ledger.
    private static func auditEvidenceID(_ value: String) throws -> String {
        let canonical = try ContinuityValidation.requiredText(
            value,
            field: "auditEvidenceID",
            maximumBytes: 256
        )
        guard canonical.hasPrefix("ev_"),
              canonical.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                      true
                  default:
                      false
                  }
              }) else {
            throw ContinuityValidationError.invalidReconciliationEvidence
        }

        let terms = canonical.lowercased().split(whereSeparator: { ".-_".contains($0) })
        let prohibitedTerms: Set<Substring> = [
            "transcript", "session", "path", "file", "secret", "token", "password", "credential", "sk",
        ]
        guard prohibitedTerms.isDisjoint(with: terms) else {
            throw ContinuityValidationError.invalidReconciliationEvidence
        }
        return canonical
    }
}

public enum ContinuityValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty(field: String)
    case containsControlCharacters(field: String)
    case exceedsByteLimit(field: String, actualBytes: Int, maximumBytes: Int)
    case invalidDate(field: String)
    case invalidSessionReference
    case negativeAttempt(Int)
    case negativeRevision(Int64)
    case invalidLeaseDuration(TimeInterval)
    case invalidReconciliationEvidence
    case invalidSyncCompletion(state: ContinuitySyncState)

    public var description: String {
        switch self {
        case let .empty(field):
            "Continuity \(field) cannot be empty."
        case let .containsControlCharacters(field):
            "Continuity \(field) contains control characters."
        case let .exceedsByteLimit(field, actualBytes, maximumBytes):
            "Continuity \(field) is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case let .invalidDate(field):
            "Continuity \(field) must be a finite date."
        case .invalidSessionReference:
            "A continuity session link must reference exactly one local session."
        case let .negativeAttempt(attempt):
            "Continuity sync attempt cannot be negative (received \(attempt))."
        case let .negativeRevision(revision):
            "Continuity revision cannot be negative (received \(revision))."
        case let .invalidLeaseDuration(duration):
            "Continuity writer lease duration must be finite and between 1 and 300 seconds (received \(duration))."
        case .invalidReconciliationEvidence:
            "Continuity audit evidence must be an opaque ev_-prefixed ledger identifier."
        case let .invalidSyncCompletion(state):
            "Continuity sync state \(state.rawValue) has an invalid completion timestamp."
        }
    }
}

private enum ContinuityValidation {
    static func requiredText(_ value: String, field: String, maximumBytes: Int) throws -> String {
        let canonical = try canonicalText(value, field: field, maximumBytes: maximumBytes)
        guard !canonical.isEmpty else { throw ContinuityValidationError.empty(field: field) }
        return canonical
    }

    static func optionalText(_ value: String?, field: String, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        let canonical = try canonicalText(value, field: field, maximumBytes: maximumBytes)
        return canonical.isEmpty ? nil : canonical
    }

    static func validateDate(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ContinuityValidationError.invalidDate(field: field)
        }
    }

    private static func canonicalText(_ value: String, field: String, maximumBytes: Int) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ContinuityValidationError.containsControlCharacters(field: field)
        }
        let canonical = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = canonical.utf8.count
        guard byteCount <= maximumBytes else {
            throw ContinuityValidationError.exceedsByteLimit(
                field: field,
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
        return canonical
    }
}
