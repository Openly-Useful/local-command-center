import Foundation

struct ObsidianVaultDescriptor: Identifiable, Hashable, Sendable {
    var id: String { rootURL.path }
    let rootURL: URL
    let displayName: String
    let isOpen: Bool
}

enum ObsidianVaultRegistryError: LocalizedError, Equatable {
    case configurationIsNotARegularFile
    case configurationTooLarge
    case malformedConfiguration

    var errorDescription: String? {
        switch self {
        case .configurationIsNotARegularFile:
            return "The Obsidian vault registry is not a regular local file."
        case .configurationTooLarge:
            return "The Obsidian vault registry exceeds the 1 MiB safety limit."
        case .malformedConfiguration:
            return "The Obsidian vault registry is malformed."
        }
    }
}

/// Reads only Obsidian's small vault registry. It never enumerates a vault or
/// opens any note inside one.
struct ObsidianVaultRegistry: Sendable {
    static let maximumConfigurationBytes = 1_048_576
    static let maximumVaults = 32

    let configurationURL: URL

    init(configurationURL: URL? = nil) {
        self.configurationURL = configurationURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    func discoverVaults() throws -> [ObsidianVaultDescriptor] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: configurationURL.path) else { return [] }

        let values: URLResourceValues
        do {
            values = try configurationURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw ObsidianVaultRegistryError.configurationIsNotARegularFile
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ObsidianVaultRegistryError.configurationIsNotARegularFile
        }
        guard let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumConfigurationBytes else {
            throw ObsidianVaultRegistryError.configurationTooLarge
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: configurationURL)
        } catch {
            throw ObsidianVaultRegistryError.configurationIsNotARegularFile
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maximumConfigurationBytes + 1) ?? Data()
        } catch {
            throw ObsidianVaultRegistryError.malformedConfiguration
        }
        guard data.count <= Self.maximumConfigurationBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVaults = root["vaults"] as? [String: Any] else {
            if data.count > Self.maximumConfigurationBytes {
                throw ObsidianVaultRegistryError.configurationTooLarge
            }
            throw ObsidianVaultRegistryError.malformedConfiguration
        }

        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        var seenPaths: Set<String> = []
        var discovered: [ObsidianVaultDescriptor] = []

        for key in rawVaults.keys.sorted() {
            guard discovered.count < Self.maximumVaults,
                  let raw = rawVaults[key] as? [String: Any],
                  let path = raw["path"] as? String,
                  !path.isEmpty,
                  path.utf8.count <= 16_384,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  path.hasPrefix("/") else { continue }

            let candidate = URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard candidate.path != "/", candidate.path != home.path else { continue }
            guard seenPaths.insert(candidate.path).inserted else { continue }

            guard let candidateValues = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .volumeIsLocalKey,
            ]),
            candidateValues.isDirectory == true,
            candidateValues.volumeIsLocal != false else { continue }

            let fallbackName = candidate.lastPathComponent
            let rawName = raw["name"] as? String ?? fallbackName
            let displayName = Self.safeDisplayName(rawName, fallback: fallbackName)
            discovered.append(ObsidianVaultDescriptor(
                rootURL: candidate,
                displayName: displayName,
                isOpen: raw["open"] as? Bool ?? false
            ))
        }

        return discovered.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return nameOrder == .orderedSame ? $0.rootURL.path < $1.rootURL.path : nameOrder == .orderedAscending
        }
    }

    private static func safeDisplayName(_ value: String, fallback: String) -> String {
        let inputPrefix = String(value.unicodeScalars.prefix(512))
        let normalized = inputPrefix.precomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let bounded = String(String.UnicodeScalarView(normalized.prefix(128)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !bounded.isEmpty { return bounded }
        let fallbackPrefix = String(fallback.unicodeScalars.prefix(128))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackPrefix.isEmpty ? "Obsidian vault" : fallbackPrefix
    }
}
