import Foundation

public enum ExternalSessionSurface: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode
}

public enum ExternalSessionValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty(field: String)
    case containsControlCharacters(field: String)
    case exceedsByteLimit(field: String, actualBytes: Int, maximumBytes: Int)
    case negativeSourceByteCount(Int64)
    case invalidDate(field: String)

    public var description: String {
        switch self {
        case let .empty(field):
            "External session \(field) cannot be empty."
        case let .containsControlCharacters(field):
            "External session \(field) contains control characters."
        case let .exceedsByteLimit(field, actualBytes, maximumBytes):
            "External session \(field) is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case let .negativeSourceByteCount(value):
            "External session sourceByteCount cannot be negative (received \(value))."
        case let .invalidDate(field):
            "External session \(field) must be a finite date."
        }
    }
}

public struct ExternalSession: Codable, Equatable, Identifiable, Sendable {
    public static let maximumSessionIDBytes = 1_024
    public static let maximumTitleBytes = 1_024
    public static let maximumPreviewBytes = 4 * 1_024
    public static let maximumStatusBytes = 1_024
    public static let maximumPathBytes = 16 * 1_024
    public static let maximumContentDigestBytes = 1_024

    public let id: UUID
    public let provider: ProviderKind
    public let surface: ExternalSessionSurface
    public let providerSessionID: String
    public let workspacePath: String?
    public let title: String
    public let preview: String
    public let providerStatus: String
    public let canResume: Bool
    public let canReadTranscript: Bool
    public let sourcePath: String
    public let sourceByteCount: Int64
    public let sourceModifiedAt: Date
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let parentProviderSessionID: String?
    public let isSidechain: Bool
    public let contentDigest: String?
    public let missingSince: Date?

    public init(
        id: UUID = UUID(),
        provider: ProviderKind,
        surface: ExternalSessionSurface,
        providerSessionID: String,
        workspacePath: String? = nil,
        title: String,
        preview: String,
        providerStatus: String,
        canResume: Bool,
        canReadTranscript: Bool,
        sourcePath: String,
        sourceByteCount: Int64,
        sourceModifiedAt: Date,
        firstSeenAt: Date,
        lastSeenAt: Date,
        parentProviderSessionID: String? = nil,
        isSidechain: Bool = false,
        contentDigest: String? = nil,
        missingSince: Date? = nil
    ) throws {
        guard sourceByteCount >= 0 else {
            throw ExternalSessionValidationError.negativeSourceByteCount(sourceByteCount)
        }
        try Self.validateDate(sourceModifiedAt, field: "sourceModifiedAt")
        try Self.validateDate(firstSeenAt, field: "firstSeenAt")
        try Self.validateDate(lastSeenAt, field: "lastSeenAt")
        if let missingSince {
            try Self.validateDate(missingSince, field: "missingSince")
        }

        self.id = id
        self.provider = provider
        self.surface = surface
        self.providerSessionID = try Self.canonicalProviderSessionID(providerSessionID)
        self.workspacePath = try Self.canonicalOptionalPath(
            workspacePath,
            field: "workspacePath"
        )
        self.title = try Self.canonicalText(
            title,
            field: "title",
            maximumBytes: Self.maximumTitleBytes,
            required: false
        )
        self.preview = try Self.canonicalText(
            preview,
            field: "preview",
            maximumBytes: Self.maximumPreviewBytes,
            required: false
        )
        self.providerStatus = try Self.canonicalText(
            providerStatus,
            field: "providerStatus",
            maximumBytes: Self.maximumStatusBytes,
            required: false
        )
        self.canResume = canResume
        self.canReadTranscript = canReadTranscript
        self.sourcePath = try Self.canonicalPath(sourcePath, field: "sourcePath", required: true)
        self.sourceByteCount = sourceByteCount
        self.sourceModifiedAt = sourceModifiedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.parentProviderSessionID = try Self.canonicalOptionalText(
            parentProviderSessionID,
            field: "parentProviderSessionID",
            maximumBytes: Self.maximumSessionIDBytes
        )
        self.isSidechain = isSidechain
        self.contentDigest = try Self.canonicalOptionalText(
            contentDigest,
            field: "contentDigest",
            maximumBytes: Self.maximumContentDigestBytes
        )
        self.missingSince = missingSince
    }

