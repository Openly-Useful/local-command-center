import CommandCenterCore
import XCTest
@testable import CommandCenter

final class ContinuityPreflightViewModelTests: XCTestCase {
    func testValidPreviewIsReadOnlyAndDisclosesDestinationUsage() {
        let preview = makePreview(reviewOnly: false)

        XCTAssertTrue(preview.isConfirmable)
        XCTAssertEqual(preview.permissionLabel, "Read only")
        XCTAssertEqual(preview.modeTitle, "Compact continuation")
        XCTAssertTrue(preview.usageDisclosure.contains("read-only"))
        XCTAssertTrue(preview.usageDisclosure.contains("usage"))
    }

    func testInvalidPreviewDisablesConfirmationAndPreservesRecoveryError() {
        let preview = ContinuityHandoffPreview(
            sourceConversationID: UUID(),
            destination: .claude,
            reviewOnly: true,
            sourceTitle: "Review source",
            boundary: boundary(),
            recoveryError: "The repository changed after the preview. Prepare a new preview."
        )

        XCTAssertFalse(preview.isConfirmable)
        XCTAssertEqual(preview.modeTitle, "Read-only review")
        XCTAssertTrue(preview.usageDisclosure.contains("advisory"))
        XCTAssertEqual(preview.recoveryError, "The repository changed after the preview. Prepare a new preview.")
    }

    func testSelectedStatusDistinguishesWriterReviewerAndReconciliation() {
        let writer = makeStatus(isActiveWriter: true, isReadOnlyReviewer: false, requiresReconciliation: false)
        let reviewer = makeStatus(isActiveWriter: false, isReadOnlyReviewer: true, requiresReconciliation: true)

        XCTAssertEqual(writer.roleLabel, "Destination continuation")
        XCTAssertEqual(writer.executionLabel, "Active writer")
        XCTAssertEqual(reviewer.executionLabel, "Read-only reviewer")
        XCTAssertTrue(reviewer.requiresReconciliation)
        XCTAssertEqual(reviewer.changedPaths, [".continuity/context.md", "Sources/App.swift"])
    }

    func testAmbiguousLineageFailsClosedInsteadOfSelectingAnArbitraryHandoff() {
        let first = makeStatus(isActiveWriter: false, isReadOnlyReviewer: false, requiresReconciliation: false)
        let second = makeStatus(isActiveWriter: true, isReadOnlyReviewer: false, requiresReconciliation: true)

        XCTAssertEqual(ContinuityLineageSelection.resolve([]), .none)
        XCTAssertEqual(ContinuityLineageSelection.resolve([first]), .unique(first))
        XCTAssertEqual(ContinuityLineageSelection.resolve([first, second]), .ambiguous)
    }

    func testConfirmationGateAllowsExactlyOneCurrentReadyPreview() {
        let preview = makePreview(reviewOnly: false)
        XCTAssertTrue(ContinuityPreviewConfirmationGate.canBegin(
            preview: preview,
            isInFlight: false,
            consumedIDs: []
        ))

        let consumed: Set<UUID> = [preview.id]
        XCTAssertFalse(ContinuityPreviewConfirmationGate.canBegin(
            preview: preview,
            isInFlight: false,
            consumedIDs: consumed
        ))
        XCTAssertFalse(ContinuityPreviewConfirmationGate.remainsValid(
            preview: preview,
            selectedConversationID: preview.sourceConversationID,
            currentPreviewID: nil,
            isInFlight: true,
            consumedIDs: consumed,
            sourceIsReady: true,
            provider: .claude,
            reviewOnly: false
        ), "Cancelling the sheet invalidates an in-flight confirmation.")
        XCTAssertFalse(ContinuityPreviewConfirmationGate.remainsValid(
            preview: preview,
            selectedConversationID: preview.sourceConversationID,
            currentPreviewID: preview.id,
            isInFlight: true,
            consumedIDs: consumed,
            sourceIsReady: false,
            provider: .claude,
            reviewOnly: false
        ), "A source that became busy after preflight cannot be mutated.")
        XCTAssertTrue(ContinuityPreviewConfirmationGate.remainsValid(
            preview: preview,
            selectedConversationID: preview.sourceConversationID,
            currentPreviewID: preview.id,
            isInFlight: true,
            consumedIDs: consumed,
            sourceIsReady: true,
            provider: .claude,
            reviewOnly: false
        ))
    }

    func testPreparedPreviewIsDiscardedWhenSelectionOrSourceReadinessChanges() {
        let sourceID = UUID()
        XCTAssertFalse(ContinuityPreviewConfirmationGate.canPresentPreparedPreview(
            sourceConversationID: sourceID,
            selectedConversationID: UUID(),
            sourceIsReady: true
        ))
        XCTAssertFalse(ContinuityPreviewConfirmationGate.canPresentPreparedPreview(
            sourceConversationID: sourceID,
            selectedConversationID: sourceID,
            sourceIsReady: false
        ))
        XCTAssertTrue(ContinuityPreviewConfirmationGate.canPresentPreparedPreview(
            sourceConversationID: sourceID,
            selectedConversationID: sourceID,
            sourceIsReady: true
        ))
    }

    private func makePreview(reviewOnly: Bool) -> ContinuityHandoffPreview {
        ContinuityHandoffPreview(
            sourceConversationID: UUID(),
            destination: .claude,
            reviewOnly: reviewOnly,
            sourceTitle: "Source task",
            boundary: boundary()
        )
    }

    private func boundary() -> ContinuityHandoffBoundary {
        ContinuityHandoffBoundary(
            capsuleDigest: String(repeating: "a", count: 64),
            commit: String(repeating: "b", count: 40),
            statusDigest: String(repeating: "c", count: 64),
            sourceLabel: "Codex",
            destinationLabel: "Claude",
            changedPaths: ["Sources/App.swift", ".continuity/context.md"]
        )
    }

    private func makeStatus(
        isActiveWriter: Bool,
        isReadOnlyReviewer: Bool,
        requiresReconciliation: Bool
    ) -> SelectedContinuityStatus {
        SelectedContinuityStatus(
            projectName: "Continuity project",
            handoffTitle: "Compact continuation",
            handoffState: .ready,
            role: .destination,
            capsuleDigest: String(repeating: "a", count: 64),
            revision: 1,
            commit: String(repeating: "b", count: 40),
            statusDigest: String(repeating: "c", count: 64),
            changedPaths: [".continuity/context.md", "Sources/App.swift"],
            isActiveWriter: isActiveWriter,
            isReadOnlyReviewer: isReadOnlyReviewer,
            requiresReconciliation: requiresReconciliation
        )
    }
}
