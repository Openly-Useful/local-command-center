import AppKit
import Combine
import CommandCenterCore
import Foundation

/// Bridges the provider runner's serial callback queue to MainActor with
/// backpressure. The runner cannot deliver exit before an earlier session/text
/// checkpoint finishes, and at most one bounded provider event is retained.
final class SerializedProviderEventHandoff: @unchecked Sendable {
    private let handler: @MainActor @Sendable (ProviderStreamEvent) async -> Void

    init(handler: @escaping @MainActor @Sendable (ProviderStreamEvent) async -> Void) {
        self.handler = handler
    }

    /// Called only from ProviderProcessRunner's private serial callback queue.
    func accept(_ event: ProviderStreamEvent) {
        let completion = DispatchSemaphore(value: 0)
        Task { @MainActor [handler] in
            await handler(event)
            completion.signal()
        }
        completion.wait()
    }
}

actor ObsidianProjectionCoordinator {
    func write(
        vaultURL: URL,
        sessions: [ObsidianSessionProjection]
    ) throws -> ObsidianProjectionResult {
        let writer = try ObsidianProjectionWriter(vaultURL: vaultURL)
        return try writer.write(sessions: sessions)
    }
}

/// A read-only, per-action handoff preview. It contains only the compact
/// continuity boundary and repository facts needed for an explicit operator
/// confirmation; no provider transcript or session identity is copied here.
struct ContinuityHandoffPreview: Identifiable, Equatable {
    let id: UUID
    let sourceConversationID: UUID
    let destination: RuntimeProvider
    let reviewOnly: Bool
    let sourceTitle: String
    let boundary: ContinuityHandoffBoundary
    let recoveryError: String?

    init(
        id: UUID = UUID(),
        sourceConversationID: UUID,
        destination: RuntimeProvider,
        reviewOnly: Bool,
        sourceTitle: String,
        boundary: ContinuityHandoffBoundary,
        recoveryError: String? = nil
    ) {
        self.id = id
        self.sourceConversationID = sourceConversationID
        self.destination = destination
        self.reviewOnly = reviewOnly
        self.sourceTitle = sourceTitle
        self.boundary = boundary
        self.recoveryError = recoveryError
    }

    var isConfirmable: Bool { recoveryError == nil }
    var modeTitle: String { reviewOnly ? "Read-only review" : "Compact continuation" }
    var permissionLabel: String { "Read only" }
    var usageDisclosure: String {
        reviewOnly
            ? "The reviewer receives a bounded continuity capsule and can only return advisory findings. It cannot write to the workspace."
            : "The destination first validates this bounded capsule in read-only mode. Destination processing consumes that provider's usage."
    }
}

struct SelectedContinuityStatus: Equatable {
    enum Role: String, Equatable {
        case source
        case destination
    }

    let projectName: String
    let handoffTitle: String
    let handoffState: ContinuityHandoffState
    let role: Role
    let capsuleDigest: String
    let revision: Int
    let commit: String
    let statusDigest: String
    let changedPaths: [String]
    let isActiveWriter: Bool
    let isReadOnlyReviewer: Bool
    let requiresReconciliation: Bool

    var roleLabel: String { role == .source ? "Source boundary" : "Destination continuation" }
    var executionLabel: String {
        isActiveWriter ? "Active writer" : (isReadOnlyReviewer ? "Read-only reviewer" : "No active writer")
    }
}

enum ContinuityLineageSelection: Equatable {
    case none
    case unique(SelectedContinuityStatus)
    case ambiguous

    static func resolve(_ candidates: [SelectedContinuityStatus]) -> Self {
        switch candidates.count {
        case 0: .none
        case 1: .unique(candidates[0])
        default: .ambiguous
        }
    }
}

enum ContinuityPreviewConfirmationGate {
    static func canPresentPreparedPreview(
        sourceConversationID: UUID,
        selectedConversationID: UUID?,
        sourceIsReady: Bool
    ) -> Bool {
        selectedConversationID == sourceConversationID && sourceIsReady
    }

    static func canBegin(
        preview: ContinuityHandoffPreview?,
        isInFlight: Bool,
        consumedIDs: Set<UUID>
    ) -> Bool {
        guard let preview else { return false }
        return preview.isConfirmable && !isInFlight && !consumedIDs.contains(preview.id)
    }

