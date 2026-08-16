import Foundation

public enum ResourceMode: String, Codable, CaseIterable, Sendable {
    case focus
    case balanced
    case throughput
}

public struct ProviderCostEstimates: Codable, Equatable, Sendable {
    public var codexBytes: UInt64
    public var claudeBytes: UInt64

    public init(
        codexBytes: UInt64 = 768 * 1_024 * 1_024,
        claudeBytes: UInt64 = 768 * 1_024 * 1_024
    ) {
        self.codexBytes = codexBytes
        self.claudeBytes = claudeBytes
    }

    public func bytes(for provider: ProviderKind) -> UInt64 {
        switch provider {
        case .codex: codexBytes
        case .claude: claudeBytes
        }
    }
}

public struct QueuedJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let provider: ProviderKind
    public let workflow: WorkflowKind
    public let enqueuedAt: Date
    public let estimatedMemoryBytes: UInt64?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        provider: ProviderKind,
        workflow: WorkflowKind,
        enqueuedAt: Date = Date(),
        estimatedMemoryBytes: UInt64? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.provider = provider
        self.workflow = workflow
        self.enqueuedAt = enqueuedAt
        self.estimatedMemoryBytes = estimatedMemoryBytes
    }
}

public struct ActiveJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let provider: ProviderKind
    public let workflow: WorkflowKind
    public let startedAt: Date

    public init(
        id: UUID,
        conversationID: UUID,
        provider: ProviderKind,
        workflow: WorkflowKind,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.provider = provider
        self.workflow = workflow
        self.startedAt = startedAt
    }
}

public enum AdmissionDeferralReason: String, Codable, Equatable, Sendable {
    case activeLimit
    case insufficientHeadroom
}

public struct DeferredJob: Codable, Equatable, Sendable {
    public let job: QueuedJob
    public let reason: AdmissionDeferralReason

    public init(job: QueuedJob, reason: AdmissionDeferralReason) {
        self.job = job
        self.reason = reason
    }
}

public struct AdmissionPlan: Codable, Equatable, Sendable {
    public let admitted: [QueuedJob]
    public let deferred: [DeferredJob]
    public let projectedAvailableBytes: UInt64

    public init(
        admitted: [QueuedJob],
        deferred: [DeferredJob],
        projectedAvailableBytes: UInt64
    ) {
        self.admitted = admitted
        self.deferred = deferred
        self.projectedAvailableBytes = projectedAvailableBytes
    }
}
