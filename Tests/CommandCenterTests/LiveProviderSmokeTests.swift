import Foundation
import XCTest
@testable import CommandCenter

final class LiveProviderSmokeTests: XCTestCase {
    final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var text: [String] = []
        private(set) var diagnostics: [String] = []
        private(set) var exitStatus: Int32?

        func record(_ event: ProviderStreamEvent) {
            if case .batch(let events) = event {
                for event in events { record(event) }
                return
            }
            lock.lock()
            defer { lock.unlock() }
            switch event {
            case .batch:
                break
            case .text(let value), .result(let value): text.append(value)
            case .diagnostic(let value): diagnostics.append(value)
            case .exited(let status): exitStatus = status
            case .sessionID, .activity: break
            }
        }

        func snapshot() -> (text: [String], diagnostics: [String], exitStatus: Int32?) {
            lock.lock()
            defer { lock.unlock() }
            return (text, diagnostics, exitStatus)
        }
    }

    func testAuthenticatedCodexAndClaudeReadOnlyTurns() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_COMMAND_CENTER_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set LOCAL_COMMAND_CENTER_LIVE_SMOKE=1 for subscription-backed smoke testing.")
        }

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        for (provider, marker) in [(RuntimeProvider.codex, "LCC_CODEX_OK"), (.claude, "LCC_CLAUDE_OK")] {
            let plan = try ProviderCommandBuilder.build(
                provider: provider,
                workspaceURL: workspace,
                prompt: "Reply with exactly \(marker). Do not call tools and do not add punctuation.",
                permission: .readOnly,
                workflow: .direct,
                selectedSkills: [],
                sessionID: nil
            )
            let completed = expectation(description: "\(provider.displayName) exited")
            let state = ProbeState()
            let process = try ProviderProcessRunner().start(plan) { event in
                state.record(event)
                if case .exited = event { completed.fulfill() }
            }

            await fulfillment(of: [completed], timeout: 180)
            withExtendedLifetime(process) {}
            let result = state.snapshot()
            XCTAssertEqual(result.exitStatus, 0, "\(provider.displayName) diagnostics: \(result.diagnostics)")
            XCTAssertTrue(
                result.text.joined(separator: "\n").contains(marker),
                "\(provider.displayName) did not return the expected marker; diagnostics: \(result.diagnostics)"
            )
        }
    }
}
