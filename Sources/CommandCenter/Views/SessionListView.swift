import CommandCenterCore
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search tasks")
                if !model.searchText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)

            Divider()

            if model.filteredConversations.isEmpty && model.selectedProjectExternalSessions.isEmpty {
                ContentUnavailableView {
                    Label("No tasks here", systemImage: "text.bubble")
                } description: {
                    Text("Create a task or select another project.")
                } actions: {
                    Button("New Task") { Task { await model.createConversation() } }
                }
            } else {
                List(selection: $model.selectedConversationID) {
                    if !model.filteredConversations.isEmpty {
                        Section("Command Center tasks") {
                            ForEach(model.filteredConversations) { conversation in
                                SessionRow(conversation: conversation)
                                    .tag(conversation.id)
                                    .contextMenu {
                                        Button(model.isPinned(conversation.id) ? "Unpin" : "Pin") {
                                            model.togglePin(conversation.id)
                                        }
                                    }
                            }
                        }
                    }
                    if !model.selectedProjectExternalSessions.isEmpty {
                        Section("Provider history") {
                            ForEach(model.selectedProjectExternalSessions) { session in
                                Button {
                                    model.selectedSidebar = .history
                                    Task { await model.selectExternalSession(session.id) }
                                } label: {
                                    LocalHistoryRow(session: session)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens this provider task in Local history")
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: model.selectedConversationID) { _, id in
                    Task { await model.selectConversation(id) }
                }
            }
        }
        .navigationTitle(sectionTitle)
        .toolbar {
            ToolbarItem {
                Button("New Task", systemImage: "square.and.pencil") {
                    Task { await model.createConversation() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusCommandCenterSearch)) { _ in
            searchFocused = true
        }
    }

    private var sectionTitle: String {
        switch model.selectedSidebar {
        case .inbox: "Tasks"
        case .pinned: "Pinned"
        case .ready: "Ready"
        case .history: "Local history"
        case .workspace(let id): model.workspaces.first(where: { $0.id == id })?.name ?? "Project"
        case .skills: "Skills"
        case .runtime: "Runtime"
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: conversation.status.symbolName)
                .foregroundStyle(conversation.status.tint)
                .frame(width: 16)
                .accessibilityLabel(conversation.status.displayName)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if model.isPinned(conversation.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(workspaceName)
                    Text("·")
                    Text(conversation.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: conversation.provider.symbolName)
                        .accessibilityHidden(true)
                    Text(conversation.status.displayName)
                    Text("·")
                    Text(conversation.provider.displayName)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(conversation.status.tint)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var workspaceName: String {
        model.workspaces.first(where: { $0.id == conversation.workspaceID })?.name ?? "Project"
    }
}
