import Foundation

/// Operations a provider session adapter can be asked to perform. Adapters
/// report unsupported operations honestly instead of simulating them.
enum ProviderSessionOperation: String, CaseIterable, Sendable {
    case start
    case resume
    case fork
    case checkpoint
}

/// Capability report for one provider. `unsupportedReasons` carries the honest
/// explanation surfaced to the user for every unsupported operation.
struct ProviderSessionCapabilities: Equatable, Sendable {
    let supported: Set<ProviderSessionOperation>
    let unsupportedReasons: [ProviderSessionOperation: String]

    func supports(_ operation: ProviderSessionOperation) -> Bool {
        supported.contains(operation)
    }

    func reasonForUnsupported(_ operation: ProviderSessionOperation) -> String {
        unsupportedReasons[operation]
            ?? "\(operation.rawValue) is not supported by this provider."
    }
}

/// One dispatch request. Provider-native session identity is passed separately
/// so start and resume cannot be conflated.
struct ProviderSessionRequest: Sendable {
    var workspaceURL: URL
    var prompt: String
    var permission: RuntimePermission
    var workflow: RuntimeWorkflow
    var selectedSkills: [String]

    init(
        workspaceURL: URL,
        prompt: String,
        permission: RuntimePermission = .readOnly,
        workflow: RuntimeWorkflow = .direct,
        selectedSkills: [String] = []
    ) {
        self.workspaceURL = workspaceURL
        self.prompt = prompt
        self.permission = permission
        self.workflow = workflow
        self.selectedSkills = selectedSkills
    }
}

/// Provider-native lineage for fork requests. Fork is a same-provider
/// operation by contract; cross-provider movement is a continuity handoff.
struct ProviderSessionLineage: Equatable, Sendable {
    let provider: RuntimeProvider
    let providerSessionID: String
}

/// A resumable position observed from provider output: the provider-reported
/// session identity plus the last delivered event sequence.
struct ProviderSessionCheckpoint: Equatable, Sendable {
    let provider: RuntimeProvider
    let providerSessionID: String
    let lastEventSequence: Int
}

/// Ordered, bounded stream element. Sequences are assigned monotonically per
/// dispatch; `.exited` is always last because the runner emits it single-shot
/// after both pipes reach EOF.
struct ProviderSessionEventEnvelope: Sendable {
    let sequence: Int
    let event: ProviderStreamEvent
}

enum ProviderSessionAdapterError: Error, Equatable, LocalizedError {
    case unsupportedOperation(
        provider: RuntimeProvider,
        operation: ProviderSessionOperation,
        reason: String
    )
    case crossProviderForkRejected(source: RuntimeProvider, requested: RuntimeProvider)
    case checkpointUnavailable(RuntimeProvider)

    var errorDescription: String? {
        switch self {
        case let .unsupportedOperation(provider, operation, reason):
            return "\(provider.displayName) does not support \(operation.rawValue): \(reason)"
        case let .crossProviderForkRejected(source, requested):
            return "A \(source.displayName) session cannot fork into \(requested.displayName); cross-provider transfer uses a continuity handoff."
        case let .checkpointUnavailable(provider):
            return "\(provider.displayName) has not reported a session identity to checkpoint."
        }
    }
}

/// Idempotent handle for one dispatched provider session. `stop()` performs
/// the underlying cancellation at most once and reports whether this call was
/// the effective one.
final class ProviderSessionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var didStop = false
    private let onStop: @Sendable () -> Void
    private let runningProbe: @Sendable () -> Bool

    init(
        isRunning: @escaping @Sendable () -> Bool,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.runningProbe = isRunning
        self.onStop = onStop
    }

    var isRunning: Bool { runningProbe() }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let firstStop = !didStop
        didStop = true
        lock.unlock()
        if firstStop { onStop() }
        return firstStop
    }
}

/// Execution seam between plan construction and process ownership so adapter
/// semantics are testable with fakes and the production path stays on
/// `ProviderProcessRunner`.
protocol ProviderSessionExecuting: Sendable {
    func execute(
        _ plan: ProviderLaunchPlan,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) throws -> ProviderSessionHandle
}

