import Foundation

/// Continuity participant role. Exactly one writer exists per workstream;
/// reviewers are technically read-only by contract (ADR-004).
enum ContinuityParticipantRole: String, CaseIterable, Sendable {
    case writer
    case reviewer
}

/// Bridge-facing actions gated by role authority.
enum ContinuityBridgeAction: String, CaseIterable, Sendable {
    case readLineage
    case prepareReadOnlyReview
    case recordHandoff
    case acquireWorkstreamLease
    case dispatchWriteCapableWork
}

enum ReviewAuthorityError: Error, Equatable, LocalizedError {
    case reviewerDenied(ContinuityBridgeAction)

    var errorDescription: String? {
        switch self {
        case let .reviewerDenied(action):
            return "A reviewer is read-only and cannot \(action.rawValue)."
        }
    }
}

/// Single authority decision point for continuity actions. The denial happens
/// before any writer transaction or lease row could be created, and a
/// reviewer's provider permission is pinned to read-only regardless of what
/// was requested.
enum ReviewAuthorityService {
    static func permits(
        _ role: ContinuityParticipantRole,
        _ action: ContinuityBridgeAction
    ) -> Bool {
        switch role {
        case .writer:
            return true
        case .reviewer:
            switch action {
            case .readLineage, .prepareReadOnlyReview:
                return true
            case .recordHandoff, .acquireWorkstreamLease, .dispatchWriteCapableWork:
                return false
            }
        }
    }

    static func require(
        _ role: ContinuityParticipantRole,
        _ action: ContinuityBridgeAction
    ) throws {
        guard permits(role, action) else {
            throw ReviewAuthorityError.reviewerDenied(action)
        }
    }

    /// The effective provider permission for a role. A reviewer can never
    /// escalate to workspace-write, whatever the composer requested.
    static func effectivePermission(
        for role: ContinuityParticipantRole,
        requested: RuntimePermission
    ) -> RuntimePermission {
        switch role {
        case .writer:
            return requested
        case .reviewer:
            return .readOnly
        }
    }
}
