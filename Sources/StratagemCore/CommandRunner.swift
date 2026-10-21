import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let cancelled: Bool
    public let truncated: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
public struct CommandRunner: Sendable {
    // The host calls setsid() then execv(). It gives each invocation an owned process group.
    public var hostURL: URL?
    public init(hostURL: URL? = nil) { self.hostURL = hostURL }
    public func run(executable: String, arguments: [String] = [], directory: String = "", environment: [String: String] = [:], timeout: Double = 30) async throws -> CommandResult {
        guard executable.hasPrefix("/"), timeout.isFinite, timeout > 0 else { throw DeskError("可执行文件必须为绝对路径，超时必须大于零") }
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.runBlocking(executable: executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout, flag: flag)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { flag.cancel() })
    }
    private func runBlocking(executable: String, arguments: [String], directory: String, environment: [String: String], timeout: Double, flag: CancellationFlag) throws -> CommandResult {
        if flag.cancelled { throw CancellationError() }
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = hostURL ?? URL(fileURLWithPath: executable)
        process.arguments = hostURL == nil ? arguments : ["--command-host", executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory.isEmpty ? NSHomeDirectory() : (directory as NSString).expandingTildeInPath)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        defer {
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        }
        let outFD = out.fileHandleForReading.fileDescriptor, errFD = err.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        try process.run()
        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        var stdout = Data(), stderr = Data(), truncated = false, timedOut = false, cancelled = false
        let limit = 1_048_576
        func drain(_ fd: Int32, _ data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bounded work per poll even if a process continuously floods output.
            for _ in 0..<32 {
                let size = read(fd, &buffer, buffer.count)
                if size <= 0 { break }
                let remaining = max(0, limit - data.count)
                data.append(contentsOf: buffer.prefix(min(size, remaining)))
                if size > remaining { truncated = true }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var stopTime: Double?
        func signal(_ value: Int32) {
            if hostURL != nil { _ = kill(-process.processIdentifier, value) }
            if process.isRunning { _ = kill(process.processIdentifier, value) }
        }
        while process.isRunning {
            drain(outFD, &stdout); drain(errFD, &stderr)
            let now = ProcessInfo.processInfo.systemUptime
            if stopTime == nil && (flag.cancelled || now - start >= timeout) {
                cancelled = flag.cancelled; timedOut = !cancelled
                stopTime = now; signal(SIGTERM)
            }
            if let stop = stopTime, now - stop >= 0.25 { signal(SIGKILL) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Do not let descendants outlive their owning command, or wait on inherited pipe writers.
        if hostURL != nil { _ = kill(-process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        drain(outFD, &stdout); drain(errFD, &stderr)
        return CommandResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: process.terminationStatus, timedOut: timedOut, cancelled: cancelled || flag.cancelled, truncated: truncated)
    }
}