    static func remainsValid(
        preview: ContinuityHandoffPreview,
        selectedConversationID: UUID?,
        currentPreviewID: UUID?,
        isInFlight: Bool,
        consumedIDs: Set<UUID>,
        sourceIsReady: Bool,
        provider: RuntimeProvider,
        reviewOnly: Bool
    ) -> Bool {
        selectedConversationID == preview.sourceConversationID
            && currentPreviewID == preview.id
            && isInFlight
            && consumedIDs.contains(preview.id)
            && sourceIsReady
            && preview.destination == provider
            && preview.reviewOnly == reviewOnly
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let maximumPromptBytes = 256 * 1_024
    private static let maximumContinuityPromptBytes = maximumPromptBytes + ContinuityCapsuleLimits.contextByteLimit
    private static let maximumQueuedDispatches = 16
    private static let maximumQueuedPromptBytes = 2 * 1_048_576
    private static let continuityWriterHeartbeatNanoseconds: UInt64 = 120 * 1_000_000_000

    struct PendingDispatch {
        var id: UUID
        var conversationID: UUID
        var prompt: String
        var provider: RuntimeProvider
        /// Controls the provider prompt shape. Scheduling and persisted task
        /// classification intentionally live in `classification` so an
        /// automated read-only review is never promoted to foreground work.
        var workflow: RuntimeWorkflow
        var classification: WorkflowKind
        var permission: RuntimePermission
        var skills: [String]
        var enqueuedAt: Date
        var promptCheckpointed: Bool
        var continuityHandoffID: UUID?
    }

    private struct PreparedContinuityDispatch {
        let prompt: String
        let handoffID: UUID?
    }

    private enum ContinuityWriterHandoffRole {
        case source
        case destination
    }

    private struct ContinuityWriterHandoff {
        let handoff: ContinuityHandoff
        let role: ContinuityWriterHandoffRole
    }

    @Published var workspaces: [Workspace] = []
    @Published var conversations: [Conversation] = []
    @Published var messages: [Message] = []
    @Published var providerHealth: [ProviderHealth] = []
    @Published var skills: [LocalSkillDescriptor] = []
    @Published var externalSessions: [ExternalSession] = []
    @Published var externalTranscript: [LocalTranscriptRow] = []
    @Published var selectedSidebar: SidebarDestination = .inbox
    @Published var selectedConversationID: UUID?
    @Published var selectedExternalSessionID: UUID?
    @Published var searchText = ""
    @Published var skillSearchText = ""
    @Published var selectedSkills: Set<String> = ["pickup-swarm", "engineering:code-review"]
    @Published var composerText = ""
    @Published var selectedProvider: RuntimeProvider = .codex
    @Published var selectedWorkflow: RuntimeWorkflow = .direct
    @Published var selectedPermission: RuntimePermission = .readOnly
    @Published var resourceMode: ResourceMode = .balanced
    @Published var memorySnapshot: SystemMemorySnapshot?
    @Published var activityText = "Starting local services…"
    @Published var alertText: String?
    @Published var isBootstrapping = true
    @Published var isHistoryRefreshing = false
    @Published var isExternalTranscriptLoading = false
    @Published var externalTranscriptWasTruncated = false
    @Published var externalTranscriptBytesRead = 0
    @Published var historyLastRefreshedAt: Date?
    @Published var historyDiagnosticCount = 0
    @Published var historyDiagnostics: [LocalHistoryDiagnostic] = []
    @Published var historyIndexedSessionCount = 0
    @Published var historyOmittedSessionCount = 0
    @Published var historyLastScanDuration: TimeInterval = 0
    @Published var obsidianVaults: [ObsidianVaultDescriptor] = []
    @Published var connectedObsidianVaultPath: String?
    @Published var obsidianProjectionStatus = "Not connected"
    @Published var obsidianProjectedFileCount = 0
    @Published var continuityPreview: ContinuityHandoffPreview?
    @Published var selectedContinuityStatus: SelectedContinuityStatus?
    @Published var continuityStatusWarning: String?
    @Published var isContinuityConfirmationInFlight = false

    private let providerHealthService = ProviderHealthService()
    private let providerRunner = ProviderProcessRunner()
    private let skillCatalog = SkillCatalog()
    private let historyCoordinator = LocalHistoryRefreshCoordinator()
    private let transcriptReader = LocalTranscriptReader()
    private let obsidianRegistry = ObsidianVaultRegistry()
    private let obsidianProjectionCoordinator = ObsidianProjectionCoordinator()
    private let governor = ResourceGovernor()
    private let metrics = DarwinSystemMetrics()
    private var store: SQLiteStore?
    private var runningProcesses: [UUID: RunningProviderProcess] = [:]
    private var reservedDispatches: [UUID: PendingDispatch] = [:]
    private var queuedDispatches: [PendingDispatch] = []
    private var queueReservations: [UUID: PendingDispatch] = [:]
    /// Local-only process ownership. The durable lease itself remains in
    /// SQLite, so a crashed app can recover safely after its bounded expiry.
    private var continuityWriterLeases: [UUID: ContinuityWorkstreamWriterLease] = [:]
    private var continuityWriterHeartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var consumedContinuityPreviewIDs: Set<UUID> = []
    private var preparingConversationIDs: Set<UUID> = []
    private var pairedReviewPrimaries: Set<UUID> = []
    private var lastAssistantText: [UUID: String] = [:]
    private var pinnedIDs: Set<UUID> = []
    private var cancellationRequestedIDs: Set<UUID> = []
    private var preparingExternalSessionIDs: Set<UUID> = []
    private var queueDrainInProgress = false
    private var applicationIsActive = true
    private var obsidianSelectionGeneration = 0
    private var obsidianProjectionRequest = 0
    private var externalTranscriptLoadGeneration = 0

    private static let connectedObsidianVaultDefaultsKey = "connectedObsidianVaultPath"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: "pinnedConversationIDs") ?? []
        pinnedIDs = Set(stored.compactMap(UUID.init(uuidString:)))
        Task { await bootstrap() }
    }

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == selectedConversationID })
    }

    var selectedExternalSession: ExternalSession? {
        guard let selectedExternalSessionID else { return nil }
        return externalSessions.first(where: { $0.id == selectedExternalSessionID })
    }

    var selectedWorkspace: Workspace? {
        if case .workspace(let id) = selectedSidebar {
            return workspaces.first(where: { $0.id == id })
        }
        if let selectedConversation {
            return workspaces.first(where: { $0.id == selectedConversation.workspaceID })
        }
        return workspaces.first
    }

    var filteredConversations: [Conversation] {
        let scoped: [Conversation]
        switch selectedSidebar {
        case .inbox:
            scoped = conversations.filter {
                [.running, .queued, .waitingForInput, .failed].contains($0.status)
            }
        case .pinned:
            scoped = conversations.filter { pinnedIDs.contains($0.id) }
        case .ready:
            scoped = conversations.filter { $0.status == .completed }
        case .workspace(let id):
            scoped = conversations.filter { $0.workspaceID == id }
        case .history, .skills, .runtime:
            scoped = []
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return scoped
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var filteredExternalSessions: [ExternalSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return externalSessions.filter {
            query.isEmpty
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || ($0.workspacePath?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.provider.displayName.localizedCaseInsensitiveContains(query)
        }.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var filteredSkills: [LocalSkillDescriptor] {
        let query = skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var inboxCount: Int {
        conversations.filter {
            [.running, .queued, .waitingForInput, .failed].contains($0.status)
        }.count
    }

    var readyCount: Int { conversations.filter { $0.status == .completed }.count }
    var pinnedCount: Int { conversations.filter { pinnedIDs.contains($0.id) }.count }
    var codexHistoryCount: Int { externalSessions.filter { $0.provider == .codex }.count }
    var claudeHistoryCount: Int { externalSessions.filter { $0.provider == .claude }.count }
    var resumableHistoryCount: Int {
        externalSessions.filter { $0.canResume && $0.missingSince == nil }.count
    }
    var runningCount: Int { runningProcesses.count + reservedDispatches.count }
    var queuedCount: Int { queuedDispatches.count + queueReservations.count }
    var maximumWorkers: Int { governor.policy(for: resourceMode).maximumActiveJobs }
    var isSelectedConversationRunning: Bool {
        selectedConversationID.map { runningProcesses[$0] != nil } ?? false
    }
    var isSelectedConversationBusy: Bool {
        guard let selectedConversationID else { return false }
        return runningProcesses[selectedConversationID] != nil
            || reservedDispatches[selectedConversationID] != nil
            || preparingConversationIDs.contains(selectedConversationID)
            || queuedDispatches.contains(where: { $0.conversationID == selectedConversationID })
            || queueReservations.values.contains(where: { $0.conversationID == selectedConversationID })
    }

    var selectedExternalWorkspace: Workspace? {
        guard let session = selectedExternalSession else { return nil }
        return approvedWorkspace(for: session)
    }

    var canContinueSelectedExternalSession: Bool {
        guard let session = selectedExternalSession else { return false }
        return session.canResume
            && session.missingSince == nil
            && UUID(uuidString: session.providerSessionID) != nil
            && selectedExternalWorkspace != nil
    }

    var canRunComposerCommand: Bool {
        selectedSidebar.supportsConversationDispatch
            && selectedConversation != nil
            && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSelectedConversationBusy
    }

    var canCancelSelectedCommand: Bool {
        selectedSidebar.supportsConversationDispatch && isSelectedConversationRunning
    }

    var selectedProjectExternalSessions: [ExternalSession] {
        guard case .workspace(let workspaceID) = selectedSidebar,
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return externalSessions.filter { session in
            standardizedStoredPath(session.workspacePath) == workspace.rootPath
                && (query.isEmpty
                    || session.title.localizedCaseInsensitiveContains(query)
                    || session.preview.localizedCaseInsensitiveContains(query)
                    || session.provider.displayName.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var projectTaskCounts: [UUID: Int] {
        var counts = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, 0) })
        for conversation in conversations {
            counts[conversation.workspaceID, default: 0] += 1
        }
        let workspaceIDsByPath = Dictionary(
            uniqueKeysWithValues: workspaces.map { ($0.rootPath, $0.id) }
        )
        for session in externalSessions {
            guard let path = standardizedStoredPath(session.workspacePath),
                  let workspaceID = workspaceIDsByPath[path] else { continue }
            counts[workspaceID, default: 0] += 1
        }
        return counts
    }

    var connectedObsidianVault: ObsidianVaultDescriptor? {
        guard let connectedObsidianVaultPath else { return nil }
        return obsidianVaults.first(where: { $0.rootURL.path == connectedObsidianVaultPath })
    }

    func isPinned(_ id: UUID) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: UUID) {
        if pinnedIDs.contains(id) { pinnedIDs.remove(id) } else { pinnedIDs.insert(id) }
        UserDefaults.standard.set(pinnedIDs.map(\.uuidString).sorted(), forKey: "pinnedConversationIDs")
        objectWillChange.send()
    }

    func bootstrap() async {
        defer { isBootstrapping = false }
        do {
            let databaseURL = try Self.databaseURL()
            let database = try SQLiteStore(databaseURL: databaseURL)
            store = database
            workspaces = try await database.listWorkspaces()
            conversations = try await database.listConversations()
            for index in conversations.indices where [.running, .queued].contains(conversations[index].status) {
                conversations[index].status = .waitingForInput
                conversations[index].updatedAt = Date()
                try await database.updateConversation(conversations[index])
            }
            selectedConversationID = conversations.first(where: {
                [.running, .queued, .waitingForInput, .failed].contains($0.status)
            })?.id
            if let selectedConversationID {
                messages = try await database.listRecentMessages(conversationID: selectedConversationID)
                adoptSettings(from: selectedConversation)
                await refreshSelectedContinuityStatus()
            }
            activityText = "Local database ready"
        } catch {
            alertText = "Local database could not start: \(error.localizedDescription)"
            activityText = "Database unavailable"
        }

        async let health = providerHealthService.checkAll()
        async let catalog = skillCatalog.scan()
        providerHealth = await health
        skills = await catalog
        await refreshObsidianVaults()
        await refreshLocalHistory(reason: "launch")
        refreshMetrics()
        activityText = providerHealth.allSatisfy(\.isAuthenticated)
            ? "Codex and Claude are authenticated"
            : "A provider needs authentication"
    }

    func refreshRuntime() async {
        async let health = providerHealthService.checkAll()
        async let catalog = skillCatalog.scan()
        providerHealth = await health
        skills = await catalog
        await refreshObsidianVaults()
        await refreshLocalHistory(reason: "manual")
        refreshMetrics()
    }

    func runHistoryRefreshLoop() async {
        while !Task.isCancelled {
            let delay: Duration = applicationIsActive ? .seconds(30) : .seconds(120)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refreshLocalHistory(
                reason: applicationIsActive ? "foreground timer" : "inactive timer"
            )
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        applicationIsActive = isActive
    }

    func refreshLocalHistory(reason: String) async {
        guard let store, !isHistoryRefreshing else { return }
        isHistoryRefreshing = true
        let previouslySelected = selectedExternalSession
        let result = await historyCoordinator.refresh()
        do {
            for observation in result.observations {
                try await store.upsertExternalSessions(observation.snapshot.sessions)
                if observation.snapshot.authoritative {
                    try await store.markExternalSessionsMissing(
                        provider: observation.provider,
                        surface: observation.surface,
                        seenProviderSessionIDs: observation.snapshot.sessions.map(\.providerSessionID),
                        at: result.finishedAt
                    )
                }
            }
            externalSessions = try await store.listExternalSessions(
                includeMissing: true,
                limit: SQLiteStore.maximumExternalSessionListCount
            )
            historyIndexedSessionCount = try await store.externalSessionCount(includeMissing: true)
            historyOmittedSessionCount = max(0, historyIndexedSessionCount - externalSessions.count)
            if conversations.isEmpty, selectedSidebar == .inbox, !externalSessions.isEmpty {
                selectedSidebar = .history
            }
            historyLastRefreshedAt = result.finishedAt
            historyLastScanDuration = max(
                0,
                result.finishedAt.timeIntervalSince(result.startedAt)
            )
            var actionableDiagnostics = result.diagnostics.filter {
                $0.severity != .info
            }
            if historyOmittedSessionCount > 0 {
                actionableDiagnostics.append(.init(
                    severity: .warning,
                    code: "history-ui-window-limit-reached",
                    sourcePath: nil,
                    detail: "\(historyOmittedSessionCount) older indexed sessions exceed the combined 10,000-session UI safety ceiling. Reduce provider history before continuing one of those older sessions."
                ))
            }
            historyDiagnosticCount = actionableDiagnostics.count
            historyDiagnostics = Array(actionableDiagnostics.prefix(12))
            if let previouslySelected,
               selectedExternalSessionID == previouslySelected.id,
               let refreshed = externalSessions.first(where: { $0.id == previouslySelected.id }),
               (refreshed.contentDigest != previouslySelected.contentDigest
                    || refreshed.sourceModifiedAt != previouslySelected.sourceModifiedAt
                    || refreshed.sourceByteCount != previouslySelected.sourceByteCount) {
                await selectExternalSession(refreshed.id)
            }
            await projectHistoryToObsidianIfConnected()
            activityText = "History mirrored · \(externalSessions.count) local sessions"
        } catch {
            alertText = "Local history index could not refresh: \(error.localizedDescription)"
            activityText = "History mirror needs attention"
        }
        isHistoryRefreshing = false
        _ = reason // Stable reason hook for future local diagnostics; never logs bodies.
    }

    func refreshObsidianVaults() async {
        let selectionGeneration = obsidianSelectionGeneration
        let registry = obsidianRegistry
        let discovered = await Task.detached(priority: .utility) {
            (try? registry.discoverVaults()) ?? []
        }.value
        obsidianVaults = discovered
        guard selectionGeneration == obsidianSelectionGeneration else { return }
        let stored = UserDefaults.standard.string(
            forKey: Self.connectedObsidianVaultDefaultsKey
        )
        if let stored, discovered.contains(where: { $0.rootURL.path == stored }) {
            connectedObsidianVaultPath = stored
            if obsidianProjectionStatus == "Not connected" {
                obsidianProjectionStatus = "Connected · metadata graph only"
            }
        } else {
            connectedObsidianVaultPath = nil
            if stored != nil {
                UserDefaults.standard.removeObject(
                    forKey: Self.connectedObsidianVaultDefaultsKey
                )
                obsidianProjectionStatus = "Disconnected · registered vault unavailable"
            }
        }
    }

    func connectObsidianVault(_ descriptor: ObsidianVaultDescriptor) async {
        guard obsidianVaults.contains(descriptor) else {
            alertText = "Refresh the local Obsidian vault registry before connecting."
            return
        }
        obsidianSelectionGeneration &+= 1
        connectedObsidianVaultPath = descriptor.rootURL.path
        await projectHistoryToObsidianIfConnected()
    }

    func disconnectObsidianVault() {
        obsidianSelectionGeneration &+= 1
        obsidianProjectionRequest &+= 1
        connectedObsidianVaultPath = nil
        obsidianProjectionStatus = "Disconnected · existing Command Center notes retained"
        obsidianProjectedFileCount = 0
        UserDefaults.standard.removeObject(forKey: Self.connectedObsidianVaultDefaultsKey)
    }

    private func projectHistoryToObsidianIfConnected() async {
        guard let descriptor = connectedObsidianVault else { return }
        let selectionGeneration = obsidianSelectionGeneration
        obsidianProjectionRequest &+= 1
        let projectionRequest = obsidianProjectionRequest
        let presentSessions = externalSessions
            .filter { $0.missingSince == nil }
            .prefix(ObsidianProjectionWriter.maximumSessions)
        let projections = presentSessions.map { session in
            let projectPath = session.workspacePath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            }
            let projectID = projectPath.map {
                LocalHistoryUtilities.stableSessionID(
                    provider: .codex,
                    sessionID: "command-center-project:\($0)"
                )
            }
            let parentID = session.parentProviderSessionID.map {
                LocalHistoryUtilities.stableSessionID(
                    provider: session.provider,
                    sessionID: $0
                )
            }
            return ObsidianSessionProjection(
                id: session.id,
                providerDisplay: session.provider.displayName,
                title: session.title,
                status: session.statusDisplayName,
                sourceUpdatedAt: session.lastSeenAt,
                projectID: projectID,
                projectName: projectPath.map {
                    URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent
                },
                parentID: parentID,
                resumable: session.canResume && session.missingSince == nil
            )
        }
        let vaultURL = descriptor.rootURL
        do {
            let result = try await obsidianProjectionCoordinator.write(
                vaultURL: vaultURL,
                sessions: projections
            )
            guard Self.projectionResultIsCurrent(
                expectedGeneration: selectionGeneration,
                expectedRequest: projectionRequest,
                expectedPath: vaultURL.path,
                currentGeneration: obsidianSelectionGeneration,
                currentRequest: obsidianProjectionRequest,
                currentPath: connectedObsidianVaultPath
            ) else { return }
            obsidianProjectedFileCount = result.writtenFiles + result.unchangedFiles
            UserDefaults.standard.set(
                vaultURL.path,
                forKey: Self.connectedObsidianVaultDefaultsKey
            )
            let missingSuffix = result.missingSessions > 0
                ? " · \(result.missingSessions) retained missing"
                : ""
            let truncatedSuffix = externalSessions.filter { $0.missingSince == nil }.count
                > ObsidianProjectionWriter.maximumSessions
                ? " · newest \(ObsidianProjectionWriter.maximumSessions) projected"
                : ""
            obsidianProjectionStatus = result.writtenFiles == 0
                ? "Current · \(result.unchangedFiles) metadata files unchanged\(missingSuffix)\(truncatedSuffix)"
                : "Updated · \(result.writtenFiles) metadata files written\(missingSuffix)\(truncatedSuffix)"
        } catch {
            guard Self.projectionResultIsCurrent(
                expectedGeneration: selectionGeneration,
                expectedRequest: projectionRequest,
                expectedPath: vaultURL.path,
                currentGeneration: obsidianSelectionGeneration,
                currentRequest: obsidianProjectionRequest,
                currentPath: connectedObsidianVaultPath
            ) else { return }
            obsidianSelectionGeneration &+= 1
            connectedObsidianVaultPath = nil
            UserDefaults.standard.removeObject(
                forKey: Self.connectedObsidianVaultDefaultsKey
            )
            obsidianProjectionStatus = "Projection stopped · \(error.localizedDescription)"
            alertText = "Obsidian projection could not update: \(error.localizedDescription)"
        }
    }

    static func projectionResultIsCurrent(
        expectedGeneration: Int,
        expectedRequest: Int,
        expectedPath: String,
        currentGeneration: Int,
        currentRequest: Int,
        currentPath: String?
    ) -> Bool {
        expectedGeneration == currentGeneration
            && expectedRequest == currentRequest
            && expectedPath == currentPath
    }

    func refreshMetrics() {
        memorySnapshot = try? metrics.snapshot()
        Task { await drainQueueIfPossible() }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Add a local project"
        panel.message = "Command Center stores only the folder path and app-owned conversation state."
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.addWorkspace(url) }
        }
    }

    func addWorkspace(_ url: URL, createTask: Bool = true) async {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard normalized.isFileURL,
              (try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let store else {
            alertText = "Choose an existing local folder."
            return
        }
        if let existing = workspaces.first(where: { $0.rootPath == normalized.path }) {
            selectedSidebar = .workspace(existing.id)
            return
        }
        let workspace = Workspace(name: normalized.lastPathComponent, rootPath: normalized.path)
        do {
            try await store.upsertWorkspace(workspace)
            workspaces.append(workspace)
            workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedSidebar = .workspace(workspace.id)
            if createTask { await createConversation() }
        } catch {
            alertText = "Project could not be added: \(error.localizedDescription)"
        }
    }

    func approveSelectedExternalWorkspace() {
        guard let session = selectedExternalSession,
              let workspacePath = session.workspacePath else {
            alertText = "This provider session has no usable local project folder."
            return
        }
        let expected = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard expected.path != "/",
              (try? expected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            alertText = "The provider’s project folder no longer exists."
            return
        }

        let sessionID = session.id
        let panel = NSOpenPanel()
        panel.title = "Approve project for \(session.provider.displayName)"
        panel.message = "Choose this exact folder to allow subscription-CLI continuation:\n\(expected.path)"
        panel.prompt = "Approve Project"
        panel.directoryURL = expected.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let selected = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                let approved = selected.resolvingSymlinksInPath().standardizedFileURL
                guard approved.path == expected.path else {
                    self.alertText = "Choose the exact provider project folder shown in the approval prompt."
                    return
                }
                await self.addWorkspace(approved, createTask: false)
                self.selectedSidebar = .history
                self.selectedExternalSessionID = sessionID
                await self.continueSelectedExternalSession()
            }
        }
    }

    func continueSelectedExternalSession() async {
        guard let selectedSession = selectedExternalSession, let store else { return }
        guard preparingExternalSessionIDs.insert(selectedSession.id).inserted else { return }
        defer { preparingExternalSessionIDs.remove(selectedSession.id) }
        guard UUID(uuidString: selectedSession.providerSessionID) != nil else {
            alertText = "This provider task has an unsupported session identifier and cannot be resumed safely."
            return
        }
        guard selectedSession.missingSince == nil, selectedSession.canResume else {
            alertText = "This provider source is not currently resumable. Refresh history and verify the provider session still exists."
            return
        }
        activityText = "Revalidating \(selectedSession.provider.displayName) source…"
        let validation = await historyCoordinator.revalidate(session: selectedSession)
        guard selectedExternalSessionID == selectedSession.id else { return }
        guard validation.permitsResume, let refreshedSession = validation.refreshedSession else {
            if validation.state == .unavailable {
                do {
                    try await store.markExternalSessionMissing(
                        id: selectedSession.id,
                        at: validation.checkedAt
                    )
                    externalSessions = try await store.listExternalSessions(
                        includeMissing: true,
                        limit: SQLiteStore.maximumExternalSessionListCount
                    )
                } catch {
                    alertText = "The missing provider task could not be checkpointed: \(error.localizedDescription)"
                    return
                }
            }
            let detail = validation.diagnostic?.detail
                ?? "The provider source could not be confirmed safely."
            alertText = validation.state == .unavailable
                ? "This provider task is no longer present locally and was marked missing."
                : "\(detail) No provider process was started; refresh and retry."
            activityText = "Continuation blocked safely"
            return
        }
        do {
            try await store.upsertExternalSessions([refreshedSession])
        } catch {
            alertText = "The revalidated provider metadata could not be checkpointed: \(error.localizedDescription)"
            return
        }
        let session = (try? await store.externalSession(
            provider: refreshedSession.provider,
            surface: refreshedSession.surface,
            providerSessionID: refreshedSession.providerSessionID
        )) ?? refreshedSession
        guard let workspace = approvedWorkspace(for: session) else {
            alertText = "Approve this task’s exact project folder before continuing it."
            return
        }

        if let linkedID = try? await store.conversationID(forExternalSessionID: session.id) {
            guard selectedExternalSessionID == session.id else { return }
            let existing: Conversation?
            if let loaded = conversations.first(where: { $0.id == linkedID }) {
                existing = loaded
            } else {
                existing = try? await store.conversation(id: linkedID)
            }
            guard selectedExternalSessionID == session.id else { return }
            if let existing,
               Self.conversationIdentityMatches(existing, session: session, workspace: workspace) {
                if !conversations.contains(where: { $0.id == existing.id }) {
                    conversations.insert(existing, at: 0)
                }
                selectedConversationID = existing.id
                selectedSidebar = .workspace(existing.workspaceID)
                await selectConversation(existing.id)
                return
            }

            // Preserve the old app task, but release its stale external identity
            // before creating a correctly typed continuation task.
            do {
                try await store.unlinkConversation(conversationID: linkedID)
            } catch {
                alertText = "The stale provider-task link could not be released: \(error.localizedDescription)"
                return
            }
            guard selectedExternalSessionID == session.id else { return }
        }

        let now = Date()
        let conversation = Conversation(
            workspaceID: workspace.id,
            title: session.title,
            provider: session.provider,
            workflow: .interactive,
            permissionMode: .readOnly,
            status: .idle,
            providerSessionID: session.providerSessionID,
            skillIDs: [],
            createdAt: now,
            updatedAt: max(session.lastSeenAt, now)
        )
        do {
            try await store.insertConversation(conversation)
            guard selectedExternalSessionID == session.id else {
                try? await store.deleteConversation(id: conversation.id)
                return
            }
            do {
                try await store.linkConversation(
                    conversationID: conversation.id,
                    externalSessionID: session.id
                )
            } catch {
                try? await store.deleteConversation(id: conversation.id)
                throw error
            }
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            selectedSidebar = .workspace(workspace.id)
            messages = []
            selectedProvider = session.provider.runtimeProvider
            selectedWorkflow = .direct
            selectedPermission = .readOnly
            selectedSkills = []
            _ = await appendMessage(
                .system,
                content: "Existing \(session.surface.displayName) task linked locally. Provider history remains authoritative; only new turns sent here are checkpointed in Command Center.",
                conversationID: conversation.id
            )
        } catch {
            alertText = "Provider task could not be linked: \(error.localizedDescription)"
        }
    }

    func createConversation() async {
        guard let store else { return }
        guard let workspace = selectedWorkspace ?? workspaces.first else {
            chooseWorkspace()
            return
        }
        let now = Date()
        let conversation = Conversation(
            workspaceID: workspace.id,
            title: "New \(selectedProvider.displayName) task",
            provider: selectedProvider.providerKind,
            workflow: selectedWorkflow.workflowKind,
            permissionMode: selectedPermission.permissionMode,
            status: .idle,
            skillIDs: Array(selectedSkills),
            createdAt: now,
            updatedAt: now
        )
        do {
            try await store.insertConversation(conversation)
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            selectedSidebar = .workspace(workspace.id)
            messages = []
        } catch {
            alertText = "Task could not be created: \(error.localizedDescription)"
        }
    }

    /// Builds a non-mutating handoff preview for an explicit confirmation.
    /// A fresh prepare is also performed at confirmation so a changed capsule
    /// or Git boundary cannot be accepted from a stale sheet.
    func prepareContinuityPreview(in provider: RuntimeProvider, reviewOnly: Bool = false) async {
        continuityPreview = nil
        guard let source = selectedConversation,
              let workspace = workspaces.first(where: { $0.id == source.workspaceID }) else { return }
        guard source.provider.runtimeProvider != provider || reviewOnly else {
            alertText = "Choose the other provider for a continuity handoff."
            return
        }
        guard isSourceReadyForContinuity(source.id) else {
            alertText = "Finish or stop the source task before creating a continuity handoff."
            return
        }
        do {
            let sourceLabel = source.provider.displayName
            let destinationLabel = provider.displayName
            let preflight = try await Task.detached(priority: .userInitiated) {
                try ContinuityHandoffPreflight().prepare(
                    workspaceURL: URL(fileURLWithPath: workspace.rootPath, isDirectory: true),
                    sourceLabel: sourceLabel,
                    destinationLabel: destinationLabel
                )
            }.value
            guard ContinuityPreviewConfirmationGate.canPresentPreparedPreview(
                sourceConversationID: source.id,
                selectedConversationID: selectedConversation?.id,
                sourceIsReady: isSourceReadyForContinuity(source.id)
            ) else {
                return
            }
            continuityPreview = ContinuityHandoffPreview(
                sourceConversationID: source.id,
                destination: provider,
                reviewOnly: reviewOnly,
                sourceTitle: source.title,
                boundary: preflight.boundary
            )
        } catch {
            alertText = "Continuity preflight blocked: \(error.localizedDescription)"
        }
    }

    func dismissContinuityPreview() {
        continuityPreview = nil
    }

    func confirmContinuityPreview() async {
        guard ContinuityPreviewConfirmationGate.canBegin(
            preview: continuityPreview,
            isInFlight: isContinuityConfirmationInFlight,
            consumedIDs: consumedContinuityPreviewIDs
        ), let preview = continuityPreview else {
            alertText = continuityPreview?.recoveryError ?? "Prepare a valid continuity preflight before confirming."
            return
        }
        consumedContinuityPreviewIDs.insert(preview.id)
        isContinuityConfirmationInFlight = true
        defer { isContinuityConfirmationInFlight = false }
        let created = await continueSelected(
            in: preview.destination,
            reviewOnly: preview.reviewOnly,
            expectedPreview: preview
        )
        if created {
            continuityPreview = nil
        } else if continuityPreview?.id == preview.id {
            continuityPreview = ContinuityHandoffPreview(
                id: preview.id,
                sourceConversationID: preview.sourceConversationID,
                destination: preview.destination,
                reviewOnly: preview.reviewOnly,
                sourceTitle: preview.sourceTitle,
                boundary: preview.boundary,
                recoveryError: alertText ?? "The preview could not be confirmed. Prepare a new preview."
            )
        }
    }

    /// Creates an app-owned successor or read-only reviewer task. Provider
    /// identities remain immutable: this always creates a new local task and
    /// records the relationship in the continuity ledger.
    @discardableResult
    func continueSelected(
        in provider: RuntimeProvider,
        reviewOnly: Bool = false,
        expectedPreview: ContinuityHandoffPreview? = nil
    ) async -> Bool {
        guard let source = selectedConversation,
              let workspace = workspaces.first(where: { $0.id == source.workspaceID }),
              let store else { return false }
        guard source.provider.runtimeProvider != provider || reviewOnly else {
            alertText = "Choose the other provider for a continuity handoff."
            return false
        }
        guard isSourceReadyForContinuity(source.id) else {
            alertText = "Finish or stop the source task before creating a continuity handoff."
            return false
        }
        if let expectedPreview,
           (expectedPreview.sourceConversationID != source.id
                || expectedPreview.destination != provider
                || expectedPreview.reviewOnly != reviewOnly) {
            alertText = "The continuity preview no longer matches this task. Prepare a new preview."
            return false
        }
        let now = Date()
        do {
            let workspaceURL = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            let sourceLabel = source.provider.displayName
            let destinationLabel = provider.displayName
            let preflight = try await Task.detached(priority: .userInitiated) {
                try ContinuityHandoffPreflight().prepare(
                    workspaceURL: workspaceURL,
                    sourceLabel: sourceLabel,
                    destinationLabel: destinationLabel
                )
            }.value
            if let expectedPreview, preflight.boundary != expectedPreview.boundary {
                throw AppModelError.continuityPreviewStale
            }
            if let expectedPreview {
                guard ContinuityPreviewConfirmationGate.remainsValid(
                    preview: expectedPreview,
                    selectedConversationID: selectedConversation?.id,
                    currentPreviewID: continuityPreview?.id,
                    isInFlight: isContinuityConfirmationInFlight,
                    consumedIDs: consumedContinuityPreviewIDs,
                    sourceIsReady: isSourceReadyForContinuity(source.id),
                    provider: provider,
                    reviewOnly: reviewOnly
                ) else {
                    throw AppModelError.continuityPreviewStale
                }
            }
            let boundarySummary = try preflight.boundary.encodedSummary()
            let existingProject = try await store.listContinuityProjects(workspaceID: workspace.id).first
            let project = try existingProject ?? ContinuityProject(
                workspaceID: workspace.id,
                name: workspace.name,
                summary: "Bridge-owned project continuity ledger"
            )
            if try await store.continuityProject(id: project.id) == nil {
                try await store.upsertContinuityProject(project)
            }
            let sourceLink = try ContinuitySessionLink(
                projectID: project.id,
                conversationID: source.id,
                kind: .primary,
                createdAt: now,
                updatedAt: now
            )
            try await store.upsertContinuitySessionLink(sourceLink)
            let destination = Conversation(
                workspaceID: workspace.id,
                title: reviewOnly ? "Review · \(source.title)" : "Continue · \(source.title)",
                provider: provider.providerKind,
                workflow: reviewOnly ? .backgroundReview : .interactive,
                permissionMode: .readOnly,
                status: .idle,
                skillIDs: reviewOnly ? ["engineering:code-review"] : source.skillIDs,
                createdAt: now,
                updatedAt: now
            )
            try await store.insertConversation(destination)
            let destinationLink = try ContinuitySessionLink(
                projectID: project.id,
                conversationID: destination.id,
                kind: .successor,
                createdAt: now,
                updatedAt: now
            )
            try await store.upsertContinuitySessionLink(destinationLink)
            let handoff = try ContinuityHandoff(
                projectID: project.id,
                sourceSessionLinkID: sourceLink.id,
                destinationSessionLinkID: destinationLink.id,
                title: reviewOnly ? "Read-only review of \(source.title)" : "Compact continuation of \(source.title)",
                summary: boundarySummary,
                state: .ready,
                createdAt: now,
                updatedAt: now
            )
            try await store.upsertContinuityHandoff(handoff)
            try await store.insertContinuityEvent(try ContinuityEvent(
                projectID: project.id,
                sessionLinkID: destinationLink.id,
                handoffID: handoff.id,
                kind: .handoffCreated,
                detail: "Validated compact handoff prepared at capsule \(preflight.boundary.capsuleDigest.prefix(12)).",
                occurredAt: now
            ))
            conversations.insert(destination, at: 0)
            selectedConversationID = destination.id
            selectedSidebar = .workspace(workspace.id)
            messages = []
            _ = await appendMessage(
                .system,
                content: reviewOnly
                    ? "Read-only reviewer task created for \(provider.displayName) at capsule \(preflight.boundary.capsuleDigest.prefix(12)). Findings are advisory and cannot write."
                    : "Compact continuity handoff created for \(provider.displayName) at capsule \(preflight.boundary.capsuleDigest.prefix(12)). Provider sessions remain separate; the repository boundary will be revalidated before the first turn.",
                conversationID: destination.id
            )
            selectedProvider = provider
            selectedWorkflow = .direct
            selectedPermission = .readOnly
            selectedSkills = Set(destination.skillIDs)
            await refreshSelectedContinuityStatus()
            return true
        } catch {
            alertText = "Continuity handoff could not be created: \(error.localizedDescription)"
            return false
        }
    }

    private func isSourceReadyForContinuity(_ conversationID: UUID) -> Bool {
        runningProcesses[conversationID] == nil
            && reservedDispatches[conversationID] == nil
            && !preparingConversationIDs.contains(conversationID)
            && !queuedDispatches.contains(where: { $0.conversationID == conversationID })
            && !queueReservations.values.contains(where: { $0.conversationID == conversationID })
    }

    func selectConversation(_ id: UUID?) async {
        selectedConversationID = id
        guard let id, let store else {
            messages = []
            selectedContinuityStatus = nil
            continuityStatusWarning = nil
            return
        }
        do {
            let loaded = try await store.listRecentMessages(conversationID: id)
            guard selectedConversationID == id else { return }
            messages = loaded
            adoptSettings(from: conversations.first(where: { $0.id == id }))
            await refreshSelectedContinuityStatus()
        } catch {
            alertText = "Conversation could not be loaded: \(error.localizedDescription)"
        }
    }

    /// Loads concise bridge-owned continuity metadata for the currently
    /// selected task. Provider sessions and transcript locations remain local
    /// transport details and are deliberately not represented in this view.
    func refreshSelectedContinuityStatus() async {
        guard let conversation = selectedConversation, let store else {
            selectedContinuityStatus = nil
            continuityStatusWarning = nil
            return
        }
        do {
            var candidates: [SelectedContinuityStatus] = []
            for project in try await store.listContinuityProjects(workspaceID: conversation.workspaceID) {
                let links = try await store.listContinuitySessionLinks(projectID: project.id)
                let conversationLinks = links.filter { $0.conversationID == conversation.id }
                guard !conversationLinks.isEmpty else { continue }
                let handoffs = try await store.listContinuityHandoffs(projectID: project.id)
                for link in conversationLinks {
                    for handoff in handoffs where handoff.sourceSessionLinkID == link.id || handoff.destinationSessionLinkID == link.id {
                        let boundary = try ContinuityHandoffBoundary.decode(summary: handoff.summary)
                        let role: SelectedContinuityStatus.Role = handoff.sourceSessionLinkID == link.id ? .source : .destination
                        let requiresReconciliation = try await store.continuityWorkstreamRequiresReconciliation(
                            projectID: project.id,
                            workstreamID: handoff.id
                        )
                        let hasActiveWriter = try await store.hasActiveContinuityWorkstreamWriterLease(
                            projectID: project.id,
                            workstreamID: handoff.id
                        )
                        candidates.append(SelectedContinuityStatus(
                            projectName: project.name,
                            handoffTitle: handoff.title,
                            handoffState: handoff.state,
                            role: role,
                            capsuleDigest: boundary.capsuleDigest,
                            revision: boundary.version,
                            commit: boundary.commit,
                            statusDigest: boundary.statusDigest,
                            changedPaths: Array(boundary.changedPaths.prefix(12)),
                            isActiveWriter: hasActiveWriter,
                            isReadOnlyReviewer: conversation.workflow == .backgroundReview
                                && conversation.permissionMode == .readOnly,
                            requiresReconciliation: requiresReconciliation
                        ))
                    }
                }
            }
            guard selectedConversationID == conversation.id else { return }
            switch ContinuityLineageSelection.resolve(candidates) {
            case .none:
                selectedContinuityStatus = nil
                continuityStatusWarning = nil
            case let .unique(status):
                selectedContinuityStatus = status
                continuityStatusWarning = nil
            case .ambiguous:
                selectedContinuityStatus = nil
                continuityStatusWarning = "Continuity lineage is ambiguous. Audit and reconcile the linked handoffs before continuing."
            }
        } catch {
            selectedContinuityStatus = nil
            continuityStatusWarning = "Continuity status requires reconciliation: \(error.localizedDescription)"
        }
    }

    func selectExternalSession(_ id: UUID?) async {
        externalTranscriptLoadGeneration &+= 1
        let loadGeneration = externalTranscriptLoadGeneration
        selectedExternalSessionID = id
        externalTranscript = []
        externalTranscriptWasTruncated = false
        externalTranscriptBytesRead = 0
        guard let id,
              let session = externalSessions.first(where: { $0.id == id }),
              session.canReadTranscript else {
            isExternalTranscriptLoading = false
            return
        }
        isExternalTranscriptLoading = true
        let snapshot = await transcriptReader.read(
            session: session,
            limits: LocalTranscriptReadLimits(messageCount: 50, readBytes: 2 * 1_048_576)
        )
        guard selectedExternalSessionID == id,
              externalTranscriptLoadGeneration == loadGeneration else { return }
        externalTranscript = snapshot.rows
        externalTranscriptWasTruncated = snapshot.wasTruncated
        externalTranscriptBytesRead = snapshot.bytesRead
        isExternalTranscriptLoading = false
    }

    private func prepareContinuityDispatch(
        conversation: Conversation,
        userPrompt: String,
        permission: RuntimePermission
    ) async throws -> PreparedContinuityDispatch {
        guard let store,
              let workspace = workspaces.first(where: { $0.id == conversation.workspaceID }) else {
            return PreparedContinuityDispatch(prompt: userPrompt, handoffID: nil)
        }

        var readyHandoffs: [ContinuityHandoff] = []
        for project in try await store.listContinuityProjects(workspaceID: workspace.id) {
            let destinationIDs = Set(try await store.listContinuitySessionLinks(projectID: project.id)
                .filter { $0.conversationID == conversation.id }
                .map(\.id))
            guard !destinationIDs.isEmpty else { continue }
            readyHandoffs.append(contentsOf: try await store.listContinuityHandoffs(projectID: project.id)
                .filter { $0.destinationSessionLinkID.map(destinationIDs.contains) == true && $0.state == .ready })
        }
        guard readyHandoffs.count <= 1 else { throw AppModelError.continuityWriterAmbiguous }
        guard let handoff = readyHandoffs.first else {
            return PreparedContinuityDispatch(prompt: userPrompt, handoffID: nil)
        }
        guard permission == .readOnly else {
            throw AppModelError.continuityFirstTurnMustBeReadOnly
        }

        let boundary = try ContinuityHandoffBoundary.decode(summary: handoff.summary)
        let workspaceURL = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        let capsulePrompt = try await Task.detached(priority: .userInitiated) {
            try ContinuityHandoffPreflight().revalidate(
                boundary: boundary,
                workspaceURL: workspaceURL
            )
        }.value
        let combined = """
        \(capsulePrompt)
        BEGIN CURRENT USER DIRECTION
        \(userPrompt)
        END CURRENT USER DIRECTION
        """
        guard combined.utf8.count <= Self.maximumContinuityPromptBytes else {
            throw AppModelError.continuityPromptTooLarge
        }
        return PreparedContinuityDispatch(prompt: combined, handoffID: handoff.id)
    }

    private func acknowledgeContinuityHandoff(
        _ handoffID: UUID,
        conversationID: UUID
    ) async throws {
        guard let store, var handoff = try await store.continuityHandoff(id: handoffID) else {
            throw AppModelError.persistenceRequired
        }
        guard handoff.state == .ready else { return }
        let now = Date()
        handoff.state = .acknowledged
        handoff.updatedAt = now
        try await store.upsertContinuityHandoff(handoff)
        try await store.insertContinuityEvent(try ContinuityEvent(
            projectID: handoff.projectID,
            handoffID: handoff.id,
            kind: .handoffStateChanged,
            detail: "Destination task acknowledged the validated compact handoff.",
            occurredAt: now
        ))
        _ = await appendMessage(
            .system,
            content: "Validated compact handoff supplied once; later turns use only new user direction and provider-native context.",
            conversationID: conversationID
        )
    }

    /// Returns the one continuity handoff that owns this destination task.
    /// Multiple candidates are a ledger conflict, not an invitation to choose
    /// whichever happened to sort first.
    private func continuityHandoffForWriterLease(
        conversationID: UUID,
        workspaceID: UUID,
        preferredHandoffID: UUID?
    ) async throws -> ContinuityWriterHandoff? {
        guard let store else { return nil }
        if let preferredHandoffID {
            guard let handoff = try await store.continuityHandoff(id: preferredHandoffID) else {
                throw AppModelError.continuityWriterAmbiguous
            }
            let projects = try await store.listContinuityProjects(workspaceID: workspaceID)
            guard projects.contains(where: { $0.id == handoff.projectID }),
                  let destinationLinkID = handoff.destinationSessionLinkID,
                  let destinationLink = try await store.continuitySessionLink(id: destinationLinkID),
                  destinationLink.conversationID == conversationID else {
                throw AppModelError.continuityWriterAmbiguous
            }
            return ContinuityWriterHandoff(handoff: handoff, role: .destination)
        }

        var candidates: [ContinuityWriterHandoff] = []
        for project in try await store.listContinuityProjects(workspaceID: workspaceID) {
            let destinationLinks = try await store.listContinuitySessionLinks(projectID: project.id)
                .filter { $0.conversationID == conversationID }
            guard !destinationLinks.isEmpty else { continue }
            let destinationIDs = Set(destinationLinks.map(\.id))
            for handoff in try await store.listContinuityHandoffs(projectID: project.id) {
                guard handoff.state == .ready || handoff.state == .acknowledged else { continue }
                if destinationIDs.contains(handoff.sourceSessionLinkID) {
                    candidates.append(ContinuityWriterHandoff(handoff: handoff, role: .source))
                }
                if handoff.destinationSessionLinkID.map(destinationIDs.contains) == true {
                    candidates.append(ContinuityWriterHandoff(handoff: handoff, role: .destination))
                }
            }
        }
        guard candidates.count <= 1 else { throw AppModelError.continuityWriterAmbiguous }
        return candidates.first
    }

    private func renewContinuityWriterLease(for conversationID: UUID) async {
        guard let store, let lease = continuityWriterLeases[conversationID] else { return }
        do {
            guard let renewed = try await ContinuityWriterLeaseGate.renew(store: store, lease: lease) else {
                await requireContinuityReconciliation(
                    for: conversationID,
                    lease: lease,
                    reason: "Writer lease renewal lost ownership while the provider process remained live."
                )
                return
            }
            continuityWriterLeases[conversationID] = renewed
        } catch {
            await requireContinuityReconciliation(
                for: conversationID,
                lease: lease,
                reason: "Writer lease renewal could not be verified while the provider process remained live."
            )
        }
    }

    private func requireContinuityReconciliation(
        for conversationID: UUID,
        lease: ContinuityWorkstreamWriterLease,
        reason: String
    ) async {
        continuityWriterHeartbeatTasks.removeValue(forKey: conversationID)?.cancel()
        guard let store else {
            alertText = "Continuity writer ownership could not be persisted for reconciliation."
            return
        }
        do {
            guard try await ContinuityWriterLeaseGate.requireReconciliation(
                store: store,
                lease: lease,
                reason: reason
            ) else {
                throw AppModelError.continuityWriterLeaseLost
            }
            try await store.insertContinuityEvent(try ContinuityEvent(
                projectID: lease.projectID,
                handoffID: lease.workstreamID,
                kind: .note,
                detail: "Writer ownership requires explicit reconciliation before another writable launch."
            ))
            alertText = "Continuity writer ownership requires reconciliation before another writable launch."
        } catch {
            alertText = "Continuity writer ownership could not be persisted for reconciliation: \(error.localizedDescription)"
        }
    }

    private func startContinuityWriterHeartbeat(for conversationID: UUID) {
        continuityWriterHeartbeatTasks[conversationID]?.cancel()
        continuityWriterHeartbeatTasks[conversationID] = ContinuityWriterLeaseHeartbeat.start(
            intervalNanoseconds: Self.continuityWriterHeartbeatNanoseconds
        ) { [weak self] in
            await self?.renewContinuityWriterLease(for: conversationID)
        }
    }

    private func releaseContinuityWriterLease(
        for conversationID: UUID,
        succeeded: Bool
    ) async {
        continuityWriterHeartbeatTasks.removeValue(forKey: conversationID)?.cancel()
        guard let store, let lease = continuityWriterLeases.removeValue(forKey: conversationID) else {
            return
        }
        do {
            guard try await ContinuityWriterLeaseGate.release(
                store: store,
                lease: lease
            ) else {
                await requireContinuityReconciliation(
                    for: conversationID,
                    lease: lease,
                    reason: "Provider process exited without a verified writer lease release."
                )
                return
            }
            try await store.insertContinuityEvent(try ContinuityEvent(
                projectID: lease.projectID,
                handoffID: lease.workstreamID,
                kind: .note,
                detail: succeeded
                    ? "Exclusive writer lease released after provider completion."
                    : "Exclusive writer lease released after provider failure or cancellation."
            ))
            await refreshSelectedContinuityStatus()
        } catch {
            await requireContinuityReconciliation(
                for: conversationID,
                lease: lease,
                reason: "Provider process exited and writer lease release could not be verified."
            )
        }
    }

    func dispatchComposer() async {
        guard selectedSidebar.supportsConversationDispatch else {
            alertText = "Open an app-owned task before running a prompt. Local history, Skills, and Runtime are non-dispatch surfaces."
            return
        }
        let input = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = TerminalTextSanitizer.sanitize(
            input,
            limits: TextSanitizationLimits(
                maximumLineBytes: 64 * 1_024,
                maximumMessageBytes: Self.maximumPromptBytes
            )
        )
        let prompt = sanitized.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let dispatchProvider = selectedProvider
        let dispatchWorkflow = selectedWorkflow
        let dispatchPermission = selectedPermission
        let dispatchSkills = Array(selectedSkills).sorted()
        let intendedWorkspaceID = selectedWorkspace?.id
        guard !sanitized.messageWasTruncated, sanitized.truncatedLineCount == 0 else {
            composerText = prompt
            alertText = "The prompt was reduced to the 256 KiB local safety limit. Review the shortened text, then send it again."
            return
        }
        if selectedConversation == nil {
            await createConversation()
        }
        guard let conversation = selectedConversation,
              intendedWorkspaceID == nil || conversation.workspaceID == intendedWorkspaceID else {
            alertText = "The project changed while the new task was being created. Select the intended project and retry."
            return
        }
        let targetConversationID = conversation.id
        guard runningProcesses[conversation.id] == nil,
              reservedDispatches[conversation.id] == nil,
              !preparingConversationIDs.contains(conversation.id),
              !queuedDispatches.contains(where: { $0.conversationID == conversation.id }),
              !queueReservations.values.contains(where: { $0.conversationID == conversation.id }) else {
            alertText = "This task already has active or queued work. Stop it or wait for completion before sending another turn."
            return
        }
        preparingConversationIDs.insert(conversation.id)
        defer { preparingConversationIDs.remove(conversation.id) }
        let continuityDispatch: PreparedContinuityDispatch
        do {
            continuityDispatch = try await prepareContinuityDispatch(
                conversation: conversation,
                userPrompt: prompt,
                permission: dispatchPermission
            )
        } catch {
            alertText = error.localizedDescription
            activityText = "Continuity preflight blocked"
            return
        }
        guard await appendMessage(.user, content: prompt, conversationID: conversation.id) != nil else {
            activityText = "Prompt checkpoint failed"
            return
        }
        guard conversations.contains(where: { $0.id == targetConversationID }),
              runningProcesses[targetConversationID] == nil,
              reservedDispatches[targetConversationID] == nil,
              !queuedDispatches.contains(where: { $0.conversationID == targetConversationID }),
              !queueReservations.values.contains(where: { $0.conversationID == targetConversationID }) else {
            alertText = "The task changed while its local checkpoint was saving. Your prompt is preserved; review the task and retry."
            return
        }
        if selectedConversationID == targetConversationID,
           composerText.trimmingCharacters(in: .whitespacesAndNewlines) == input {
            composerText = ""
        }
        let pending = PendingDispatch(
            id: UUID(),
            conversationID: targetConversationID,
            prompt: continuityDispatch.prompt,
            provider: dispatchProvider,
            workflow: dispatchWorkflow,
            classification: dispatchWorkflow.workflowKind,
            permission: dispatchPermission,
            skills: dispatchSkills,
            enqueuedAt: Date(),
            promptCheckpointed: true,
            continuityHandoffID: continuityDispatch.handoffID
        )
        if dispatchWorkflow == .pairedReview {
            pairedReviewPrimaries.insert(targetConversationID)
        }
        await admitOrQueue(pending)
    }

    func cancelSelected() {
        guard selectedSidebar.supportsConversationDispatch,
              let id = selectedConversationID,
              let process = runningProcesses[id],
              process.isRunning else { return }
        cancellationRequestedIDs.insert(id)
        process.cancel()
        activityText = "Cancellation requested"
    }

    func shutdown() {
        Task { await historyCoordinator.cancel() }
        for heartbeat in continuityWriterHeartbeatTasks.values {
            heartbeat.cancel()
        }
        continuityWriterHeartbeatTasks.removeAll()
        for (conversationID, process) in runningProcesses {
            cancellationRequestedIDs.insert(conversationID)
            process.cancel()
        }
    }

    func clearAlert() { alertText = nil }

    private func admitOrQueue(_ pending: PendingDispatch) async {
        guard await linkedIdentityAllows(pending, revalidateSource: false) else {
            pairedReviewPrimaries.remove(pending.conversationID)
            activityText = "Linked provider identity protected"
            return
        }
        refreshMetricsWithoutDrain()
        let memory = memorySnapshot ?? SystemMemorySnapshot(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            availableBytes: ProcessInfo.processInfo.physicalMemory,
            appResidentBytes: 0
        )
        let queuedJob = QueuedJob(
            id: pending.id,
            conversationID: pending.conversationID,
            provider: pending.provider.providerKind,
            workflow: pending.classification,
            enqueuedAt: pending.enqueuedAt
        )
        let plan = governor.makeAdmissionPlan(
            queuedJobs: [queuedJob],
            activeJobs: activeJobs(),
            memory: memory,
            mode: resourceMode
        )
        if plan.admitted.isEmpty {
            let allQueued = queuedDispatches + Array(queueReservations.values)
            let retainedPromptBytes = allQueued.reduce(0) { $0 + $1.prompt.utf8.count }
            guard allQueued.count < Self.maximumQueuedDispatches,
                  pending.prompt.utf8.count <= Self.maximumQueuedPromptBytes - retainedPromptBytes else {
                pairedReviewPrimaries.remove(pending.conversationID)
                await setStatus(.waitingForInput, for: pending.conversationID)
                _ = await appendMessage(
                    .tool,
                    content: "Not queued: the local queue reached its bounded memory limit. Retry after active work completes.",
                    conversationID: pending.conversationID
                )
                activityText = "Queue memory limit reached"
                alertText = "The task was checkpointed but not queued because the local queue is full. Retry after active work completes."
                return
            }
            var checkpointed = pending
            queueReservations[checkpointed.id] = checkpointed
            if !checkpointed.promptCheckpointed {
                guard await appendMessage(
                    .user,
                    content: checkpointed.prompt,
                    conversationID: checkpointed.conversationID
                ) != nil else {
                    queueReservations.removeValue(forKey: checkpointed.id)
                    pairedReviewPrimaries.remove(checkpointed.conversationID)
                    activityText = "Queue checkpoint failed"
                    return
                }
                checkpointed.promptCheckpointed = true
                queueReservations[checkpointed.id] = checkpointed
            }
            let previousProvider = conversations.first(where: {
                $0.id == checkpointed.conversationID
            })?.provider
            guard await updateConversation(checkpointed.conversationID, mutate: {
                if previousProvider != checkpointed.provider.providerKind {
                    $0.providerSessionID = nil
                }
                $0.provider = checkpointed.provider.providerKind
                $0.workflow = checkpointed.classification
                $0.permissionMode = checkpointed.permission.permissionMode
                $0.skillIDs = checkpointed.skills
                $0.status = .queued
            }) else {
                queueReservations.removeValue(forKey: checkpointed.id)
                pairedReviewPrimaries.remove(checkpointed.conversationID)
                return
            }
            queueReservations.removeValue(forKey: checkpointed.id)
            queuedDispatches.append(checkpointed)
            activityText = plan.deferred.first?.reason == .insufficientHeadroom
                ? "Queued until memory headroom recovers"
                : "Queued behind active work"
            return
        }
        reservedDispatches[pending.conversationID] = pending
        await start(pending)
    }

    private func start(_ pending: PendingDispatch) async {
        guard await linkedIdentityAllows(pending, revalidateSource: true) else {
            reservedDispatches.removeValue(forKey: pending.conversationID)
            pairedReviewPrimaries.remove(pending.conversationID)
            await setStatus(.waitingForInput, for: pending.conversationID)
            activityText = "Linked provider source needs attention"
            return
        }
        guard let conversation = conversations.first(where: { $0.id == pending.conversationID }),
              let workspace = workspaces.first(where: { $0.id == conversation.workspaceID }) else {
            reservedDispatches.removeValue(forKey: pending.conversationID)
            pairedReviewPrimaries.remove(pending.conversationID)
            return
        }
        var writerLease: ContinuityWorkstreamWriterLease?
        do {
            guard !(conversation.workflow == .backgroundReview && pending.permission != .readOnly) else {
                throw AppModelError.continuityReviewerMustRemainReadOnly
            }
            if pending.permission == .workspaceWrite,
               let writerHandoff = try await continuityHandoffForWriterLease(
                   conversationID: conversation.id,
                   workspaceID: workspace.id,
                   preferredHandoffID: pending.continuityHandoffID
               ) {
                guard let store else { throw AppModelError.persistenceRequired }
                let handoff = writerHandoff.handoff
                if writerHandoff.role == .source {
                    _ = try await store.requireContinuityWorkstreamReconciliation(
                        projectID: handoff.projectID,
                        workstreamID: handoff.id,
                        reason: "Source task attempted a writable turn after its handoff boundary."
                    )
                    try await store.insertContinuityEvent(try ContinuityEvent(
                        projectID: handoff.projectID,
                        handoffID: handoff.id,
                        kind: .note,
                        detail: "Source task attempted a writable turn after its handoff boundary. Reconciliation is required."
                    ))
                    await refreshSelectedContinuityStatus()
                    throw AppModelError.continuitySourceDivergent
                }
                guard let acquired = try await ContinuityWriterLeaseGate.acquireIfWritable(
                    store: store,
                    projectID: handoff.projectID,
                    handoffID: handoff.id,
                    permission: pending.permission,
                    ownerID: pending.id
                ) else {
                    throw AppModelError.continuityWriterConflict
                }
                writerLease = acquired
                try await store.insertContinuityEvent(try ContinuityEvent(
                    projectID: handoff.projectID,
                    handoffID: handoff.id,
                    kind: .note,
                    detail: "Exclusive writer lease acquired for a continuity workstream."
                ))
            }
            let plan = try ProviderCommandBuilder.build(
                provider: pending.provider,
                workspaceURL: URL(fileURLWithPath: workspace.rootPath, isDirectory: true),
                prompt: pending.prompt,
                permission: pending.permission,
                workflow: pending.workflow,
                selectedSkills: pending.skills,
                sessionID: conversation.provider == pending.provider.providerKind
                    ? conversation.providerSessionID
                    : nil
            )
            if !pending.promptCheckpointed {
                guard await appendMessage(.user, content: pending.prompt, conversationID: conversation.id) != nil else {
                    throw AppModelError.persistenceRequired
                }
            }
            let providerChanged = conversation.provider != pending.provider.providerKind
            guard await updateConversation(conversation.id, mutate: {
                if providerChanged { $0.providerSessionID = nil }
                $0.provider = pending.provider.providerKind
                $0.workflow = pending.classification
                $0.permissionMode = pending.permission.permissionMode
                $0.skillIDs = pending.skills
                $0.status = .running
                if $0.title.hasPrefix("New ") {
                    $0.title = Self.title(from: pending.prompt)
                }
            }) else { throw AppModelError.persistenceRequired }
            lastAssistantText.removeValue(forKey: conversation.id)
            let handoff = SerializedProviderEventHandoff { [weak self] event in
                await self?.handle(event, conversationID: pending.conversationID)
            }
            let running = try providerRunner.start(plan) { event in
                handoff.accept(event)
            }
            runningProcesses[pending.conversationID] = running
            if let acquiredWriterLease = writerLease {
                continuityWriterLeases[pending.conversationID] = acquiredWriterLease
                startContinuityWriterHeartbeat(for: pending.conversationID)
                writerLease = nil
                await refreshSelectedContinuityStatus()
            }
            if let handoffID = pending.continuityHandoffID {
                do {
                    try await acknowledgeContinuityHandoff(
                        handoffID,
                        conversationID: pending.conversationID
                    )
                } catch {
                    running.cancel()
                    throw AppModelError.persistenceRequired
                }
            }
            reservedDispatches.removeValue(forKey: pending.conversationID)
            activityText = "\(pending.provider.displayName) running · \(pending.workflow.displayName)"
        } catch {
            if let store, let writerLease {
                do {
                    let released = try await ContinuityWriterLeaseGate.release(store: store, lease: writerLease)
                    if !released {
                        await requireContinuityReconciliation(
                            for: pending.conversationID,
                            lease: writerLease,
                            reason: "Provider launch failed and writer lease release could not be verified."
                        )
                    }
                } catch {
                    await requireContinuityReconciliation(
                        for: pending.conversationID,
                        lease: writerLease,
                        reason: "Provider launch failed and writer lease release could not be persisted."
                    )
                }
            }
            reservedDispatches.removeValue(forKey: pending.conversationID)
            pairedReviewPrimaries.remove(pending.conversationID)
            _ = await appendMessage(.tool, content: error.localizedDescription, conversationID: conversation.id)
            await setStatus(.failed, for: conversation.id)
            activityText = "Dispatch failed"
            alertText = error.localizedDescription
        }
    }

    private func handle(_ event: ProviderStreamEvent, conversationID: UUID) async {
        if case .exited = event {
            // Completion below owns lease release for a process that started.
        } else {
            await renewContinuityWriterLease(for: conversationID)
        }
        switch event {
        case .batch(let events):
            for event in events {
                await handle(event, conversationID: conversationID)
            }
        case .sessionID(let sessionID):
            guard let validatedID = UUID(uuidString: sessionID)?.uuidString.lowercased() else {
                _ = await appendMessage(
                    .tool,
                    content: "The provider reported an invalid session identifier. It was ignored so this task can retry safely.",
                    conversationID: conversationID
                )
                alertText = "Invalid provider session identity was ignored."
                return
            }
            if let store {
                do {
                    if let linked = try await store.externalSession(forConversationID: conversationID),
                       (linked.providerSessionID.lowercased() != validatedID
                            || conversations.first(where: { $0.id == conversationID })?.provider != linked.provider) {
                        _ = await appendMessage(
                            .tool,
                            content: "The provider reported a different session identity. The imported task link was preserved and not reassigned.",
                            conversationID: conversationID
                        )
                        alertText = "Provider identity changed unexpectedly; this task was not relinked."
                        return
                    }
                } catch {
                    alertText = "Provider identity could not be verified: \(error.localizedDescription)"
                    return
                }
            }
            await updateConversation(conversationID) { $0.providerSessionID = validatedID }
        case .text(let text):
            lastAssistantText[conversationID] = text
            _ = await appendMessage(.assistant, content: text, conversationID: conversationID)
        case .result(let text):
            if lastAssistantText[conversationID] != text {
                lastAssistantText[conversationID] = text
                _ = await appendMessage(.assistant, content: text, conversationID: conversationID)
            }
        case .activity(let label):
            activityText = label
        case .diagnostic(let text):
            _ = await appendMessage(.tool, content: text, conversationID: conversationID)
        case .exited(let status):
            runningProcesses.removeValue(forKey: conversationID)
            lastAssistantText.removeValue(forKey: conversationID)
            let wasCancelled = cancellationRequestedIDs.remove(conversationID) != nil
            let shouldLaunchPairedReview = pairedReviewPrimaries.remove(conversationID) != nil
            let finalStatus: ConversationStatus = wasCancelled ? .cancelled : (status == 0 ? .completed : .failed)
            await releaseContinuityWriterLease(
                for: conversationID,
                succeeded: !wasCancelled && status == 0
            )
            await setStatus(finalStatus, for: conversationID)
            activityText = wasCancelled
                ? "Cancelled"
                : (status == 0 ? "Ready for review" : "Provider exited with status \(status)")
            if !wasCancelled, status == 0, shouldLaunchPairedReview {
                await launchPairedReview(for: conversationID)
            }
            await drainQueueIfPossible()
            await refreshLocalHistory(reason: "provider exit")
        }
    }

    private func launchPairedReview(for primaryID: UUID) async {
        guard let store,
              let primary = conversations.first(where: { $0.id == primaryID }),
              let workspace = workspaces.first(where: { $0.id == primary.workspaceID }) else { return }
        let reviewer: RuntimeProvider = primary.provider == .codex ? .claude : .codex
        let now = Date()
        let review = Conversation(
            workspaceID: workspace.id,
            title: "Review · \(primary.title)",
            provider: reviewer.providerKind,
            workflow: .backgroundReview,
            permissionMode: .readOnly,
            status: .idle,
            skillIDs: ["engineering:code-review"],
            createdAt: now,
            updatedAt: now
        )
        do {
            try await store.insertConversation(review)
            conversations.insert(review, at: 0)
            let prompt = Self.pairedReviewPrompt(primaryID: primary.id)
            let pending = PendingDispatch(
                id: UUID(),
                conversationID: review.id,
                prompt: prompt,
                provider: reviewer,
                workflow: .direct,
                classification: .backgroundReview,
                permission: .readOnly,
                skills: ["engineering:code-review"],
                enqueuedAt: Date(),
                promptCheckpointed: false,
                continuityHandoffID: nil
            )
            await admitOrQueue(pending)
        } catch {
            alertText = "Paired review could not start: \(error.localizedDescription)"
        }
    }

    private func drainQueueIfPossible() async {
        guard !queueDrainInProgress, !queuedDispatches.isEmpty else { return }
        queueDrainInProgress = true
        defer { queueDrainInProgress = false }
        refreshMetricsWithoutDrain()
        let memory = memorySnapshot ?? SystemMemorySnapshot(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            availableBytes: ProcessInfo.processInfo.physicalMemory,
            appResidentBytes: 0
        )
        let plan = governor.makeAdmissionPlan(
            queuedJobs: queuedDispatches.map {
                QueuedJob(
                    id: $0.id,
                    conversationID: $0.conversationID,
                    provider: $0.provider.providerKind,
                    workflow: $0.classification,
                    enqueuedAt: $0.enqueuedAt
                )
            },
            activeJobs: activeJobs(),
            memory: memory,
            mode: resourceMode
        )
        let admittedIDs = Set(plan.admitted.map(\.id))
        let admitted = plan.admitted.compactMap { job in
            queuedDispatches.first(where: { $0.id == job.id })
        }
        queuedDispatches.removeAll(where: { admittedIDs.contains($0.id) })
        for pending in admitted {
            reservedDispatches[pending.conversationID] = pending
        }
        for pending in admitted {
            await start(pending)
        }
    }

    private func activeJobs() -> [ActiveJob] {
        let running: [ActiveJob] = runningProcesses.compactMap { conversationID, process -> ActiveJob? in
            guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
            return ActiveJob(
                id: process.id,
                conversationID: conversationID,
                provider: conversation.provider,
                workflow: conversation.workflow,
                startedAt: process.startedAt
            )
        }
        let reserved = reservedDispatches.values.map { pending in
            ActiveJob(
                id: pending.id,
                conversationID: pending.conversationID,
                provider: pending.provider.providerKind,
                workflow: pending.classification,
                startedAt: pending.enqueuedAt
            )
        }
        return running + reserved
    }

    @discardableResult
    private func appendMessage(_ role: MessageRole, content: String, conversationID: UUID) async -> Message? {
        guard let store else { return nil }
        let sanitized = TerminalTextSanitizer.sanitize(content)
        let bounded = sanitized.text
        guard !bounded.isEmpty else { return nil }
        do {
            let message = try await store.appendMessage(
                conversationID: conversationID,
                role: role,
                content: bounded
            )
            if selectedConversationID == conversationID {
                messages.append(message)
                trimVisibleTranscript()
            }
            return message
        } catch {
            alertText = "Message could not be saved: \(error.localizedDescription)"
            return nil
        }
    }

    private func setStatus(_ status: ConversationStatus, for id: UUID) async {
        await updateConversation(id) { $0.status = status }
    }

    @discardableResult
    private func updateConversation(_ id: UUID, mutate: (inout Conversation) -> Void) async -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }), let store else { return false }
        var updated = conversations[index]
        mutate(&updated)
        updated.updatedAt = Date()
        // Publish synchronously before the actor hop so reentrant events for the
        // same conversation compose on the latest state instead of stale copies.
        conversations[index] = updated
        do {
            try await store.updateConversation(updated)
            return true
        } catch {
            if let persisted = try? await store.conversation(id: id),
               let refreshedIndex = conversations.firstIndex(where: { $0.id == id }),
               conversations[refreshedIndex] == updated {
                conversations[refreshedIndex] = persisted
            }
            alertText = "Task state could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private func adoptSettings(from conversation: Conversation?) {
        guard let conversation else { return }
        selectedProvider = conversation.provider.runtimeProvider
        selectedWorkflow = conversation.workflow.runtimeWorkflow
        selectedPermission = conversation.permissionMode.runtimePermission
        selectedSkills = Set(conversation.skillIDs)
    }

    private func refreshMetricsWithoutDrain() {
        memorySnapshot = try? metrics.snapshot()
    }

    private func canonicalWorkspacePath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != "/",
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        return resolved.path
    }

    private func standardizedStoredPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        return standardized == "/" ? nil : standardized
    }

    private func approvedWorkspace(for session: ExternalSession) -> Workspace? {
        guard let canonical = canonicalWorkspacePath(session.workspacePath),
              let workspace = workspaces.first(where: { $0.rootPath == canonical }),
              canonicalWorkspacePath(workspace.rootPath) == workspace.rootPath else {
            return nil
        }
        return workspace
    }

    static func conversationIdentityMatches(
        _ conversation: Conversation,
        session: ExternalSession,
        workspace: Workspace
    ) -> Bool {
        guard conversation.provider == session.provider,
              conversation.workspaceID == workspace.id,
              let conversationSessionID = conversation.providerSessionID,
              let conversationUUID = UUID(uuidString: conversationSessionID),
              let externalUUID = UUID(uuidString: session.providerSessionID) else {
            return false
        }
        return conversationUUID == externalUUID
    }

    private func linkedIdentityAllows(
        _ pending: PendingDispatch,
        revalidateSource: Bool
    ) async -> Bool {
        guard let store,
              let conversation = conversations.first(where: { $0.id == pending.conversationID }) else {
            return false
        }
        do {
            guard let linked = try await store.externalSession(
                forConversationID: pending.conversationID
            ) else { return true }
            guard pending.provider.providerKind == linked.provider,
                  let workspace = approvedWorkspace(for: linked),
                  Self.conversationIdentityMatches(
                    conversation,
                    session: linked,
                    workspace: workspace
                  ) else {
                alertText = "This task is linked to \(linked.surface.displayName) \(linked.providerSessionID). Continue it with its original provider, or create a new app task to switch providers."
                return false
            }
            guard revalidateSource else { return true }
            let validation = await historyCoordinator.revalidate(session: linked)
            guard let currentConversation = conversations.first(where: {
                $0.id == pending.conversationID
            }) else { return false }
            switch validation.state {
            case .available:
                guard let refreshed = validation.refreshedSession,
                      validation.permitsResume,
                      let refreshedWorkspace = approvedWorkspace(for: refreshed),
                      pending.provider.providerKind == refreshed.provider,
                      Self.conversationIdentityMatches(
                        currentConversation,
                        session: refreshed,
                        workspace: refreshedWorkspace
                      ) else {
                    alertText = "The linked provider source changed identity or project folder. Reopen it from Local History and approve the current exact folder."
                    return false
                }
                try await store.upsertExternalSessions([refreshed])
                return true
            case .unavailable:
                try await store.markExternalSessionMissing(id: linked.id, at: validation.checkedAt)
                if let index = externalSessions.firstIndex(where: { $0.id == linked.id }),
                   let missing = try await store.externalSession(id: linked.id) {
                    externalSessions[index] = missing
                }
                alertText = "This linked provider task is no longer present locally. It was marked missing and no process was started."
                return false
            case .indeterminate:
                alertText = "\(validation.diagnostic?.detail ?? "The linked provider source could not be revalidated safely.") No process was started; refresh and retry."
                return false
            }
        } catch {
            alertText = "The linked provider identity could not be verified: \(error.localizedDescription)"
            return false
        }
    }

    private func trimVisibleTranscript() {
        var retainedBytes = messages.reduce(0) { partial, message in
            partial + message.content.utf8.count
        }
        while messages.count > SQLiteStore.maximumTranscriptMessageCount
            || retainedBytes > SQLiteStore.maximumTranscriptBytes {
            guard let oldest = messages.first else { break }
            retainedBytes -= oldest.content.utf8.count
            messages.removeFirst()
        }
    }

    private static func title(from prompt: String) -> String {
        let first = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "New task"
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 72 ? String(trimmed.prefix(69)) + "…" : trimmed
    }

    static func pairedReviewPrompt(primaryID: UUID) -> String {
        """
        Independently review the current workspace changes for paired task ID \(primaryID.uuidString.lowercased()). Use the engineering code-review standard: report only actionable defects, rank by severity, cite exact files and lines, verify tests where safe, make no edits, and end with residual risks or ‘no findings’.
        """
    }

    private static func databaseURL() throws -> URL {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return support
            .appendingPathComponent("Local Command Center", isDirectory: true)
            .appendingPathComponent("command-center.sqlite", isDirectory: false)
    }

}

