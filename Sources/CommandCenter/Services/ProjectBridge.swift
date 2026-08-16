import CommandCenterCore
import CryptoKit
import Foundation

enum ProjectBridgeError: Error, Equatable, LocalizedError {
    case writerLeaseUnavailable
    case leaseReleaseRequiresReconciliation
    case invalidCapsuleDigest
    case prohibitedContent(String)

    var errorDescription: String? {
        switch self {
        case .writerLeaseUnavailable:
            return "Another writer currently owns this handoff workstream."
        case .leaseReleaseRequiresReconciliation:
            return "The writer lease could not be released; the workstream is marked for audited reconciliation."
        case .invalidCapsuleDigest:
            return "The capsule digest must be a canonical lowercase SHA-256 value."
        case let .prohibitedContent(reason):
            return "Handoff content was rejected: \(reason)."
        }
    }
}

/// Receipt for one idempotent bridge handoff write.
struct ContinuityHandoffRecordReceipt: Equatable, Sendable {
    let handoff: ContinuityHandoff
    let wasAlreadyRecorded: Bool
}

/// Bridge-owned canonical writes between immutable session-link tips.
///
/// Every write is authority-checked first, serialized through the same
/// workstream writer lease the lease gate uses (the handoff UUID is the
/// workstream key), and derived deterministically from its inputs so a
/// duplicate request converges on identical state without duplicate events.
/// Multi-line transcript bodies are structurally impossible in handoff fields
/// (single-line bounded text, ADR-004); the bridge additionally rejects
/// machine-local values in the app-authored title and summary.
struct ProjectBridge: Sendable {
    private let store: SQLiteStore
    private let role: ContinuityParticipantRole
    private let bridgeOwnerID: UUID

    init(store: SQLiteStore, role: ContinuityParticipantRole, bridgeOwnerID: UUID = UUID()) {
        self.store = store
        self.role = role
        self.bridgeOwnerID = bridgeOwnerID
    }

    /// Records one cross-tip handoff. Identity is derived from every input
    /// that defines the handoff, so replaying the same request is a no-op and
    /// changed content becomes a distinct successor handoff instead of a
    /// rewrite.
    func recordHandoff(
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID,
        title: String,
        summary: String,
        capsuleDigest: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 60
    ) async throws -> ContinuityHandoffRecordReceipt {
        try ReviewAuthorityService.require(role, .recordHandoff)
        guard Self.isCanonicalSHA256(capsuleDigest) else {
            throw ProjectBridgeError.invalidCapsuleDigest
        }
        try Self.screenBridgeText(title, field: "title")
        try Self.screenBridgeText(summary, field: "summary")

        return try await recordValidatedHandoff(
            projectID: projectID,
            sourceSessionLinkID: sourceSessionLinkID,
            destinationSessionLinkID: destinationSessionLinkID,
            title: title,
            summary: summary,
            capsuleDigest: capsuleDigest,
            eventDetail: "Bridge recorded a deterministic handoff for capsule \(capsuleDigest.prefix(12)).",
            now: now,
            leaseDuration: leaseDuration
        )
    }

    /// Records the handoff row for a preflighted repository boundary. The
    /// boundary's machine format is the privacy contract on this path: an
    /// encode/decode round trip enforces digest grammar, known provider
    /// labels, and repo-relative changed paths, which screens strictly without
    /// misclassifying repository-relative paths the way the free-text screen
    /// would. The title is local-only metadata bounded by the model layer.
    func recordBoundaryHandoff(
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID,
        title: String,
        boundary: ContinuityHandoffBoundary,
        eventDetail: String? = nil,
        now: Date = Date(),
        leaseDuration: TimeInterval = 60
    ) async throws -> ContinuityHandoffRecordReceipt {
        try ReviewAuthorityService.require(role, .recordHandoff)
        let summary = try boundary.encodedSummary()
        let validated = try ContinuityHandoffBoundary.decode(summary: summary)
        return try await recordValidatedHandoff(
            projectID: projectID,
            sourceSessionLinkID: sourceSessionLinkID,
            destinationSessionLinkID: destinationSessionLinkID,
            title: title,
            summary: summary,
            capsuleDigest: validated.capsuleDigest,
            eventDetail: eventDetail
                ?? "Bridge recorded a boundary handoff for capsule \(validated.capsuleDigest.prefix(12)).",
            now: now,
            leaseDuration: leaseDuration
        )
    }

