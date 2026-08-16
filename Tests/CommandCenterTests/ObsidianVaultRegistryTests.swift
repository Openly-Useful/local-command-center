import Foundation
import XCTest
@testable import CommandCenter

final class ObsidianVaultRegistryTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testMissingRegistryReturnsNoVaults() throws {
        let root = try makeTemporaryDirectory()
        let registry = ObsidianVaultRegistry(configurationURL: root.appendingPathComponent("missing.json"))
        XCTAssertEqual(try registry.discoverVaults(), [])
    }

    func testDiscoversOneNormalizedExistingLocalVault() throws {
        let root = try makeTemporaryDirectory()
        let vault = root.appendingPathComponent("My Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
        let registryURL = root.appendingPathComponent("obsidian.json")
        try writeRegistry([
            "primary": ["path": vault.appendingPathComponent("..").appendingPathComponent("My Vault").path, "open": true],
        ], to: registryURL)

        let result = try ObsidianVaultRegistry(configurationURL: registryURL).discoverVaults()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rootURL, vault.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(result[0].displayName, "My Vault")
        XCTAssertTrue(result[0].isOpen)
    }

    func testMalformedAndOversizedRegistriesAreRejected() throws {
        let root = try makeTemporaryDirectory()
        let malformed = root.appendingPathComponent("malformed.json")
        try Data("not json".utf8).write(to: malformed)
        XCTAssertThrowsError(try ObsidianVaultRegistry(configurationURL: malformed).discoverVaults()) {
            XCTAssertEqual($0 as? ObsidianVaultRegistryError, .malformedConfiguration)
        }

        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: ObsidianVaultRegistry.maximumConfigurationBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try ObsidianVaultRegistry(configurationURL: oversized).discoverVaults()) {
            XCTAssertEqual($0 as? ObsidianVaultRegistryError, .configurationTooLarge)
        }

        let directory = root.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ObsidianVaultRegistry(configurationURL: directory).discoverVaults()) {
            XCTAssertEqual($0 as? ObsidianVaultRegistryError, .configurationIsNotARegularFile)
        }

        let regularTarget = root.appendingPathComponent("real-registry.json")
        try writeRegistry([:], to: regularTarget)
        let symbolicRegistry = root.appendingPathComponent("linked-registry.json")
        try FileManager.default.createSymbolicLink(at: symbolicRegistry, withDestinationURL: regularTarget)
        XCTAssertThrowsError(try ObsidianVaultRegistry(configurationURL: symbolicRegistry).discoverVaults()) {
            XCTAssertEqual($0 as? ObsidianVaultRegistryError, .configurationIsNotARegularFile)
        }
    }

    func testDeduplicatesAndExcludesUnsafeOrMissingVaultRoots() throws {
        let root = try makeTemporaryDirectory()
        let vault = root.appendingPathComponent("Accepted", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        let registryURL = root.appendingPathComponent("obsidian.json")
        try writeRegistry([
            "a": ["path": vault.path, "open": true],
            "b": ["path": vault.appendingPathComponent(".").path, "open": false],
            "c": ["path": "/", "open": false],
            "d": ["path": FileManager.default.homeDirectoryForCurrentUser.path, "open": false],
            "e": ["path": missing.path, "open": false],
            "f": ["path": "relative/vault", "open": false],
        ], to: registryURL)

        let result = try ObsidianVaultRegistry(configurationURL: registryURL).discoverVaults()
        XCTAssertEqual(result.map(\.rootURL), [vault.resolvingSymlinksInPath().standardizedFileURL])
    }

    func testRegistryOutputIsCappedAtThirtyTwoVaultsAndDisplayNamesAreBounded() throws {
        let root = try makeTemporaryDirectory()
        var entries: [String: Any] = [:]
        for index in 0..<40 {
            let vault = root.appendingPathComponent("Vault-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
            entries[String(format: "%02d", index)] = [
                "path": vault.path,
                "name": String(repeating: "A", count: 200) + "\u{0007}",
                "open": false,
            ]
        }
        let registryURL = root.appendingPathComponent("obsidian.json")
        try writeRegistry(entries, to: registryURL)

        let result = try ObsidianVaultRegistry(configurationURL: registryURL).discoverVaults()
        XCTAssertEqual(result.count, ObsidianVaultRegistry.maximumVaults)
        XCTAssertTrue(result.allSatisfy { $0.displayName.unicodeScalars.count == 128 })
        XCTAssertTrue(result.allSatisfy { !$0.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-center-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryRoots.append(root)
        return root
    }

    private func writeRegistry(_ vaults: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["vaults": vaults], options: [.sortedKeys])
        try data.write(to: url)
    }
}
