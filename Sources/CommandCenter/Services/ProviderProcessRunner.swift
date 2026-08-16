import Foundation
import Darwin

enum RuntimePermission: String, CaseIterable, Identifiable, Sendable {
    case readOnly
    case workspaceWrite

    var id: String { rawValue }
    var displayName: String { self == .readOnly ? "Read only" : "Workspace write" }
}

enum RuntimeWorkflow: String, CaseIterable, Identifiable, Sendable {
    case direct
    case pickupSwarm
    case pairedReview

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .pickupSwarm: return "Pickup swarm"
        case .pairedReview: return "Paired review"
        }
    }
}

struct ProviderLaunchPlan: Sendable {
    var provider: RuntimeProvider
    var executableURL: URL
    var arguments: [String]
    var workspaceURL: URL
    var prompt: String
}

enum ProviderStreamEvent: Sendable {
    case batch([ProviderStreamEvent])
    case sessionID(String)
    case text(String)
    case activity(String)
    case result(String)
    case diagnostic(String)
    case exited(Int32)
}

enum ProviderLaunchError: LocalizedError {
    case missingExecutable(RuntimeProvider)
    case invalidWorkspace
    case emptyPrompt
    case promptTooLarge
    case inputDeliveryUnavailable
    case invalidSessionID

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let provider): return "\(provider.displayName) CLI is not available."
        case .invalidWorkspace: return "Choose an existing workspace folder before dispatching."
        case .emptyPrompt: return "Enter a prompt before dispatching."
        case .promptTooLarge: return "The prompt exceeds the 1 MiB delivery safety limit."
        case .inputDeliveryUnavailable: return "Provider input could not be prepared safely."
        case .invalidSessionID: return "The provider session identifier is not a valid UUID."
        }
    }
}

enum ProviderCommandBuilder {
    static func build(
        provider: RuntimeProvider,
        workspaceURL: URL,
        prompt: String,
        permission: RuntimePermission,
        workflow: RuntimeWorkflow,
        selectedSkills: [String],
        sessionID: String?,
        executableURL: URL? = nil
    ) throws -> ProviderLaunchPlan {
        guard workspaceURL.isFileURL else {
            throw ProviderLaunchError.invalidWorkspace
        }
        let approvedWorkspace = workspaceURL.standardizedFileURL
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let workspaceValues = try? resolvedWorkspace.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard approvedWorkspace.path != "/",
              approvedWorkspace.path == resolvedWorkspace.path,
              workspaceValues?.isDirectory == true,
              workspaceValues?.isSymbolicLink != true else {
            throw ProviderLaunchError.invalidWorkspace
        }
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { throw ProviderLaunchError.emptyPrompt }
        let validatedSessionID: String?
        if let sessionID, !sessionID.isEmpty {
            guard let uuid = UUID(uuidString: sessionID) else {
                throw ProviderLaunchError.invalidSessionID
            }
            validatedSessionID = uuid.uuidString.lowercased()
        } else {
            validatedSessionID = nil
        }
        guard let executable = executableURL ?? ExecutableResolver.resolve(provider.rawValue),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProviderLaunchError.missingExecutable(provider)
        }

        let effectivePrompt = composePrompt(
            normalizedPrompt,
            workflow: workflow,
            skills: selectedSkills
        )

