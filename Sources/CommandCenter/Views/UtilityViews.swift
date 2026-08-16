import CommandCenterCore
import SwiftUI

struct SkillsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search installed skills", text: $model.skillSearchText)
                .textFieldStyle(.roundedBorder)
                .padding()
            List(model.filteredSkills) { skill in
                Toggle(isOn: Binding(
                    get: { model.selectedSkills.contains(skill.name) },
                    set: { enabled in
                        if enabled { model.selectedSkills.insert(skill.name) }
                        else { model.selectedSkills.remove(skill.name) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.body.weight(.medium))
                        Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(skill.source).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .toggleStyle(.checkbox)
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshRuntime() } }
        }
    }
}

struct LocalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    private struct HistoryGroup: Identifiable {
        let id: String
        let label: String
        let sessions: [ExternalSession]
    }

    private var groupedSessions: [HistoryGroup] {
        let groups = Dictionary(grouping: model.filteredExternalSessions) { session in
            session.workspacePath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .standardizedFileURL.path
            } ?? ""
        }
        return groups.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { path in
            let label: String
            if path.isEmpty {
                label = "Unassigned"
            } else {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let parent = url.deletingLastPathComponent().lastPathComponent
                label = parent.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) — \(parent)"
            }
            return HistoryGroup(
                id: path.isEmpty ? "unassigned" : path,
                label: label,
                sessions: groups[path, default: []].sorted { $0.lastSeenAt > $1.lastSeenAt }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search local Codex and Claude history", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                if model.isHistoryRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing local history")
                }
            }
            .padding()
            HStack(spacing: 10) {
                Label("\(model.codexHistoryCount) Codex", systemImage: ProviderKind.codex.symbolName)
                Label("\(model.claudeHistoryCount) Claude", systemImage: ProviderKind.claude.symbolName)
                Spacer()
                Text("\(model.resumableHistoryCount) resumable")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()
            if groupedSessions.isEmpty {
                ContentUnavailableView(
                    "No local provider history",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Refresh after using Codex or Claude Code locally.")
                )
            } else {
                List(selection: $model.selectedExternalSessionID) {
                    ForEach(groupedSessions) { group in
                        Section(group.label) {
                            ForEach(group.sessions) { session in
                                LocalHistoryRow(session: session)
                                    .tag(session.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: model.selectedExternalSessionID) { _, id in
                    Task { await model.selectExternalSession(id) }
                }
            }
        }
        .navigationTitle("Local history")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshLocalHistory(reason: "manual history") }
            }
            .disabled(model.isHistoryRefreshing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusCommandCenterSearch)) { _ in
            searchFocused = true
        }
    }
}

struct LocalHistoryRow: View {
    let session: ExternalSession

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: session.provider.symbolName)
                .foregroundStyle(session.provider == .claude ? .orange : .green)
                .frame(width: 18)
                .accessibilityLabel(session.provider.displayName)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.surface.displayName)
                    Text("·")
                    Text(session.statusDisplayName)
                    Text("·")
                    Text(session.lastSeenAt, style: .relative)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(session.statusTint)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.provider.displayName), \(session.title), \(session.statusDisplayName)")
    }
}

