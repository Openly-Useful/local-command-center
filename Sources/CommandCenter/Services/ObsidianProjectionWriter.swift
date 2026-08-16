import CryptoKit
import Darwin
import Foundation

struct ObsidianSessionProjection: Equatable, Sendable {
    let id: UUID
    let providerDisplay: String
    let title: String
    let status: String
    let sourceUpdatedAt: Date
    let projectID: UUID?
    let projectName: String?
    let parentID: UUID?
    let resumable: Bool

    init(
        id: UUID,
        providerDisplay: String,
        title: String,
        status: String,
        sourceUpdatedAt: Date,
        projectID: UUID? = nil,
        projectName: String? = nil,
        parentID: UUID? = nil,
        resumable: Bool
    ) {
        self.id = id
        self.providerDisplay = providerDisplay
        self.title = title
        self.status = status
        self.sourceUpdatedAt = sourceUpdatedAt
        self.projectID = projectID
        self.projectName = projectName
        self.parentID = parentID
        self.resumable = resumable
    }
}

struct ObsidianProjectionResult: Equatable, Sendable {
    let writtenFiles: Int
    let unchangedFiles: Int
    let missingSessions: Int
}

enum ObsidianProjectionError: LocalizedError, Equatable {
    case vaultIsNotDirectory
    case unsafeVaultRoot
    case pathEscapesManagedSubtree
    case symbolicLinkInManagedSubtree(String)
    case unmanagedCollision(String)
    case malformedManifest
    case manifestTooLarge
    case tooManySessions
    case duplicateSessionID(UUID)
    case unsupportedProvider(String)
    case invalidTimestamp
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .vaultIsNotDirectory: return "The selected Obsidian vault is not an existing directory."
        case .unsafeVaultRoot: return "The filesystem root and home directory cannot be selected as a vault."
        case .pathEscapesManagedSubtree: return "A projection path escaped the Command Center subtree."
        case .symbolicLinkInManagedSubtree(let path): return "A symbolic link is not allowed in the managed subtree: \(path)"
        case .unmanagedCollision(let path): return "An unmanaged file already occupies a projection path: \(path)"
        case .malformedManifest: return "The Command Center projection manifest is malformed."
        case .manifestTooLarge: return "The Command Center projection manifest exceeds its safety limit."
        case .tooManySessions: return "The projection contains more than 4,096 sessions."
        case .duplicateSessionID(let id): return "The projection contains duplicate session ID \(id.uuidString.lowercased())."
        case .unsupportedProvider(let provider): return "Unsupported projection provider: \(provider)"
        case .invalidTimestamp: return "A projection timestamp is outside the supported range."
        case .ioFailure(let operation): return "The projection could not complete: \(operation)"
        }
    }
}

/// Creates a deterministic, metadata-only Obsidian projection beneath a single
/// explicitly selected vault. The writer never enumerates or reads other notes.
struct ObsidianProjectionWriter: Sendable {
    static let maximumSessions = 4_096
    static let maximumManifestBytes = 1_048_576
    static let maximumNoteBytes = 2_097_152

    let vaultURL: URL
    let managedRootURL: URL
    private let vaultAnchor: ObsidianDirectoryDescriptor

