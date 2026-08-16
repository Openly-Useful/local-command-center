import CommandCenterCore
import SwiftUI

enum SidebarDestination: Hashable {
    case inbox
    case pinned
    case ready
    case history
    case workspace(UUID)
    case skills
    case runtime

    var supportsConversationDispatch: Bool {
        switch self {
        case .inbox, .pinned, .ready, .workspace:
            true
        case .history, .skills, .runtime:
            false
        }
    }
}

extension ExternalSessionSurface {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

extension ExternalSession {
    var projectDisplayName: String {
        guard let workspacePath, !workspacePath.isEmpty else { return "Unassigned" }
        let name = URL(fileURLWithPath: workspacePath, isDirectory: true).lastPathComponent
        return name.isEmpty ? "Unassigned" : name
    }

    var statusDisplayName: String {
        if missingSince != nil { return "Source missing" }
        switch providerStatus.lowercased() {
        case "archived": return "Archived"
        case "running": return "Running"
        case "waitingforinput", "waiting_for_input", "waiting": return "Needs input"
        case "failed": return "Failed"
        case "cancelled", "canceled", "aborted": return "Cancelled"
        case "completed", "complete": return "Completed"
        default: return "Available"
        }
    }

    var statusTint: Color {
        if missingSince != nil { return .secondary }
        switch providerStatus.lowercased() {
        case "running": return .blue
        case "waitingforinput", "waiting_for_input", "waiting": return .orange
        case "failed": return .red
        case "completed", "complete": return .mint
        default: return .secondary
        }
    }
}

extension ProviderKind {
    var runtimeProvider: RuntimeProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }

    var displayName: String { runtimeProvider.displayName }

    var symbolName: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkle"
        }
    }
}

extension RuntimeProvider {
    var providerKind: ProviderKind {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}

extension WorkflowKind {
    var runtimeWorkflow: RuntimeWorkflow {
        switch self {
        case .interactive, .backgroundReview: .direct
        case .implementation: .pairedReview
        case .swarmWorker: .pickupSwarm
        }
    }

    var displayName: String {
        switch self {
        case .interactive: "Direct"
        case .implementation: "Paired review"
        case .backgroundReview: "Background review"
        case .swarmWorker: "Pickup swarm"
        }
    }
}

extension RuntimeWorkflow {
    var workflowKind: WorkflowKind {
        switch self {
        case .direct: .interactive
        case .pickupSwarm: .swarmWorker
        case .pairedReview: .implementation
        }
    }
}

extension PermissionMode {
    var runtimePermission: RuntimePermission {
        switch self {
        case .readOnly: .readOnly
        case .workspaceWrite: .workspaceWrite
        }
    }
}

extension RuntimePermission {
    var permissionMode: PermissionMode {
        switch self {
        case .readOnly: .readOnly
        case .workspaceWrite: .workspaceWrite
        }
    }
}

extension ConversationStatus {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .queued: "Queued"
        case .running: "Running"
        case .waitingForInput: "Needs input"
        case .completed: "Ready for review"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "circle"
        case .queued: "clock"
        case .running: "bolt.fill"
        case .waitingForInput: "questionmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .blue
        case .waitingForInput, .queued: .orange
        case .completed: .mint
        case .failed: .red
        case .idle, .cancelled: .secondary
        }
    }
}

extension MessageRole {
    var displayName: String {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        case .tool: "Activity"
        }
    }
}

extension ResourceMode {
    var displayName: String { rawValue.capitalized }
}

@MainActor
enum Formatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func memory(_ value: UInt64) -> String {
        bytes.string(fromByteCount: Int64(clamping: value))
    }
}
