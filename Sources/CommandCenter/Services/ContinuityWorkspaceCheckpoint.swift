import CryptoKit
import Foundation

/// A bounded, read-only description of the Git state used to gate a
/// continuity handoff. It intentionally contains repository facts only; it
/// never includes provider output, session identifiers, or transcript data.
struct ContinuityWorkspaceCheckpoint: Sendable, Equatable {
    enum HeadState: Sendable, Equatable {
        case branch(String)
        case detached
    }

    struct Change: Sendable, Equatable {
        enum Ownership: Sendable, Equatable {
            case owned
            case unowned
        }

        /// The two-character porcelain-v1 status, for example `" M"` or `"??"`.
        let status: String
        let path: String
        /// Present for a rename or copy. Both paths must be owned for the
        /// change to be considered owned.
        let originalPath: String?
        let ownership: Ownership

        var paths: [String] {
            [path] + (originalPath.map { [$0] } ?? [])
        }

        var isUntracked: Bool { status == "??" }
    }

    let workspacePath: String
    let commit: String
    let headState: HeadState
    /// Lowercase SHA-256 of Git's bounded `status --porcelain=v1 -z` bytes.
    let statusDigest: String
    let changes: [Change]

    var isClean: Bool { changes.isEmpty }
    var hasUnownedChanges: Bool { changes.contains { $0.ownership == .unowned } }
    /// An unowned change means the handoff must not proceed automatically.
    var blocksHandoff: Bool { hasUnownedChanges }
    var changedPaths: [String] { changes.flatMap(\.paths) }
}

struct ContinuityWorkspaceCheckpointLimits: Sendable, Equatable {
    static let standard = Self()

    let maximumProcessOutputBytes: Int
    let maximumProcessDuration: TimeInterval
    let maximumChangedPaths: Int
    let maximumPathBytes: Int
    let maximumOwnedPaths: Int

    init(
        maximumProcessOutputBytes: Int = 64 * 1_024,
        maximumProcessDuration: TimeInterval = 4,
        maximumChangedPaths: Int = 512,
        maximumPathBytes: Int = 1_024,
        maximumOwnedPaths: Int = 256
    ) {
        self.maximumProcessOutputBytes = max(1, maximumProcessOutputBytes)
        self.maximumProcessDuration = max(0.01, maximumProcessDuration)
        self.maximumChangedPaths = max(1, maximumChangedPaths)
        self.maximumPathBytes = max(1, maximumPathBytes)
        self.maximumOwnedPaths = max(1, maximumOwnedPaths)
    }
}

enum ContinuityWorkspaceCheckpointError: LocalizedError, Sendable, Equatable {
    case invalidWorkspace
    case invalidOwnedPath
    case commandFailed
    case commandTimedOut
    case commandOutputExceeded
    case malformedRepositoryStatus
    case unsafeRepositoryPath
    case invalidRepositoryMetadata

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            return "The approved workspace is not an existing non-symlink folder."
        case .invalidOwnedPath:
            return "An owned path is not a safe workspace-relative path."
        case .commandFailed:
            return "Git could not inspect the approved workspace."
        case .commandTimedOut:
            return "Git workspace inspection exceeded its time limit."
        case .commandOutputExceeded:
            return "Git workspace inspection exceeded its output limit."
        case .malformedRepositoryStatus:
            return "Git returned a malformed workspace status."
        case .unsafeRepositoryPath:
            return "Git returned an unsafe or oversized changed path."
        case .invalidRepositoryMetadata:
            return "Git returned invalid repository metadata."
        }
    }
}

/// Inspects Git through a fixed executable and an argument array. It never
/// creates a shell, changes the workspace, or accepts an executable from a
/// caller.
struct ContinuityWorkspaceCheckpointInspector: Sendable {
    private static let gitExecutableURL = URL(fileURLWithPath: "/usr/bin/git")

    let limits: ContinuityWorkspaceCheckpointLimits

    init(limits: ContinuityWorkspaceCheckpointLimits = .standard) {
        self.limits = limits
    }

