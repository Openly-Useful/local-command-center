import CommandCenterCore
import Foundation

/// App-facing ownership for the one-writer continuity invariant.
///
/// The handoff UUID is the stable workstream key: it never contains a
/// provider identity or repository path, while allowing a recovered app
/// process to contend for the same SQLite compare-and-swap row. It is stored
/// separately from external-sync transactions. Reviewer dispatches are
/// excluded before a workstream lease row is even created.
enum ContinuityWriterLeaseGate {
    static let defaultDuration: TimeInterval = 300

    static func acquireIfWritable(
        store: SQLiteStore,
        projectID: UUID,
        handoffID: UUID,
        permission: RuntimePermission,
        ownerID: UUID,
        now: Date = Date(),
        duration: TimeInterval = defaultDuration
    ) async throws -> ContinuityWorkstreamWriterLease? {
        guard permission == .workspaceWrite else { return nil }
        return try await store.acquireContinuityWorkstreamWriterLease(
            projectID: projectID,
            workstreamID: handoffID,
            ownerID: ownerID,
            now: now,
            duration: duration
        )
    }

    @discardableResult
    static func release(
        store: SQLiteStore,
        lease: ContinuityWorkstreamWriterLease,
        at timestamp: Date = Date()
    ) async throws -> Bool {
        try await store.releaseContinuityWorkstreamWriterLease(
            projectID: lease.projectID,
            workstreamID: lease.workstreamID,
            ownerID: lease.ownerID,
            at: timestamp
        )
    }

    static func renew(
        store: SQLiteStore,
        lease: ContinuityWorkstreamWriterLease,
        now: Date = Date(),
        duration: TimeInterval = defaultDuration
    ) async throws -> ContinuityWorkstreamWriterLease? {
        try await store.renewContinuityWorkstreamWriterLease(
            projectID: lease.projectID,
            workstreamID: lease.workstreamID,
            ownerID: lease.ownerID,
            now: now,
            duration: duration
        )
    }

    @discardableResult
    static func requireReconciliation(
        store: SQLiteStore,
        lease: ContinuityWorkstreamWriterLease,
        reason: String
    ) async throws -> Bool {
        try await store.requireContinuityWorkstreamReconciliation(
            projectID: lease.projectID,
            workstreamID: lease.workstreamID,
            reason: reason
        )
    }
}

/// Periodically renews a lease while a provider process remains live. The
/// scheduler is intentionally small and injectable so tests can prove the
/// silent-process path without waiting for production intervals.
enum ContinuityWriterLeaseHeartbeat {
    static func start(
        intervalNanoseconds: UInt64,
        onTick: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await onTick()
            }
        }
    }
}
