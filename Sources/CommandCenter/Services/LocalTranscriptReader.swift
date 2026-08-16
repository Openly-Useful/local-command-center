import CommandCenterCore
import Foundation

struct LocalTranscriptReader: Sendable {
    private let codexRolloutRoots: [URL]
    private let claudeProjectsRoot: URL

    init(
        codexRolloutRoots: [URL]? = nil,
        claudeProjectsRoot: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.codexRolloutRoots = (codexRolloutRoots ?? [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.claudeProjectsRoot = (claudeProjectsRoot ?? home.appendingPathComponent(
            ".claude/projects", isDirectory: true
        )).resolvingSymlinksInPath().standardizedFileURL
    }

    func read(
        session: ExternalSession,
        limits: LocalTranscriptReadLimits = LocalTranscriptReadLimits()
    ) async -> LocalTranscriptSnapshot {
        await Task.detached(priority: .utility) {
            readSynchronously(session: session, limits: limits)
        }.value
    }

    private func readSynchronously(
        session: ExternalSession,
        limits: LocalTranscriptReadLimits
    ) -> LocalTranscriptSnapshot {
        let sourceURL = URL(fileURLWithPath: session.sourcePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard let sessionID = LocalHistoryUtilities.validatedUUID(session.providerSessionID) else {
            return failure(session, code: "transcript-invalid-session-id", detail: "Session identifier is invalid.")
        }
        guard sourceURL.pathExtension.lowercased() == "jsonl",
              sourceSessionID(from: sourceURL, provider: session.provider) == sessionID,
              isAllowedSource(sourceURL, provider: session.provider),
              let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return failure(session, code: "transcript-source-unavailable", detail: "Transcript source is not a direct regular JSONL file.")
        }

        do {
            let bounded = try LocalHistoryUtilities.boundedTailLines(
                from: sourceURL,
                maximumBytes: limits.readBytes
            )
            var malformed = 0
            var parsed: [OrderedTranscriptRow] = []
            var codexFallback: [OrderedTranscriptRow] = []
            for (ordinal, line) in bounded.lines.enumerated() {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    malformed += 1
                    continue
                }
                switch session.provider {
                case .claude:
                    if let row = decodeClaude(
                        object,
                        expectedSessionID: session.providerSessionID,
                        fallbackTimestamp: session.sourceModifiedAt,
                        ordinal: ordinal,
                        maximumTextBytes: limits.readBytes
                    ) {
                        parsed.append(row)
                    }
                case .codex:
                    if let row = decodeCodexResponse(
                        object,
                        fallbackTimestamp: session.sourceModifiedAt,
                        ordinal: ordinal,
                        maximumTextBytes: limits.readBytes
                    ) {
                        parsed.append(row)
                    } else if let row = decodeCodexEventFallback(
                        object,
                        fallbackTimestamp: session.sourceModifiedAt,
                        ordinal: ordinal,
                        maximumTextBytes: limits.readBytes
                    ) {
                        codexFallback.append(row)
                    }
                }
            }
            if session.provider == .codex, parsed.isEmpty { parsed = codexFallback }

            parsed.sort {
                if $0.row.timestamp != $1.row.timestamp { return $0.row.timestamp < $1.row.timestamp }
                return $0.ordinal < $1.ordinal
            }
            let boundedRows = newestRows(
                parsed.map(\.row),
                messageLimit: limits.messageCount,
                byteLimit: limits.readBytes
            )
            var diagnostics: [LocalHistoryDiagnostic] = []
            if malformed > 0 || bounded.oversizedLines > 0 {
                diagnostics.append(.init(
                    severity: .warning,
                    code: "transcript-records-skipped",
                    sourcePath: sourceURL.path,
                    detail: "Skipped \(malformed) malformed and \(bounded.oversizedLines) oversized records."
                ))
            }
            let digest = LocalHistoryUtilities.digest(boundedRows.flatMap {
                [$0.id, $0.role.rawValue, $0.text, String($0.timestamp.timeIntervalSince1970)]
            })
            return LocalTranscriptSnapshot(
                sessionID: session.providerSessionID,
                rows: boundedRows,
                bytesRead: bounded.bytesRead,
                wasTruncated: bounded.wasTruncated || parsed.count > boundedRows.count,
                diagnostics: diagnostics,
                contentDigest: digest
            )
        } catch {
            return failure(session, code: "transcript-read-failed", detail: "Transcript could not be read.")
        }
    }

    private struct OrderedTranscriptRow {
        var row: LocalTranscriptRow
        var ordinal: Int
    }

    private func decodeClaude(
        _ object: [String: Any],
        expectedSessionID: String,
        fallbackTimestamp: Date,
        ordinal: Int,
        maximumTextBytes: Int
    ) -> OrderedTranscriptRow? {
        guard let recordSessionID = LocalHistoryUtilities.validatedUUID(object["sessionId"] as? String),
              recordSessionID == expectedSessionID,
              (object["isMeta"] as? Bool) != true,
              let type = object["type"] as? String,
              type == "user" || type == "assistant" else { return nil }
        let role: MessageRole = type == "user" ? .user : .assistant
        let text = boundedText(
            LocalHistoryUtilities.visibleMessageText(object["message"]),
            maximumBytes: maximumTextBytes
        )
        guard !text.isEmpty else { return nil }
        let providerID = validatedRecordID(object["uuid"] as? String)
        let parentID = LocalHistoryUtilities.validatedUUID(object["parentUuid"] as? String)
        let timestamp = LocalHistoryUtilities.date(object["timestamp"]) ?? fallbackTimestamp
        let identity = providerID ?? LocalHistoryUtilities.digest([
            expectedSessionID, role.rawValue, text, String(timestamp.timeIntervalSince1970),
            String(ordinal),
        ])
        return OrderedTranscriptRow(
            row: .init(
                id: "claude:\(identity)",
                providerRecordID: providerID,
                parentRecordID: parentID,
                role: role,
                text: text,
                timestamp: timestamp
            ),
            ordinal: ordinal
        )
    }

    private func decodeCodexResponse(
        _ object: [String: Any],
        fallbackTimestamp: Date,
        ordinal: Int,
        maximumTextBytes: Int
    ) -> OrderedTranscriptRow? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let roleValue = payload["role"] as? String,
              roleValue == "user" || roleValue == "assistant" else { return nil }
        let role: MessageRole = roleValue == "user" ? .user : .assistant
        let text = boundedText(
            LocalHistoryUtilities.visibleMessageText(payload),
            maximumBytes: maximumTextBytes
        )
        guard !text.isEmpty else { return nil }
        let providerID = validatedRecordID(payload["id"] as? String)
        let parentID = LocalHistoryUtilities.validatedUUID(
            payload["parentUuid"] as? String ?? payload["parent_id"] as? String
        )
        let timestamp = LocalHistoryUtilities.date(object["timestamp"]) ?? fallbackTimestamp
        let identity = providerID ?? LocalHistoryUtilities.digest([
            role.rawValue, text, String(timestamp.timeIntervalSince1970), String(ordinal),
        ])
        return OrderedTranscriptRow(
            row: .init(
                id: "codex:\(identity)",
                providerRecordID: providerID,
                parentRecordID: parentID,
                role: role,
                text: text,
                timestamp: timestamp
            ),
            ordinal: ordinal
        )
    }

