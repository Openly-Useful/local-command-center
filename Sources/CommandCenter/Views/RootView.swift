import AppKit
import CommandCenterCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } content: {
            switch model.selectedSidebar {
            case .history:
                LocalHistoryView()
            case .skills:
                SkillsView()
            case .runtime:
                RuntimeView()
            default:
                SessionListView()
            }
        } detail: {
            if model.selectedSidebar == .history {
                LocalHistoryDetailView()
            } else {
                ConversationDetailView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { GlobalStatusBar() }
        .task {
            while !Task.isCancelled {
                model.refreshMetrics()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .task { await model.runHistoryRefreshLoop() }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
            guard phase == .active else { return }
            Task { await model.refreshLocalHistory(reason: "foreground") }
        }
        .alert("Command Center", isPresented: Binding(
            get: { model.alertText != nil },
            set: { if !$0 { model.clearAlert() } }
        )) {
            Button("OK") { model.clearAlert() }
        } message: {
            Text(model.alertText ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedSidebar) {
            Section {
                destination("Inbox", symbol: "tray", count: model.inboxCount, tag: .inbox)
                destination("Pinned", symbol: "pin", count: model.pinnedCount, tag: .pinned)
                destination("Ready for review", symbol: "checkmark.seal", count: model.readyCount, tag: .ready)
                destination("Local history", symbol: "clock.arrow.circlepath", count: model.externalSessions.count, tag: .history)
            }

            Section("Projects") {
                let taskCounts = model.projectTaskCounts
                ForEach(model.workspaces) { workspace in
                    Label {
                        HStack {
                            Text(workspace.name).lineLimit(1)
                            Spacer()
                            Text(taskCounts[workspace.id, default: 0], format: .number)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(SidebarDestination.workspace(workspace.id))
                    .help(workspace.rootPath)
                }
                Button("Add project…", systemImage: "plus") { model.chooseWorkspace() }
                    .buttonStyle(.plain)
            }

            Section {
                destination("Skills", symbol: "wrench.and.screwdriver", count: model.skills.count, tag: .skills)
                destination("Runtime", symbol: "gauge.with.dots.needle.50percent", count: nil, tag: .runtime)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Command Center")
    }

    @ViewBuilder
    private func destination(
        _ title: String,
        symbol: String,
        count: Int?,
        tag: SidebarDestination
    ) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count, count > 0 {
                    Text(count, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(tag)
    }
}

struct GlobalStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Text("\(model.runningCount > 0 ? "RUNNING" : "READY") · \(model.activityText) · Workers \(model.runningCount)/\(model.maximumWorkers) · Queue \(model.queuedCount)")
                .lineLimit(1)
            Spacer(minLength: 12)
            if let memory = model.memorySnapshot {
                Text("STATUS BOT · \(Formatters.memory(memory.availableBytes)) available · App \(Formatters.memory(memory.appResidentBytes)) · History \(model.externalSessions.count) · \(model.resourceMode.displayName)")
                    .lineLimit(1)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct RuntimeFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle()
                    .fill(model.runningCount > 0 ? Color.blue : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(model.runningCount > 0 ? "Work running" : "No work running")
                Text("\(model.runningCount) running · \(model.queuedCount) queued")
                    .font(.caption.monospacedDigit())
            }
            if let memory = model.memorySnapshot {
                Text("\(Formatters.memory(memory.availableBytes)) available · app \(Formatters.memory(memory.appResidentBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(model.resourceMode.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker("Resource policy", selection: $model.resourceMode) {
                ForEach(ResourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text("Memory pressure pauses new dispatch only. Running provider work is never killed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 180)
        .padding()
    }
}
