import XCTest
import Darwin
@testable import StratagemCore

final class ExecutionTests: XCTestCase {
    func testCapturesBothStreamsAndExitCode() async throws {
        let r = try await CommandRunner().run(executable: "/bin/zsh", arguments: ["-c", "printf output; printf error >&2; exit 7"])
        XCTAssertEqual(r.stdout, "output"); XCTAssertEqual(r.stderr, "error"); XCTAssertEqual(r.exitCode, 7); XCTAssertFalse(r.succeeded)
    }
    func testStructuredArgumentsAreLiteral() async throws {
        let literal = "$(touch /tmp/SHOULD_NOT_EXIST); 'hello'"
        let r = try await CommandRunner().run(executable: "/usr/bin/printf", arguments: ["%s", literal])
        XCTAssertEqual(r.stdout, literal); XCTAssertTrue(r.succeeded)
    }
    func testWorkingDirectoryAndEnvironment() async throws {
        let r = try await CommandRunner().run(executable: "/bin/zsh", arguments: ["-c", "printf '%s|%s' \"$PWD\" \"$DESK_TEST_VALUE\""], directory: "/private/tmp", environment: ["DESK_TEST_VALUE":"a value with spaces"])
        XCTAssertEqual(r.stdout, "/private/tmp|a value with spaces")
    }
    func testMissingExecutableThrows() async {
        do { _ = try await CommandRunner().run(executable: "/nonexistent-stratagem-command"); XCTFail("Should throw") } catch {}
    }
    func testTimeoutKillsUncooperativeProcess() async throws {
        let start = Date()
        let r = try await CommandRunner().run(executable: "/bin/zsh", arguments: ["-c", "trap '' TERM; while true; do :; done"], timeout: 0.15)
        XCTAssertTrue(r.timedOut); XCTAssertFalse(r.succeeded); XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testManualCancellation() async throws {
        let task = Task { try await CommandRunner().run(executable: "/bin/zsh", arguments: ["-c", "while true; do :; done"], timeout: 20) }
        try await Task.sleep(nanoseconds: 80_000_000); task.cancel()
        let r = try await task.value; XCTAssertTrue(r.cancelled); XCTAssertFalse(r.succeeded)
    }
    func testOutputFloodIsBoundedAndDoesNotDeadlock() async throws {
        let r = try await CommandRunner().run(executable: "/usr/bin/yes", timeout: 0.2)
        XCTAssertTrue(r.timedOut); XCTAssertTrue(r.truncated); XCTAssertLessThanOrEqual(r.stdout.utf8.count, 1_048_576)
    }
    func testOwnedProcessGroupIsTerminated() async throws {
        let products = Bundle(for: ExecutionTests.self).bundleURL.deletingLastPathComponent()
        let candidates = [ProcessInfo.processInfo.environment["STRATAGEM_TEST_HOST"],
                          products.appendingPathComponent("StratagemDeskPublic.app/Contents/MacOS/StratagemDeskPublic").path,
                          products.appendingPathComponent("StratagemDesk").path].compactMap { $0 }
        guard let host = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Build StratagemDesk or set STRATAGEM_TEST_HOST to verify descendant cleanup")
        }
        let r = try await CommandRunner(hostURL: URL(fileURLWithPath: host)).run(executable: "/bin/zsh", arguments: ["-c", "sleep 60 & child=$!; printf '%s' $child; wait"], timeout: 0.2)
        XCTAssertTrue(r.timedOut)
        let pid = try XCTUnwrap(Int32(r.stdout))
        // Give launchd a moment to reap an orphan after both processes receive the signal.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
    @MainActor func fixture(_ count: Int = 2) -> (Stratagem, Configuration) {
        var s = Stratagem(); var c = Configuration()
        for index in 0..<count { var a = ActionDefinition(); a.approved = true; a.name = "step \(index)"; c.actions.append(a); s.steps.append(WorkflowStep(actionID: a.id)) }
        return (s,c)
    }
    @MainActor func testSequentialWorkflowAndDuplicateRunGuard() async {
        let (s,c) = fixture(); let executor = WorkflowExecutor(); var order: [String] = []
        XCTAssertTrue(executor.start(s, configuration: c) { a, _ in order.append(a.id); return ActionOutcome(success: true, detail: "ok") })
        XCTAssertFalse(executor.start(s, configuration: c) { _, _ in XCTFail(); return ActionOutcome(success: true, detail: "") })
        await executor.waitUntilFinished()
        XCTAssertEqual(order, c.actions.map(\.id)); XCTAssertEqual(executor.status, .succeeded); XCTAssertNil(executor.runningID)
    }
    @MainActor func testUnapprovedWorkflowNeverDispatches() {
        var (s,c) = fixture(); c.actions[1].approved = false; s.enabled = true
        let executor = WorkflowExecutor()
        XCTAssertFalse(executor.start(s, configuration: c) { _, _ in XCTFail(); return ActionOutcome(success: true, detail: "") })
        XCTAssertEqual(executor.status, .failed)
    }
    @MainActor func testFailureStopsOrContinues() async {
        var (s,c) = fixture(); let executor = WorkflowExecutor()
        executor.start(s, configuration: c) { _, _ in ActionOutcome(success: false, detail: "fail") }
        await executor.waitUntilFinished(); XCTAssertEqual(executor.logs.count, 1); XCTAssertEqual(executor.status, .failed)
        s.steps[0].continueOnFailure = true
        executor.start(s, configuration: c) { _, _ in ActionOutcome(success: false, detail: "fail") }
        await executor.waitUntilFinished(); XCTAssertEqual(executor.logs.count, 2); XCTAssertEqual(executor.status, .failed)
    }
    @MainActor func testWorkflowCancelDuringDelay() async throws {
        let (s,c) = fixture(); let executor = WorkflowExecutor()
        executor.start(s, configuration: c) { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return ActionOutcome(success: true, detail: "") }
        try await Task.sleep(nanoseconds: 40_000_000); executor.cancel(); await executor.waitUntilFinished()
        XCTAssertEqual(executor.status, .cancelled); XCTAssertEqual(executor.logs.count, 1)
    }
    @MainActor func testSensitiveWorkflowRedactsLaterStepOutput() async {
        var (s,c) = fixture(); c.actions[0].sensitive = true
        let executor = WorkflowExecutor()
        executor.start(s, configuration: c) { _, _ in ActionOutcome(success: true, detail: "SECRET") }
        await executor.waitUntilFinished()
        XCTAssertFalse(executor.logs.contains { $0.detail.contains("SECRET") })
        XCTAssertTrue(executor.logs.allSatisfy { $0.name.hasPrefix("敏感步骤") })
        XCTAssertEqual(executor.status, .succeeded)
    }
    @MainActor func testWorkflowDeadlineCancelsActiveStep() async {
        var (s,c) = fixture(1); c.settings.workflowTimeout = 0.05
        let executor = WorkflowExecutor(), start = Date()
        executor.start(s, configuration: c) { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return ActionOutcome(success: true, detail: "must not finish")
        }
        await executor.waitUntilFinished()
        XCTAssertEqual(executor.status, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    @MainActor func testWorkflowDeadlineStopsBetweenSteps() async {
        var (s,c) = fixture(); c.settings.workflowTimeout = 0.03
        let executor = WorkflowExecutor()
        executor.start(s, configuration: c) { _, _ in try await Task.sleep(nanoseconds: 50_000_000); return ActionOutcome(success: true, detail: "ok") }
        await executor.waitUntilFinished(); XCTAssertEqual(executor.logs.count, 1); XCTAssertEqual(executor.status, .failed)
    }
    @MainActor func testSequenceToRealCommandToResult() async throws {
        var (s,c) = fixture(1); s.enabled = true; s.sequence = [.up, .left, .right, .down]
        XCTAssertEqual(SequenceMatcher.match(s.sequence, in: [s]), .matched(s.id))
        let executor = WorkflowExecutor()
        executor.start(s, configuration: c) { _, timeout in
            let r = try await CommandRunner().run(executable: "/usr/bin/printf", arguments: ["STRATAGEMDESK_E2E_OK"], timeout: timeout)
            return ActionOutcome(success: r.succeeded, detail: r.stdout)
        }
        await executor.waitUntilFinished()
        XCTAssertEqual(executor.status, .succeeded); XCTAssertEqual(executor.logs.first?.detail, "STRATAGEMDESK_E2E_OK")
    }
}