    func inspect(
        approvedWorkspaceURL: URL,
        ownedPaths: Set<String>
    ) throws -> ContinuityWorkspaceCheckpoint {
        let workspaceURL = try validatedWorkspaceURL(approvedWorkspaceURL)
        guard ownedPaths.count <= limits.maximumOwnedPaths else {
            throw ContinuityWorkspaceCheckpointError.invalidOwnedPath
        }
        for path in ownedPaths {
            guard isSafeRelativePath(path, maximumBytes: limits.maximumPathBytes) else {
                throw ContinuityWorkspaceCheckpointError.invalidOwnedPath
            }
        }

        let status = try runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: workspaceURL
        ).stdout
        let changes = try parseStatus(status, ownedPaths: ownedPaths)

        let commitOutput = try runGit(["rev-parse", "--verify", "HEAD^{commit}"], in: workspaceURL).stdout
        let commit = try singleMetadataLine(commitOutput)
        guard commit.count == 40,
              commit.allSatisfy({ $0.isHexDigit }) else {
            throw ContinuityWorkspaceCheckpointError.invalidRepositoryMetadata
        }

        let branchResult = try runGit(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: workspaceURL,
            permittedExitStatuses: [0, 1]
        )
        let headState: ContinuityWorkspaceCheckpoint.HeadState
        if branchResult.status == 0 {
            let branch = try singleMetadataLine(branchResult.stdout)
            guard isSafeMetadata(branch) else {
                throw ContinuityWorkspaceCheckpointError.invalidRepositoryMetadata
            }
            headState = .branch(branch)
        } else {
            guard branchResult.stdout.isEmpty else {
                throw ContinuityWorkspaceCheckpointError.invalidRepositoryMetadata
            }
            headState = .detached
        }

