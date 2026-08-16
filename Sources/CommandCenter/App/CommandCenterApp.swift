import SwiftUI

@main
struct CommandCenterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Command Center") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { Task { await model.createConversation() } }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Project…") { model.chooseWorkspace() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Task") {
                Button("Run") { Task { await model.dispatchComposer() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRunComposerCommand)
                Button("Cancel Running Task") { model.cancelSelected() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancelSelectedCommand)
            }
            CommandMenu("Navigate") {
                Button("Inbox") { model.selectedSidebar = .inbox }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Pinned") { model.selectedSidebar = .pinned }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Ready for Review") { model.selectedSidebar = .ready }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Local History") { model.selectedSidebar = .history }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Search") { NotificationCenter.default.post(name: .focusCommandCenterSearch, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

extension Notification.Name {
    static let focusCommandCenterSearch = Notification.Name("local.commandcenter.focus-search")
}
