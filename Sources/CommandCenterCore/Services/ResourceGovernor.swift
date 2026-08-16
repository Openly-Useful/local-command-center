import Foundation

public struct ResourcePolicy: Codable, Equatable, Sendable {
    public let maximumActiveJobs: Int
    public let minimumAvailableBytes: UInt64
    public let reserveNumerator: UInt64
    public let reserveDenominator: UInt64

    public init(
        maximumActiveJobs: Int,
        minimumAvailableBytes: UInt64,
        reserveNumerator: UInt64,
        reserveDenominator: UInt64
    ) {
        precondition(maximumActiveJobs > 0)
        precondition(reserveDenominator > 0)
        self.maximumActiveJobs = maximumActiveJobs
        self.minimumAvailableBytes = minimumAvailableBytes
        self.reserveNumerator = reserveNumerator
        self.reserveDenominator = reserveDenominator
    }

    public func requiredReserve(physicalBytes: UInt64) -> UInt64 {
        let quotient = physicalBytes / reserveDenominator
        let remainder = physicalBytes % reserveDenominator
        let scaledQuotient = quotient.multipliedReportingOverflow(by: reserveNumerator)
        let scaledRemainder = remainder.multipliedReportingOverflow(by: reserveNumerator)
        let fractional = scaledRemainder.overflow ? UInt64.max : scaledRemainder.partialValue / reserveDenominator
        let proportional: UInt64
        if scaledQuotient.overflow || scaledQuotient.partialValue > UInt64.max - fractional {
            proportional = UInt64.max
        } else {
            proportional = scaledQuotient.partialValue + fractional
        }
        return max(minimumAvailableBytes, proportional)
    }
}

public struct ResourceGovernor: Sendable {
    public let costEstimates: ProviderCostEstimates

    public init(costEstimates: ProviderCostEstimates = ProviderCostEstimates()) {
        self.costEstimates = costEstimates
    }

    public func policy(for mode: ResourceMode) -> ResourcePolicy {
        let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
        switch mode {
        case .focus:
            return ResourcePolicy(
                maximumActiveJobs: 1,
                minimumAvailableBytes: 2 * gibibyte,
                reserveNumerator: 1,
                reserveDenominator: 4
            )
        case .balanced:
            return ResourcePolicy(
                maximumActiveJobs: 2,
                minimumAvailableBytes: 3 * gibibyte / 2,
                reserveNumerator: 1,
                reserveDenominator: 5
            )
        case .throughput:
            return ResourcePolicy(
                maximumActiveJobs: 4,
                minimumAvailableBytes: gibibyte,
                reserveNumerator: 1,
                reserveDenominator: 8
            )
        }
    }

    public func makeAdmissionPlan(
        queuedJobs: [QueuedJob],
        activeJobs: [ActiveJob],
        memory: SystemMemorySnapshot,
        mode: ResourceMode
    ) -> AdmissionPlan {
        let policy = policy(for: mode)
        let reserve = policy.requiredReserve(physicalBytes: memory.physicalBytes)
        var projectedAvailable = memory.availableBytes
        var availableSlots = max(0, policy.maximumActiveJobs - activeJobs.count)
        var admitted: [QueuedJob] = []
        var deferred: [DeferredJob] = []

        let orderedJobs = queuedJobs.sorted(by: Self.hasHigherPriority)
        for job in orderedJobs {
            guard availableSlots > 0 else {
                deferred.append(DeferredJob(job: job, reason: .activeLimit))
                continue
            }

            let estimate = job.estimatedMemoryBytes ?? costEstimates.bytes(for: job.provider)
            guard projectedAvailable >= reserve,
                  estimate <= projectedAvailable - reserve
            else {
                deferred.append(DeferredJob(job: job, reason: .insufficientHeadroom))
                continue
            }

            admitted.append(job)
            projectedAvailable -= estimate
            availableSlots -= 1
        }

        return AdmissionPlan(
            admitted: admitted,
            deferred: deferred,
            projectedAvailableBytes: projectedAvailable
        )
    }

    private static func hasHigherPriority(_ left: QueuedJob, _ right: QueuedJob) -> Bool {
        if left.workflow.isInteractive != right.workflow.isInteractive {
            return left.workflow.isInteractive
        }
        if left.enqueuedAt != right.enqueuedAt {
            return left.enqueuedAt < right.enqueuedAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}
