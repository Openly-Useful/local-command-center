import CommandCenterCore
import Foundation
import SQLite3

private final class ReadOnlySQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close_v2(handle) }
}

struct CodexLocalHistorySource: LocalHistorySource, Sendable {
    static let maximumAcceptedSessionCount = LocalHistoryLimits.maximumSessionsPerProvider
    static let maximumRevalidationEntryCount = 20_000
    static let maximumDatabaseRowCount = 20_000

    let provider: ProviderKind = .codex
    let databaseURL: URL
    let rolloutRootURLs: [URL]
    let maximumAcceptedSessions: Int
    let maximumRevalidationEntries: Int
    let maximumDatabaseRows: Int

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite"),
        rolloutRootURLs: [URL]? = nil,
        maximumAcceptedSessions: Int = LocalHistoryLimits.maximumSessionsPerProvider,
        maximumRevalidationEntries: Int = CodexLocalHistorySource.maximumRevalidationEntryCount,
        maximumDatabaseRows: Int = CodexLocalHistorySource.maximumDatabaseRowCount
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.databaseURL = databaseURL.standardizedFileURL
        self.rolloutRootURLs = (rolloutRootURLs ?? [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]).map(\.standardizedFileURL)
        self.maximumAcceptedSessions = min(
            max(maximumAcceptedSessions, 1),
            Self.maximumAcceptedSessionCount
        )
        self.maximumRevalidationEntries = min(
            max(maximumRevalidationEntries, 1),
            Self.maximumRevalidationEntryCount
        )
        self.maximumDatabaseRows = min(
            max(maximumDatabaseRows, 1),
            Self.maximumDatabaseRowCount
        )
    }

    func scan() async -> LocalHistorySnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    func revalidate(session: ExternalSession) async -> LocalSessionRevalidation {
        await Task.detached(priority: .utility) {
            revalidateSynchronously(session: session)
        }.value
    }

    private func revalidateSynchronously(
        session: ExternalSession
    ) -> LocalSessionRevalidation {
        let checkedAt = Date()
        guard session.provider == .codex,
              let sessionID = LocalHistoryUtilities.validatedUUID(session.providerSessionID) else {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "codex-revalidation-invalid-identity",
                detail: "The selected task does not have a valid Codex session identity."
            )
        }

        if let currentURL = validatedDatabaseRolloutURL(
            sourcePath: session.sourcePath,
            expectedSessionID: sessionID
        ) {
            return refreshedRevalidation(
                session: session,
                sourceURL: currentURL,
                checkedAt: checkedAt
            )
        }

        // The immutable state database cannot prove absence because a live row
        // may exist only in WAL. Search the configured active + archived
        // rollout roots instead, without reading any transcript body.
        guard !rolloutRootURLs.isEmpty else {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "codex-revalidation-roots-unavailable",
                detail: "No trusted Codex rollout roots are configured for revalidation."
            )
        }

        let manager = FileManager.default
        var entriesConsidered = 0
        var enumerationFailed = false
        for root in rolloutRootURLs {
            var rootEnumerationFailed = false
            guard let enumerator = manager.enumerator(
                at: root.standardizedFileURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    rootEnumerationFailed = true
                    return true
                }
            ) else {
                enumerationFailed = true
                continue
            }

            for case let entryURL as URL in enumerator {
                guard !Task.isCancelled else {
                    return revalidation(
                        session: session,
                        state: .indeterminate,
                        checkedAt: checkedAt,
                        code: "codex-revalidation-cancelled",
                        detail: "Codex session revalidation was cancelled before completion."
                    )
                }
                guard entriesConsidered < maximumRevalidationEntries else {
                    return revalidation(
                        session: session,
                        state: .indeterminate,
                        checkedAt: checkedAt,
                        code: "codex-revalidation-entry-limit-reached",
                        detail: "Codex session revalidation stopped at its bounded filesystem entry limit."
                    )
                }
                entriesConsidered += 1
                guard entryURL.pathExtension.lowercased() == "jsonl",
                      CodexRolloutFilename.sessionID(from: entryURL) == sessionID,
                      let trustedURL = validatedDatabaseRolloutURL(
                        sourcePath: entryURL.standardizedFileURL.path,
                        expectedSessionID: sessionID
                      ) else { continue }
                return refreshedRevalidation(
                    session: session,
                    sourceURL: trustedURL,
                    checkedAt: checkedAt
                )
            }
            if rootEnumerationFailed { enumerationFailed = true }
        }

        if enumerationFailed {
            return revalidation(
                session: session,
                state: .indeterminate,
                checkedAt: checkedAt,
                code: "codex-revalidation-incomplete",
                detail: "Codex rollout enumeration was incomplete, so absence could not be proven."
            )
        }
        return revalidation(
            session: session,
            state: .unavailable,
            checkedAt: checkedAt,
            code: "codex-session-source-unavailable",
            detail: "The Codex session no longer exists in any configured active or archived rollout root."
        )
    }

    private func scanSynchronously() -> LocalHistorySnapshot {
        let startedAt = Date()
        do {
            let databaseSnapshot = try scanDatabase(startedAt: startedAt)
            let rolloutSnapshot = scanRollouts(
                startedAt: startedAt,
                excludingProviderSessionIDs: Set(
                    databaseSnapshot.sessions.map(\.providerSessionID)
                )
            )
            return mergeDatabaseAndRolloutSnapshots(
                databaseSnapshot,
                rolloutSnapshot: rolloutSnapshot
            )
        } catch {
            var fallback = scanRollouts(startedAt: startedAt)
            fallback.metrics.usedFallback = true
            if fallback.diagnostics.count >= LocalHistoryLimits.maximumDiagnosticsPerScan {
                fallback.diagnostics.removeLast()
            }
            fallback.diagnostics.insert(.init(
                severity: .warning,
                code: "codex-state-database-unavailable",
                sourcePath: databaseURL.path,
                detail: "Codex state metadata was unavailable; rollout metadata fallback was used."
            ), at: 0)
            return fallback
        }
    }

    private func mergeDatabaseAndRolloutSnapshots(
        _ databaseSnapshot: LocalHistorySnapshot,
        rolloutSnapshot: LocalHistorySnapshot
    ) -> LocalHistorySnapshot {
        var diagnostics: [LocalHistoryDiagnostic] = []
        for diagnostic in databaseSnapshot.diagnostics + rolloutSnapshot.diagnostics {
            guard !diagnostics.contains(where: {
                $0.code == diagnostic.code && $0.sourcePath == diagnostic.sourcePath
            }) else { continue }
            appendDiagnostic(diagnostic, to: &diagnostics)
        }

        var retained = BoundedNewestCodexSessions(limit: maximumAcceptedSessions)
        var databaseProviderIDs: Set<String> = []
        databaseProviderIDs.reserveCapacity(databaseSnapshot.sessions.count)
        for session in databaseSnapshot.sessions {
            databaseProviderIDs.insert(session.providerSessionID)
            retained.insert(session)
        }

        var observedRolloutOnlySession = false
        for session in rolloutSnapshot.sessions {
            // State DB metadata is richer and always wins for the same identity.
            guard !databaseProviderIDs.contains(session.providerSessionID) else { continue }
            observedRolloutOnlySession = true
            retained.insert(session)
        }

        if observedRolloutOnlySession {
            appendDiagnostic(.init(
                severity: .info,
                code: "codex-rollout-supplement",
                sourcePath: nil,
                detail: "Codex rollout metadata supplied sessions not visible in the immutable state database view."
            ), to: &diagnostics)
        }
        let wasCapped = retained.wasCapped
            || diagnostics.contains { $0.code == "codex-session-limit-reached" }
        if wasCapped,
           !diagnostics.contains(where: { $0.code == "codex-session-limit-reached" }) {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "codex-session-limit-reached",
                sourcePath: nil,
                detail: "Codex discovery returned the newest \(maximumAcceptedSessions) sessions; older sessions were omitted."
            ), to: &diagnostics)
        }

        let sessions = retained.sortedSessions()
        let databaseMetrics = databaseSnapshot.metrics
        let rolloutMetrics = rolloutSnapshot.metrics
        let metrics = LocalHistoryScanMetrics(
            startedAt: min(databaseMetrics.startedAt, rolloutMetrics.startedAt),
            finishedAt: Date(),
            filesConsidered: databaseMetrics.filesConsidered + rolloutMetrics.filesConsidered,
            filesRead: databaseMetrics.filesRead + rolloutMetrics.filesRead,
            rowsConsidered: databaseMetrics.rowsConsidered + rolloutMetrics.rowsConsidered,
            sessionsAccepted: sessions.count,
            bytesRead: databaseMetrics.bytesRead + rolloutMetrics.bytesRead,
            malformedRecords: databaseMetrics.malformedRecords + rolloutMetrics.malformedRecords,
            oversizedRecords: databaseMetrics.oversizedRecords + rolloutMetrics.oversizedRecords,
            skippedEntries: databaseMetrics.skippedEntries + rolloutMetrics.skippedEntries,
            usedFallback: false
        )
        return LocalHistorySnapshot(
            sessions: sessions,
            diagnostics: diagnostics,
            metrics: metrics,
            // Both sources are deliberately lock-free observations. Absence in
            // either can race a live append and must never authorize tombstones.
            authoritative: false
        )
    }

    private func openReadOnlyDatabase() throws -> ReadOnlySQLiteConnection {
        var raw: OpaquePointer?
        // `immutable=1` is SQLite's no-lock/no-sidecar read path. It never
        // creates, writes, or locks the provider's WAL/SHM files. The tradeoff
        // is explicit below: this view can omit records only present in a live
        // WAL and therefore can never authorize tombstoning by absence.
        let uri = databaseURL.absoluteString + "?mode=ro&immutable=1"
        let result = sqlite3_open_v2(
            uri,
            &raw,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard result == SQLITE_OK, let raw else {
            if let raw { sqlite3_close_v2(raw) }
            throw CodexHistoryError.sqlite(result)
        }
        let connection = ReadOnlySQLiteConnection(handle: raw)
        guard sqlite3_db_readonly(raw, "main") == 1 else {
            throw CodexHistoryError.sqlite(sqlite3_errcode(raw))
        }
        return connection
    }

    private func scanDatabase(startedAt: Date) throws -> LocalHistorySnapshot {
        let connection = try openReadOnlyDatabase()
        let sql = """
        SELECT
            t.id, t.rollout_path, t.created_at, t.updated_at, t.source, t.cwd,
            t.title, t.archived, t.archived_at, t.first_user_message,
            t.created_at_ms, t.updated_at_ms, t.thread_source, t.preview,
            t.recency_at, t.recency_at_ms, t.name,
            e.parent_thread_id
        FROM threads AS t
        LEFT JOIN thread_spawn_edges AS e ON e.child_thread_id = t.id
        ORDER BY
            CASE
                WHEN t.recency_at_ms > 0 THEN t.recency_at_ms
                WHEN t.updated_at_ms > 0 THEN t.updated_at_ms
                WHEN t.recency_at > 0 THEN t.recency_at * 1000
                ELSE t.updated_at * 1000
            END DESC,
            t.id ASC
        LIMIT \(maximumDatabaseRows)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CodexHistoryError.sqlite(sqlite3_errcode(connection.handle))
        }
        defer { sqlite3_finalize(statement) }

        var metrics = LocalHistoryScanMetrics.empty(startedAt: startedAt)
        var diagnostics: [LocalHistoryDiagnostic] = [
            .init(
                severity: .info,
                code: "codex-immutable-state-view",
                sourcePath: databaseURL.path,
                detail: "Codex metadata was read without provider-file locks or sidecar writes; live WAL-only changes may be omitted."
            ),
        ]
        var sessions: [LocalHistorySession] = []
        sessions.reserveCapacity(maximumAcceptedSessions)
        var wasCapped = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CodexHistoryError.sqlite(sqlite3_errcode(connection.handle))
            }
            metrics.rowsConsidered += 1
            guard let sessionID = LocalHistoryUtilities.validatedUUID(text(
                statement, 0, maximumBytes: ExternalSession.maximumSessionIDBytes
            )) else {
                metrics.skippedEntries += 1
                appendDiagnostic(.init(
                    severity: .warning,
                    code: "codex-invalid-session-id",
                    sourcePath: databaseURL.path,
                    detail: "A Codex metadata row with an invalid session identifier was skipped."
                ), to: &diagnostics)
                continue
            }

            guard let databaseSourcePath = LocalHistoryUtilities.normalizedPath(text(
                statement, 1, maximumBytes: ExternalSession.maximumPathBytes
            )) else {
                metrics.skippedEntries += 1
                appendDiagnostic(.init(
                    severity: .warning,
                    code: "codex-invalid-rollout-path",
                    sourcePath: databaseURL.path,
                    detail: "A Codex metadata row with an invalid rollout path was skipped."
                ), to: &diagnostics)
                continue
            }
            guard let sourceURL = validatedDatabaseRolloutURL(
                sourcePath: databaseSourcePath,
                expectedSessionID: sessionID
            ) else {
                metrics.skippedEntries += 1
                appendDiagnostic(.init(
                    severity: .warning,
                    code: "codex-untrusted-rollout-path",
                    sourcePath: databaseURL.path,
                    detail: "A Codex metadata row referenced an untrusted rollout path and was skipped."
                ), to: &diagnostics)
                continue
            }
            let sourcePath = sourceURL.path
            let sourceFile = LocalHistoryUtilities.fileMetadata(sourceURL)
            let name = LocalHistoryUtilities.sanitizedText(text(
                statement, 16, maximumBytes: ExternalSession.maximumTitleBytes
            ))
            let databaseTitle = LocalHistoryUtilities.sanitizedText(text(
                statement, 6, maximumBytes: ExternalSession.maximumTitleBytes
            ))
            let firstUser = LocalHistoryUtilities.sanitizedText(text(
                statement, 9, maximumBytes: ExternalSession.maximumPreviewBytes
            ))
            let databasePreview = LocalHistoryUtilities.sanitizedText(text(
                statement, 13, maximumBytes: ExternalSession.maximumPreviewBytes
            ))
            let titleCandidate = firstNonempty([name, databaseTitle, firstUser, databasePreview])
                ?? "Untitled Codex session"
            let title = LocalHistoryUtilities.firstLine(
                LocalHistoryUtilities.sanitizedText(
                    titleCandidate,
                    maximumBytes: ExternalSession.maximumTitleBytes
                )
            )
            let preview = firstNonempty([databasePreview, firstUser, databaseTitle, name]) ?? ""
            let createdAt = preferredDate(
                milliseconds: optionalInt64(statement, 10),
                seconds: optionalInt64(statement, 2)
            ) ?? sourceFile.modifiedAt
            let updatedAt = [
                preferredDate(milliseconds: optionalInt64(statement, 15), seconds: optionalInt64(statement, 14)),
                preferredDate(milliseconds: optionalInt64(statement, 11), seconds: optionalInt64(statement, 3)),
                sourceFile.modifiedAt,
            ].compactMap { $0 }.max() ?? sourceFile.modifiedAt
            let archived = sqlite3_column_int(statement, 7) != 0
            let parent = LocalHistoryUtilities.validatedUUID(text(
                statement, 17, maximumBytes: ExternalSession.maximumSessionIDBytes
            ))
            let workspace = LocalHistoryUtilities.normalizedPath(text(
                statement, 5, maximumBytes: ExternalSession.maximumPathBytes
            ))
            let source = firstNonempty([
                LocalHistoryUtilities.sanitizedText(text(
                    statement, 12, maximumBytes: ExternalSession.maximumStatusBytes
                )),
                LocalHistoryUtilities.sanitizedText(text(
                    statement, 4, maximumBytes: ExternalSession.maximumStatusBytes
                )),
            ]) ?? "unknown"
            let status = archived ? "archived" : "available"
            let digest = LocalHistoryUtilities.digest([
                sessionID, sourcePath, workspace ?? "", title, preview, status, source,
                parent ?? "", String(createdAt.timeIntervalSince1970),
                String(updatedAt.timeIntervalSince1970), String(sourceFile.size),
                String(sourceFile.modifiedAt.timeIntervalSince1970),
            ])
            do {
                let session = try LocalHistorySession(
                    id: LocalHistoryUtilities.stableSessionID(provider: .codex, sessionID: sessionID),
                    provider: .codex,
                    surface: .codex,
                    providerSessionID: sessionID,
                    workspacePath: workspace,
                    title: title.isEmpty ? "Untitled Codex session" : title,
                    preview: preview,
                    providerStatus: status,
                    canResume: true,
                    canReadTranscript: sourceFile.isRegular,
                    sourcePath: sourcePath,
                    sourceByteCount: sourceFile.size,
                    sourceModifiedAt: sourceFile.modifiedAt,
                    firstSeenAt: createdAt,
                    lastSeenAt: updatedAt,
                    parentProviderSessionID: parent,
                    isSidechain: parent != nil,
                    contentDigest: digest,
                    missingSince: nil
                )
                if sessions.count >= maximumAcceptedSessions {
                    wasCapped = true
                    break
                }
                sessions.append(session)
            } catch {
                metrics.skippedEntries += 1
                appendDiagnostic(.init(
                    severity: .warning,
                    code: "codex-invalid-metadata-row",
                    sourcePath: databaseURL.path,
                    detail: "A Codex metadata row failed bounded validation and was skipped."
                ), to: &diagnostics)
            }
        }

        let databaseRowLimitReached = metrics.rowsConsidered >= maximumDatabaseRows
        if databaseRowLimitReached {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "codex-database-row-limit-reached",
                sourcePath: databaseURL.path,
                detail: "Codex state discovery stopped at its bounded metadata row limit."
            ), to: &diagnostics)
        }
        if sessions.count >= maximumAcceptedSessions { wasCapped = true }
        sessions.sort(by: sessionSort)
        if wasCapped {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "codex-session-limit-reached",
                sourcePath: databaseURL.path,
                detail: "Codex discovery returned the newest \(maximumAcceptedSessions) sessions; older sessions were omitted."
            ), to: &diagnostics)
        }
        metrics.filesConsidered = sessions.count
        // This query reads metadata columns only, never rollout transcript bodies.
        metrics.filesRead = 0
        metrics.bytesRead = 0
        metrics.sessionsAccepted = sessions.count
        metrics.finishedAt = Date()
        return LocalHistorySnapshot(
            sessions: sessions,
            diagnostics: diagnostics,
            metrics: metrics,
            // Immutable SQLite deliberately ignores a possibly live WAL.
            authoritative: false
        )
    }

    private func scanRollouts(
        startedAt: Date,
        excludingProviderSessionIDs: Set<String> = []
    ) -> LocalHistorySnapshot {
        var metrics = LocalHistoryScanMetrics.empty(startedAt: startedAt)
        var diagnostics: [LocalHistoryDiagnostic] = []
        var retained = BoundedNewestCodexSessions(limit: maximumAcceptedSessions)
        let manager = FileManager.default
        var rolloutEntryLimitReached = false
        var rolloutEntriesConsidered = 0

        for root in rolloutRootURLs {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = manager.enumerator(
                at: resolvedRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            let archived = resolvedRoot.path.contains("archived")
            for case let fileURL as URL in enumerator {
                if rolloutEntriesConsidered >= maximumRevalidationEntries {
                    rolloutEntryLimitReached = true
                    break
                }
                rolloutEntriesConsidered += 1
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                metrics.filesConsidered += 1
                let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
                guard fileURL.standardizedFileURL.path == resolvedFile.path,
                LocalHistoryUtilities.isContained(resolvedFile, in: resolvedRoot),
                let filenameID = CodexRolloutFilename.sessionID(from: resolvedFile),
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true else {
                    metrics.skippedEntries += 1
                    continue
                }
                guard !excludingProviderSessionIDs.contains(filenameID) else {
                    continue
                }
                do {
                    let bounded = try readRolloutMetadataLine(from: resolvedFile)
                    metrics.filesRead += 1
                    metrics.bytesRead += Int64(bounded.bytesRead)
                    if bounded.wasOversized { metrics.oversizedRecords += 1 }
                    var metadata: [String: Any]?
                    if let line = bounded.line {
                        metrics.rowsConsidered += 1
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            if object["type"] as? String == "session_meta" {
                                metadata = object
                            }
                        } else {
                            metrics.malformedRecords += 1
                        }
                    }
                    let payload = metadata?["payload"] as? [String: Any]
                    let payloadID = LocalHistoryUtilities.validatedUUID(
                        payload?["id"] as? String ?? payload?["session_id"] as? String
                    )
                    guard payloadID == nil || payloadID == filenameID else {
                        metrics.skippedEntries += 1
                        continue
                    }
                    let file = LocalHistoryUtilities.fileMetadata(resolvedFile)
                    let created = LocalHistoryUtilities.date(metadata?["timestamp"]) ?? file.modifiedAt
                    let workspace = LocalHistoryUtilities.normalizedPath(payload?["cwd"] as? String)
                    let sourcePath = resolvedFile.path
                    let title = "Untitled Codex session"
                    let session = try LocalHistorySession(
                        id: LocalHistoryUtilities.stableSessionID(provider: .codex, sessionID: filenameID),
                        provider: .codex,
                        surface: .codex,
                        providerSessionID: filenameID,
                        workspacePath: workspace,
                        title: title,
                        preview: "",
                        providerStatus: archived ? "archived" : "available",
                        canResume: true,
                        canReadTranscript: file.isRegular,
                        sourcePath: sourcePath,
                        sourceByteCount: file.size,
                        sourceModifiedAt: file.modifiedAt,
                        firstSeenAt: created,
                        lastSeenAt: max(created, file.modifiedAt),
                        parentProviderSessionID: LocalHistoryUtilities.validatedUUID(
                            payload?["forked_from_id"] as? String
                        ),
                        isSidechain: payload?["forked_from_id"] != nil,
                        contentDigest: LocalHistoryUtilities.digest([
                            filenameID, sourcePath, workspace ?? "", title,
                            archived ? "archived" : "available", String(file.size),
                            String(file.modifiedAt.timeIntervalSince1970),
                        ]),
                        missingSince: nil
                    )
                    retained.insert(session)
                } catch {
                    appendDiagnostic(.init(
                        severity: .warning,
                        code: "codex-rollout-unreadable",
                        sourcePath: fileURL.standardizedFileURL.path,
                        detail: "A Codex rollout metadata file could not be read."
                    ), to: &diagnostics)
                }
            }
            if rolloutEntryLimitReached { break }
        }
        let sessions = retained.sortedSessions()
        if retained.wasCapped {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "codex-session-limit-reached",
                sourcePath: nil,
                detail: "Codex rollout discovery returned the newest \(maximumAcceptedSessions) sessions; older sessions were omitted."
            ), to: &diagnostics)
        }
        if rolloutEntryLimitReached {
            appendPriorityDiagnostic(.init(
                severity: .warning,
                code: "codex-rollout-entry-limit-reached",
                sourcePath: nil,
                detail: "Codex rollout discovery stopped after \(maximumRevalidationEntries) filesystem entries."
            ), to: &diagnostics)
        }
        metrics.sessionsAccepted = sessions.count
        metrics.finishedAt = Date()
        return LocalHistorySnapshot(
            sessions: sessions,
            diagnostics: diagnostics,
            metrics: metrics,
            authoritative: false
        )
    }

    private struct RolloutMetadataLine {
        var line: Data?
        var bytesRead: Int
        var wasOversized: Bool
    }

    /// Validates a DB-controlled path without first touching arbitrary file
    /// metadata. Lexical containment and row/filename identity are checked
    /// before inspecting only descendants of an explicitly configured root.
    private func validatedDatabaseRolloutURL(
        sourcePath: String,
        expectedSessionID: String
    ) -> URL? {
        let candidate = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "jsonl",
              CodexRolloutFilename.sessionID(from: candidate) == expectedSessionID,
              let lexicalRoot = rolloutRootURLs.first(where: {
                  LocalHistoryUtilities.isContained(candidate, in: $0)
              }) else { return nil }

        let rootPath = lexicalRoot.standardizedFileURL.path
        let relativeComponents = candidate.path.dropFirst(rootPath.count)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !relativeComponents.isEmpty else { return nil }

        // Reject every descendant symlink before resolving the final path.
        // The configured root itself is the trust anchor and may resolve
        // through an OS-level alias such as /var -> /private/var.
        var descendant = lexicalRoot.standardizedFileURL
        for component in relativeComponents {
            descendant.appendPathComponent(String(component))
            guard let values = try? descendant.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard LocalHistoryUtilities.isContained(resolvedCandidate, in: resolvedRoot),
              CodexRolloutFilename.sessionID(from: resolvedCandidate) == expectedSessionID,
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
                code: "codex-revalidation-invalid-metadata",
                detail: "The located Codex session failed bounded metadata validation."
            )
        }
        return LocalSessionRevalidation(
            provider: .codex,
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
            provider: .codex,
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

    private func readRolloutMetadataLine(from url: URL) throws -> RolloutMetadataLine {
        // The UUID filename and file metadata are sufficient to surface a live
        // rollout. Reading a small first-line window only enriches cwd/parent
        // metadata and avoids rescanning transcript bodies on every refresh.
        let maximumBytes = 64 * 1_024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        let bounded = Data(data.prefix(maximumBytes))
        let newline = bounded.firstIndex(of: 0x0A)
        let line: Data?
        if let newline {
            line = Data(bounded.prefix(upTo: newline))
        } else if data.count <= maximumBytes {
            line = bounded.isEmpty ? nil : bounded
        } else {
            line = nil
        }
        return RolloutMetadataLine(
            line: line,
            bytesRead: data.count,
            wasOversized: data.count > maximumBytes && newline == nil
        )
    }

    private func text(
        _ statement: OpaquePointer,
        _ index: Int32,
        maximumBytes: Int
    ) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { return nil }
        let byteCount = sqlite3_column_bytes(statement, index)
        guard byteCount >= 0,
              Int(byteCount) <= maximumBytes,
              let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(
            decoding: UnsafeBufferPointer(start: raw, count: Int(byteCount)),
            as: UTF8.self
        )
    }

    private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func preferredDate(milliseconds: Int64?, seconds: Int64?) -> Date? {
        if let milliseconds, milliseconds > 0 {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        if let seconds, seconds > 0 {
            return Date(timeIntervalSince1970: Double(seconds))
        }
        return nil
    }

    private func firstNonempty(_ values: [String]) -> String? {
        values.first(where: { !$0.isEmpty })
    }

    private func sessionSort(_ lhs: LocalHistorySession, _ rhs: LocalHistorySession) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.id < rhs.id
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

/// Worst-first bounded heap with O(log limit) insertion/replacement and O(1)
/// identity lookup. This prevents a large rollout tree from triggering an
/// O(entries × 5,000) scan while retaining deterministic newest-first output.
private struct BoundedNewestCodexSessions {
    let limit: Int
    private var heap: [LocalHistorySession] = []
    private var indexByProviderID: [String: Int] = [:]
    private(set) var wasCapped = false

    init(limit: Int) {
        self.limit = max(limit, 1)
        heap.reserveCapacity(self.limit)
        indexByProviderID.reserveCapacity(self.limit)
    }

    mutating func insert(_ session: LocalHistorySession) {
        let key = session.providerSessionID
        if let index = indexByProviderID[key] {
            guard Self.isNewer(session, than: heap[index]) else { return }
            heap[index] = session
            siftDown(from: index)
            return
        }
        guard heap.count >= limit else {
            heap.append(session)
            indexByProviderID[key] = heap.count - 1
            siftUp(from: heap.count - 1)
            return
        }

        wasCapped = true
        guard let worst = heap.first, Self.isNewer(session, than: worst) else { return }
        indexByProviderID.removeValue(forKey: worst.providerSessionID)
        heap[0] = session
        indexByProviderID[key] = 0
        siftDown(from: 0)
    }

    func sortedSessions() -> [LocalHistorySession] {
        heap.sorted(by: Self.isNewer)
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isWorse(heap[child], than: heap[parent]) else { return }
            swap(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var worseChild = left
            if right < heap.count, Self.isWorse(heap[right], than: heap[left]) {
                worseChild = right
            }
            guard Self.isWorse(heap[worseChild], than: heap[parent]) else { return }
            swap(parent, worseChild)
            parent = worseChild
        }
    }

    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        heap.swapAt(lhs, rhs)
        indexByProviderID[heap[lhs].providerSessionID] = lhs
        indexByProviderID[heap[rhs].providerSessionID] = rhs
    }

    private static func isNewer(
        _ lhs: LocalHistorySession,
        than rhs: LocalHistorySession
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.id < rhs.id
    }

    private static func isWorse(
        _ lhs: LocalHistorySession,
        than rhs: LocalHistorySession
    ) -> Bool {
        isNewer(rhs, than: lhs)
    }
}

private enum CodexHistoryError: Error {
    case sqlite(Int32)
}
