import Foundation

struct LocalSkillDescriptor: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var summary: String
    var source: String
    var fileURL: URL
}

struct SkillCatalog: Sendable {
    struct Root: Sendable {
        let url: URL
        let source: String
    }

    private let maximumFiles = 600
    private let maximumDepth = 9
    private let maximumSkillBytes = 1_048_576
    private let metadataReadBytes = 16_384
    private let roots: [Root]

    init(roots: [Root]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.roots = [
                Root(url: home.appendingPathComponent(".codex/skills", isDirectory: true), source: "Codex"),
                Root(url: home.appendingPathComponent(".agents/skills", isDirectory: true), source: "Agents"),
                Root(url: home.appendingPathComponent(".claude/skills", isDirectory: true), source: "Claude"),
            ]
        }
    }

    func scan() async -> [LocalSkillDescriptor] {
        await Task.detached(priority: .utility) { scanSynchronously() }.value
    }

    private func scanSynchronously() -> [LocalSkillDescriptor] {
        var visited: Set<String> = []
        var files: [(url: URL, source: String, root: URL)] = []
        for root in roots {
            let resolvedRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
            guard isDirectory(resolvedRoot) else { continue }
            walk(
                resolvedRoot,
                source: root.source,
                root: resolvedRoot,
                depth: 0,
                visited: &visited,
                files: &files
            )
            if files.count >= maximumFiles { break }
        }

        var byName: [String: LocalSkillDescriptor] = [:]
        for file in files.prefix(maximumFiles) {
            guard let descriptor = parse(file.url, source: file.source, root: file.root) else { continue }
            if byName[descriptor.name] == nil { byName[descriptor.name] = descriptor }
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func walk(
        _ url: URL,
        source: String,
        root: URL,
        depth: Int,
        visited: inout Set<String>,
        files: inout [(url: URL, source: String, root: URL)]
    ) {
        guard depth <= maximumDepth, files.count < maximumFiles else { return }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved, beneath: root) else { return }
        guard visited.insert(resolved.path).inserted else { return }
        guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .nameKey]),
              values.isDirectory == true else { return }

        let skipped = [".git", "node_modules", ".build", "dist"]
        guard !skipped.contains(resolved.lastPathComponent) else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children.sorted(by: { $0.path < $1.path }) {
            let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
            // A skill root is the complete authorization boundary. Do not
            // parse a linked SKILL.md or descend into a linked directory that
            // resolves outside that root.
            guard isContained(resolvedChild, beneath: root) else { continue }
            if child.lastPathComponent == "SKILL.md" {
                files.append((url: resolvedChild, source: source, root: root))
                if files.count >= maximumFiles { return }
            } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(
                    child,
                    source: source,
                    root: root,
                    depth: depth + 1,
                    visited: &visited,
                    files: &files
                )
            }
        }
    }

    private func parse(_ url: URL, source: String, root: URL) -> LocalSkillDescriptor? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved, beneath: root) else { return nil }
        guard let values = try? resolved.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumSkillBytes,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: metadataReadBytes)
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                name = value(after: "name:", in: trimmed)
            } else if trimmed.hasPrefix("description:") {
                let candidate = value(after: "description:", in: trimmed)
                if !candidate.isEmpty, candidate != ">", candidate != "|" { description = candidate }
            }
        }
        let fallback = resolved.deletingLastPathComponent().lastPathComponent
        let finalName = (name?.isEmpty == false ? name! : fallback)
        guard !finalName.isEmpty else { return nil }
        return LocalSkillDescriptor(
            name: finalName,
            summary: description ?? "Installed local skill",
            source: source,
            fileURL: resolved
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isContained(_ candidate: URL, beneath root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func value(after prefix: String, in line: String) -> String {
        line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
