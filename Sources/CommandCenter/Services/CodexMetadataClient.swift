import Foundation

struct CodexThreadSummary: Identifiable, Sendable {
    var id: String
    var title: String
    var preview: String
    var workspacePath: String
    var status: String
    var updatedAt: Date
    var sectionName: String?
    var source: String
    var canAcceptInput: Bool
}

enum CodexMetadataError: LocalizedError {
    case unavailable
    case timeout
    case malformedResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex CLI is not available."
        case .timeout: return "Codex metadata request timed out."
        case .malformedResponse: return "Codex returned an unreadable metadata response."
        case .server(let message): return message
        }
    }
}

struct CodexMetadataClient: Sendable {
    func listThreads(limit: Int = 120) async throws -> [CodexThreadSummary] {
        guard let executable = ExecutableResolver.resolve("codex") else {
            throw CodexMetadataError.unavailable
        }
        let safeLimit = min(max(limit, 1), 250)
        return try await Task.detached(priority: .utility) {
            try Self.listThreads(executable: executable, limit: safeLimit)
        }.value
    }

    private static func listThreads(executable: URL, limit: Int) throws -> [CodexThreadSummary] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
        }

        try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "local-command-center", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true],
            ],
        ], to: input.fileHandleForWriting)

        var buffer = Data()
        var initialized = false
        while true {
            guard let line = readLine(from: output.fileHandleForReading, buffer: &buffer) else {
                if process.terminationReason == .uncaughtSignal { throw CodexMetadataError.timeout }
                let diagnostic = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw CodexMetadataError.server(diagnostic.isEmpty ? "Codex app-server stopped before responding." : diagnostic)
            }
            guard line.count <= 4_194_304,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }

            if number(object["id"]) == 1, !initialized {
                initialized = true
                try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]], to: input.fileHandleForWriting)
                try send([
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "thread/list",
                    "params": [
                        "limit": limit,
                        "sortKey": "recency_at",
                        "sortDirection": "desc",
                        "useStateDbOnly": true,
                        "sourceKinds": [],
                    ],
                ], to: input.fileHandleForWriting)
            }

            if number(object["id"]) == 2 {
                if let serverError = object["error"] as? [String: Any] {
                    throw CodexMetadataError.server(serverError["message"] as? String ?? "Codex metadata request failed.")
                }
                guard let result = object["result"] as? [String: Any],
                      let rows = result["data"] as? [[String: Any]] else {
                    throw CodexMetadataError.malformedResponse
                }
                return rows.compactMap(decodeThread)
            }
        }
    }

    private static func decodeThread(_ row: [String: Any]) -> CodexThreadSummary? {
        guard let id = row["id"] as? String else { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = (name?.isEmpty == false ? name! : firstLine(preview))
        let section = row["section"] as? [String: Any]
        return CodexThreadSummary(
            id: id,
            title: title.isEmpty ? "Untitled Codex session" : ProviderEventDecoder.sanitize(title),
            preview: ProviderEventDecoder.sanitize(preview),
            workspacePath: row["cwd"] as? String ?? "",
            status: stringValue(row["status"]),
            updatedAt: dateValue(row["recencyAt"] ?? row["updatedAt"]),
            sectionName: section?["name"] as? String ?? section?["title"] as? String,
            source: stringValue(row["source"] ?? row["threadSource"]),
            canAcceptInput: row["canAcceptDirectInput"] as? Bool ?? false
        )
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func readLine(from handle: FileHandle, buffer: inout Data) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                return line
            }
            let data = handle.availableData
            if data.isEmpty {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(data)
            if buffer.count > 4_194_304 { return nil }
        }
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            return (dictionary["type"] as? String) ?? (dictionary["status"] as? String) ?? "unknown"
        }
        return "unknown"
    }

    private static func dateValue(_ value: Any?) -> Date {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let string = value as? String {
            if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            if let date = ISO8601DateFormatter().date(from: string) { return date }
        }
        return .distantPast
    }

    private static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