    init(vaultURL: URL) throws {
        let manager = FileManager.default
        let resolvedVault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolvedVault.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey]),
              values.isDirectory == true,
              values.volumeIsLocal != false else {
            throw ObsidianProjectionError.vaultIsNotDirectory
        }
        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedVault.path != "/", resolvedVault.path != home.path else {
            throw ObsidianProjectionError.unsafeVaultRoot
        }
        let managedRoot = resolvedVault.appendingPathComponent("Command Center", isDirectory: true)
        self.vaultURL = resolvedVault
        self.managedRootURL = managedRoot
        let anchor = try Self.openVaultAnchor(resolvedVault)
        self.vaultAnchor = anchor
        let managedDirectory = try Self.openManagedRoot(beneath: anchor, displayURL: managedRoot)
        try Self.ensureDirectoryTree(beneath: managedDirectory)
    }

    @discardableResult
    func write(sessions: [ObsidianSessionProjection]) throws -> ObsidianProjectionResult {
        guard sessions.count <= Self.maximumSessions else { throw ObsidianProjectionError.tooManySessions }
        let managedRoot = try Self.openManagedRoot(beneath: vaultAnchor, displayURL: managedRootURL)
        try Self.ensureDirectoryTree(beneath: managedRoot)

        let normalized = try Self.normalize(sessions)
        let previous = try Self.loadManifest(from: managedRoot)
        let previousByPath = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.relativePath, $0) })
        let desired = Self.renderFiles(for: normalized)
        let desiredPaths = Set(desired.map(\.relativePath))

        var retainedEntries = previous.entries.filter { !desiredPaths.contains($0.relativePath) }
        for index in retainedEntries.indices { retainedEntries[index].missing = true }
        let currentEntries = desired.map {
            ManifestEntry(
                relativePath: $0.relativePath,
                digest: $0.digest,
                kind: $0.kind,
                opaqueID: $0.opaqueID,
                provider: $0.provider,
                missing: false
            )
        }
        let manifestEntries = (currentEntries + retainedEntries)
            .sorted { $0.relativePath < $1.relativePath }
        guard manifestEntries.count <= Self.maximumSessions * 3 + 4 else {
            throw ObsidianProjectionError.manifestTooLarge
        }

        let sourceUpdatedAt = normalized.map(\.sourceUpdatedAt).max() ?? Date(timeIntervalSince1970: 0)
        let manifestData = try Self.renderManifest(entries: manifestEntries, sourceUpdatedAt: sourceUpdatedAt)
        let manifestDigest = Self.digest(manifestData)
        let manifestPath = "_data/manifest.json"

        // Validate every destination before the first content write so an
        // unmanaged collision cannot leave a partially updated projection.
        for file in desired {
            guard file.data.count <= Self.maximumNoteBytes else {
                throw ObsidianProjectionError.ioFailure("a generated note exceeds 2 MiB")
            }
            let prior = previousByPath[file.relativePath]
            let target = try Self.fileLocation(for: file.relativePath, managedRoot: managedRoot)
            if try Self.pathEntryExists(target) {
                guard prior != nil else {
                    throw ObsidianProjectionError.unmanagedCollision(file.relativePath)
                }
                guard try Self.isSafeRegularFile(target) else {
                    throw ObsidianProjectionError.ioFailure("a projection path is not a regular file")
                }
            }
        }
        let manifest = try Self.fileLocation(for: manifestPath, managedRoot: managedRoot)
        if try Self.pathEntryExists(manifest) {
            guard previous.wasLoaded else {
                throw ObsidianProjectionError.unmanagedCollision("_data/manifest.json")
            }
            guard try Self.isSafeRegularFile(manifest) else {
                throw ObsidianProjectionError.ioFailure("the projection manifest is not a regular file")
            }
        }

        var written = 0
        var unchanged = 0
        for file in desired {
            let prior = previousByPath[file.relativePath]
            if try Self.canSkip(
                relativePath: file.relativePath,
                expectedDigest: file.digest,
                expectedData: file.data,
                previous: prior,
                managedRoot: managedRoot
            ) {
                unchanged += 1
                continue
            }
            try Self.atomicWrite(file.data, relativePath: file.relativePath, managedRoot: managedRoot)
            written += 1
        }

        if previous.serializedDigest == manifestDigest,
           try Self.fileMatches(
               manifest,
               expectedData: manifestData,
               maximumBytes: Self.maximumManifestBytes
           ) {
            unchanged += 1
        } else {
            if try Self.pathEntryExists(manifest), !previous.wasLoaded {
                throw ObsidianProjectionError.unmanagedCollision("_data/manifest.json")
            }
            try Self.atomicWrite(manifestData, relativePath: manifestPath, managedRoot: managedRoot)
            written += 1
        }

        return ObsidianProjectionResult(
            writtenFiles: written,
            unchangedFiles: unchanged,
            missingSessions: retainedEntries.filter { $0.missing && $0.kind == "session" }.count
        )
    }
}

