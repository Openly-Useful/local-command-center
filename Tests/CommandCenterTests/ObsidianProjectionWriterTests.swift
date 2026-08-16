import Foundation
import XCTest
@testable import CommandCenter

final class ObsidianProjectionWriterTests: XCTestCase {
    private var temporaryRoots: [URL] = []
    private let sessionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let projectID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testWritesOnlyExpectedMetadataProjectionWithSafeNamesAndEscapes() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let session = projection(
            title: "Unsafe ]] | title\nnext",
            status: "ready\u{0007}",
            projectName: "Project [[ | link"
        )

        let result = try writer.write(sessions: [session])
        XCTAssertEqual(result.writtenFiles, 4)
        XCTAssertEqual(result.unchangedFiles, 0)
        XCTAssertEqual(result.missingSessions, 0)

        let managed = vault.appendingPathComponent("Command Center")
        let sessionURL = managed.appendingPathComponent("Sessions/Codex/\(sessionID.uuidString.lowercased()).md")
        let projectURL = managed.appendingPathComponent("Projects/\(projectID.uuidString.lowercased()).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("Home.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("_data/manifest.json").path))

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: managed.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)

        let sessionText = try String(contentsOf: sessionURL, encoding: .utf8)
        XCTAssertTrue(sessionText.contains("command_center_managed: true"))
        XCTAssertTrue(sessionText.contains("schema: 1"))
        XCTAssertTrue(sessionText.contains("provider: \"Codex\""))
        XCTAssertFalse(sessionText.contains("\u{0007}"))
        XCTAssertFalse(sessionText.contains("/Users/"))
        XCTAssertEqual(sessionURL.lastPathComponent, "\(sessionID.uuidString.lowercased()).md")

        let homeText = try String(contentsOf: managed.appendingPathComponent("Home.md"), encoding: .utf8)
        XCTAssertTrue(homeText.contains("Unsafe ］］ ¦ titlenext"))
        XCTAssertTrue(homeText.contains("Project ［［ ¦ link"))
        XCTAssertFalse(homeText.contains("Unsafe ]] |"))
    }

    func testAbsolutePathLikeNamesAreNotProjected() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let sourcePath = ["", "Users", "fixture-owner", "Secret Workspace"].joined(separator: "/")
        let session = projection(title: sourcePath, projectName: sourcePath)
        try writer.write(sessions: [session])

        for url in knownOutputURLs(vault: vault, sessions: [session]) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.contains(sourcePath), "Absolute path leaked into \(url.lastPathComponent)")
            XCTAssertFalse(contents.contains(["", "Users", "fixture-owner"].joined(separator: "/")))
        }
    }

    func testOutputIsDeterministicAcrossFreshVaults() throws {
        let firstVault = try makeVault()
        let secondVault = try makeVault()
        let sessions = [
            projection(),
            projection(id: secondSessionID, provider: "Claude", title: "Claude review", parentID: sessionID),
        ]
        try ObsidianProjectionWriter(vaultURL: firstVault).write(sessions: sessions)
        try ObsidianProjectionWriter(vaultURL: secondVault).write(sessions: Array(sessions.reversed()))

        let relativePaths = [
            "Home.md",
            "Sessions/Codex/\(sessionID.uuidString.lowercased()).md",
            "Sessions/Claude/\(secondSessionID.uuidString.lowercased()).md",
            "Projects/\(projectID.uuidString.lowercased()).md",
            "_data/manifest.json",
        ]
        for path in relativePaths {
            let first = try Data(contentsOf: firstVault.appendingPathComponent("Command Center/\(path)"))
            let second = try Data(contentsOf: secondVault.appendingPathComponent("Command Center/\(path)"))
            XCTAssertEqual(first, second, "Projection differed for \(path)")
        }
    }

    func testUnchangedDigestPreservesFilesAndReportsZeroWrites() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let sessions = [projection()]
        try writer.write(sessions: sessions)
        let target = vault.appendingPathComponent("Command Center/Sessions/Codex/\(sessionID.uuidString.lowercased()).md")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)

        let result = try writer.write(sessions: sessions)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)

        XCTAssertEqual(result.writtenFiles, 0)
        XCTAssertEqual(result.unchangedFiles, 4)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testTamperedManagedNoteIsDetectedAndRepairedDespiteManifestDigest() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let sessions = [projection()]
        try writer.write(sessions: sessions)
        let target = vault.appendingPathComponent(
            "Command Center/Sessions/Codex/\(sessionID.uuidString.lowercased()).md"
        )
        let expected = try Data(contentsOf: target)
        var tampered = expected
        tampered[tampered.startIndex] ^= 0x01
        try tampered.write(to: target)

        let result = try writer.write(sessions: sessions)

        XCTAssertEqual(result.writtenFiles, 1)
        XCTAssertEqual(try Data(contentsOf: target), expected)
    }

    func testMissingSessionIsMarkedButItsNoteIsNeverDeleted() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let first = projection()
        let missing = projection(id: secondSessionID, provider: "Claude", title: "Keep me")
        try writer.write(sessions: [first, missing])
        let missingURL = vault.appendingPathComponent("Command Center/Sessions/Claude/\(secondSessionID.uuidString.lowercased()).md")
        let original = try Data(contentsOf: missingURL)

        let result = try writer.write(sessions: [first])
        XCTAssertEqual(result.missingSessions, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertEqual(try Data(contentsOf: missingURL), original)
        let manifest = try String(contentsOf: vault.appendingPathComponent("Command Center/_data/manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("Sessions/Claude/\(secondSessionID.uuidString.lowercased()).md"))
        XCTAssertTrue(manifest.contains("\"missing\" : true"))
    }

    func testManagedSubtreeSymlinkEscapeIsRejectedWithoutExternalWrites() throws {
        let vault = try makeVault()
        let external = try makeTemporaryDirectory(prefix: "command-center-external")
        let managed = vault.appendingPathComponent("Command Center")
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: external)

        XCTAssertThrowsError(try ObsidianProjectionWriter(vaultURL: vault))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testNestedSymlinkReplacementIsRejectedAndLeavesNoTemporaryFiles() throws {
        let vault = try makeVault()
        let external = try makeTemporaryDirectory(prefix: "command-center-external")
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        try writer.write(sessions: [])
        let codexDirectory = vault.appendingPathComponent("Command Center/Sessions/Codex")
        try FileManager.default.removeItem(at: codexDirectory)
        try FileManager.default.createSymbolicLink(at: codexDirectory, withDestinationURL: external)

        XCTAssertThrowsError(try writer.write(sessions: [projection()]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertTrue(try temporaryFiles(beneath: vault.appendingPathComponent("Command Center")).isEmpty)
    }

    func testWriterStaysAnchoredToOriginalVaultAfterPathReplacement() throws {
        let vault = try makeVault()
        let external = try makeTemporaryDirectory(prefix: "command-center-external")
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let movedVault = vault.deletingLastPathComponent()
            .appendingPathComponent("command-center-moved-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(movedVault)

        try FileManager.default.moveItem(at: vault, to: movedVault)
        try FileManager.default.createSymbolicLink(at: vault, withDestinationURL: external)

        try writer.write(sessions: [projection()])

        let projected = movedVault.appendingPathComponent(
            "Command Center/Sessions/Codex/\(sessionID.uuidString.lowercased()).md"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: projected.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testUnmanagedFileCollisionIsNeverOverwritten() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let home = vault.appendingPathComponent("Command Center/Home.md")
        let original = Data("owner note".utf8)
        try original.write(to: home)

        XCTAssertThrowsError(try writer.write(sessions: [projection()])) {
            XCTAssertEqual($0 as? ObsidianProjectionError, .unmanagedCollision("Home.md"))
        }
        XCTAssertEqual(try Data(contentsOf: home), original)
    }

    func testDanglingSymlinkCollisionIsRejectedAndNotReplaced() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let home = vault.appendingPathComponent("Command Center/Home.md")
        let missingTarget = vault.appendingPathComponent("does-not-exist.md")
        try FileManager.default.createSymbolicLink(
            at: home,
            withDestinationURL: missingTarget
        )

        XCTAssertThrowsError(try writer.write(sessions: [projection()])) {
            XCTAssertEqual($0 as? ObsidianProjectionError, .unmanagedCollision("Home.md"))
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: home.path),
            missingTarget.path
        )
    }

    func testSessionLimitAndStringBoundsAreEnforced() throws {
        let vault = try makeVault()
        let writer = try ObsidianProjectionWriter(vaultURL: vault)
        let tooMany = (0...ObsidianProjectionWriter.maximumSessions).map { index in
            ObsidianSessionProjection(
                id: UUID(),
                providerDisplay: index.isMultiple(of: 2) ? "Codex" : "Claude",
                title: "Session",
                status: "ready",
                sourceUpdatedAt: Date(timeIntervalSince1970: 1_723_500_000),
                resumable: true
            )
        }
        XCTAssertThrowsError(try writer.write(sessions: tooMany)) {
            XCTAssertEqual($0 as? ObsidianProjectionError, .tooManySessions)
        }

        let longTitle = String(repeating: "x", count: 400)
        try writer.write(sessions: [projection(title: longTitle)])
        let file = vault.appendingPathComponent("Command Center/Sessions/Codex/\(sessionID.uuidString.lowercased()).md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"\(String(repeating: "x", count: 160))\""))
        XCTAssertFalse(text.contains(String(repeating: "x", count: 161)))
    }

    private func projection(
        id: UUID? = nil,
        provider: String = "Codex",
        title: String = "Session title",
        status: String = "ready",
        projectName: String = "Local project",
        parentID: UUID? = nil
    ) -> ObsidianSessionProjection {
        ObsidianSessionProjection(
            id: id ?? sessionID,
            providerDisplay: provider,
            title: title,
            status: status,
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_723_500_000.125),
            projectID: projectID,
            projectName: projectName,
            parentID: parentID,
            resumable: true
        )
    }

    private func makeVault() throws -> URL {
        try makeTemporaryDirectory(prefix: "command-center-vault")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryRoots.append(root)
        return root
    }

    private func knownOutputURLs(vault: URL, sessions: [ObsidianSessionProjection]) -> [URL] {
        var paths = ["Command Center/Home.md", "Command Center/_data/manifest.json"]
        for session in sessions {
            paths.append("Command Center/Sessions/\(session.providerDisplay)/\(session.id.uuidString.lowercased()).md")
            if let projectID = session.projectID {
                paths.append("Command Center/Projects/\(projectID.uuidString.lowercased()).md")
            }
        }
        return Array(Set(paths)).sorted().map { vault.appendingPathComponent($0) }
    }

    private func temporaryFiles(beneath root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(".tmp") }
    }
}