        switch provider {
        case .codex:
            var arguments = [
                "exec", "--json", "--color", "never", "--skip-git-repo-check",
                "-C", resolvedWorkspace.path,
                "-s", permission == .readOnly ? "read-only" : "workspace-write",
            ]
            if permission == .workspaceWrite {
                arguments.append("--approve-for-me")
            }
            if let sessionID = validatedSessionID {
                arguments += ["resume", sessionID, "-"]
            } else {
                arguments.append("-")
            }
            return ProviderLaunchPlan(
                provider: provider,
                executableURL: executable,
                arguments: arguments,
                workspaceURL: resolvedWorkspace,
                prompt: effectivePrompt
            )

        case .claude:
            var arguments = [
                "-p", "--output-format", "stream-json", "--verbose", "--no-chrome",
                "--prompt-suggestions", "false",
                "--permission-mode", permission == .readOnly ? "plan" : "acceptEdits",
            ]
            if let sessionID = validatedSessionID {
                arguments += ["--resume", sessionID]
            } else {
                arguments += ["--session-id", UUID().uuidString.lowercased()]
            }
            return ProviderLaunchPlan(
                provider: provider,
                executableURL: executable,
                arguments: arguments,
                workspaceURL: resolvedWorkspace,
                prompt: effectivePrompt
            )
        }
    }

    private static func composePrompt(_ prompt: String, workflow: RuntimeWorkflow, skills: [String]) -> String {
        var context: [String] = []
        let safeSkills = skills
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
        if !safeSkills.isEmpty {
            context.append("Use these installed skills when applicable: \(safeSkills.joined(separator: ", ")).")
        }
        switch workflow {
        case .direct:
            break
        case .pickupSwarm:
            context.append(
                "Use the pickup-swarm workflow: reconstruct current evidence first, define binary completion, delegate only independent work, preserve existing changes, verify actual outputs, and finish with the exact remaining action if anything is incomplete."
            )
        case .pairedReview:
            context.append(
                "This is the implementation half of a paired-review workflow. Produce a clear handoff containing changed files, commands, tests, residual risks, and the exact review target for the other provider."
            )
        }
        return (context + [prompt]).joined(separator: "\n\n")
    }
}

final class RunningProviderProcess: @unchecked Sendable {
    let id = UUID()
    let provider: RuntimeProvider
    let startedAt = Date()

    private let process: Process
    private let inputDelivery: ProviderStdinDelivery
    private let lock = NSLock()

    fileprivate init(provider: RuntimeProvider, process: Process, inputDelivery: ProviderStdinDelivery) {
        self.provider = provider
        self.process = process
        self.inputDelivery = inputDelivery
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        inputDelivery.cancel()
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Delivers provider stdin without ever blocking the caller that starts a
/// process. Writes are nonblocking, bounded, and tied to the lifetime of the
/// returned RunningProviderProcess.
private final class ProviderStdinDelivery: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "local.commandcenter.provider-stdin", qos: .userInitiated)
    private let timeout: TimeInterval
    private let maximumWriteBytesPerEvent = 64 * 1_024

    // All state below is confined to queue.
    private var writeSource: DispatchSourceWrite?
    private var payload = Data()
    private var offset = 0
    private var isClosed = false
    private var didReportFailure = false
    private var onFailure: (@Sendable (String) -> Void)?

    init(handle: FileHandle, timeout: TimeInterval) throws {
        self.handle = handle
        self.timeout = timeout
        let descriptor = handle.fileDescriptor
        let existingFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            throw ProviderLaunchError.inputDeliveryUnavailable
        }
    }

    deinit {
        try? handle.close()
    }

    func start(_ payload: Data, onFailure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            guard !isClosed else { return }
            self.payload = payload
            self.onFailure = onFailure
            guard !payload.isEmpty else {
                finish()
                return
            }

            let source = DispatchSource.makeWriteSource(
                fileDescriptor: handle.fileDescriptor,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.writeAvailableBytes()
            }
            writeSource = source
            source.resume()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeoutIfNeeded()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            finish()
        }
    }

    private func writeAvailableBytes() {
        guard !isClosed else { return }
        var writtenThisEvent = 0
        while offset < payload.count, writtenThisEvent < maximumWriteBytesPerEvent {
            let remaining = min(payload.count - offset, maximumWriteBytesPerEvent - writtenThisEvent)
            let result: Int
            result = payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(handle.fileDescriptor, base.advanced(by: offset), remaining)
            }
            if result > 0 {
                offset += result
                writtenThisEvent += result
                continue
            }
            if result == -1, errno == EINTR { continue }
            if result == -1, errno == EAGAIN || errno == EWOULDBLOCK { return }
            if result == -1, errno == EPIPE {
                finish()
                return
            }
            reportFailure("Provider input could not be delivered.")
            finish()
            return
        }
        if offset == payload.count { finish() }
    }

    private func timeoutIfNeeded() {
        guard !isClosed else { return }
        reportFailure("Provider input delivery timed out and was cancelled.")
        finish()
    }

    private func reportFailure(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure?(message)
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        writeSource?.cancel()
        writeSource = nil
        payload.removeAll(keepingCapacity: false)
        try? handle.close()
    }
}