/// A directory descriptor is an authorization anchor: descendants are opened
/// one component at a time with O_NOFOLLOW, so an intermediate path cannot be
/// swapped for a symlink between validation and I/O.
private final class ObsidianDirectoryDescriptor: @unchecked Sendable {
    let fileDescriptor: Int32
    let displayURL: URL

    init(fileDescriptor: Int32, displayURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.displayURL = displayURL
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}

private extension ObsidianProjectionWriter {
    struct NormalizedSession: Equatable {
        let id: UUID
        let provider: String
        let title: String
        let status: String
        let sourceUpdatedAt: Date
        let projectID: UUID?
        let projectName: String?
        let parentID: UUID?
        let resumable: Bool

        var idString: String { id.uuidString.lowercased() }
        var relativePath: String { "Sessions/\(provider)/\(idString).md" }
    }

    struct ProjectProjection {
        let id: UUID
        let name: String
        let updatedAt: Date
        let sessions: [NormalizedSession]

        var idString: String { id.uuidString.lowercased() }
        var relativePath: String { "Projects/\(idString).md" }
    }

    struct RenderedFile {
        let relativePath: String
        let data: Data
        let digest: String
        let kind: String
        let opaqueID: String?
        let provider: String?
    }

    struct ManifestEntry: Equatable {
        let relativePath: String
        let digest: String
        let kind: String
        let opaqueID: String?
        let provider: String?
        var missing: Bool
    }

    struct LoadedManifest {
        let entries: [ManifestEntry]
        let serializedDigest: String?
        let wasLoaded: Bool

        static let empty = LoadedManifest(entries: [], serializedDigest: nil, wasLoaded: false)
    }

    struct ManagedFileLocation {
        let parent: ObsidianDirectoryDescriptor
        let name: String
        let displayURL: URL
    }

    static func openVaultAnchor(_ vault: URL) throws -> ObsidianDirectoryDescriptor {
        let descriptor = Darwin.open(vault.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ObsidianProjectionError.symbolicLinkInManagedSubtree(vault.path) }
            throw ObsidianProjectionError.vaultIsNotDirectory
        }
        return ObsidianDirectoryDescriptor(fileDescriptor: descriptor, displayURL: vault)
    }

    static func openManagedRoot(
        beneath vault: ObsidianDirectoryDescriptor,
        displayURL: URL
    ) throws -> ObsidianDirectoryDescriptor {
        try openDirectory(named: "Command Center", in: vault, displayURL: displayURL, createIfMissing: true)
    }

    static func ensureDirectoryTree(beneath managedRoot: ObsidianDirectoryDescriptor) throws {
        for relativePath in ["Sessions", "Sessions/Codex", "Sessions/Claude", "Projects", "_data"] {
            _ = try openDirectory(relativePath: relativePath, in: managedRoot, createIfMissing: true)
        }
    }

