import Foundation
import XCTest
@testable import CommandCenter

private final class ProviderEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ProviderStreamEvent] = []

    func append(_ event: ProviderStreamEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func snapshot() -> [ProviderStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

final class ProviderRuntimeTests: XCTestCase {
    private let fixtureExecutableURL = URL(fileURLWithPath: "/usr/bin/true")

    func testProviderLaunchRejectsWorkspaceReplacedBySymlink() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let real = fixture.appendingPathComponent("real", isDirectory: true)
        let approved = fixture.appendingPathComponent("approved", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: approved, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: fixture) }

        XCTAssertThrowsError(try ProviderCommandBuilder.build(
            provider: .codex,
            workspaceURL: approved,
            prompt: "read only",
            permission: .readOnly,
            workflow: .direct,
            selectedSkills: [],
            sessionID: nil,
            executableURL: fixtureExecutableURL
        )) { error in
            guard case ProviderLaunchError.invalidWorkspace = error else {
                return XCTFail("Expected invalidWorkspace, received \(error)")
            }
        }
    }

    private let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    func testCodexNewSessionKeepsPromptOutOfArgumentsAndAppliesReadOnlyBoundary() throws {
        let prompt = "Inspect safely; $(touch /tmp/should-never-run) `whoami`"
        let plan = try ProviderCommandBuilder.build(
            provider: .codex,
            workspaceURL: workspaceURL,
            prompt: prompt,
            permission: .readOnly,
            workflow: .direct,
            selectedSkills: [],
            sessionID: nil,
            executableURL: fixtureExecutableURL
        )

        XCTAssertEqual(plan.prompt, prompt)
        XCTAssertFalse(plan.arguments.contains(where: { $0.contains("touch") || $0.contains("whoami") }))
        XCTAssertEqual(plan.arguments.prefix(3), ["exec", "--json", "--color"])
        XCTAssertTrue(plan.arguments.contains("read-only"))
        XCTAssertFalse(plan.arguments.contains("--approve-for-me"))
        XCTAssertEqual(plan.arguments.last, "-")
    }

    func testCodexResumePlacesSafetyOptionsBeforeSubcommand() throws {
        let sessionID = "11111111-1111-4111-8111-111111111111"
        let plan = try ProviderCommandBuilder.build(
            provider: .codex,
            workspaceURL: workspaceURL,
            prompt: "Continue",
            permission: .workspaceWrite,
            workflow: .direct,
            selectedSkills: [],
            sessionID: sessionID,
            executableURL: fixtureExecutableURL
        )

        let resumeIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "resume"))
        let sandboxIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-s"))
        let approvalIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--approve-for-me"))
        XCTAssertLessThan(sandboxIndex, resumeIndex)
        XCTAssertLessThan(approvalIndex, resumeIndex)
        XCTAssertEqual(Array(plan.arguments.suffix(3)), ["resume", sessionID, "-"])
    }

    func testProviderSessionIdentifiersRejectOptionInjection() {
        XCTAssertThrowsError(try ProviderCommandBuilder.build(
            provider: .codex,
            workspaceURL: workspaceURL,
            prompt: "Continue",
            permission: .workspaceWrite,
            workflow: .direct,
            selectedSkills: [],
            sessionID: "--dangerously-bypass-approvals-and-sandbox",
            executableURL: fixtureExecutableURL
        )) { error in
            guard case ProviderLaunchError.invalidSessionID = error else {
                return XCTFail("Expected invalid session ID, got \(error)")
            }
        }
    }

    func testClaudeUsesStreamJSONAndKeepsPromptOnStdin() throws {
        let prompt = "Read this literally: ; rm -rf never"
        let plan = try ProviderCommandBuilder.build(
            provider: .claude,
            workspaceURL: workspaceURL,
            prompt: prompt,
            permission: .readOnly,
            workflow: .pickupSwarm,
            selectedSkills: ["pickup-swarm"],
            sessionID: nil,
            executableURL: fixtureExecutableURL
        )

        XCTAssertFalse(plan.arguments.contains(where: { $0.contains("rm -rf") }))
        XCTAssertTrue(plan.arguments.contains("stream-json"))
        XCTAssertTrue(plan.arguments.contains("plan"))
        XCTAssertTrue(plan.prompt.contains("pickup-swarm workflow"))
        XCTAssertTrue(plan.prompt.hasSuffix(prompt))
    }

    func testProviderDecodersExtractSessionAndAssistantText() throws {
        let codex = Data(#"{"type":"thread.started","thread_id":"12345678-1234-1234-1234-123456789abc"}"#.utf8)
        guard case .sessionID(let codexID) = ProviderEventDecoder.decode(codex, provider: .codex) else {
            return XCTFail("Expected Codex session ID")
        }
        XCTAssertEqual(codexID, "12345678-1234-1234-1234-123456789abc")

        let claude = Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello\u001b[31m world"}]}}"#.utf8)
        guard case .text(let text) = ProviderEventDecoder.decode(claude, provider: .claude) else {
            return XCTFail("Expected Claude text")
        }
        XCTAssertEqual(text, "hello world")
    }

    func testProviderDecoderRejectsMalformedSessionIdentityAsDiagnostic() throws {
        let codex = Data(#"{"type":"thread.started","thread_id":"--unsafe"}"#.utf8)
        guard case .diagnostic(let diagnostic) = ProviderEventDecoder.decode(codex, provider: .codex) else {
            return XCTFail("Expected malformed provider session diagnostic")
        }
        XCTAssertTrue(diagnostic.contains("invalid session identifier"))
    }

    func testClaudeDecoderPreservesAllTextAndToolBlocks() throws {
        let claude = Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"tool_use","name":"Read"},{"type":"text","text":"second"},{"type":"tool_use","name":"Grep"}]}}"#.utf8)
        guard case .batch(let events) = ProviderEventDecoder.decode(claude, provider: .claude) else {
            return XCTFail("Expected a batch")
        }
        guard events.count == 2,
              case .text(let text) = events[0],
              case .activity(let activity) = events[1] else {
            return XCTFail("Expected combined text and activity events")
        }
        XCTAssertEqual(text, "first\n\nsecond")
        XCTAssertEqual(activity, "Using Read, Grep")
    }

    func testCodexAuthenticationAcceptsCurrentCLIStderrContract() {
        XCTAssertTrue(ProviderHealthService.parseCodexAuthentication(
            status: 0,
            stdout: "",
            stderr: "Logged in using ChatGPT\n"
        ))
        XCTAssertFalse(ProviderHealthService.parseCodexAuthentication(
            status: 1,
            stdout: "Logged in using ChatGPT",
            stderr: ""
        ))
    }

    func testImmediateExitDrainsFinalJSONLBeforeSingleExitEvent() throws {
        let executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("The deterministic printf fixture is unavailable.")
        }

        let finalJSON = #"{"type":"item.completed","item":{"type":"agent_message","text":"final-marker"}}"#
        let plan = ProviderLaunchPlan(
            provider: .codex,
            executableURL: executableURL,
            arguments: ["%s\n", finalJSON],
            workspaceURL: workspaceURL,
            prompt: ""
        )
        let recorder = ProviderEventRecorder()
        let exited = expectation(description: "provider exited after its streams drained")
        exited.assertForOverFulfill = true

        let running = try ProviderProcessRunner().start(plan) { event in
            recorder.append(event)
            if case .exited = event {
                exited.fulfill()
            }
        }
        _ = running

        wait(for: [exited], timeout: 3)
        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 2, "Expected one final provider record followed by exactly one exit event.")

        guard events.count == 2 else { return }
        guard case .text(let text) = events[0] else {
            return XCTFail("Expected the final JSONL record before process exit.")
        }
        XCTAssertEqual(text, "final-marker")
        guard case .exited(let status) = events[1] else {
            return XCTFail("Expected .exited to be the final event.")
        }
        XCTAssertEqual(status, 0)
    }

    func testProviderStdinDeliveryIsNonblockingAndTimesOutWhenChildDoesNotRead() throws {
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("The shell fixture is unavailable.")
        }

        let plan = ProviderLaunchPlan(
            provider: .codex,
            executableURL: executableURL,
            arguments: ["-c", "sleep 1"],
            workspaceURL: workspaceURL,
            prompt: String(repeating: "x", count: 256 * 1_024)
        )
        let recorder = ProviderEventRecorder()
        let inputTimedOut = expectation(description: "bounded stdin delivery times out")
        let exited = expectation(description: "provider exits after stdin timeout")
        let started = Date()
        let running = try ProviderProcessRunner(inputDeliveryTimeout: 0.05).start(plan) { event in
            recorder.append(event)
            if case .diagnostic(let message) = event, message.contains("delivery timed out") {
                inputTimedOut.fulfill()
            }
            if case .exited = event { exited.fulfill() }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Starting must not block on provider stdin.")
        withExtendedLifetime(running) {
            wait(for: [inputTimedOut, exited], timeout: 3)
        }
        XCTAssertTrue(recorder.snapshot().contains {
            if case .diagnostic(let message) = $0 { return message.contains("delivery timed out") }
            return false
        })
    }

    func testHealthProbeDrainsBothPipesAndKillsTermIgnoringChildAtDeadline() throws {
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("The shell fixture is unavailable.")
        }

        let started = Date()
        let result = ProviderHealthService.run(
            executableURL,
            arguments: ["-c", "trap '' TERM; while :; do printf x; printf y >&2; done"],
            timeout: 0.1
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "A TERM-ignoring probe must be force-killed.")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, ProviderHealthService.maximumProbeOutputBytes)
        XCTAssertLessThanOrEqual(result.stderr.utf8.count, ProviderHealthService.maximumProbeOutputBytes)
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}
