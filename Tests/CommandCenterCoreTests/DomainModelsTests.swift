import Foundation
import XCTest
@testable import CommandCenterCore

final class DomainModelsTests: XCTestCase {
    func testDomainModelsRoundTripThroughCodable() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let conversation = Conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            workspaceID: workspaceID,
            title: "A local session",
            provider: .claude,
            workflow: .swarmWorker,
            permissionMode: .workspaceWrite,
            status: .waitingForInput,
            providerSessionID: "provider-session",
            skillIDs: [
                " pickup-swarm ",
                "engineering:code-review",
                "re\u{301}sume\u{301}",
                "résumé",
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let encoded = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)

        XCTAssertEqual(decoded, conversation)
        XCTAssertEqual(
            decoded.skillIDs,
            ["engineering:code-review", "pickup-swarm", "résumé"]
        )
        XCTAssertFalse(decoded.workflow.isInteractive)
        XCTAssertTrue(WorkflowKind.implementation.isInteractive)
    }

    func testSkillIDsAreCanonicalAndBounded() {
        let candidates = (0..<Conversation.maximumSkillIDCount + 8).map {
            "skill-\(String(format: "%03d", $0))"
        } + [
            " skill-000 ",
            "",
            "control\u{0}value",
            String(repeating: "x", count: Conversation.maximumSkillIDBytes + 1),
        ]

        var conversation = Conversation(
            workspaceID: UUID(),
            title: "bounded skills",
            provider: .codex,
            skillIDs: candidates
        )

        XCTAssertEqual(conversation.skillIDs.count, Conversation.maximumSkillIDCount)
        XCTAssertEqual(conversation.skillIDs, conversation.skillIDs.sorted())
        XCTAssertEqual(Set(conversation.skillIDs).count, conversation.skillIDs.count)
        XCTAssertTrue(conversation.skillIDs.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= Conversation.maximumSkillIDBytes
        })

        conversation.skillIDs = [" zeta ", "alpha", "alpha"]
        XCTAssertEqual(conversation.skillIDs, ["alpha", "zeta"])
    }

    func testConversationDecodesLegacyPayloadWithoutSkillIDs() throws {
        let conversation = Conversation(
            workspaceID: UUID(),
            title: "legacy JSON",
            provider: .claude,
            skillIDs: ["pickup-swarm"]
        )
        let encoded = try JSONEncoder().encode(conversation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "skillIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)

        XCTAssertEqual(decoded.skillIDs, [])
        XCTAssertEqual(decoded.id, conversation.id)
        XCTAssertEqual(decoded.title, conversation.title)
    }
}
