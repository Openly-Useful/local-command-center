import CommandCenterCore
import Foundation
import XCTest
@testable import CommandCenter

final class LocalHistoryRefreshCoordinatorTests: XCTestCase {
    func testConcurrentRefreshesCoalesceIntoOneScanPerSource() async {
        let codex = CountingHistorySource(provider: .codex)
        let claude = CountingHistorySource(provider: .claude)
        let coordinator = LocalHistoryRefreshCoordinator(sources: [codex, claude])

        async let first = coordinator.refresh()
        async let second = coordinator.refresh()
        let results = await (first, second)

        XCTAssertEqual(results.0.observations.count, 2)
        XCTAssertEqual(results.1.observations.count, 2)
        let codexCount = await codex.scanCount()
        let claudeCount = await claude.scanCount()
        XCTAssertEqual(codexCount, 1)
        XCTAssertEqual(claudeCount, 1)
    }
}

private actor CountingHistorySource: LocalHistorySource {
    let provider: ProviderKind
    private var count = 0

    init(provider: ProviderKind) {
        self.provider = provider
    }

    func scan() async -> LocalHistorySnapshot {
        count += 1
        try? await Task.sleep(for: .milliseconds(25))
        let now = Date()
        return LocalHistorySnapshot(
            sessions: [],
            diagnostics: [],
            metrics: .empty(startedAt: now),
            authoritative: true
        )
    }

    func scanCount() -> Int { count }
}
