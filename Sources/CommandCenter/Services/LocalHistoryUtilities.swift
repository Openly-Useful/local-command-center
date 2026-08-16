import CommandCenterCore
import CryptoKit
import Foundation

enum LocalHistoryUtilities {
    static let maximumPreviewBytes = 4 * 1_024
    static let maximumJSONLineBytes = 1_048_576

    static func validatedUUID(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= ExternalSession.maximumPathBytes else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    static func sanitizedText(_ value: String?, maximumBytes: Int = maximumPreviewBytes) -> String {
        guard let value else { return "" }
        return TerminalTextSanitizer.sanitize(
            value,
            limits: TextSanitizationLimits(
                maximumLineBytes: maximumBytes,
                maximumMessageBytes: maximumBytes
            )
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String {
            if let raw = Double(string) {
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            if let parsed = fractional.date(from: string) ?? standard.date(from: string) {
                return parsed
            }
        }
        return nil
    }

    static func digest(_ components: [String]) -> String {
        let data = Data(components.joined(separator: "\u{1F}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stableSessionID(provider: ProviderKind, sessionID: String) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data("\(provider.rawValue):\(sessionID)".utf8)).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func fileMetadata(_ url: URL) -> (size: Int64, modifiedAt: Date, isRegular: Bool) {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
        ]) else {
            return (0, .distantPast, false)
        }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast, values.isRegularFile == true)
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Reads no more than `maximumBytes`. Large files are sampled from both the
    /// beginning (identity/first prompt) and tail (latest cwd/title/lifecycle).
    static func boundedHeadAndTailLines(
        from url: URL,
        maximumBytes: Int
    ) throws -> (lines: [Data], bytesRead: Int, wasTruncated: Bool, oversizedLines: Int) {
        let metadata = fileMetadata(url)
        guard metadata.isRegular else { return ([], 0, false, 0) }
        let budget = max(1, maximumBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var chunks: [(Data, dropLeadingPartial: Bool, dropTrailingPartial: Bool)] = []
        var bytesRead = 0
        let size = max(metadata.size, 0)
        if size <= Int64(budget) {
            let data = try handle.read(upToCount: Int(size)) ?? Data()
            bytesRead = data.count
            chunks.append((data, false, false))
        } else {
            let headBudget = budget / 2
            let tailBudget = budget - headBudget
            let head = try handle.read(upToCount: headBudget) ?? Data()
            try handle.seek(toOffset: UInt64(size - Int64(tailBudget)))
            let tail = try handle.read(upToCount: tailBudget) ?? Data()
            bytesRead = head.count + tail.count
            chunks.append((head, false, true))
            chunks.append((tail, true, false))
        }

        var lines: [Data] = []
        var oversized = 0
        for (data, dropLeading, dropTrailing) in chunks {
            var start = data.startIndex
            if dropLeading, let newline = data.firstIndex(of: 0x0A) {
                start = data.index(after: newline)
            } else if dropLeading {
                continue
            }
            let end: Data.Index
            if dropTrailing, let newline = data.lastIndex(of: 0x0A) {
                end = newline
            } else if dropTrailing {
                continue
            } else {
                end = data.endIndex
            }
            guard start <= end else { continue }
            let segment = data[start..<end]
            for line in segment.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if line.count > maximumJSONLineBytes {
                    oversized += 1
                } else {
                    lines.append(Data(line))
                }
            }
        }
        return (lines, bytesRead, size > Int64(budget), oversized)
    }

    /// Reads only the newest bounded bytes of a transcript. A leading partial
    /// line is discarded so untrusted JSON is never spliced into a record.
    static func boundedTailLines(
        from url: URL,
        maximumBytes: Int
    ) throws -> (lines: [Data], bytesRead: Int, wasTruncated: Bool, oversizedLines: Int) {
        let metadata = fileMetadata(url)
        guard metadata.isRegular else { return ([], 0, false, 0) }
        let budget = max(1, maximumBytes)
        let size = max(metadata.size, 0)
        let readCount = min(Int64(budget), size)
        let offset = size - readCount
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(readCount)) ?? Data()
        var start = data.startIndex
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return ([], data.count, true, data.count > maximumJSONLineBytes ? 1 : 0)
            }
            start = data.index(after: newline)
        }
        var lines: [Data] = []
        var oversized = 0
        for line in data[start...].split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.count > maximumJSONLineBytes {
                oversized += 1
            } else {
                lines.append(Data(line))
            }
        }
        return (lines, data.count, offset > 0, oversized)
    }

    static func visibleMessageText(_ message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "" }
        if let text = message["content"] as? String {
            return sanitizedText(text, maximumBytes: 1_048_576)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" || (block["type"] as? String) == "input_text" || (block["type"] as? String) == "output_text" else {
                return nil
            }
            return block["text"] as? String
        }.joined(separator: "\n\n")
        return sanitizedText(text, maximumBytes: 1_048_576)
    }
}
