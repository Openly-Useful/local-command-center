import Foundation
import XCTest
@testable import CommandCenterCore

final class ResourceGovernorTests: XCTestCase {
    private let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

    func testInteractiveJobsAlwaysSortAheadOfBackgroundJobs() {
        let governor = ResourceGovernor()
        let timestamp = Date(timeIntervalSince1970: 100)
        let background = job(
            id: "00000000-0000-0000-0000-000000000001",
            workflow: .backgroundReview,
            enqueuedAt: timestamp.addingTimeInterval(-100),
            estimate: 1
        )
        let interactive = job(
            id: "00000000-0000-0000-0000-000000000002",
            workflow: .interactive,
            enqueuedAt: timestamp,
            estimate: 1
        )

        let plan = governor.makeAdmissionPlan(
            queuedJobs: [background, interactive],
            activeJobs: [],
            memory: snapshot(available: 16 * gibibyte),
            mode: .focus
        )

        XCTAssertEqual(plan.admitted.map(\.id), [interactive.id])
        XCTAssertEqual(plan.deferred.map(\.job.id), [background.id])
        XCTAssertEqual(plan.deferred.first?.reason, .activeLimit)
    }

    func testExactReserveBoundaryAdmitsAndOneByteBelowDefers() {
        let governor = ResourceGovernor()
        let policy = governor.policy(for: .balanced)
        let reserve = policy.requiredReserve(physicalBytes: 16 * gibibyte)
        let estimate: UInt64 = 123_456
        let request = job(estimate: estimate)

        let exact = governor.makeAdmissionPlan(
            queuedJobs: [request],
            activeJobs: [],
            memory: snapshot(available: reserve + estimate),
            mode: .balanced
        )
        XCTAssertEqual(exact.admitted.map(\.id), [request.id])
        XCTAssertEqual(exact.projectedAvailableBytes, reserve)

        let below = governor.makeAdmissionPlan(
            queuedJobs: [request],
            activeJobs: [],
            memory: snapshot(available: reserve + estimate - 1),
            mode: .balanced
        )
        XCTAssertTrue(below.admitted.isEmpty)
        XCTAssertEqual(below.deferred.first?.reason, .insufficientHeadroom)
    }

    func testActiveLimitNeverChangesActiveWork() {
        let governor = ResourceGovernor()
        let active = ActiveJob(
            id: UUID(),
            conversationID: UUID(),
            provider: .claude,
            workflow: .backgroundReview,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let queued = job(workflow: .interactive, estimate: 1)

        let plan = governor.makeAdmissionPlan(
            queuedJobs: [queued],
            activeJobs: [active],
            memory: snapshot(available: 16 * gibibyte),
            mode: .focus
        )

        XCTAssertTrue(plan.admitted.isEmpty)
        XCTAssertEqual(plan.deferred, [DeferredJob(job: queued, reason: .activeLimit)])
        XCTAssertEqual(active.workflow, .backgroundReview, "The governor has no active-job mutation or kill path")
    }

    func testProjectedHeadroomAndCapacityAreAppliedSequentially() {
        let governor = ResourceGovernor()
        let policy = governor.policy(for: .throughput)
        let reserve = policy.requiredReserve(physicalBytes: 16 * gibibyte)
        let first = job(
            id: "00000000-0000-0000-0000-000000000001",
            enqueuedAt: Date(timeIntervalSince1970: 1),
            estimate: 100
        )
        let second = job(
            id: "00000000-0000-0000-0000-000000000002",
            enqueuedAt: Date(timeIntervalSince1970: 2),
            estimate: 100
        )

        let plan = governor.makeAdmissionPlan(
            queuedJobs: [second, first],
            activeJobs: [],
            memory: snapshot(available: reserve + 150),
            mode: .throughput
        )

        XCTAssertEqual(plan.admitted.map(\.id), [first.id])
        XCTAssertEqual(plan.deferred, [DeferredJob(job: second, reason: .insufficientHeadroom)])
        XCTAssertEqual(plan.projectedAvailableBytes, reserve + 50)
    }

    func testInjectedProviderCostsDriveAdmission() {
        let governor = ResourceGovernor(
            costEstimates: ProviderCostEstimates(codexBytes: 10, claudeBytes: 20)
        )
        let policy = governor.policy(for: .balanced)
        let reserve = policy.requiredReserve(physicalBytes: 16 * gibibyte)
        let codex = job(
            id: "00000000-0000-0000-0000-000000000001",
            provider: .codex,
            enqueuedAt: Date(timeIntervalSince1970: 1)
        )
        let claude = job(
            id: "00000000-0000-0000-0000-000000000002",
            provider: .claude,
            enqueuedAt: Date(timeIntervalSince1970: 2)
        )

        let plan = governor.makeAdmissionPlan(
            queuedJobs: [codex, claude],
            activeJobs: [],
            memory: snapshot(available: reserve + 25),
            mode: .balanced
        )

        XCTAssertEqual(plan.admitted.map(\.id), [codex.id])
        XCTAssertEqual(plan.deferred.first?.job.id, claude.id)
        XCTAssertEqual(plan.deferred.first?.reason, .insufficientHeadroom)
    }

    func testModePoliciesExposeIntentionalParallelismLevels() {
        let governor = ResourceGovernor()
        XCTAssertEqual(governor.policy(for: .focus).maximumActiveJobs, 1)
        XCTAssertEqual(governor.policy(for: .balanced).maximumActiveJobs, 2)
        XCTAssertEqual(governor.policy(for: .throughput).maximumActiveJobs, 4)
    }

    private func snapshot(available: UInt64) -> SystemMemorySnapshot {
        SystemMemorySnapshot(
            physicalBytes: 16 * gibibyte,
            availableBytes: available,
            appResidentBytes: 10,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func job(
        id: String = "00000000-0000-0000-0000-000000000010",
        provider: ProviderKind = .codex,
        workflow: WorkflowKind = .interactive,
        enqueuedAt: Date = Date(timeIntervalSince1970: 0),
        estimate: UInt64? = nil
    ) -> QueuedJob {
        QueuedJob(
            id: UUID(uuidString: id)!,
            conversationID: UUID(),
            provider: provider,
            workflow: workflow,
            enqueuedAt: enqueuedAt,
            estimatedMemoryBytes: estimate
        )
    }
}
