import CommandCenterCore
import Foundation

actor ClaudeLocalHistorySource: LocalHistorySource {
    static let maximumAcceptedSessionCount = LocalHistoryLimits.maximumSessionsPerProvider
    static let maximumDirectoryEntryCount = 20_000

    let provider: ProviderKind = .claude
    let projectsRootURL: URL
    let maximumMetadataBytesPerSession: Int
    let maximumAcceptedSessions: Int
    let maximumDirectoryEntries: Int
    private var cache: [String: CacheEntry] = [:]

    private struct CacheEntry: Sendable {
        var size: Int64
        var modifiedAt: Date
        var parsed: ParsedClaudeSession
    }

    private struct Candidate: Sendable {
        var fileURL: URL
        var sessionID: String
        var size: Int64
        var modifiedAt: Date
    }

    init(
        projectsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        maximumMetadataBytesPerSession: Int = 8 * 1_048_576,
        maximumAcceptedSessions: Int = LocalHistoryLimits.maximumSessionsPerProvider,
        maximumDirectoryEntries: Int = ClaudeLocalHistorySource.maximumDirectoryEntryCount
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.maximumMetadataBytesPerSession = min(
            max(maximumMetadataBytesPerSession, 1),
            8 * 1_048_576
        )
        self.maximumAcceptedSessions = min(
            max(maximumAcceptedSessions, 1),
            Self.maximumAcceptedSessionCount
        )
        self.maximumDirectoryEntries = min(
            max(maximumDirectoryEntries, 1),
            Self.maximumDirectoryEntryCount
        )
    }

    func scan() async -> LocalHistorySnapshot {
        scanSynchronously()
    }

    func revalidate(session: ExternalSession) async -> LocalSessionRevalidation {
        revalidateSynchronously(session: session)
    }

    func cacheEntryCount() -> Int {
        cache.count
    }

    private func revalidateSynchronously(
        session: ExternalSession
    ) -> LocalSessionRevalidation {
        let checkedAt = Date()
        guard session.provider == .claude,
              let sessionID = LocalHistoryUtilities.validatedUUID(session.providerSessionID) else {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "claude-revalidation-invalid-identity",
                detail: "The selected task does not have a valid Claude session identity."
            )
        }

        if let currentURL = validatedDirectSessionURL(
            sourcePath: session.sourcePath,
            expectedSessionID: sessionID
        ) {
            return refreshedRevalidation(
                session: session,
                sourceURL: currentURL,
                checkedAt: checkedAt
            )
        }

        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRootURL.standardizedFileURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }
        ) else {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "claude-revalidation-root-unavailable",
                detail: "The trusted Claude projects root could not be enumerated."
            )
        }

        let root = projectsRootURL.standardizedFileURL
        let rootPrefix = root.path + "/"
        var entriesConsidered = 0
        for case let entryURL as URL in enumerator {
            guard !Task.isCancelled else {
                return revalidation(
                    session: session,
                    state: .indeterminate,
                    checkedAt: checkedAt,
                    code: "claude-revalidation-cancelled",
                    detail: "Claude session revalidation was cancelled before completion."
                )
            }
            guard entriesConsidered < maximumDirectoryEntries else {
                return revalidation(
                    session: session,
                    state: .indeterminate,
                    checkedAt: checkedAt,
                    code: "claude-revalidation-entry-limit-reached",
                    detail: "Claude session revalidation stopped at its bounded filesystem entry limit."
                )
            }
            entriesConsidered += 1
            let entry = entryURL.standardizedFileURL
            guard entry.path.hasPrefix(rootPrefix) else {
                enumerationFailed = true
                enumerator.skipDescendants()
                continue
            }
            let relative = entry.path.dropFirst(rootPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: true)
            guard !relative.isEmpty, relative.count <= 2 else {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]) else {
                enumerationFailed = true
                enumerator.skipDescendants()
                continue
            }
            if relative.count == 1 {
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }
            if values.isDirectory == true { enumerator.skipDescendants() }
            guard entry.pathExtension.lowercased() == "jsonl",
                  LocalHistoryUtilities.validatedUUID(
                    entry.deletingPathExtension().lastPathComponent
                  ) == sessionID,
                  let trustedURL = validatedDirectSessionURL(
                    sourcePath: entry.path,
                    expectedSessionID: sessionID
                  ) else { continue }
            return refreshedRevalidation(
                session: session,
                sourceURL: trustedURL,
                checkedAt: checkedAt
            )
        }

        if enumerationFailed {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "claude-revalidation-incomplete",
                detail: "Claude project enumeration was incomplete, so absence could not be proven."
            )
        }
        return revalidation(
            session: session,
            state: .unavailable,
            checkedAt: checkedAt,
            code: "claude-session-source-unavailable",
            detail: "The Claude session no longer exists as a canonical direct project session file."
        )
    }

    private func validatedDirectSessionURL(
        sourcePath: String,
        expectedSessionID: String
    ) -> URL? {
        let root = projectsRootURL.standardizedFileURL
        let candidate = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "jsonl",
              LocalHistoryUtilities.validatedUUID(
                candidate.deletingPathExtension().lastPathComponent
              ) == expectedSessionID,
              LocalHistoryUtilities.isContained(candidate, in: root) else { return nil }
        let relative = candidate.path.dropFirst(root.path.count)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard relative.count == 2 else { return nil }

        var descendant = root
        for component in relative {
            descendant.appendPathComponent(String(component))
            guard let values = try? descendant.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard LocalHistoryUtilities.isContained(resolvedCandidate, in: resolvedRoot),
              let values = try? resolvedCandidate.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return resolvedCandidate
    }

    private func refreshedRevalidation(
        session: ExternalSession,
        sourceURL: URL,
        checkedAt: Date
    ) -> LocalSessionRevalidation {
        let file = LocalHistoryUtilities.fileMetadata(sourceURL)
        guard file.isRegular,
              let refreshed = try? ExternalSession(
                id: session.id,
                provider: session.provider,
                surface: session.surface,
                providerSessionID: session.providerSessionID,
                workspacePath: session.workspacePath,
                title: session.title,
                preview: session.preview,
                providerStatus: session.providerStatus,
                canResume: session.canResume,
                canReadTranscript: true,
                sourcePath: sourceURL.path,
                sourceByteCount: file.size,
                sourceModifiedAt: file.modifiedAt,
                firstSeenAt: session.firstSeenAt,
                lastSeenAt: max(session.lastSeenAt, file.modifiedAt),
                parentProviderSessionID: session.parentProviderSessionID,
                isSidechain: session.isSidechain,
                contentDigest: LocalHistoryUtilities.digest([
                    session.contentDigest ?? "",
                    sourceURL.path,
                    String(file.size),
                    String(file.modifiedAt.timeIntervalSince1970),
                ]),
                missingSince: nil
              ) else {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "claude-revalidation-invalid-metadata",
                detail: "The located Claude session failed bounded metadata validation."
            )
        }
        return LocalSessionRevalidation(
            provider: .claude,
            providerSessionID: session.providerSessionID,
            state: .available,
            checkedAt: checkedAt,
            refreshedSession: refreshed,
            diagnostic: nil
        )
    }

    private func revalidation(
        session: ExternalSession,
        state: LocalSessionRevalidationState,
        checkedAt: Date,
        code: String,
        detail: String
    ) -> LocalSessionRevalidation {
        LocalSessionRevalidation(
            provider: .claude,
            providerSessionID: session.providerSessionID,
            state: state,
            checkedAt: checkedAt,
            refreshedSession: nil,
            diagnostic: .init(
                severity: state == .unavailable ? .info : .warning,
                code: code,
                sourcePath: nil,
                detail: detail
            )
        )
    }

    private func scanSynchronously() -> LocalHistorySnapshot {
        let startedAt = Date()
        var metrics = LocalHistoryScanMetrics.empty(startedAt: startedAt)
        var diagnostics: [LocalHistoryDiagnostic] = []
        var candidates: [Candidate] = []
        candidates.reserveCapacity(maximumAcceptedSessions)
        var validCandidateCount = 0
        var directoryEnumerationFailed = false
        var directoryEntryLimitReached = false
        var directoryEntriesConsidered = 0
        let manager = FileManager.default

        let normalizedRoot = projectsRootURL.standardizedFileURL
        let rootPrefix = normalizedRoot.path + "/"
        guard let enumerator = manager.enumerator(
            at: projectsRootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                directoryEnumerationFailed = true
                return true
            }
        ) else {
            diagnostics.append(.init(
                severity: .warning,
                code: "claude-projects-unavailable",
                sourcePath: projectsRootURL.path,
                detail: "Claude projects metadata directory could not be enumerated."
            ))
            metrics.finishedAt = Date()
            return LocalHistorySnapshot(
                sessions: [], diagnostics: diagnostics, metrics: metrics, authoritative: false
            )
        }

        for case let entryURL as URL in enumerator {
            guard directoryEntriesConsidered < maximumDirectoryEntries else {
                directoryEntryLimitReached = true
                break
            }
            directoryEntriesConsidered += 1
            let entry = entryURL.standardizedFileURL
            guard entry.path.hasPrefix(rootPrefix) else {
                metrics.skippedEntries += 1
                directoryEnumerationFailed = true
                enumerator.skipDescendants()
                continue
            }
            let relativeComponents = entry.path
                .dropFirst(rootPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: true)
            guard !relativeComponents.isEmpty, relativeComponents.count <= 2 else {
                metrics.skippedEntries += 1
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey,
            ]) else {
                metrics.skippedEntries += 1
                directoryEnumerationFailed = true
                enumerator.skipDescendants()
                continue
            }

            if relativeComponents.count == 1 {
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    metrics.skippedEntries += 1
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            // Depth two is the only accepted layout:
            // ~/.claude/projects/<encoded-project>/<UUID>.jsonl.
            metrics.filesConsidered += 1
            if values.isDirectory == true { enumerator.skipDescendants() }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  entry.pathExtension.lowercased() == "jsonl",
                  !entry.lastPathComponent.hasPrefix("agent-"),
                  let sessionID = LocalHistoryUtilities.validatedUUID(
                    entry.deletingPathExtension().lastPathComponent
                  ) else {
                metrics.skippedEntries += 1
                continue
            }

            validCandidateCount += 1
            retainNewestCandidate(
                Candidate(
                    fileURL: entry,
                    sessionID: sessionID,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                ),
                in: &candidates
            )
        }

        candidates.sort(by: candidateSort)
        var sessions: [LocalHistorySession] = []
        sessions.reserveCapacity(candidates.count)
        var seenPaths: Set<String> = []
        seenPaths.reserveCapacity(candidates.count)
        var seenSessionIDs: Set<String> = []
        seenSessionIDs.reserveCapacity(candidates.count)

        for candidate in candidates {
            let fileURL = candidate.fileURL
            let cacheKey = fileURL.path
            seenPaths.insert(cacheKey)
            guard seenSessionIDs.insert(candidate.sessionID).inserted else {
                metrics.skippedEntries += 1
                continue
            }

            if let cached = cache[cacheKey],
               cached.size == candidate.size,
               cached.modifiedAt == candidate.modifiedAt {
                for diagnostic in cached.parsed.diagnostics {
                    appendDiagnostic(diagnostic, to: &diagnostics)
                }
                sessions.append(cached.parsed.session)
                continue
            }

            do {
                let result = try parseSession(
                    fileURL: fileURL,
                    expectedSessionID: candidate.sessionID
                )
                metrics.filesRead += 1
                metrics.rowsConsidered += result.rowsConsidered
                metrics.bytesRead += Int64(result.bytesRead)
                metrics.malformedRecords += result.malformedRecords
                metrics.oversizedRecords += result.oversizedRecords
                for diagnostic in result.diagnostics {
                    appendDiagnostic(diagnostic, to: &diagnostics)
                }
                sessions.append(result.session)
                cache[cacheKey] = CacheEntry(
                    size: candidate.size,
                    modifiedAt: candidate.modifiedAt,
                    parsed: result
                )
            } catch {
                appendDiagnostic(.init(
                    severity: .warning,
                    code: "claude-session-unreadable",
                    sourcePath: fileURL.path,
                    detail: "Session metadata could not be read."
                ), to: &diagnostics)
            }
        }

        sessions.sort(by: sessionSort)
        // Partial absence is never authoritative. Pruning even after a partial
        // scan keeps the long-lived cache bounded; omitted files are reparsed
        // after a later complete enumeration.
        cache = cache.filter { seenPaths.contains($0.key) }
        let wasCapped = validCandidateCount > maximumAcceptedSessions
        if wasCapped {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "claude-session-limit-reached",
                sourcePath: projectsRootURL.path,
                detail: "Claude discovery returned the newest \(maximumAcceptedSessions) sessions; older sessions were omitted."
            ), to: &diagnostics)
        }
        if directoryEntryLimitReached {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "claude-directory-entry-limit-reached",
                sourcePath: projectsRootURL.path,
                detail: "Claude discovery stopped after \(maximumDirectoryEntries) filesystem entries."
            ), to: &diagnostics)
        }
        metrics.sessionsAccepted = sessions.count
        metrics.finishedAt = Date()
        return LocalHistorySnapshot(
            sessions: sessions,
            diagnostics: diagnostics,
            metrics: metrics,
            authoritative: !wasCapped
                && !directoryEntryLimitReached
                && !directoryEnumerationFailed
                && !diagnostics.contains { $0.code == "claude-session-unreadable" }
        )
    }

    private struct ParsedClaudeSession: Sendable {
        var session: LocalHistorySession
        var diagnostics: [LocalHistoryDiagnostic]
        var rowsConsidered: Int
        var bytesRead: Int
        var malformedRecords: Int
        var oversizedRecords: Int
    }

    private func parseSession(fileURL: URL, expectedSessionID: String) throws -> ParsedClaudeSession {
        let bounded = try LocalHistoryUtilities.boundedHeadAndTailLines(
            from: fileURL,
            maximumBytes: maximumMetadataBytesPerSession
        )
        let file = LocalHistoryUtilities.fileMetadata(fileURL)
        var malformed = 0
        var diagnostics: [LocalHistoryDiagnostic] = []
        var customTitle: String?
        var aiTitle: String?
        var firstUserText: String?
        var lastPrompt: String?
        var latestWorkspace: (date: Date, ordinal: Int, path: String)?
        var firstSeen: Date?
        var lastSeen: Date?
        var status = "available"

        for (ordinal, line) in bounded.lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                malformed += 1
                continue
            }
            guard let recordSessionID = LocalHistoryUtilities.validatedUUID(object["sessionId"] as? String),
                  recordSessionID == expectedSessionID else {
                malformed += 1
                continue
            }
            let timestamp = LocalHistoryUtilities.date(object["timestamp"])
            if let timestamp {
                firstSeen = min(firstSeen ?? timestamp, timestamp)
                lastSeen = max(lastSeen ?? timestamp, timestamp)
            }

            if let candidate = LocalHistoryUtilities.normalizedPath(object["cwd"] as? String),
               FileManager.default.fileExists(atPath: candidate) {
                let orderingDate = timestamp ?? .distantPast
                if latestWorkspace == nil
                    || orderingDate > latestWorkspace!.date
                    || (orderingDate == latestWorkspace!.date && ordinal > latestWorkspace!.ordinal) {
                    latestWorkspace = (orderingDate, ordinal, candidate)
                }
            }

            switch object["type"] as? String {
            case "custom-title":
                let candidate = LocalHistoryUtilities.sanitizedText(object["customTitle"] as? String)
                if !candidate.isEmpty { customTitle = candidate }
            case "ai-title":
                let candidate = LocalHistoryUtilities.sanitizedText(object["aiTitle"] as? String)
                if !candidate.isEmpty { aiTitle = candidate }
            case "last-prompt":
                let candidate = LocalHistoryUtilities.sanitizedText(object["lastPrompt"] as? String)
                if !candidate.isEmpty { lastPrompt = candidate }
            case "user":
                guard (object["isMeta"] as? Bool) != true else { break }
                let candidate = LocalHistoryUtilities.visibleMessageText(object["message"])
                if firstUserText == nil, !candidate.isEmpty { firstUserText = candidate }
            case "system":
                if let lifecycle = lifecycleStatus(object) { status = lifecycle }
            default:
                break
            }
        }

        if bounded.wasTruncated {
            diagnostics.append(.init(
                severity: .info,
                code: "claude-metadata-window-bounded",
                sourcePath: fileURL.standardizedFileURL.path,
                detail: "Metadata scan used a bounded head/tail window."
            ))
        }
        if malformed > 0 || bounded.oversizedLines > 0 {
            diagnostics.append(.init(
                severity: .warning,
                code: "claude-records-skipped",
                sourcePath: fileURL.standardizedFileURL.path,
                detail: "Skipped \(malformed) malformed and \(bounded.oversizedLines) oversized records."
            ))
        }

        let titleCandidate = customTitle ?? aiTitle ?? firstUserText ?? lastPrompt ?? "Untitled Claude session"
        let title = LocalHistoryUtilities.firstLine(
            LocalHistoryUtilities.sanitizedText(
                titleCandidate,
                maximumBytes: ExternalSession.maximumTitleBytes
            )
        )
        let preview = LocalHistoryUtilities.sanitizedText(lastPrompt ?? firstUserText ?? aiTitle ?? customTitle)
        let normalizedSource = fileURL.standardizedFileURL.path
        let effectiveFirstSeen = firstSeen ?? file.modifiedAt
        let effectiveLastSeen = max(lastSeen ?? file.modifiedAt, file.modifiedAt)
        let digest = LocalHistoryUtilities.digest([
            expectedSessionID,
            latestWorkspace?.path ?? "",
            title,
            preview,
            status,
            String(file.size),
            String(file.modifiedAt.timeIntervalSince1970),
            String(effectiveFirstSeen.timeIntervalSince1970),
            String(effectiveLastSeen.timeIntervalSince1970),
        ])
        let session = try LocalHistorySession(
            id: LocalHistoryUtilities.stableSessionID(provider: .claude, sessionID: expectedSessionID),
            provider: .claude,
            surface: .claudeCode,
            providerSessionID: expectedSessionID,
            workspacePath: latestWorkspace?.path,
            title: title.isEmpty ? "Untitled Claude session" : title,
            preview: preview,
            providerStatus: status,
            canResume: true,
            canReadTranscript: file.isRegular,
            sourcePath: normalizedSource,
            sourceByteCount: file.size,
            sourceModifiedAt: file.modifiedAt,
            firstSeenAt: effectiveFirstSeen,
            lastSeenAt: effectiveLastSeen,
            parentProviderSessionID: nil,
            isSidechain: false,
            contentDigest: digest,
            missingSince: nil
        )
        return ParsedClaudeSession(
            session: session,
            diagnostics: diagnostics,
            rowsConsidered: bounded.lines.count,
            bytesRead: bounded.bytesRead,
            malformedRecords: malformed,
            oversizedRecords: bounded.oversizedLines
        )
    }

    private func lifecycleStatus(_ object: [String: Any]) -> String? {
        let subtype = (object["subtype"] as? String)?.lowercased()
        let explicit = (object["status"] as? String)?.lowercased()
        switch explicit ?? subtype {
        case "running", "started", "in_progress": return "running"
        case "waiting", "needs_input", "waiting_for_input": return "waitingForInput"
        case "failed", "error": return "failed"
        case "cancelled", "canceled", "aborted": return "cancelled"
        case "completed", "complete", "session_end": return "completed"
        default: return nil
        }
    }

    private func sessionSort(_ lhs: LocalHistorySession, _ rhs: LocalHistorySession) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.id < rhs.id
    }

    private func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.fileURL.path < rhs.fileURL.path
    }

    /// Maintains a worst-first bounded heap while traversing every direct
    /// provider entry. This keeps selection O(files × log(cap)) and avoids an
    /// unbounded pre-sort array on large provider histories.
    private func retainNewestCandidate(_ candidate: Candidate, in candidates: inout [Candidate]) {
        if candidates.count < maximumAcceptedSessions {
            candidates.append(candidate)
            siftCandidateUp(from: candidates.count - 1, in: &candidates)
            return
        }
        guard let worst = candidates.first, candidateSort(candidate, worst) else { return }
        candidates[0] = candidate
        siftCandidateDown(from: 0, in: &candidates)
    }

    private func siftCandidateUp(from index: Int, in candidates: inout [Candidate]) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard candidateIsWorse(candidates[child], than: candidates[parent]) else { return }
            candidates.swapAt(child, parent)
            child = parent
        }
    }

    private func siftCandidateDown(from index: Int, in candidates: inout [Candidate]) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < candidates.count else { return }
            let right = left + 1
            var worseChild = left
            if right < candidates.count,
               candidateIsWorse(candidates[right], than: candidates[left]) {
                worseChild = right
            }
            guard candidateIsWorse(candidates[worseChild], than: candidates[parent]) else {
                return
            }
            candidates.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    private func candidateIsWorse(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        candidateSort(rhs, lhs)
    }

    private func appendDiagnostic(
        _ diagnostic: LocalHistoryDiagnostic,
        to diagnostics: inout [LocalHistoryDiagnostic]
    ) {
        guard diagnostics.count < LocalHistoryLimits.maximumDiagnosticsPerScan else { return }
        diagnostics.append(diagnostic)
    }

    private func appendPriorityDiagnostic(
        _ diagnostic: LocalHistoryDiagnostic,
        to diagnostics: inout [LocalHistoryDiagnostic]
    ) {
        if diagnostics.count >= LocalHistoryLimits.maximumDiagnosticsPerScan {
            diagnostics.removeLast()
        }
        diagnostics.append(diagnostic)
    }
}