/// Mutable bytes are confined to ProviderProcessRunner.callbackQueue. The
/// reference is Sendable so FileHandle/Process callbacks never capture mutable
/// local variables across concurrency domains.
private final class ProviderStreamBufferState: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
    var stdoutReachedEOF = false
    var stderrReachedEOF = false
    var terminationStatus: Int32?
    var didEmitExit = false
}

final class ProviderProcessRunner: @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "local.commandcenter.provider-stream", qos: .userInitiated)
    private let maximumLineBytes = 1_048_576
    private let maximumDiagnosticBytes = 65_536
    private let maximumInputBytes = 1_048_576
    private let inputDeliveryTimeout: TimeInterval

    init(inputDeliveryTimeout: TimeInterval = 5) {
        self.inputDeliveryTimeout = max(0.01, inputDeliveryTimeout)
    }

    @discardableResult
    func start(
        _ plan: ProviderLaunchPlan,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) throws -> RunningProviderProcess {
        guard let promptData = plan.prompt.data(using: .utf8),
              promptData.count <= maximumInputBytes else {
            throw ProviderLaunchError.promptTooLarge
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let inputDelivery = try ProviderStdinDelivery(
            handle: input.fileHandleForWriting,
            timeout: inputDeliveryTimeout
        )
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workspaceURL.standardizedFileURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment

        let buffers = ProviderStreamBufferState()

        output.fileHandleForReading.readabilityHandler = { [callbackQueue, maximumLineBytes] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                callbackQueue.async {
                    buffers.stdoutReachedEOF = true
                    self.finishIfReady(
                        buffers,
                        provider: plan.provider,
                        onEvent: onEvent
                    )
                }
                return
            }
            callbackQueue.async {
                buffers.stdout.append(data)
                while let newline = buffers.stdout.firstIndex(of: 0x0A) {
                    let line = buffers.stdout.prefix(upTo: newline)
                    buffers.stdout.removeSubrange(...newline)
                    if line.count > maximumLineBytes {
                        onEvent(.diagnostic("Provider event exceeded the 1 MiB safety bound and was discarded."))
                        continue
                    }
                    if let event = ProviderEventDecoder.decode(Data(line), provider: plan.provider) {
                        onEvent(event)
                    }
                }
                if buffers.stdout.count > maximumLineBytes {
                    buffers.stdout.removeAll(keepingCapacity: false)
                    onEvent(.diagnostic("Unterminated provider output exceeded the 1 MiB safety bound and was discarded."))
                }
            }
        }

        error.fileHandleForReading.readabilityHandler = { [callbackQueue, maximumDiagnosticBytes] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                callbackQueue.async {
                    buffers.stderrReachedEOF = true
                    self.finishIfReady(
                        buffers,
                        provider: plan.provider,
                        onEvent: onEvent
                    )
                }
                return
            }
            callbackQueue.async {
                if buffers.stderr.count < maximumDiagnosticBytes {
                    buffers.stderr.append(data.prefix(maximumDiagnosticBytes - buffers.stderr.count))
                }
            }
        }

        process.terminationHandler = { [callbackQueue] completed in
            let status = completed.terminationStatus
            callbackQueue.async {
                buffers.terminationStatus = status
                self.finishIfReady(
                    buffers,
                    provider: plan.provider,
                    onEvent: onEvent
                )
            }
        }

        try process.run()
        let running = RunningProviderProcess(
            provider: plan.provider,
            process: process,
            inputDelivery: inputDelivery
        )
        inputDelivery.start(promptData) { [callbackQueue] message in
            callbackQueue.async {
                guard !buffers.didEmitExit else { return }
                onEvent(.diagnostic(message))
            }
        }
        return running
    }

    /// Must only be called on `callbackQueue`. Process termination and pipe EOF
    /// are independent signals; waiting for all three preserves every final
    /// provider record while keeping `.exited` strictly last and single-shot.
    private func finishIfReady(
        _ buffers: ProviderStreamBufferState,
        provider: RuntimeProvider,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) {
        guard !buffers.didEmitExit,
              buffers.stdoutReachedEOF,
              buffers.stderrReachedEOF,
              let status = buffers.terminationStatus else { return }

        buffers.didEmitExit = true

        if !buffers.stdout.isEmpty {
            if buffers.stdout.count <= maximumLineBytes,
               let event = ProviderEventDecoder.decode(buffers.stdout, provider: provider) {
                onEvent(event)
            } else {
                onEvent(.diagnostic("Final provider event exceeded the 1 MiB safety bound and was discarded."))
            }
            buffers.stdout.removeAll(keepingCapacity: false)
        }

        if status != 0, !buffers.stderr.isEmpty {
            let diagnostic = String(decoding: buffers.stderr, as: UTF8.self)
            let sanitized = ProviderEventDecoder.sanitize(diagnostic)
            if !sanitized.isEmpty {
                onEvent(.diagnostic(sanitized))
            }
        }
        buffers.stderr.removeAll(keepingCapacity: false)
        onEvent(.exited(status))
    }
}