struct LocalHistoryDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let session = model.selectedExternalSession {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LOCAL PROVIDER HISTORY · READ ONLY")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        ProviderBadge(provider: session.provider, surface: session.surface)
                        Text(session.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(session.workspacePath ?? "No project path reported")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    GroupBox("Latest preview") {
                        Text(session.preview.isEmpty ? "No preview was provided by the local provider index." : session.preview)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }

                    HStack {
                        LabeledContent("Status", value: session.statusDisplayName)
                        Spacer()
                        LabeledContent("Updated", value: session.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("PURSUING GOAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Continue \(session.title) through its original \(session.surface.displayName) subscription context")
                            .font(.callout.weight(.medium))
                        Text("Metadata mirrored · transcript lazy/bounded · provider source read only")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Pursuing goal, continue \(session.title)")

                    if model.canContinueSelectedExternalSession {
                        Button("Continue in Command Center", systemImage: "arrow.right.circle.fill") {
                            Task { await model.continueSelectedExternalSession() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if session.workspacePath != nil && session.missingSince == nil && session.canResume {
                        Button("Approve project and continue…", systemImage: "folder.badge.questionmark") {
                            model.approveSelectedExternalWorkspace()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Label("Continuation unavailable from this local source", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }

                    Text("Continuation uses the original authenticated subscription CLI and UUID. The provider transcript remains authoritative and is never rewritten or copied wholesale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        Text("Recent transcript")
                            .font(.headline)
                        Spacer()
                        if model.externalTranscriptBytesRead > 0 {
                            Text("\(model.externalTranscript.count) messages · \(Formatters.memory(UInt64(model.externalTranscriptBytesRead)))\(model.externalTranscriptWasTruncated ? " · bounded" : "")")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if model.isExternalTranscriptLoading { ProgressView().controlSize(.small) }
                    }
                    if model.externalTranscript.isEmpty && !model.isExternalTranscriptLoading {
                        Text(session.canReadTranscript ? "No visible user or assistant text was found in the bounded recent window." : "The local transcript source is unavailable.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.externalTranscript) { row in
                                LocalTranscriptRowView(row: row)
                            }
                        }
                    }
                }
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        } else {
            ContentUnavailableView(
                "Select local history",
                systemImage: "clock.arrow.circlepath",
                description: Text("Codex and Claude Code tasks are indexed as bounded, read-only local metadata.")
            )
        }
    }
}

struct ProviderBadge: View {
    let provider: ProviderKind
    var surface: ExternalSessionSurface? = nil

    var body: some View {
        Label(surface?.displayName ?? provider.displayName, systemImage: provider.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(provider == .claude ? .orange : .green)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(surface?.displayName ?? provider.displayName)
    }
}

struct LocalTranscriptRowView: View {
    let row: LocalTranscriptRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: row.role == .user ? "person.fill" : "sparkles")
                Text(row.role.displayName).fontWeight(.semibold)
                Text(row.timestamp, style: .time)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.caption)
            Text(row.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.role.displayName)
    }
}

struct RuntimeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Memory governor") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Policy", selection: $model.resourceMode) {
                            ForEach(ResourceMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if let memory = model.memorySnapshot {
                            LabeledContent("Available", value: Formatters.memory(memory.availableBytes))
                            LabeledContent("Physical", value: Formatters.memory(memory.physicalBytes))
                            LabeledContent("Command Center RSS", value: Formatters.memory(memory.appResidentBytes))
                            LabeledContent("Workers", value: "\(model.runningCount) active · \(model.queuedCount) queued")
                        }
                        Text("Pressure defers only new work. Active Codex and Claude processes continue at full performance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }

                GroupBox("Provider pools") {
                    VStack(spacing: 0) {
                        ForEach(model.providerHealth) { health in
                            HStack(spacing: 10) {
                                Image(systemName: health.isAuthenticated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(health.isAuthenticated ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(health.provider.displayName).fontWeight(.medium)
                                    Text(health.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(health.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 9)
                            if health.id != model.providerHealth.last?.id { Divider() }
                        }
                    }
                }

                GroupBox("Local indexes") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("App-owned tasks", value: "\(model.conversations.count)")
                        LabeledContent("Installed skills", value: "\(model.skills.count)")
                        LabeledContent("Codex tasks discovered", value: "\(model.codexHistoryCount)")
                        LabeledContent("Claude Code sessions", value: "\(model.claudeHistoryCount)")
                        LabeledContent("Resumable local history", value: "\(model.resumableHistoryCount)")
                        LabeledContent(
                            "Indexed metadata",
                            value: "\(model.externalSessions.count) loaded / \(model.historyIndexedSessionCount) local"
                        )
                        if let refreshed = model.historyLastRefreshedAt {
                            LabeledContent("Last mirrored", value: refreshed.formatted(date: .omitted, time: .standard))
                            LabeledContent("Bounded scan", value: model.historyLastScanDuration.formatted(.number.precision(.fractionLength(2))) + " s")
                        }
                        LabeledContent("Scan warnings", value: "\(model.historyDiagnosticCount)")
                        if model.historyOmittedSessionCount > 0 {
                            Text("\(model.historyOmittedSessionCount) older sessions are safely indexed but outside the bounded in-memory window. This limit prevents a damaged or unexpectedly large provider store from exhausting RAM.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(Array(model.historyDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diagnostic.code)
                                    .font(.caption.monospaced().weight(.semibold))
                                Text(diagnostic.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Text("Provider stores remain authoritative. Automatic refresh is metadata-only; recent transcript text loads lazily when selected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Obsidian connective graph") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let vault = model.connectedObsidianVault {
                            LabeledContent("Vault", value: vault.displayName)
                            LabeledContent("Projection", value: model.obsidianProjectionStatus)
                            LabeledContent("Managed files", value: "\(model.obsidianProjectedFileCount)")
                            Button("Disconnect (keep notes)") {
                                model.disconnectObsidianVault()
                            }
                        } else if model.obsidianVaults.isEmpty {
                            Text("No registered local Obsidian vault was found.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose one registered vault to create an app-owned Command Center/ metadata graph. It writes provider-derived task titles (which may come from a first prompt), project folder labels, statuses, timestamps, and opaque IDs. Obsidian Sync or plugins may export that metadata:")
                                .foregroundStyle(.secondary)
                            ForEach(model.obsidianVaults) { vault in
                                Button("Connect and export metadata to \(vault.displayName)", systemImage: "point.3.connected.trianglepath.dotted") {
                                    Task { await model.connectObsidianVault(vault) }
                                }
                            }
                        }
                        Text("Existing notes and transcript bodies are never read, changed, or exported. Disconnecting retains the generated Command Center/ files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }

                GroupBox("Provider capability boundary") {
                    Text("Codex and Claude Code sessions that exist on this Mac can be indexed and resumed. Consumer-only ChatGPT and Claude.ai web chats remain BLOCKED_PROVIDER_CAPABILITY until an official local read-and-resume interface exists; Command Center does not scrape app caches or credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Runtime")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshRuntime() } }
        }
    }
}