    private func recordValidatedHandoff(
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID,
        title: String,
        summary: String,
        capsuleDigest: String,
        eventDetail: String,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> ContinuityHandoffRecordReceipt {
        let identity = Self.handoffIdentity(
            projectID: projectID,
            sourceSessionLinkID: sourceSessionLinkID,
            destinationSessionLinkID: destinationSessionLinkID,
            title: title,
            summary: summary,
            capsuleDigest: capsuleDigest
        )
        let handoffID = Self.deterministicUUID(identity)

        if let existing = try await store.continuityHandoff(id: handoffID) {
            return ContinuityHandoffRecordReceipt(handoff: existing, wasAlreadyRecorded: true)
        }

        try ReviewAuthorityService.require(role, .acquireWorkstreamLease)
        let lease = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: store,
            projectID: projectID,
            handoffID: handoffID,
            permission: ReviewAuthorityService.effectivePermission(
                for: role,
                requested: .workspaceWrite
            ),
            ownerID: bridgeOwnerID,
            now: now,
            duration: leaseDuration
        )
        guard let lease else {
            throw ProjectBridgeError.writerLeaseUnavailable
        }

        let handoff = try ContinuityHandoff(
            id: handoffID,
            projectID: projectID,
            sourceSessionLinkID: sourceSessionLinkID,
            destinationSessionLinkID: destinationSessionLinkID,
            title: title,
            summary: summary,
            state: .ready,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await store.upsertContinuityHandoff(handoff)
            try await store.insertContinuityEvent(try ContinuityEvent(
                id: Self.deterministicUUID(identity + "|event"),
                projectID: projectID,
                sessionLinkID: destinationSessionLinkID,
                handoffID: handoffID,
                kind: .handoffCreated,
                detail: eventDetail,
                occurredAt: now
            ))
        } catch {
            _ = try? await ContinuityWriterLeaseGate.release(store: store, lease: lease, at: now)
            throw error
        }

        let released = try await ContinuityWriterLeaseGate.release(
            store: store,
            lease: lease,
            at: now
        )
        guard released else {
            _ = try? await ContinuityWriterLeaseGate.requireReconciliation(
                store: store,
                lease: lease,
                reason: "Bridge write completed but its writer lease release was not verified."
            )
            throw ProjectBridgeError.leaseReleaseRequiresReconciliation
        }
        return ContinuityHandoffRecordReceipt(handoff: handoff, wasAlreadyRecorded: false)
    }

    /// The deterministic workstream key a bridge write will contend on, for
    /// callers that need to inspect or await lease state.
    static func workstreamID(
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID,
        title: String,
        summary: String,
        capsuleDigest: String
    ) -> UUID {
        deterministicUUID(handoffIdentity(
            projectID: projectID,
            sourceSessionLinkID: sourceSessionLinkID,
            destinationSessionLinkID: destinationSessionLinkID,
            title: title,
            summary: summary,
            capsuleDigest: capsuleDigest
        ))
    }

    private static func handoffIdentity(
        projectID: UUID,
        sourceSessionLinkID: UUID,
        destinationSessionLinkID: UUID,
        title: String,
        summary: String,
        capsuleDigest: String
    ) -> String {
        let titleDigest = SHA256.hash(data: Data(title.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let summaryDigest = SHA256.hash(data: Data(summary.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            "continuity-handoff", "v1",
            projectID.uuidString.lowercased(),
            sourceSessionLinkID.uuidString.lowercased(),
            destinationSessionLinkID.uuidString.lowercased(),
            titleDigest,
            summaryDigest,
            capsuleDigest,
        ].joined(separator: "|")
    }

    private static func deterministicUUID(_ identity: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }

    /// Deterministic machine-local screening for the two app-authored bridge
    /// fields. The full recursive scan lives in the capsule reader; this layer
    /// only has to keep paths, secret-shaped values, and host/process/socket
    /// identifiers out of canonical handoff rows.
    private static let prohibitedFragments: [String] = [
        "/users/", "/private/", "/var/", "/home/", "/tmp/", "file://", "~/",
        "tcp://", "ssh://", "127.0.0.1", "localhost:", ".sock",
        "pid:", "process id",
    ]

    private static let secretExpression = try! NSRegularExpression(
        pattern: "sk-[a-z0-9]{8,}|ghp_[a-z0-9]{8,}|xox[a-z]-|-----begin|(api[_ -]?key|secret|token|password|credential)\\s*[:=]",
        options: [.caseInsensitive]
    )

    private static func screenBridgeText(_ value: String, field: String) throws {
        let lowered = value.lowercased()
        for fragment in prohibitedFragments where lowered.contains(fragment) {
            throw ProjectBridgeError.prohibitedContent(
                "\(field) contains the machine-local fragment \"\(fragment)\""
            )
        }
        let range = NSRange(lowered.startIndex..., in: lowered)
        if secretExpression.firstMatch(in: lowered, range: range) != nil {
            throw ProjectBridgeError.prohibitedContent(
                "\(field) contains a secret-shaped value"
            )
        }
    }
}