    public static func canonicalProviderSessionID(_ value: String) throws -> String {
        try canonicalText(
            value,
            field: "providerSessionID",
            maximumBytes: maximumSessionIDBytes,
            required: true
        )
    }

    public static func canonicalWorkspacePath(_ value: String) throws -> String {
        try canonicalPath(value, field: "workspacePath", required: true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, surface, providerSessionID, workspacePath, title, preview
        case providerStatus, canResume, canReadTranscript, sourcePath, sourceByteCount
        case sourceModifiedAt, firstSeenAt, lastSeenAt, parentProviderSessionID
        case isSidechain, contentDigest, missingSince
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(UUID.self, forKey: .id),
            provider: try values.decode(ProviderKind.self, forKey: .provider),
            surface: try values.decode(ExternalSessionSurface.self, forKey: .surface),
            providerSessionID: try values.decode(String.self, forKey: .providerSessionID),
            workspacePath: try values.decodeIfPresent(String.self, forKey: .workspacePath),
            title: try values.decode(String.self, forKey: .title),
            preview: try values.decode(String.self, forKey: .preview),
            providerStatus: try values.decode(String.self, forKey: .providerStatus),
            canResume: try values.decode(Bool.self, forKey: .canResume),
            canReadTranscript: try values.decode(Bool.self, forKey: .canReadTranscript),
            sourcePath: try values.decode(String.self, forKey: .sourcePath),
            sourceByteCount: try values.decode(Int64.self, forKey: .sourceByteCount),
            sourceModifiedAt: try values.decode(Date.self, forKey: .sourceModifiedAt),
            firstSeenAt: try values.decode(Date.self, forKey: .firstSeenAt),
            lastSeenAt: try values.decode(Date.self, forKey: .lastSeenAt),
            parentProviderSessionID: try values.decodeIfPresent(
                String.self,
                forKey: .parentProviderSessionID
            ),
            isSidechain: try values.decode(Bool.self, forKey: .isSidechain),
            contentDigest: try values.decodeIfPresent(String.self, forKey: .contentDigest),
            missingSince: try values.decodeIfPresent(Date.self, forKey: .missingSince)
        )
    }

    private static func canonicalPath(
        _ value: String,
        field: String,
        required: Bool
    ) throws -> String {
        let candidate = try canonicalText(
            value,
            field: field,
            maximumBytes: maximumPathBytes,
            required: required
        )
        let standardized: String
        if candidate.hasPrefix("/") {
            standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        } else {
            standardized = (candidate as NSString).standardizingPath
        }
        return try canonicalText(
            standardized,
            field: field,
            maximumBytes: maximumPathBytes,
            required: required
        )
    }

    private static func canonicalOptionalText(
        _ value: String?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value else { return nil }
        let canonical = try canonicalText(
            value,
            field: field,
            maximumBytes: maximumBytes,
            required: false
        )
        return canonical.isEmpty ? nil : canonical
    }

    private static func canonicalOptionalPath(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        let canonical = try canonicalPath(value, field: field, required: false)
        return canonical.isEmpty ? nil : canonical
    }

    private static func canonicalText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        required: Bool
    ) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ExternalSessionValidationError.containsControlCharacters(field: field)
        }
        let canonical = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !required || !canonical.isEmpty else {
            throw ExternalSessionValidationError.empty(field: field)
        }
        let byteCount = canonical.utf8.count
        guard byteCount <= maximumBytes else {
            throw ExternalSessionValidationError.exceedsByteLimit(
                field: field,
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
        return canonical
    }

    private static func validateDate(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ExternalSessionValidationError.invalidDate(field: field)
        }
    }
}

public struct ConversationExternalLink: Codable, Equatable, Sendable {
    public let conversationID: UUID
    public let externalSessionID: UUID

    public init(conversationID: UUID, externalSessionID: UUID) {
        self.conversationID = conversationID
        self.externalSessionID = externalSessionID
    }
}
