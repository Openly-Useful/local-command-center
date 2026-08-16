import Foundation
import XCTest
@testable import CommandCenter

/// Deterministic executor emitting a scripted event stream synchronously.
private struct ScriptedExecutor: ProviderSessionExecuting {
    let script: [ProviderStreamEvent]
    let stopCounter: StopCounter

    func execute(
        _ plan: ProviderLaunchPlan,
        onEvent: @escaping @Sendable (ProviderStreamEvent) -> Void
    ) throws -> ProviderSessionHandle {
        for event in script { onEvent(event) }
        return ProviderSessionHandle(
            isRunning: { false },
            onStop: { stopCounter.increment() }
        )
    }
}

private final class StopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class EnvelopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [ProviderSessionEventEnvelope] = []

    func append(_ envelope: ProviderSessionEventEnvelope) {
        lock.lock()
        envelopes.append(envelope)
        lock.unlock()
    }

    func snapshot() -> [ProviderSessionEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return envelopes
    }
}

/// Fake adapter proving the protocol permits same-provider fork when a
/// provider genuinely supports it, while the cross-provider guard stays.
private struct ForkCapableFakeAdapter: ProviderSessionAdapter {
    let provider: RuntimeProvider = .codex
    let executableURL: URL
    let workspaceURL: URL

    var capabilities: ProviderSessionCapabilities {
        ProviderSessionCapabilities(supported: [.start, .fork], unsupportedReasons: [:])
    }

    func startPlan(_ request: ProviderSessionRequest) throws -> ProviderLaunchPlan {
        try ProviderCommandBuilder.build(
            provider: provider,
            workspaceURL: request.workspaceURL,
            prompt: request.prompt,
            permission: request.permission,
            workflow: request.workflow,
            selectedSkills: request.selectedSkills,
            sessionID: nil,
            executableURL: executableURL
        )
    }

    func resumePlan(
        _ request: ProviderSessionRequest,
        providerSessionID: String
    ) throws -> ProviderLaunchPlan {
        try startPlan(request)
    }

    func forkPlan(
        _ request: ProviderSessionRequest,
        from source: ProviderSessionLineage
    ) throws -> ProviderLaunchPlan {
        guard source.provider == provider else {
            throw ProviderSessionAdapterError.crossProviderForkRejected(
                source: source.provider,
                requested: provider
            )
        }
        return try startPlan(request)
    }
}

final class ProviderSessionAdapterTests: XCTestCase {
    private let fixtureExecutableURL = URL(fileURLWithPath: "/usr/bin/true")
    private var workspaceURL: URL!

