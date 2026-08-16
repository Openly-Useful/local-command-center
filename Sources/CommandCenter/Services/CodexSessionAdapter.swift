import Foundation

/// Codex adapter over the existing safe launch path. Start and resume reuse
/// `ProviderCommandBuilder` unchanged, so current CLI behavior is preserved:
/// absolute executable, argument array, prompt on stdin, validated workspace,
/// and UUID-validated resume identity.
struct CodexSessionAdapter: ProviderSessionAdapter {
    let provider: RuntimeProvider = .codex

    /// Optional override used by tests; production resolution stays in
    /// `ExecutableResolver`.
    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    var capabilities: ProviderSessionCapabilities {
        ProviderSessionCapabilities(
            supported: [.start, .resume, .checkpoint],
            unsupportedReasons: [
                .fork: "The Codex CLI exposes no verified fork verb; resuming continues one thread, and cross-provider transfer uses a continuity handoff.",
            ]
        )
    }

    func startPlan(_ request: ProviderSessionRequest) throws -> ProviderLaunchPlan {
        try ProviderCommandBuilder.build(
            provider: provider,
            workspaceURL: request.workspaceURL,
            prompt: request.prompt,
            permission: request.permission,
            workflow: request.workflow,
            selectedSkills: request.selectedSkills,
            sessionID: nil,
            executableURL: executableURL
        )
    }

    func resumePlan(
        _ request: ProviderSessionRequest,
        providerSessionID: String
    ) throws -> ProviderLaunchPlan {
        try ProviderCommandBuilder.build(
            provider: provider,
            workspaceURL: request.workspaceURL,
            prompt: request.prompt,
            permission: request.permission,
            workflow: request.workflow,
            selectedSkills: request.selectedSkills,
            sessionID: providerSessionID,
            executableURL: executableURL
        )
    }
}
