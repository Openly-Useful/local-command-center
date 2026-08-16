import Foundation
import Darwin

enum RuntimeProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

struct ProviderHealth: Identifiable, Sendable {
    var id: RuntimeProvider { provider }
    var provider: RuntimeProvider
    var executableURL: URL?
    var version: String
    var isAuthenticated: Bool
    var detail: String

    var isAvailable: Bool { executableURL != nil }
}

enum ExecutableResolver {
    static func resolve(_ name: String) -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let fixedCandidates = [
            home.appendingPathComponent(".local/bin/\(name)"),
            home.appendingPathComponent(".npm-global/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ]

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }

        for candidate in fixedCandidates + pathCandidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            if manager.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }
}

actor ProviderHealthService {
    func checkAll() async -> [ProviderHealth] {
        await withTaskGroup(of: ProviderHealth.self) { group in
            for provider in RuntimeProvider.allCases {
                group.addTask { await Self.check(provider) }
            }
            var results: [ProviderHealth] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }

    private static func check(_ provider: RuntimeProvider) async -> ProviderHealth {
        guard let executable = ExecutableResolver.resolve(provider.rawValue) else {
            return ProviderHealth(
                provider: provider,
                executableURL: nil,
                version: "Not found",
                isAuthenticated: false,
                detail: "CLI not installed"
            )
        }

        return await Task.detached(priority: .utility) {
            let versionResult = run(executable, arguments: ["--version"], timeout: 5)
            let version = firstNonemptyLine(versionResult.stdout + "\n" + versionResult.stderr) ?? "Installed"

            switch provider {
            case .codex:
                let auth = run(executable, arguments: ["login", "status"], timeout: 7)
                let authenticated = parseCodexAuthentication(
                    status: auth.status,
                    stdout: auth.stdout,
                    stderr: auth.stderr
                )
                return ProviderHealth(
                    provider: provider,
                    executableURL: executable,
                    version: version,
                    isAuthenticated: authenticated,
                    detail: authenticated ? "ChatGPT subscription" : "Authentication required"
                )

            case .claude:
                let auth = run(executable, arguments: ["auth", "status"], timeout: 7)
                var authenticated = false
                var detail = "Authentication required"
                if auth.status == 0,
                   let data = auth.stdout.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    authenticated = object["loggedIn"] as? Bool == true
                    if authenticated {
                        let subscription = (object["subscriptionType"] as? String)?.capitalized
                        detail = subscription.map { "Claude \($0) subscription" } ?? "Claude subscription"
                    }
                }
                return ProviderHealth(
                    provider: provider,
                    executableURL: executable,
                    version: version,
                    isAuthenticated: authenticated,
                    detail: detail
                )
            }
        }.value
    }

    struct ProbeResult: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static let maximumProbeOutputBytes = 256 * 1_024
    static let terminationGrace: TimeInterval = 0.5
    static let killGrace: TimeInterval = 1

    /// Probes a provider without allowing a verbose or hung CLI to block a
    /// health refresh. Both pipes are drained as soon as the process starts;
    /// each is independently bounded so a hostile tool cannot grow memory.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProbeResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return ProbeResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let drainGroup = DispatchGroup()
        let stdoutBox = ProbeOutputBox()
        let stderrBox = ProbeOutputBox()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.store(drain(output.fileHandleForReading, maximumBytes: maximumProbeOutputBytes))
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.store(drain(error.fileHandleForReading, maximumBytes: maximumProbeOutputBytes))
            drainGroup.leave()
        }

        let deadline = DispatchTime.now() + max(0.01, timeout)
        let didExitBeforeDeadline: Bool
        if process.isRunning {
            didExitBeforeDeadline = terminated.wait(timeout: deadline) == .success
        } else {
            didExitBeforeDeadline = true
        }

        if !didExitBeforeDeadline {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + terminationGrace) == .timedOut {
                let processID = process.processIdentifier
                if processID > 0 { _ = Darwin.kill(processID, SIGKILL) }
                _ = terminated.wait(timeout: .now() + killGrace)
            }
        }

        // Once the child has exited the readers should receive EOF immediately.
        // Bound this wait too so an unexpected descriptor failure cannot hang a
        // UI health refresh indefinitely.
        if drainGroup.wait(timeout: .now() + killGrace) == .timedOut {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            _ = drainGroup.wait(timeout: .now() + 0.1)
        }

        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return ProbeResult(
            status: status,
            stdout: String(data: stdoutBox.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
        )
    }

    private final class ProbeOutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ data: Data) {
            lock.lock()
            self.data = data
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static func drain(_ handle: FileHandle, maximumBytes: Int) -> Data {
        defer { try? handle.close() }
        var collected = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return collected }
            if collected.count < maximumBytes {
                collected.append(chunk.prefix(maximumBytes - collected.count))
            }
        }
    }

    private static func firstNonemptyLine(_ value: String) -> String? {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    static func parseCodexAuthentication(status: Int32, stdout: String, stderr: String) -> Bool {
        status == 0 && (stdout + "\n" + stderr).localizedCaseInsensitiveContains("logged in")
    }
}
