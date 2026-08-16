import CommandCenterCore
import Foundation

typealias LocalHistorySession = ExternalSession
typealias LocalHistorySurface = ExternalSessionSurface

enum LocalHistoryLimits {
    /// A provider scan may never retain or return more than this many sessions.
    /// A lower injected limit is supported by deterministic fixture tests.
    static let maximumSessionsPerProvider = 5_000
    static let maximumDiagnosticsPerScan = 256
}

/// Codex uses both bare UUID rollout names and timestamp-prefixed rollout
/// names. Keep identity extraction shared by discovery and lazy transcript
/// loading so the two trust boundaries cannot disagree about a valid source.
enum CodexRolloutFilename {
    static func sessionID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        if let direct = LocalHistoryUtilities.validatedUUID(stem) { return direct }
        guard stem.hasPrefix("rollout-"), stem.utf8.count > 36 else { return nil }
        return LocalHistoryUtilities.validatedUUID(String(stem.suffix(36)))
    }
}

enum LocalHistoryDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

/// Diagnostics use stable codes and paths only. Provider message text is never
/// included, which makes them safe to show in a runtime/status surface.
struct LocalHistoryDiagnostic: Codable, Equatable, Sendable {
    var severity: LocalHistoryDiagnosticSeverity
    var code: String
    var sourcePath: String?
    var detail: String
}

struct LocalHistoryScanMetrics: Codable, Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date
    var filesConsidered: Int
    var filesRead: Int
    var rowsConsidered: Int
    var sessionsAccepted: Int
    var bytesRead: Int64
    var malformedRecords: Int
    var oversizedRecords: Int
    var skippedEntries: Int
    var usedFallback: Bool

    static func empty(startedAt: Date = Date()) -> Self {
        Self(
            startedAt: startedAt,
            finishedAt: startedAt,
            filesConsidered: 0,
            filesRead: 0,
            rowsConsidered: 0,
            sessionsAccepted: 0,
            bytesRead: 0,
            malformedRecords: 0,
            oversizedRecords: 0,
            skippedEntries: 0,
            usedFallback: false
        )
    }
}

struct LocalHistorySnapshot: Codable, Equatable, Sendable {
    var sessions: [LocalHistorySession]
    var diagnostics: [LocalHistoryDiagnostic]
    var metrics: LocalHistoryScanMetrics
    /// False means absence must not be interpreted as deletion/tombstoning.
    var authoritative: Bool
}

protocol LocalHistorySource: Sendable {
    var provider: ProviderKind { get }
    func scan() async -> LocalHistorySnapshot
    func revalidate(session: ExternalSession) async -> LocalSessionRevalidation
}

enum LocalSessionRevalidationState: String, Codable, Sendable {
    case available
    case unavailable
    case indeterminate
}

struct LocalSessionRevalidation: Equatable, Sendable {
    let provider: ProviderKind
    let providerSessionID: String
    let state: LocalSessionRevalidationState
    let checkedAt: Date
    let refreshedSession: ExternalSession?
    let diagnostic: LocalHistoryDiagnostic?

    var permitsResume: Bool {
        state == .available && refreshedSession?.canResume == true
    }
}

extension LocalHistorySource {
    func revalidate(session: ExternalSession) async -> LocalSessionRevalidation {
        LocalSessionRevalidation(
            provider: provider,
            providerSessionID: session.providerSessionID,
            state: .indeterminate,
            checkedAt: Date(),
            refreshedSession: nil,
            diagnostic: .init(
                severity: .warning,
                code: "local-session-revalidation-unsupported",
                sourcePath: nil,
                detail: "This local history source cannot safely revalidate a session before resume."
            )
        )
    }
}

struct LocalTranscriptReadLimits: Equatable, Sendable {
    static let maximumMessageCount = 200
    static let maximumReadBytes = 8 * 1_048_576

    var messageCount: Int
    var readBytes: Int

    init(messageCount: Int = 50, readBytes: Int = 2 * 1_048_576) {
        self.messageCount = min(max(messageCount, 1), Self.maximumMessageCount)
        self.readBytes = min(max(readBytes, 1), Self.maximumReadBytes)
    }
}

/// Service-local imported row. Provider IDs remain strings because not every
/// provider record identifier is a UUID, while UUID parents are validated.
struct LocalTranscriptRow: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var providerRecordID: String?
    var parentRecordID: String?
    var role: MessageRole
    var text: String
    var timestamp: Date
}

struct LocalTranscriptSnapshot: Codable, Equatable, Sendable {
    var sessionID: String
    var rows: [LocalTranscriptRow]
    var bytesRead: Int
    var wasTruncated: Bool
    var diagnostics: [LocalHistoryDiagnostic]
    var contentDigest: String
}
