import CommandCenterCore
import Foundation
import XCTest
@testable import CommandCenter

final class ContinuityWriterLeaseGateTests: XCTestCase {
    func testConcurrentWritersHaveExactlyOneLeaseWinner() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let leases = await withTaskGroup(
            of: ContinuityWorkstreamWriterLease?.self,
            returning: [ContinuityWorkstreamWriterLease?].self
        ) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    try? await ContinuityWriterLeaseGate.acquireIfWritable(
                        store: fixture.store,
                        projectID: fixture.projectID,
                        handoffID: fixture.handoffID,
                        permission: .workspaceWrite,
                        ownerID: self.uuid(UInt8(100 + index)),
                        now: self.date(10),
                        duration: 60
                    )
                }
            }
            var values: [ContinuityWorkstreamWriterLease?] = []
            for await lease in group { values.append(lease) }
            return values
        }

        let winners = leases.compactMap { $0 }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(winners.first?.workstreamID, fixture.handoffID)
    }

    func testReviewerPermissionCreatesNoWriterTransaction() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let lease = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .readOnly,
            ownerID: uuid(200),
            now: date(10)
        )

        XCTAssertNil(lease)
        let syncTransaction = try await fixture.store.continuitySyncTransaction(id: fixture.handoffID)
        XCTAssertNil(syncTransaction, "Reviewer dispatches must not create external-sync state.")
    }

    func testReleasedLeasePermitsSafeRecovery() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let maybeFirst = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(30),
            now: date(10),
            duration: 60
        )
        let first = try XCTUnwrap(maybeFirst)
        let released = try await ContinuityWriterLeaseGate.release(
            store: fixture.store,
            lease: first,
            at: date(11)
        )
        XCTAssertTrue(released)
        let maybeAfterRelease = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(31),
            now: date(12),
            duration: 60
        )
        let afterRelease = try XCTUnwrap(maybeAfterRelease)
        XCTAssertEqual(afterRelease.ownerID, uuid(31))
    }

    func testSilentWriterHeartbeatRenewalPreventsSecondWriter() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let maybeFirst = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(40),
            now: date(10),
            duration: 2
        )
        let first = try XCTUnwrap(maybeFirst)
        let maybeRenewed = try await ContinuityWriterLeaseGate.renew(
            store: fixture.store,
            lease: first,
            now: date(11),
            duration: 2
        )
        let renewed = try XCTUnwrap(maybeRenewed)

        let challenger = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(41),
            now: date(12),
            duration: 2
        )

        XCTAssertGreaterThan(renewed.revision, first.revision)
        XCTAssertNil(challenger)
    }

    func testSourceAndDestinationOwnersContendForSameHandoffWorkstream() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        async let sourceLease = ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(50),
            now: date(10),
            duration: 60
        )
        async let destinationLease = ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(51),
            now: date(10),
            duration: 60
        )

        let leases = try await [sourceLease, destinationLease].compactMap { $0 }
        XCTAssertEqual(leases.count, 1)
        XCTAssertEqual(leases.first?.workstreamID, fixture.handoffID)
    }

    @MainActor
    func testScheduledHeartbeatKeepsSilentLiveWriterOwned() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let maybeFirst = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(60),
            now: Date(),
            duration: 1
        )
        let first = try XCTUnwrap(maybeFirst)
        let heartbeat = ContinuityWriterLeaseHeartbeat.start(
            intervalNanoseconds: 100_000_000
        ) {
            _ = try? await ContinuityWriterLeaseGate.renew(
                store: fixture.store,
                lease: first,
                now: Date(),
                duration: 1
            )
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        heartbeat.cancel()

        let challenger = try await ContinuityWriterLeaseGate.acquireIfWritable(
            store: fixture.store,
            projectID: fixture.projectID,
            handoffID: fixture.handoffID,
            permission: .workspaceWrite,
            ownerID: uuid(61),
            now: Date(),
            duration: 1
        )

        XCTAssertNil(challenger)
    }

    private func makeFixture() async throws -> (root: URL, store: SQLiteStore, projectID: UUID, handoffID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityWriterLeaseGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("store.sqlite"))
        let workspaceID = uuid(1)
        let projectID = uuid(2)
        let now = date(1)
        try await store.upsertWorkspace(Workspace(
            id: workspaceID,
            name: "Lease tests",
            rootPath: root.path,
            createdAt: now,
            updatedAt: now
        ))
        try await store.upsertContinuityProject(try ContinuityProject(
            id: projectID,
            workspaceID: workspaceID,
            name: "Lease tests",
            summary: "Local writer lease fixture",
            createdAt: now,
            updatedAt: now
        ))
        return (root, store, projectID, uuid(3))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