    static func openDirectory(
        relativePath: String,
        in root: ObsidianDirectoryDescriptor,
        createIfMissing: Bool
    ) throws -> ObsidianDirectoryDescriptor {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ isSafePathComponent($0) }) else {
            throw ObsidianProjectionError.pathEscapesManagedSubtree
        }
        var current = root
        var display = root.displayURL
        for component in components {
            display.appendPathComponent(component, isDirectory: true)
            current = try openDirectory(
                named: component,
                in: current,
                displayURL: display,
                createIfMissing: createIfMissing
            )
        }
        return current
    }

    static func openDirectory(
        named name: String,
        in parent: ObsidianDirectoryDescriptor,
        displayURL: URL,
        createIfMissing: Bool
    ) throws -> ObsidianDirectoryDescriptor {
        guard isSafePathComponent(name) else {
            throw ObsidianProjectionError.pathEscapesManagedSubtree
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        var descriptor = Darwin.openat(parent.fileDescriptor, name, flags)
        var wasCreated = false
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let createResult = Darwin.mkdirat(parent.fileDescriptor, name, S_IRWXU)
            guard createResult == 0 || errno == EEXIST else {
                throw ObsidianProjectionError.ioFailure("create managed directory")
            }
            wasCreated = createResult == 0
            descriptor = Darwin.openat(parent.fileDescriptor, name, flags)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ObsidianProjectionError.symbolicLinkInManagedSubtree(displayURL.path) }
            throw ObsidianProjectionError.ioFailure("open managed directory")
        }
        if wasCreated, Darwin.fchmod(descriptor, S_IRWXU) != 0 {
            Darwin.close(descriptor)
            throw ObsidianProjectionError.ioFailure("apply managed directory permissions")
        }
        return ObsidianDirectoryDescriptor(fileDescriptor: descriptor, displayURL: displayURL)
    }

    static func fileLocation(
        for relativePath: String,
        managedRoot: ObsidianDirectoryDescriptor
    ) throws -> ManagedFileLocation {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ isSafePathComponent($0) }) else {
            throw ObsidianProjectionError.pathEscapesManagedSubtree
        }
        let name = try requiredLast(components)
        let parent: ObsidianDirectoryDescriptor
        if components.count == 1 {
            parent = managedRoot
        } else {
            parent = try openDirectory(
                relativePath: components.dropLast().joined(separator: "/"),
                in: managedRoot,
                createIfMissing: false
            )
        }
        return ManagedFileLocation(
            parent: parent,
            name: name,
            displayURL: parent.displayURL.appendingPathComponent(name)
        )
    }

    static func normalize(_ sessions: [ObsidianSessionProjection]) throws -> [NormalizedSession] {
        var seen: Set<UUID> = []
        var output: [NormalizedSession] = []
        output.reserveCapacity(sessions.count)
        for session in sessions {
            guard seen.insert(session.id).inserted else {
                throw ObsidianProjectionError.duplicateSessionID(session.id)
            }
            let provider: String
            guard session.providerDisplay.utf8.count <= 64 else {
                throw ObsidianProjectionError.unsupportedProvider("oversized")
            }
            switch session.providerDisplay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "codex": provider = "Codex"
            case "claude": provider = "Claude"
            default: throw ObsidianProjectionError.unsupportedProvider(bounded(session.providerDisplay, limit: 32, fallback: "unknown"))
            }
            guard session.sourceUpdatedAt.timeIntervalSince1970.isFinite,
                  session.sourceUpdatedAt.timeIntervalSince1970 >= 0,
                  session.sourceUpdatedAt.timeIntervalSince1970 <= 32_503_680_000 else {
                throw ObsidianProjectionError.invalidTimestamp
            }
            output.append(NormalizedSession(
                id: session.id,
                provider: provider,
                title: boundedName(session.title, limit: 160, fallback: "Untitled session"),
                status: boundedName(session.status, limit: 64, fallback: "unknown"),
                sourceUpdatedAt: session.sourceUpdatedAt,
                projectID: session.projectID,
                projectName: session.projectID == nil ? nil : boundedName(session.projectName ?? "Untitled project", limit: 128, fallback: "Untitled project"),
                parentID: session.parentID,
                resumable: session.resumable
            ))
        }
        return output.sorted {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.idString < $1.idString
        }
    }

    static func renderFiles(for sessions: [NormalizedSession]) -> [RenderedFile] {
        let projects = projectProjections(from: sessions)
        var files: [RenderedFile] = []
        files.append(renderHome(sessions: sessions, projects: projects))
        files.append(contentsOf: sessions.map(renderSession))
        files.append(contentsOf: projects.map(renderProject))
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func projectProjections(from sessions: [NormalizedSession]) -> [ProjectProjection] {
        Dictionary(grouping: sessions.compactMap { session -> (UUID, NormalizedSession)? in
            session.projectID.map { ($0, session) }
        }, by: { $0.0 })
        .map { id, pairs in
            let grouped = pairs.map(\.1)
            let names = Set(grouped.compactMap(\.projectName))
            return ProjectProjection(
                id: id,
                name: names.sorted().first ?? "Untitled project",
                updatedAt: grouped.map(\.sourceUpdatedAt).max() ?? Date(timeIntervalSince1970: 0),
                sessions: grouped.sorted { $0.relativePath < $1.relativePath }
            )
        }
        .sorted { $0.idString < $1.idString }
    }

    static func renderHome(sessions: [NormalizedSession], projects: [ProjectProjection]) -> RenderedFile {
        let updatedAt = sessions.map(\.sourceUpdatedAt).max() ?? Date(timeIntervalSince1970: 0)
        var links = ["[[Command Center/Home|Command Center]]"]
        links.append(contentsOf: projects.map {
            "[[Command Center/Projects/\($0.idString)|\(wikiAlias($0.name))]]"
        })
        links.append(contentsOf: sessions.map {
            "[[Command Center/\($0.relativePath.dropLast(3))|\(wikiAlias($0.title))]]"
        })
        let metadata = [
            "kind: \(yaml("home"))",
            "source_updated_at: \(yaml(timestamp(updatedAt)))",
        ]
        return markdownFile(relativePath: "Home.md", kind: "home", opaqueID: nil, provider: nil, metadata: metadata, links: links)
    }

    static func renderSession(_ session: NormalizedSession) -> RenderedFile {
        var links = ["[[Command Center/Home|Command Center]]"]
        if let projectID = session.projectID {
            links.append("[[Command Center/Projects/\(projectID.uuidString.lowercased())|\(wikiAlias(session.projectName ?? "Untitled project"))]]")
        }
        if let parentID = session.parentID {
            links.append("[[Command Center/Sessions/\(session.provider)/\(parentID.uuidString.lowercased())|Parent session]]")
        }
        let metadata = [
            "kind: \(yaml("session"))",
            "opaque_id: \(yaml(session.idString))",
            "provider: \(yaml(session.provider))",
            "title: \(yaml(session.title))",
            "status: \(yaml(session.status))",
            "source_updated_at: \(yaml(timestamp(session.sourceUpdatedAt)))",
            "project_opaque_id: \(session.projectID.map { yaml($0.uuidString.lowercased()) } ?? "null")",
            "parent_opaque_id: \(session.parentID.map { yaml($0.uuidString.lowercased()) } ?? "null")",
            "resumable: \(session.resumable ? "true" : "false")",
        ]
        return markdownFile(
            relativePath: session.relativePath,
            kind: "session",
            opaqueID: session.idString,
            provider: session.provider,
            metadata: metadata,
            links: links
        )
    }

    static func renderProject(_ project: ProjectProjection) -> RenderedFile {
        var links = ["[[Command Center/Home|Command Center]]"]
        links.append(contentsOf: project.sessions.map {
            "[[Command Center/\($0.relativePath.dropLast(3))|\(wikiAlias($0.title))]]"
        })
        let metadata = [
            "kind: \(yaml("project"))",
            "opaque_id: \(yaml(project.idString))",
            "name: \(yaml(project.name))",
            "source_updated_at: \(yaml(timestamp(project.updatedAt)))",
        ]
        return markdownFile(
            relativePath: project.relativePath,
            kind: "project",
            opaqueID: project.idString,
            provider: nil,
            metadata: metadata,
            links: links
        )
    }

    static func markdownFile(
        relativePath: String,
        kind: String,
        opaqueID: String?,
        provider: String?,
        metadata: [String],
        links: [String]
    ) -> RenderedFile {
        let canonicalPayload = (metadata + ["links:"] + links).joined(separator: "\n")
        let semanticDigest = digest(Data(canonicalPayload.utf8))
        let frontmatter = ([
            "---",
            "command_center_managed: true",
            "schema: 1",
        ] + metadata + [
            "digest: \(yaml(semanticDigest))",
            "---",
            "",
        ] + links + [""]).joined(separator: "\n")
        return RenderedFile(
            relativePath: relativePath,
            data: Data(frontmatter.utf8),
            digest: semanticDigest,
            kind: kind,
            opaqueID: opaqueID,
            provider: provider
        )
    }

    static func loadManifest(from managedRoot: ObsidianDirectoryDescriptor) throws -> LoadedManifest {
        let location = try fileLocation(for: "_data/manifest.json", managedRoot: managedRoot)
        guard try pathEntryExists(location) else { return .empty }
        guard try isSafeRegularFile(location) else {
            throw ObsidianProjectionError.symbolicLinkInManagedSubtree(location.displayURL.path)
        }
        let data = try readFile(location, maximumBytes: maximumManifestBytes)
        guard data.count <= maximumManifestBytes else {
            throw ObsidianProjectionError.manifestTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["command_center_managed"] as? Bool == true,
              (object["schema"] as? NSNumber)?.intValue == 1,
              let rawEntries = object["entries"] as? [[String: Any]],
              rawEntries.count <= maximumSessions * 3 + 4 else {
            throw ObsidianProjectionError.malformedManifest
        }
        var entries: [ManifestEntry] = []
        var seen: Set<String> = []
        for raw in rawEntries {
            guard let path = raw["path"] as? String,
                  isAllowedRelativePath(path),
                  seen.insert(path).inserted,
                  let digest = raw["digest"] as? String,
                  digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }),
                  let kind = raw["kind"] as? String,
                  let missing = raw["missing"] as? Bool else {
                throw ObsidianProjectionError.malformedManifest
            }
            let opaqueID = raw["opaque_id"] as? String
            if let opaqueID, UUID(uuidString: opaqueID) == nil {
                throw ObsidianProjectionError.malformedManifest
            }
            let provider = raw["provider"] as? String
            if let provider, provider != "Codex", provider != "Claude" {
                throw ObsidianProjectionError.malformedManifest
            }
            entries.append(ManifestEntry(
                relativePath: path,
                digest: digest.lowercased(),
                kind: kind,
                opaqueID: opaqueID,
                provider: provider,
                missing: missing
            ))
        }
        return LoadedManifest(entries: entries, serializedDigest: digest(data), wasLoaded: true)
    }

    static func renderManifest(entries: [ManifestEntry], sourceUpdatedAt: Date) throws -> Data {
        let entryObjects: [[String: Any]] = entries.map { entry in
            var value: [String: Any] = [
                "path": entry.relativePath,
                "digest": entry.digest,
                "kind": entry.kind,
                "missing": entry.missing,
            ]
            if let opaqueID = entry.opaqueID { value["opaque_id"] = opaqueID }
            if let provider = entry.provider { value["provider"] = provider }
            return value
        }
        let object: [String: Any] = [
            "command_center_managed": true,
            "schema": 1,
            "projection": "metadata-only",
            "source_updated_at": timestamp(sourceUpdatedAt),
            "entries": entryObjects,
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= maximumManifestBytes else { throw ObsidianProjectionError.manifestTooLarge }
        return data
    }

    static func canSkip(
        relativePath: String,
        expectedDigest: String,
        expectedData: Data,
        previous: ManifestEntry?,
        managedRoot: ObsidianDirectoryDescriptor
    ) throws -> Bool {
        guard previous?.digest == expectedDigest,
              try pathEntryExists(fileLocation(for: relativePath, managedRoot: managedRoot)) else { return false }
        let target = try fileLocation(for: relativePath, managedRoot: managedRoot)
        return try fileMatches(
            target,
            expectedData: expectedData,
            maximumBytes: maximumNoteBytes
        )
    }

    static func fileMatches(
        _ location: ManagedFileLocation,
        expectedData: Data,
        maximumBytes: Int
    ) throws -> Bool {
        guard try isSafeRegularFile(location) else { return false }
        let data = try readFile(location, maximumBytes: maximumBytes)
        return data.count <= maximumBytes && digest(data) == digest(expectedData)
    }

    static func isSafeRegularFile(_ location: ManagedFileLocation) throws -> Bool {
        var information = stat()
        let result = Darwin.fstatat(
            location.parent.fileDescriptor,
            location.name,
            &information,
            AT_SYMLINK_NOFOLLOW
        )
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw ObsidianProjectionError.ioFailure("inspect projection file")
        }
        if (information.st_mode & S_IFMT) == S_IFLNK {
            throw ObsidianProjectionError.symbolicLinkInManagedSubtree(location.displayURL.path)
        }
        return (information.st_mode & S_IFMT) == S_IFREG
    }

    static func pathEntryExists(_ location: ManagedFileLocation) throws -> Bool {
        var information = stat()
        let result = Darwin.fstatat(
            location.parent.fileDescriptor,
            location.name,
            &information,
            AT_SYMLINK_NOFOLLOW
        )
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw ObsidianProjectionError.ioFailure(
            "could not inspect \(location.name) (errno \(errno))"
        )
    }

    static func readFile(_ location: ManagedFileLocation, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.openat(location.parent.fileDescriptor, location.name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ObsidianProjectionError.symbolicLinkInManagedSubtree(location.displayURL.path) }
            throw ObsidianProjectionError.ioFailure("open projection file")
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            throw ObsidianProjectionError.ioFailure("inspect projection file")
        }
        guard information.st_size <= off_t(maximumBytes) else { return Data(repeating: 0, count: maximumBytes + 1) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    }

    static func atomicWrite(
        _ data: Data,
        relativePath: String,
        managedRoot: ObsidianDirectoryDescriptor
    ) throws {
        let target = try fileLocation(for: relativePath, managedRoot: managedRoot)
        if try pathEntryExists(target) {
            _ = try isSafeRegularFile(target)
        }

        let temporaryName = ".command-center-\(UUID().uuidString.lowercased()).tmp"
        var descriptor = Darwin.openat(
            target.parent.fileDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ObsidianProjectionError.ioFailure("create temporary file") }
        var shouldRemoveTemporary = true
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if shouldRemoveTemporary { _ = Darwin.unlinkat(target.parent.fileDescriptor, temporaryName, 0) }
        }

        do {
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw ObsidianProjectionError.ioFailure("apply projection file permissions")
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let result = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    guard result > 0 else { throw ObsidianProjectionError.ioFailure("write temporary file") }
                    offset += result
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw ObsidianProjectionError.ioFailure("flush temporary file") }
            guard Darwin.close(descriptor) == 0 else { throw ObsidianProjectionError.ioFailure("close temporary file") }
            descriptor = -1
            guard Darwin.renameat(target.parent.fileDescriptor, temporaryName, target.parent.fileDescriptor, target.name) == 0 else {
                throw ObsidianProjectionError.ioFailure("atomically replace projection file")
            }
            shouldRemoveTemporary = false
            _ = Darwin.fsync(target.parent.fileDescriptor)
        } catch {
            throw error
        }
    }

    static func isContained(_ candidate: URL, beneath boundary: URL) -> Bool {
        let rootPath = boundary.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.contains("\\")
    }

    static func requiredLast(_ components: [String]) throws -> String {
        guard let last = components.last else { throw ObsidianProjectionError.pathEscapesManagedSubtree }
        return last
    }

    static func isAllowedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.split(separator: "/").contains("..") else { return false }
        if path == "Home.md" { return true }
        let components = path.split(separator: "/").map(String.init)
        if components.count == 3,
           components[0] == "Sessions",
           ["Codex", "Claude"].contains(components[1]),
           components[2].hasSuffix(".md") {
            return UUID(uuidString: String(components[2].dropLast(3))) != nil
        }
        if components.count == 2,
           components[0] == "Projects",
           components[1].hasSuffix(".md") {
            return UUID(uuidString: String(components[1].dropLast(3))) != nil
        }
        return false
    }

    static func bounded(_ value: String, limit: Int, fallback: String) -> String {
        let inputPrefix = String(value.unicodeScalars.prefix(limit * 4))
        let filtered = inputPrefix.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let value = String(String.UnicodeScalarView(filtered.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    static func boundedName(_ value: String, limit: Int, fallback: String) -> String {
        let boundedValue = bounded(value, limit: limit, fallback: fallback)
        if boundedValue.hasPrefix("/") || boundedValue.contains(" /") {
            return fallback
        }
        return boundedValue
    }

    static func wikiAlias(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "＼")
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "|", with: "¦")
            .replacingOccurrences(of: "#", with: "＃")
            .replacingOccurrences(of: "^", with: "＾")
    }

    static func yaml(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