enum AppModelError: LocalizedError {
    case persistenceRequired
    case continuityFirstTurnMustBeReadOnly
    case continuityPromptTooLarge
    case continuityWriterConflict
    case continuityWriterAmbiguous
    case continuityWriterLeaseLost
    case continuityReviewerMustRemainReadOnly
    case continuitySourceDivergent
    case continuityPreviewStale

    var errorDescription: String? {
        switch self {
        case .persistenceRequired:
            "The turn was not started because its local checkpoint could not be saved."
        case .continuityFirstTurnMustBeReadOnly:
            "The first destination turn must remain read-only while it validates the continuity capsule."
        case .continuityPromptTooLarge:
            "The continuity capsule and current direction exceed the bounded provider prompt limit."
        case .continuityWriterConflict:
            "Another active writer owns this continuity workstream. Wait for it to finish or reconcile the handoff before retrying."
        case .continuityWriterAmbiguous:
            "The destination task has conflicting continuity handoffs. Audit and reconcile the lineage before launching a writer."
        case .continuityWriterLeaseLost:
            "Continuity writer ownership was lost or expired. Audit the workstream before launching another writer."
        case .continuityReviewerMustRemainReadOnly:
            "Reviewer tasks are read-only and cannot acquire a continuity writer lease."
        case .continuitySourceDivergent:
            "The source task advanced after its handoff boundary. Reconcile the divergent branches before another writable turn."
        case .continuityPreviewStale:
            "The continuity capsule or Git boundary changed after this preview. Prepare a new preview before confirming."
        }
    }
}