    private func decodeCodexEventFallback(
        _ object: [String: Any],
        fallbackTimestamp: Date,
        ordinal: Int,
        maximumTextBytes: Int
    ) -> OrderedTranscriptRow? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              type == "user_message" || type == "agent_message" else { return nil }
        let role: MessageRole = type == "user_message" ? .user : .assistant
        let text = boundedText(
            LocalHistoryUtilities.sanitizedText(
                payload["message"] as? String,
                maximumBytes: min(maximumTextBytes, 1_048_576)
            ),
            maximumBytes: maximumTextBytes
        )
        guard !text.isEmpty else { return nil }
        let timestamp = LocalHistoryUtilities.date(object["timestamp"]) ?? fallbackTimestamp
        let identity = LocalHistoryUtilities.digest([
            role.rawValue, text, String(timestamp.timeIntervalSince1970), String(ordinal),
        ])
        return OrderedTranscriptRow(
            row: .init(
                id: "codex:\(identity)",
                providerRecordID: nil,
                parentRecordID: nil,
                role: role,
                text: text,
                timestamp: timestamp
            ),
            ordinal: ordinal
        )
    }

    private func newestRows(
        _ rows: [LocalTranscriptRow],
        messageLimit: Int,
        byteLimit: Int
    ) -> [LocalTranscriptRow] {
        var selected: [LocalTranscriptRow] = []
        var bytes = 0
        for row in rows.reversed() {
            guard selected.count < messageLimit else { break }
            let rowBytes = row.text.utf8.count
            if bytes + rowBytes > byteLimit {
                if selected.isEmpty {
                    let text = boundedText(row.text, maximumBytes: byteLimit)
                    if !text.isEmpty {
                        var truncated = row
                        truncated.text = text
                        selected.append(truncated)
                    }
                }
                break
            }
            selected.append(row)
            bytes += rowBytes
        }
        return selected.reversed()
    }

    private func validatedRecordID(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = LocalHistoryUtilities.sanitizedText(value, maximumBytes: 1_024)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func boundedText(_ text: String, maximumBytes: Int) -> String {
        LocalHistoryUtilities.sanitizedText(
            text,
            maximumBytes: min(max(maximumBytes, 1), 1_048_576)
        )
    }

    private func failure(
        _ session: ExternalSession,
        code: String,
        detail: String
    ) -> LocalTranscriptSnapshot {
        LocalTranscriptSnapshot(
            sessionID: session.providerSessionID,
            rows: [],
            bytesRead: 0,
            wasTruncated: false,
            diagnostics: [.init(
                severity: .warning,
                code: code,
                sourcePath: session.sourcePath,
                detail: detail
            )],
            contentDigest: LocalHistoryUtilities.digest([])
        )
    }

    private func isAllowedSource(_ sourceURL: URL, provider: ProviderKind) -> Bool {
        switch provider {
        case .codex:
            return codexRolloutRoots.contains {
                LocalHistoryUtilities.isContained(sourceURL, in: $0)
            }
        case .claude:
            guard LocalHistoryUtilities.isContained(sourceURL, in: claudeProjectsRoot) else {
                return false
            }
            let relative = sourceURL.path.dropFirst(claudeProjectsRoot.path.count)
                .split(separator: "/", omittingEmptySubsequences: true)
            return relative.count == 2
        }
    }

    private func sourceSessionID(from sourceURL: URL, provider: ProviderKind) -> String? {
        switch provider {
        case .codex:
            return CodexRolloutFilename.sessionID(from: sourceURL)
        case .claude:
            return LocalHistoryUtilities.validatedUUID(
                sourceURL.deletingPathExtension().lastPathComponent
            )
        }
    }
}