        let digest = SHA256.hash(data: status).map { String(format: "%02x", $0) }.joined()
        return ContinuityWorkspaceCheckpoint(
            workspacePath: workspaceURL.path,
            commit: commit,
            headState: headState,
            statusDigest: digest,
            changes: changes
        )
    }

    private func parseStatus(
        _ status: Data,
        ownedPaths: Set<String>
    ) throws -> [ContinuityWorkspaceCheckpoint.Change] {
        guard status.count <= limits.maximumProcessOutputBytes else {
            throw ContinuityWorkspaceCheckpointError.commandOutputExceeded
        }
        guard status.isEmpty || status.last == 0 else {
            throw ContinuityWorkspaceCheckpointError.malformedRepositoryStatus
        }

        let records = status.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var changes: [ContinuityWorkspaceCheckpoint.Change] = []
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }
            guard record.count >= 4,
                  record[record.startIndex + 2] == 0x20,
                  let statusCode = String(data: record.prefix(2), encoding: .ascii),
                  isValidStatusCode(statusCode),
                  let path = String(data: record.dropFirst(3), encoding: .utf8),
                  isSafeRelativePath(path, maximumBytes: limits.maximumPathBytes) else {
                throw ContinuityWorkspaceCheckpointError.unsafeRepositoryPath
            }

            let isRenameOrCopy = statusCode.contains("R") || statusCode.contains("C")
            let originalPath: String?
            if isRenameOrCopy {
                guard index < records.count,
                      !records[index].isEmpty,
                      let original = String(data: records[index], encoding: .utf8),
                      isSafeRelativePath(original, maximumBytes: limits.maximumPathBytes) else {
                    throw ContinuityWorkspaceCheckpointError.malformedRepositoryStatus
                }
                originalPath = original
                index += 1
            } else {
                originalPath = nil
            }

            guard changes.count < limits.maximumChangedPaths else {
                throw ContinuityWorkspaceCheckpointError.commandOutputExceeded
            }
            let isOwned = ownedPaths.contains(path)
                && (originalPath.map { ownedPaths.contains($0) } ?? true)
            changes.append(.init(
                status: statusCode,
                path: path,
                originalPath: originalPath,
                ownership: isOwned ? .owned : .unowned
            ))
        }
        return changes
    }

    private func runGit(
        _ arguments: [String],
        in workspaceURL: URL,
        permittedExitStatuses: Set<Int32> = [0]
    ) throws -> GitCommandResult {
        _ = try validatedWorkspaceURL(workspaceURL)
        guard FileManager.default.isExecutableFile(atPath: Self.gitExecutableURL.path) else {
            throw ContinuityWorkspaceCheckpointError.commandFailed
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = BoundedProcessOutput(maximumBytes: limits.maximumProcessOutputBytes)
        let termination = ProcessTermination()
        let readers = DispatchGroup()
        let readerQueue = DispatchQueue(label: "local.commandcenter.continuity-git-reader", qos: .userInitiated, attributes: .concurrent)

        process.executableURL = Self.gitExecutableURL
        process.arguments = [
            "--no-optional-locks",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "submodule.recurse=false",
            "-C", workspaceURL.path,
        ] + arguments
        process.currentDirectoryURL = workspaceURL
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        process.terminationHandler = { finished in
            termination.finish(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ContinuityWorkspaceCheckpointError.commandFailed
        }

        read(stdout.fileHandleForReading, into: output, isStandardError: false, process: process, group: readers, queue: readerQueue)
        read(stderr.fileHandleForReading, into: output, isStandardError: true, process: process, group: readers, queue: readerQueue)

        let completed = termination.wait(timeout: limits.maximumProcessDuration)
        if !completed {
            process.terminate()
            _ = termination.wait(timeout: 1)
            _ = readers.wait(timeout: .now() + 1)
            throw ContinuityWorkspaceCheckpointError.commandTimedOut
        }
        guard readers.wait(timeout: .now() + 1) == .success else {
            throw ContinuityWorkspaceCheckpointError.commandTimedOut
        }

        if output.hasExceededLimit {
            throw ContinuityWorkspaceCheckpointError.commandOutputExceeded
        }
        guard let status = termination.completedStatus, permittedExitStatuses.contains(status) else {
            throw ContinuityWorkspaceCheckpointError.commandFailed
        }
        let captured = output.snapshot()
        return GitCommandResult(status: status, stdout: captured.stdout, stderr: captured.stderr)
    }

    private func read(
        _ handle: FileHandle,
        into output: BoundedProcessOutput,
        isStandardError: Bool,
        process: Process,
        group: DispatchGroup,
        queue: DispatchQueue
    ) {
        group.enter()
        queue.async {
            defer { group.leave() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if output.append(data, isStandardError: isStandardError) {
                    process.terminate()
                }
            }
        }
    }

    private func validatedWorkspaceURL(_ workspaceURL: URL) throws -> URL {
        guard workspaceURL.isFileURL,
              !containsControlCharacter(workspaceURL.path),
              !workspaceURL.pathComponents.contains("..") else {
            throw ContinuityWorkspaceCheckpointError.invalidWorkspace
        }
        let approved = workspaceURL.standardizedFileURL
        let resolved = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        guard approved.path != "/",
              approved.path == resolved.path,
              let values = try? approved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw ContinuityWorkspaceCheckpointError.invalidWorkspace
        }
        return approved
    }

    private func singleMetadataLine(_ data: Data) throws -> String {
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContinuityWorkspaceCheckpointError.invalidRepositoryMetadata
        }
        let line = output.trimmingCharacters(in: .newlines)
        guard !line.isEmpty,
              output == line + "\n",
              isSafeMetadata(line) else {
            throw ContinuityWorkspaceCheckpointError.invalidRepositoryMetadata
        }
        return line
    }

    private func isSafeMetadata(_ value: String) -> Bool {
        !value.isEmpty
            && value.lengthOfBytes(using: .utf8) <= limits.maximumPathBytes
            && !containsControlCharacter(value)
    }

    private func isSafeRelativePath(_ path: String, maximumBytes: Int) -> Bool {
        guard !path.isEmpty,
              path.lengthOfBytes(using: .utf8) <= maximumBytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("-"),
              !path.contains("\\"),
              !containsControlCharacter(path) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func isValidStatusCode(_ value: String) -> Bool {
        guard value.count == 2 else { return false }
        let allowed = Set(" MADRCU?!")
        return value.allSatisfy { allowed.contains($0) }
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}

private struct GitCommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var status: Int32?

    func finish(status: Int32) {
        lock.lock()
        self.status = status
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    var completedStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var stdout = Data()
    private var stderr = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    /// Returns true when the caller should terminate the child process.
    func append(_ data: Data, isStandardError: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return true }
        guard stdout.count + stderr.count + data.count <= maximumBytes else {
            exceededLimit = true
            return true
        }
        if isStandardError {
            stderr.append(data)
        } else {
            stdout.append(data)
        }
        return false
    }

    var hasExceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
