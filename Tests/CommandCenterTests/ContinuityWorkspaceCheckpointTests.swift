import Foundation
import XCTest
@testable import CommandCenter

final class ContinuityWorkspaceCheckpointTests: XCTestCase {
    func testCleanRepositoryRecordsCommitBranchAndEmptyStatus() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }

        let checkpoint = try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["owned.txt"]
        )

        XCTAssertTrue(checkpoint.isClean)
        XCTAssertFalse(checkpoint.hasUnownedChanges)
        XCTAssertFalse(checkpoint.blocksHandoff)
        XCTAssertEqual(checkpoint.changedPaths, [])
        XCTAssertEqual(checkpoint.commit.count, 40)
        guard case .branch(let branch) = checkpoint.headState else {
            return XCTFail("A newly created repository should be on a branch.")
        }
        XCTAssertFalse(branch.isEmpty)

        try git(["checkout", "--detach", "-q"], in: repository)
        let detached = try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["owned.txt"]
        )
        XCTAssertEqual(detached.headState, .detached)
    }

    func testOwnedDirtyChangeDoesNotBlockHandoff() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }
        try write("changed\n", to: repository.appendingPathComponent("owned.txt"))

        let checkpoint = try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["owned.txt"]
        )

        XCTAssertFalse(checkpoint.isClean)
        XCTAssertFalse(checkpoint.hasUnownedChanges)
        XCTAssertFalse(checkpoint.blocksHandoff)
        XCTAssertEqual(checkpoint.changes.count, 1)
        XCTAssertEqual(checkpoint.changes[0].path, "owned.txt")
        XCTAssertEqual(checkpoint.changes[0].ownership, .owned)
    }

    func testUnownedDirtyChangeBlocksHandoff() throws {
        let repository = try makeRepository(files: [
            "owned.txt": "initial\n",
            "other.txt": "initial\n",
        ])
        defer { remove(repository) }
        try write("changed\n", to: repository.appendingPathComponent("other.txt"))

        let checkpoint = try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["owned.txt"]
        )

        XCTAssertTrue(checkpoint.hasUnownedChanges)
        XCTAssertTrue(checkpoint.blocksHandoff)
        XCTAssertEqual(checkpoint.changes.first?.path, "other.txt")
        XCTAssertEqual(checkpoint.changes.first?.ownership, .unowned)
    }

    func testUntrackedFilesAreIncludedAndClassified() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }
        try write("new\n", to: repository.appendingPathComponent("new-owned.txt"))

        let checkpoint = try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["owned.txt", "new-owned.txt"]
        )

        XCTAssertEqual(checkpoint.changes.count, 1)
        XCTAssertEqual(checkpoint.changes[0].status, "??")
        XCTAssertTrue(checkpoint.changes[0].isUntracked)
        XCTAssertEqual(checkpoint.changes[0].ownership, .owned)
        XCTAssertFalse(checkpoint.blocksHandoff)
    }

    func testTraversalAndSymlinkWorkspacesAreRejected() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }
        let link = repository.appendingPathComponent("workspace-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository)

        let inspector = ContinuityWorkspaceCheckpointInspector()
        XCTAssertThrowsError(try inspector.inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["../outside.txt"]
        )) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .invalidOwnedPath)
        }
        XCTAssertThrowsError(try inspector.inspect(
            approvedWorkspaceURL: repository,
            ownedPaths: ["line\nbreak.txt"]
        )) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .invalidOwnedPath)
        }
        XCTAssertThrowsError(try inspector.inspect(
            approvedWorkspaceURL: link,
            ownedPaths: []
        )) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .invalidWorkspace)
        }
    }

    func testStatusDigestIsDeterministicAndTracksStatusChanges() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }
        try write("changed\n", to: repository.appendingPathComponent("owned.txt"))
        let inspector = ContinuityWorkspaceCheckpointInspector()

        let first = try inspector.inspect(approvedWorkspaceURL: repository, ownedPaths: ["owned.txt"])
        let second = try inspector.inspect(approvedWorkspaceURL: repository, ownedPaths: ["owned.txt"])
        XCTAssertEqual(first.statusDigest, second.statusDigest)
        XCTAssertEqual(first.statusDigest.count, 64)

        try write("new\n", to: repository.appendingPathComponent("another.txt"))
        let third = try inspector.inspect(approvedWorkspaceURL: repository, ownedPaths: ["owned.txt"])
        XCTAssertNotEqual(first.statusDigest, third.statusDigest)
    }

    func testOutputAndPathBoundsFailClosed() throws {
        let repository = try makeRepository(files: ["owned.txt": "initial\n"])
        defer { remove(repository) }
        let longName = "this-path-is-deliberately-long.txt"
        try write("new\n", to: repository.appendingPathComponent(longName))

        let outputBounded = ContinuityWorkspaceCheckpointInspector(limits: .init(
            maximumProcessOutputBytes: 8,
            maximumProcessDuration: 4,
            maximumChangedPaths: 8,
            maximumPathBytes: 128,
            maximumOwnedPaths: 8
        ))
        XCTAssertThrowsError(try outputBounded.inspect(approvedWorkspaceURL: repository, ownedPaths: [])) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .commandOutputExceeded)
        }

        let pathBounded = ContinuityWorkspaceCheckpointInspector(limits: .init(
            maximumProcessOutputBytes: 4_096,
            maximumProcessDuration: 4,
            maximumChangedPaths: 8,
            maximumPathBytes: 8,
            maximumOwnedPaths: 8
        ))
        XCTAssertThrowsError(try pathBounded.inspect(approvedWorkspaceURL: repository, ownedPaths: [])) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .unsafeRepositoryPath)
        }
    }

    func testGitCommandFailureFailsClosedForNonRepository() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { remove(directory) }

        XCTAssertThrowsError(try ContinuityWorkspaceCheckpointInspector().inspect(
            approvedWorkspaceURL: directory,
            ownedPaths: []
        )) { error in
            XCTAssertEqual(error as? ContinuityWorkspaceCheckpointError, .commandFailed)
        }
    }

    private func makeRepository(files: [String: String]) throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repository)
        try git(["config", "user.email", "checkpoint-tests@example.invalid"], in: repository)
        try git(["config", "user.name", "Checkpoint Tests"], in: repository)
        for (path, contents) in files {
            try write(contents, to: repository.appendingPathComponent(path))
        }
        try git(["add", "."], in: repository)
        try git(["commit", "-q", "-m", "fixture"], in: repository)
        return repository
    }

    private func git(_ arguments: [String], in repository: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ContinuityWorkspaceCheckpointTests", code: Int(process.terminationStatus))
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        guard let data = contents.data(using: .utf8) else {
            throw NSError(domain: "ContinuityWorkspaceCheckpointTests", code: 1)
        }
        try data.write(to: url)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
