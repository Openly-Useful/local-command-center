import CommandCenterCore
import Foundation

struct LocalHistoryObservation: Sendable {
    var provider: ProviderKind
    var surface: ExternalSessionSurface
    var snapshot: LocalHistorySnapshot
}

struct LocalHistoryRefreshResult: Sendable {
    var observations: [LocalHistoryObservation]
    var startedAt: Date
    var finishedAt: Date

    var sessions: [ExternalSession] {
        observations.flatMap(\.snapshot.sessions)
    }

    var diagnostics: [LocalHistoryDiagnostic] {
        observations.flatMap(\.snapshot.diagnostics)
    }
}

/// Coalesces launch, foreground, timer, manual, and provider-exit refreshes so
/// the app never performs overlapping provider-store scans. The two independent
/// sources may scan concurrently, while each adapter remains internally bounded.
actor LocalHistoryRefreshCoordinator {
    private let sources: [any LocalHistorySource]
    private var inFlight: Task<LocalHistoryRefreshResult, Never>?

    init(sources: [any LocalHistorySource] = [
        CodexLocalHistorySource(),
        ClaudeLocalHistorySource(),
    ]) {
        self.sources = sources
    }

    func refresh() async -> LocalHistoryRefreshResult {
        if let inFlight {
            return await inFlight.value
        }

        let sources = self.sources
        let startedAt = Date()
        let task = Task {
            let observations = await withTaskGroup(
                of: LocalHistoryObservation.self,
                returning: [LocalHistoryObservation].self
            ) { group in
                for source in sources {
                    let provider = source.provider
                    let surface: ExternalSessionSurface = provider == .codex ? .codex : .claudeCode
                    group.addTask {
                        LocalHistoryObservation(
                            provider: provider,
                            surface: surface,
                            snapshot: await source.scan()
                        )
                    }
                }
                var observations: [LocalHistoryObservation] = []
                observations.reserveCapacity(sources.count)
                for await observation in group {
                    observations.append(observation)
                }
                return observations.sorted { lhs, rhs in
                    lhs.provider.rawValue < rhs.provider.rawValue
                }
            }
            return LocalHistoryRefreshResult(
                observations: observations,
                startedAt: startedAt,
                finishedAt: Date()
            )
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    func revalidate(session: ExternalSession) async -> LocalSessionRevalidation {
        guard let source = sources.first(where: { $0.provider == session.provider }) else {
            return LocalSessionRevalidation(
                provider: session.provider,
                providerSessionID: session.providerSessionID,
                state: .indeterminate,
                checkedAt: Date(),
                refreshedSession: nil,
                diagnostic: .init(
                    severity: .warning,
                    code: "local-session-source-unavailable",
                    sourcePath: nil,
                    detail: "The local provider source is unavailable; refresh and retry."
                )
            )
        }
        return await source.revalidate(session: session)
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}