struct ProviderProcessSessionExecutor: ProviderSessionExecuting {
    private let runner: ProviderProcessRunner

    init(runner: ProviderProcessRunner = ProviderProcessRunner()) {
        self.runner = runner
    }

    func execute(
        _ plan: ProviderLaunchPlan,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) throws -> ProviderSessionHandle {
        let running = try runner.start(plan, onEvent: onEvent)
        return ProviderSessionHandle(
            isRunning: { running.isRunning },
            onStop: { running.cancel() }
        )
    }
}

/// One capability-reporting contract for every provider. Plans are pure and
/// separately testable; execution goes through `ProviderSessionExecuting`.
protocol ProviderSessionAdapter: Sendable {
    var provider: RuntimeProvider { get }
    var capabilities: ProviderSessionCapabilities { get }

    func startPlan(_ request: ProviderSessionRequest) throws -> ProviderLaunchPlan
    func resumePlan(
        _ request: ProviderSessionRequest,
        providerSessionID: String
    ) throws -> ProviderLaunchPlan
    func forkPlan(
        _ request: ProviderSessionRequest,
        from source: ProviderSessionLineage
    ) throws -> ProviderLaunchPlan
}

extension ProviderSessionAdapter {
    /// Contract-level fork guard: cross-provider fork is rejected before any
    /// capability is consulted, and unsupported fork is reported honestly.
    /// Adapters that support fork implement `supportedForkPlan`.
    func forkPlan(
        _ request: ProviderSessionRequest,
        from source: ProviderSessionLineage
    ) throws -> ProviderLaunchPlan {
        guard source.provider == provider else {
            throw ProviderSessionAdapterError.crossProviderForkRejected(
                source: source.provider,
                requested: provider
            )
        }
        throw ProviderSessionAdapterError.unsupportedOperation(
            provider: provider,
            operation: .fork,
            reason: capabilities.reasonForUnsupported(.fork)
        )
    }

    /// Derives the latest resumable checkpoint from delivered envelopes.
    /// Reports honestly when the provider never surfaced a session identity.
    func checkpoint(
        from envelopes: [ProviderSessionEventEnvelope]
    ) throws -> ProviderSessionCheckpoint {
        var identity: String?
        var lastSequence = -1
        for envelope in envelopes {
            lastSequence = max(lastSequence, envelope.sequence)
            if case let .sessionID(candidate) = envelope.event {
                identity = candidate
            }
        }
        guard let identity else {
            throw ProviderSessionAdapterError.checkpointUnavailable(provider)
        }
        return ProviderSessionCheckpoint(
            provider: provider,
            providerSessionID: identity,
            lastEventSequence: lastSequence
        )
    }

    /// Dispatches one plan through an executor while assigning monotonic
    /// sequence numbers. `.batch` events are flattened so ordering is total.
    func dispatch(
        _ plan: ProviderLaunchPlan,
        executor: ProviderSessionExecuting,
        onEvent: @escaping @Sendable (ProviderSessionEventEnvelope) -> Void
    ) throws -> ProviderSessionHandle {
        let sequencer = ProviderSessionEventSequencer()
        return try executor.execute(plan) { event in
            for envelope in sequencer.envelopes(for: event) {
                onEvent(envelope)
            }
        }
    }
}

/// Assigns strictly increasing sequence numbers to delivered events.
final class ProviderSessionEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence = 0

    func envelopes(for event: ProviderStreamEvent) -> [ProviderSessionEventEnvelope] {
        let flattened: [ProviderStreamEvent]
        if case let .batch(members) = event {
            flattened = members
        } else {
            flattened = [event]
        }
        lock.lock()
        defer { lock.unlock() }
        return flattened.map { member in
            let envelope = ProviderSessionEventEnvelope(sequence: nextSequence, event: member)
            nextSequence += 1
            return envelope
        }
    }
}
