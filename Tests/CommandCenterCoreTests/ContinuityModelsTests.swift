import Foundation
import XCTest
@testable import CommandCenterCore

/// WS-001 contract characterization: these tests pin the canonical continuity
/// model invariants documented in ADR-004 independently of persistence.
final class ContinuityModelsTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    func testSessionLinkRequiresExactlyOneLocalReference() {
        XCTAssertThrowsError(try ContinuitySessionLink(projectID: uuid(1))) { error in
            XCTAssertEqual(
                error as? ContinuityValidationError,
                .invalidSessionReference
            )
        }
        XCTAssertThrowsError(try ContinuitySessionLink(
            projectID: uuid(1),
            conversationID: uuid(2),
            externalSessionID: uuid(3)
        )) { error in
            XCTAssertEqual(
                error as? ContinuityValidationError,
                .invalidSessionReference
            )
        }
        XCTAssertNoThrow(try ContinuitySessionLink(projectID: uuid(1), conversationID: uuid(2)))
        XCTAssertNoThrow(try ContinuitySessionLink(projectID: uuid(1), externalSessionID: uuid(3)))
    }

    func testNonFiniteDatesAreRejectedEverywhere() {
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try ContinuityProject(
            workspaceID: uuid(1), name: "n", createdAt: invalid
        ))
        XCTAssertThrowsError(try ContinuitySessionLink(
            projectID: uuid(1), conversationID: uuid(2), updatedAt: invalid
        ))
        XCTAssertThrowsError(try ContinuityHandoff(
            projectID: uuid(1), sourceSessionLinkID: uuid(2),
            title: "t", summary: "s", updatedAt: invalid
        ))
        XCTAssertThrowsError(try ContinuityEvent(
            projectID: uuid(1), kind: .note, detail: "d", occurredAt: invalid
        ))
        XCTAssertThrowsError(try ContinuityWriterLease(
            transactionID: uuid(1), ownerID: uuid(2), expiresAt: invalid, revision: 0
        ))
        XCTAssertThrowsError(try ContinuityWorkstreamWriterLease(
            projectID: uuid(1), workstreamID: uuid(2), ownerID: uuid(3),
            expiresAt: invalid, revision: 0
        ))
    }

    func testControlCharactersAreRejectedNotSilentlyStripped() {
        XCTAssertThrowsError(try ContinuityProject(
            workspaceID: uuid(1), name: "line\nbreak"
        )) { error in
            XCTAssertEqual(
                error as? ContinuityValidationError,
                .containsControlCharacters(field: "name")
            )
        }
        XCTAssertThrowsError(try ContinuityProject(
            workspaceID: uuid(1), name: "n", summary: "nul\u{0}byte"
        ))
        XCTAssertThrowsError(try ContinuityHandoff(
            projectID: uuid(1), sourceSessionLinkID: uuid(2),
            title: "t", summary: "escape\u{1B}[31m"
        ))
        XCTAssertThrowsError(try ContinuityEvent(
            projectID: uuid(1), kind: .note, detail: "bell\u{7}"
        ))
    }

    func testByteBoundsUseUTF8LengthAndWhitespaceOnlyTextIsEmpty() {
        let overLimitMultibyte = String(
            repeating: "é",
            count: ContinuityProject.maximumNameBytes / 2 + 1
        )
        XCTAssertThrowsError(try ContinuityProject(
            workspaceID: uuid(1), name: overLimitMultibyte
        )) { error in
            guard case .exceedsByteLimit(let field, _, let maximum)? =
                error as? ContinuityValidationError else {
                return XCTFail("Expected exceedsByteLimit, received \(error)")
            }
            XCTAssertEqual(field, "name")
            XCTAssertEqual(maximum, ContinuityProject.maximumNameBytes)
        }
        XCTAssertThrowsError(try ContinuityProject(
            workspaceID: uuid(1), name: "   \n  "
        ))
        let trimmedProject = try? ContinuityProject(
            workspaceID: uuid(1), name: "  ok  ", summary: "   "
        )
        XCTAssertEqual(trimmedProject?.name, "ok")
        XCTAssertNil(trimmedProject?.summary, "Whitespace-only summary collapses to nil")
    }

    func testNegativeCountersAreRejected() {
        XCTAssertThrowsError(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, attempt: -1
        ))
        XCTAssertThrowsError(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, revision: -1
        ))
        XCTAssertThrowsError(try ContinuityWriterLease(
            transactionID: uuid(1), ownerID: uuid(2), expiresAt: time, revision: -1
        ))
        XCTAssertThrowsError(try ContinuityWorkstreamWriterLease(
            projectID: uuid(1), workstreamID: uuid(2), ownerID: uuid(3),
            expiresAt: time, revision: -5
        ))
    }

    func testSyncCompletionTimestampMatchesTerminalStateInBothDirections() {
        XCTAssertThrowsError(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, state: .pending, completedAt: time
        ))
        XCTAssertThrowsError(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, state: .running, completedAt: time
        ))
        XCTAssertThrowsError(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, state: .failed
        ))
        XCTAssertNoThrow(try ContinuitySyncTransaction(
            projectID: uuid(1), kind: .manual, state: .failed, completedAt: time
        ))
    }

    func testReconciliationEvidenceRequiresCanonicalLowercaseSHA256Digests() {
        let valid = String(repeating: "a", count: 64)
        for invalidDigest in [
            String(repeating: "A", count: 64),
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "g", count: 64),
            "",
        ] {
            XCTAssertThrowsError(try ContinuityWorkstreamReconciliationEvidence(
                capsuleDigest: invalidDigest,
                workspaceDigest: valid,
                auditEvidenceID: "ev_audit-1"
            ), "Expected digest \(invalidDigest.prefix(8))… to be rejected")
            XCTAssertThrowsError(try ContinuityWorkstreamReconciliationEvidence(
                capsuleDigest: valid,
                workspaceDigest: invalidDigest,
                auditEvidenceID: "ev_audit-1"
            ))
        }
        XCTAssertNoThrow(try ContinuityWorkstreamReconciliationEvidence(
            capsuleDigest: valid,
            workspaceDigest: valid,
            auditEvidenceID: "ev_audit-1"
        ))
    }

    func testLeaseModelsRoundTripThroughCodable() throws {
        let syncLease = try ContinuityWriterLease(
            transactionID: uuid(1), ownerID: uuid(2), expiresAt: time, revision: 3
        )
        let workstreamLease = try ContinuityWorkstreamWriterLease(
            projectID: uuid(4), workstreamID: uuid(5), ownerID: uuid(6),
            expiresAt: time, revision: 7
        )
        let decodedSync = try JSONDecoder().decode(
            ContinuityWriterLease.self,
            from: JSONEncoder().encode(syncLease)
        )
        let decodedWorkstream = try JSONDecoder().decode(
            ContinuityWorkstreamWriterLease.self,
            from: JSONEncoder().encode(workstreamLease)
        )
        XCTAssertEqual(decodedSync, syncLease)
        XCTAssertEqual(decodedWorkstream, workstreamLease)
    }

    func testHandoffDecodingEnforcesTheSameContractAsConstruction() throws {
        let handoff = try ContinuityHandoff(
            projectID: uuid(1), sourceSessionLinkID: uuid(2),
            title: "t", summary: "s", createdAt: time, updatedAt: time
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(handoff)
            ) as? [String: Any]
        )
        object["summary"] = String(
            repeating: "x",
            count: ContinuityHandoff.maximumSummaryBytes + 1
        )
        let oversized = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ContinuityHandoff.self, from: oversized)
        )
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "82000000-0000-0000-0000-%012d", number))!
    }
}
