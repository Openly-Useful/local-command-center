import CommandCenterCore
import SwiftUI

struct ConversationDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let conversation = model.selectedConversation {
            VStack(spacing: 0) {
                DetailHeader(conversation: conversation)
                Divider()
                TranscriptView()
                Divider()
                ComposerView()
            }
            .navigationTitle(conversation.title)
        } else {
            ContentUnavailableView {
                Label("Select a task", systemImage: "sidebar.right")
            } description: {
                Text("Your local Codex and Claude work stays grouped by project.")
            } actions: {
                Button("New Task") { Task { await model.createConversation() } }
            }
        }
    }
}

struct DetailHeader: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(model.selectedWorkspace?.rootPath ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.selectedWorkspace?.rootPath ?? "")
                }
                Spacer()
                Menu {
                    ForEach(RuntimeProvider.allCases.filter { $0 != conversation.provider.runtimeProvider }) { provider in
                        Button("Continue in \(provider.displayName)") {
                            Task { await model.continueSelected(in: provider) }
                        }
                    }
                } label: {
                    Label("Continue", systemImage: "arrow.triangle.branch")
                }
                .help("Create a compact continuity handoff as a separate task")
                Menu {
                    ForEach(RuntimeProvider.allCases.filter { $0 != conversation.provider.runtimeProvider }) { provider in
                        Button("Review with \(provider.displayName)") {
                            Task { await model.continueSelected(in: provider, reviewOnly: true) }
                        }
                    }
                } label: {
                    Label("Review", systemImage: "checkmark.shield")
                }
                .help("Create a read-only reviewer task with a bounded diff")
                Label(conversation.status.displayName, systemImage: conversation.status.symbolName)
                    .foregroundStyle(conversation.status.tint)
                    .font(.callout.weight(.medium))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ContextPill(text: conversation.provider.displayName, symbol: conversation.provider.symbolName)
                    ContextPill(text: conversation.permissionMode == .readOnly ? "Read only" : "Workspace write", symbol: "lock.shield")
                    ContextPill(text: conversation.workflow.displayName, symbol: "arrow.triangle.branch")
                    ForEach(conversation.skillIDs, id: \.self) { skill in
                        ContextPill(text: skill, symbol: "wrench")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("PURSUING GOAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(conversation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text("\(model.messages.count) local checkpoints · \(conversation.status.displayName) · \(model.resourceMode.displayName) resources")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pursuing goal, \(conversation.title)")
        }
        .padding(16)
    }
}

struct ContextPill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        ContentUnavailableView(
                            "Ready for direction",
                            systemImage: "ellipsis.message",
                            description: Text("Choose a provider, workflow, permissions, and skills below.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(model.messages) { message in
                            MessageView(message: message).id(message.id)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(message.role.displayName)
                    .fontWeight(.semibold)
                Text(message.createdAt, style: .time)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.caption)
            Text(message.content)
                .font(message.role == .tool ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role.displayName)
    }

    private var symbol: String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .system: "gearshape"
        case .tool: "terminal"
        }
    }

    private var background: Color {
        switch message.role {
        case .user: Color.accentColor.opacity(0.10)
        case .assistant: Color.secondary.opacity(0.08)
        case .system, .tool: Color.secondary.opacity(0.05)
        }
    }
}

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSkills = false

    var body: some View {
        VStack(spacing: 9) {
            TextEditor(text: $model.composerText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68, maxHeight: 150)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if model.composerText.isEmpty {
                        Text("Ask, direct, or hand off work…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Task prompt")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    providerPicker.frame(width: 102)
                    workflowPicker.frame(width: 128)
                    permissionPicker.frame(width: 138)
                    skillsButton
                    Spacer()
                    actionButton
                }

                VStack(spacing: 7) {
                    HStack(spacing: 8) {
                        providerPicker.frame(maxWidth: .infinity)
                        workflowPicker.frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 8) {
                        permissionPicker.frame(maxWidth: .infinity)
                        skillsButton
                        Spacer(minLength: 4)
                        actionButton
                    }
                }
            }

            HStack {
                Text(model.activityText)
                    .lineLimit(1)
                Spacer()
                if let memory = model.memorySnapshot {
                    Text("\(Formatters.memory(memory.availableBytes)) available")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.bar)
    }

    private var providerPicker: some View {
        Picker("Provider", selection: $model.selectedProvider) {
            ForEach(RuntimeProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Provider")
    }

    private var workflowPicker: some View {
        Picker("Workflow", selection: $model.selectedWorkflow) {
            ForEach(RuntimeWorkflow.allCases) { workflow in
                Text(workflow.displayName).tag(workflow)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Workflow")
    }

    private var permissionPicker: some View {
        Picker("Permission", selection: $model.selectedPermission) {
            ForEach(RuntimePermission.allCases) { permission in
                Text(permission.displayName).tag(permission)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Permission")
    }

    private var skillsButton: some View {
        Button {
            showingSkills.toggle()
        } label: {
            Label("\(model.selectedSkills.count) skills", systemImage: "wrench.and.screwdriver")
        }
        .popover(isPresented: $showingSkills) {
            SkillPickerView()
                .environmentObject(model)
                .frame(width: 360, height: 430)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.isSelectedConversationRunning {
            Button("Stop", systemImage: "stop.fill", role: .destructive) { model.cancelSelected() }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
        } else {
            Button("Run", systemImage: "arrow.up.circle.fill") {
                Task { await model.dispatchComposer() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canRunComposerCommand)
        }
    }
}

struct SkillPickerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active skills").font(.headline)
            TextField("Find installed skills", text: $model.skillSearchText)
                .textFieldStyle(.roundedBorder)
            List(model.filteredSkills) { skill in
                Toggle(isOn: Binding(
                    get: { model.selectedSkills.contains(skill.name) },
                    set: { enabled in
                        if enabled { model.selectedSkills.insert(skill.name) }
                        else { model.selectedSkills.remove(skill.name) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).lineLimit(1)
                        Text(skill.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("Metadata only. Command Center never executes skill files itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