enum ProviderEventDecoder {
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\\u001B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\u0007]*(?:\\u0007|\\u001B\\\\))"
    )

    static func decode(_ data: Data, provider: RuntimeProvider) -> ProviderStreamEvent? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let plain = sanitize(String(decoding: data, as: UTF8.self))
            return plain.isEmpty ? nil : .diagnostic(plain)
        }

        switch provider {
        case .codex: return decodeCodex(object)
        case .claude: return decodeClaude(object)
        }
    }

    static func sanitize(_ value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutANSI = ansiPattern.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        let scalars = withoutANSI.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeCodex(_ object: [String: Any]) -> ProviderStreamEvent? {
        let type = object["type"] as? String ?? ""
        switch type {
        case "thread.started":
            return sessionEvent(object["thread_id"] as? String)
        case "item.completed":
            guard let item = object["item"] as? [String: Any] else { return nil }
            if item["type"] as? String == "agent_message", let text = item["text"] as? String {
                let clean = sanitize(text)
                return clean.isEmpty ? nil : .text(clean)
            }
            return activity(from: item)
        case "item.started", "item.updated":
            return (object["item"] as? [String: Any]).flatMap(activity(from:))
        case "turn.completed":
            return .activity("Turn completed")
        case "error":
            let message = (object["message"] as? String) ?? "Codex reported an error."
            return .diagnostic(sanitize(message))
        default:
            return nil
        }
    }

    private static func decodeClaude(_ object: [String: Any]) -> ProviderStreamEvent? {
        let type = object["type"] as? String ?? ""
        switch type {
        case "system":
            return sessionEvent(object["session_id"] as? String)
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            var textBlocks: [String] = []
            var toolNames: [String] = []
            for block in content {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    let clean = sanitize(text)
                    if !clean.isEmpty { textBlocks.append(clean) }
                }
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let clean = sanitize(name)
                    if !clean.isEmpty { toolNames.append(clean) }
                }
            }
            var events: [ProviderStreamEvent] = []
            if !textBlocks.isEmpty {
                events.append(.text(textBlocks.joined(separator: "\n\n")))
            }
            if !toolNames.isEmpty {
                events.append(.activity("Using \(toolNames.joined(separator: ", "))"))
            }
            if events.count == 1 { return events[0] }
            return events.isEmpty ? nil : .batch(events)
        case "result":
            if let result = object["result"] as? String {
                let clean = sanitize(result)
                return clean.isEmpty ? .activity("Turn completed") : .result(clean)
            }
            return .activity("Turn completed")
        case "error":
            return .diagnostic(sanitize((object["error"] as? String) ?? "Claude reported an error."))
        default:
            return nil
        }
    }

    private static func sessionEvent(_ candidate: String?) -> ProviderStreamEvent? {
        guard let candidate else { return nil }
        guard let identifier = UUID(uuidString: candidate) else {
            return .diagnostic("Provider reported an invalid session identifier; it was ignored.")
        }
        return .sessionID(identifier.uuidString.lowercased())
    }

    private static func activity(from item: [String: Any]) -> ProviderStreamEvent? {
        let type = item["type"] as? String ?? ""
        let label = (item["name"] as? String) ?? type.replacingOccurrences(of: "_", with: " ").capitalized
        let clean = sanitize(label)
        return clean.isEmpty ? nil : .activity(clean)
    }
}