    override func setUpWithError() throws {
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    private func request(prompt: String = "hello adapter") -> ProviderSessionRequest {
        ProviderSessionRequest(
            workspaceURL: workspaceURL,
            prompt: prompt,
            permission: .readOnly,
            workflow: .direct,
            selectedSkills: []
        )
    }

    func testAdapterStartAndResumePlansMatchCurrentProviderCommandBehavior() throws {
        let sessionID = "6f000000-0000-4000-8000-000000000001"
        let adapters: [any ProviderSessionAdapter] = [
            CodexSessionAdapter(executableURL: fixtureExecutableURL),
            ClaudeSessionAdapter(executableURL: fixtureExecutableURL),
        ]
        for adapter in adapters {
            let start = try adapter.startPlan(request())
            let resume = try adapter.resumePlan(request(), providerSessionID: sessionID)
            let expectedStart = try ProviderCommandBuilder.build(
                provider: adapter.provider,
                workspaceURL: workspaceURL,
                prompt: "hello adapter",
                permission: .readOnly,
                workflow: .direct,
                selectedSkills: [],
                sessionID: nil,
                executableURL: fixtureExecutableURL
            )
            XCTAssertEqual(start.executableURL, expectedStart.executableURL)
            XCTAssertEqual(start.workspaceURL, expectedStart.workspaceURL)
            XCTAssertEqual(start.prompt, expectedStart.prompt)
            XCTAssertFalse(
                start.arguments.contains("hello adapter"),
                "The prompt stays on stdin, never in arguments"
            )
            switch adapter.provider {
            case .codex:
                XCTAssertEqual(start.arguments.last, "-")
                XCTAssertTrue(resume.arguments.contains("resume"))
                XCTAssertTrue(resume.arguments.contains(sessionID))
            case .claude:
                XCTAssertTrue(start.arguments.contains("--session-id"))
                XCTAssertTrue(resume.arguments.contains("--resume"))
                XCTAssertTrue(resume.arguments.contains(sessionID))
            }
        }
    }

    func testResumeRejectsInvalidSessionIdentityThroughTheAdapter() {
        let adapter = ClaudeSessionAdapter(executableURL: fixtureExecutableURL)
        XCTAssertThrowsError(
            try adapter.resumePlan(request(), providerSessionID: "--not-a-uuid")
        ) { error in
            guard case ProviderLaunchError.invalidSessionID = error else {
                return XCTFail("Expected invalidSessionID, received \(error)")
            }
        }
    }

    func testCrossProviderForkIsRejectedBeforeCapabilityIsConsulted() {
        let codex = CodexSessionAdapter(executableURL: fixtureExecutableURL)
        let claudeLineage = ProviderSessionLineage(
            provider: .claude,
            providerSessionID: "6f000000-0000-4000-8000-000000000002"
        )
        XCTAssertThrowsError(
            try codex.forkPlan(request(), from: claudeLineage)
        ) { error in
            XCTAssertEqual(
                error as? ProviderSessionAdapterError,
                .crossProviderForkRejected(source: .claude, requested: .codex)
            )
        }
    }

    func testSameProviderForkIsReportedUnsupportedNotSimulated() {
        for adapter in [
            CodexSessionAdapter(executableURL: fixtureExecutableURL) as any ProviderSessionAdapter,
            ClaudeSessionAdapter(executableURL: fixtureExecutableURL),
        ] {
            XCTAssertFalse(adapter.capabilities.supports(.fork))
            let lineage = ProviderSessionLineage(
                provider: adapter.provider,
                providerSessionID: "6f000000-0000-4000-8000-000000000003"
            )
            XCTAssertThrowsError(try adapter.forkPlan(request(), from: lineage)) { error in
                guard case let ProviderSessionAdapterError.unsupportedOperation(
                    provider, operation, reason
                )? = error as? ProviderSessionAdapterError else {
                    return XCTFail("Expected honest unsupported report, received \(error)")
                }
                XCTAssertEqual(provider, adapter.provider)
                XCTAssertEqual(operation, .fork)
                XCTAssertFalse(reason.isEmpty)
            }
        }
    }

    func testFakeForkCapableAdapterAllowsSameProviderForkOnly() throws {
        let fake = ForkCapableFakeAdapter(
            executableURL: fixtureExecutableURL,
            workspaceURL: workspaceURL
        )
        let sameProvider = ProviderSessionLineage(
            provider: .codex,
            providerSessionID: "6f000000-0000-4000-8000-000000000004"
        )
        XCTAssertNoThrow(try fake.forkPlan(request(), from: sameProvider))
        let crossProvider = ProviderSessionLineage(
            provider: .claude,
            providerSessionID: "6f000000-0000-4000-8000-000000000005"
        )
        XCTAssertThrowsError(try fake.forkPlan(request(), from: crossProvider))
    }

    func testDispatchAssignsMonotonicSequencesFlattensBatchesAndKeepsExitLast() throws {
        let adapter = CodexSessionAdapter(executableURL: fixtureExecutableURL)
        let recorder = EnvelopeRecorder()
        let counter = StopCounter()
        let executor = ScriptedExecutor(
            script: [
                .sessionID("6f000000-0000-4000-8000-000000000006"),
                .batch([.text("first"), .activity("Reading files")]),
                .text("second"),
                .exited(0),
            ],
            stopCounter: counter
        )
        _ = try adapter.dispatch(
            try adapter.startPlan(request()),
            executor: executor
        ) { envelope in
            recorder.append(envelope)
        }

        let envelopes = recorder.snapshot()
        XCTAssertEqual(envelopes.map(\.sequence), [0, 1, 2, 3, 4])
        guard case .sessionID = envelopes[0].event,
              case .text = envelopes[1].event,
              case .activity = envelopes[2].event,
              case .text = envelopes[3].event,
              case let .exited(status) = envelopes[4].event else {
            return XCTFail("Unexpected event ordering")
        }
        XCTAssertEqual(status, 0)
    }

    func testStopIsIdempotentAndReportsTheEffectiveCall() throws {
        let adapter = CodexSessionAdapter(executableURL: fixtureExecutableURL)
        let counter = StopCounter()
        let executor = ScriptedExecutor(script: [], stopCounter: counter)
        let handle = try adapter.dispatch(
            try adapter.startPlan(request()),
            executor: executor
        ) { _ in }

        XCTAssertTrue(handle.stop())
        XCTAssertFalse(handle.stop())
        XCTAssertFalse(handle.stop())
        XCTAssertEqual(counter.value, 1, "Underlying cancellation must run exactly once")
    }

    func testCheckpointCapturesLastObservedSessionIdentity() throws {
        let adapter = ClaudeSessionAdapter(executableURL: fixtureExecutableURL)
        let envelopes = [
            ProviderSessionEventEnvelope(
                sequence: 0,
                event: .sessionID("6f000000-0000-4000-8000-000000000007")
            ),
            ProviderSessionEventEnvelope(sequence: 1, event: .text("progress")),
            ProviderSessionEventEnvelope(sequence: 2, event: .exited(0)),
        ]
        let checkpoint = try adapter.checkpoint(from: envelopes)
        XCTAssertEqual(
            checkpoint,
            ProviderSessionCheckpoint(
                provider: .claude,
                providerSessionID: "6f000000-0000-4000-8000-000000000007",
                lastEventSequence: 2
            )
        )
    }

    func testCheckpointWithoutSessionIdentityIsReportedNotSimulated() {
        let adapter = CodexSessionAdapter(executableURL: fixtureExecutableURL)
        let envelopes = [
            ProviderSessionEventEnvelope(sequence: 0, event: .text("no identity")),
            ProviderSessionEventEnvelope(sequence: 1, event: .exited(1)),
        ]
        XCTAssertThrowsError(try adapter.checkpoint(from: envelopes)) { error in
            XCTAssertEqual(
                error as? ProviderSessionAdapterError,
                .checkpointUnavailable(.codex)
            )
        }
    }

    func testCapabilityReportsCarryHonestReasonsForEveryUnsupportedOperation() {
        for adapter in [
            CodexSessionAdapter(executableURL: fixtureExecutableURL) as any ProviderSessionAdapter,
            ClaudeSessionAdapter(executableURL: fixtureExecutableURL),
        ] {
            let capabilities = adapter.capabilities
            XCTAssertTrue(capabilities.supports(.start))
            XCTAssertTrue(capabilities.supports(.resume))
            XCTAssertTrue(capabilities.supports(.checkpoint))
            for operation in ProviderSessionOperation.allCases
            where !capabilities.supports(operation) {
                XCTAssertFalse(
                    capabilities.reasonForUnsupported(operation).isEmpty,
                    "\(adapter.provider) must explain unsupported \(operation)"
                )
            }
        }
    }
}
