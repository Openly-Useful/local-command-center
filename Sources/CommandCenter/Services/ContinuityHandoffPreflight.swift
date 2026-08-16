import CommandCenterCore
import Foundation

struct ContinuityHandoffBoundary: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let capsuleDigest: String
    let commit: String
    let statusDigest: String
    let sourceLabel: String
    let destinationLabel: String
    let changedPaths: [String]

    init(
        capsuleDigest: String,
        commit: String,
        statusDigest: String,
        sourceLabel: String,
        destinationLabel: String,
        changedPaths: [String]
    ) {
        self.version = Self.schemaVersion
        self.capsuleDigest = capsuleDigest
        self.commit = commit
        self.statusDigest = statusDigest
        self.sourceLabel = sourceLabel
        self.destinationLabel = destinationLabel
        self.changedPaths = changedPaths.sorted()
    }

    func encodedSummary() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= ContinuityHandoff.maximumSummaryBytes,
              let summary = String(data: data, encoding: .utf8) else {
            throw ContinuityHandoffPreflightError.boundaryTooLarge
        }
        return summary
    }

    static func decode(summary: String) throws -> Self {
        guard let data = summary.data(using: .utf8),
              data.count <= ContinuityHandoff.maximumSummaryBytes else {
            throw ContinuityHandoffPreflightError.invalidBoundary
        }
        let boundary: Self
        do {
            boundary = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ContinuityHandoffPreflightError.invalidBoundary
        }
        guard boundary.version == Self.schemaVersion else {
            throw ContinuityHandoffPreflightError.invalidBoundary
        }
        return boundary
    }
}

struct ContinuityHandoffPreflightResult: Sendable {
    let boundary: ContinuityHandoffBoundary
    let prompt: String
}

enum ContinuityHandoffPreflightError: LocalizedError, Sendable, Equatable {
    case unownedChanges
    case divergentRepository
    case invalidBoundary
    case boundaryTooLarge

    var errorDescription: String? {
        switch self {
        case .unownedChanges:
            "Continuity handoff is blocked because the workspace contains changes outside the checkpoint's owned artifact paths."
        case .divergentRepository:
            "The repository or continuity capsule changed after the handoff boundary. Audit and prepare a new handoff before continuing."
        case .invalidBoundary:
            "The stored continuity handoff boundary is invalid. Prepare a new handoff."
        case .boundaryTooLarge:
            "The continuity handoff boundary exceeds its local metadata limit."
        }
    }
}

struct ContinuityHandoffPreflight: Sendable {
    private let capsuleReader: ContinuityCapsuleReader
    private let checkpointInspector: ContinuityWorkspaceCheckpointInspector

    init(
        capsuleReader: ContinuityCapsuleReader = ContinuityCapsuleReader(),
        checkpointInspector: ContinuityWorkspaceCheckpointInspector = ContinuityWorkspaceCheckpointInspector()
    ) {
        self.capsuleReader = capsuleReader
        self.checkpointInspector = checkpointInspector
    }

    func prepare(
        workspaceURL: URL,
        sourceLabel: String,
        destinationLabel: String
    ) throws -> ContinuityHandoffPreflightResult {
        let capsule = try capsuleReader.load(fromApprovedRepository: workspaceURL)
        let portablePackagePaths: Set<String> = [
            ".continuity/manifest.json",
            ".continuity/context.md",
            ".continuity/graph.json",
            ".continuity/workstreams.json",
        ]
        let checkpoint = try checkpointInspector.inspect(
            approvedWorkspaceURL: workspaceURL,
            ownedPaths: Set(capsule.artifacts.compactMap(\.path)).union(portablePackagePaths)
        )
        guard !checkpoint.blocksHandoff else {
            throw ContinuityHandoffPreflightError.unownedChanges
        }
        let prompt = try ContinuityCapsuleRenderer.render(
            capsule,
            sourceLabel: sourceLabel,
            destinationLabel: destinationLabel
        )
        return ContinuityHandoffPreflightResult(
            boundary: ContinuityHandoffBoundary(
                capsuleDigest: capsule.contentDigest,
                commit: checkpoint.commit,
                statusDigest: checkpoint.statusDigest,
                sourceLabel: sourceLabel,
                destinationLabel: destinationLabel,
                changedPaths: checkpoint.changedPaths
            ),
            prompt: prompt
        )
    }

    func revalidate(
        boundary: ContinuityHandoffBoundary,
        workspaceURL: URL
    ) throws -> String {
        let current = try prepare(
            workspaceURL: workspaceURL,
            sourceLabel: boundary.sourceLabel,
            destinationLabel: boundary.destinationLabel
        )
        guard current.boundary == boundary else {
            throw ContinuityHandoffPreflightError.divergentRepository
        }
        return current.prompt
    }
}
