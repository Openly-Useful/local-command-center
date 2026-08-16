import Foundation
import XCTest
@testable import CommandCenter

final class SkillCatalogTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testScanRejectsLinkedSkillFilesAndDirectoriesOutsideConfiguredRoot() async throws {
        let root = try makeDirectory(prefix: "command-center-skills")
        let external = try makeDirectory(prefix: "command-center-external-skills")
        let safeDirectory = root.appendingPathComponent("safe", isDirectory: true)
        let linkedFileDirectory = root.appendingPathComponent("linked-file", isDirectory: true)
        let externalDirectory = external.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: linkedFileDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        try skill(named: "safe-skill").write(to: safeDirectory.appendingPathComponent("SKILL.md"))
        try skill(named: "escaped-file").write(to: external.appendingPathComponent("SKILL.md"))
        try skill(named: "escaped-directory").write(to: externalDirectory.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: linkedFileDirectory.appendingPathComponent("SKILL.md"),
            withDestinationURL: external.appendingPathComponent("SKILL.md")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-directory", isDirectory: true),
            withDestinationURL: externalDirectory
        )

        let catalog = SkillCatalog(roots: [.init(url: root, source: "Fixture")])
        let descriptors = await catalog.scan()

        XCTAssertEqual(descriptors.map(\.name), ["safe-skill"])
        XCTAssertTrue(descriptors.allSatisfy { $0.fileURL.path.hasPrefix(root.path + "/") })
    }

    private func makeDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryRoots.append(directory)
        return directory
    }

    private func skill(named name: String) -> Data {
        Data("---\nname: \(name)\ndescription: fixture\n---\n".utf8)
    }
}
