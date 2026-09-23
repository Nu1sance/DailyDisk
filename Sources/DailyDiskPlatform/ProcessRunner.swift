import DailyDiskCore
import Darwin
import Foundation

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        guard request.executableURL.path.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: request.executableURL.path)
        else {
            throw ProcessRunnerError.invalidExecutable(request.executableURL.path)
        }
        guard request.timeoutSeconds.isFinite, request.timeoutSeconds > 0 else {
            throw ProcessRunnerError.invalidTimeout
        }

        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        continuation.resume(returning: try execute(request, cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private func execute(
    _ request: ProcessRequest,
    cancellation: ProcessCancellation
) throws -> ProcessResult {
    if cancellation.isCancelled { throw CancellationError() }

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDisk.Process.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
    let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
    guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: nil),
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: nil),
        let stdout = FileHandle(forWritingAtPath: stdoutURL.path),
        let stderr = FileHandle(forWritingAtPath: stderrURL.path)
    else {
        throw ProcessRunnerError.cannotCreateCaptureFiles
    }
    defer {
        try? stdout.close()
        try? stderr.close()
    }

    let process = Process()
    process.executableURL = request.executableURL
    process.arguments = request.arguments
    if let environment = request.environment {
        process.environment = environment
    }
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        throw ProcessRunnerError.launchFailed(String(describing: error))
    }

    let deadline = Date().addingTimeInterval(request.timeoutSeconds)
    var terminationReason: ProcessTerminationReason?
    while process.isRunning {
        if cancellation.isCancelled {
            terminationReason = .cancelled
            terminate(process)
            break
        }
        if Date() >= deadline {
            terminationReason = .timedOut
            terminate(process)
            break
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
    process.waitUntilExit()
    try stdout.synchronize()
    try stderr.synchronize()

    switch terminationReason {
    case .cancelled:
        throw CancellationError()
    case .timedOut:
        throw ProcessRunnerError.timedOut(
            executable: request.executableURL.path,
            seconds: request.timeoutSeconds
        )
    case nil:
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: try Data(contentsOf: stdoutURL),
            standardError: try Data(contentsOf: stderrURL)
        )
    }
}

private func terminate(_ process: Process) {
    process.terminate()
    let graceDeadline = Date().addingTimeInterval(1)
    while process.isRunning && Date() < graceDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

private enum ProcessTerminationReason {
    case cancelled
    case timedOut
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case invalidExecutable(String)
    case invalidTimeout
    case cannotCreateCaptureFiles
    case launchFailed(String)
    case timedOut(executable: String, seconds: Double)
    case nonzeroExit(executable: String, status: Int32, standardError: String)
}

extension ProcessResult {
    public func requireSuccess(executable: String) throws -> Data {
        guard terminationStatus == 0 else {
            throw ProcessRunnerError.nonzeroExit(
                executable: executable,
                status: terminationStatus,
                standardError: String(decoding: standardError, as: UTF8.self)
            )
        }
        return standardOutput
    }
}
