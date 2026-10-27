import Foundation

struct ShellResult {
    var status: Int32
    var signaled: Bool
    var stdout: Data
    var stderr: String
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
    var get: T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum ProcessRunner {
    private static let live = Box<[Process]>([])
    private static let shutdown = Box(false)

    static func resetShutdown() {
        shutdown.mutate { $0 = false }
    }

    static func terminateAll(grace: TimeInterval) {
        shutdown.mutate { $0 = true }
        let processes = live.get
        for p in processes where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, processes.contains(where: { $0.isRunning }) { usleep(50_000) }
        for p in processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        onStderr: ((String) -> Void)? = nil
    ) async throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MeetRecError("Не найден исполняемый файл: \(executable)")
        }
        try Task.checkCancellation()
        if shutdown.get { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.qualityOfService = .utility
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let out = Box(Data())
        let err = Box(Data())
        let timedOut = Box(false)
        let cancelled = Box(false)
        let group = DispatchGroup()
        func drain(_ pipe: Pipe, _ sink: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global().async {
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty { sink(chunk) }
                group.leave()
            }
        }
        drain(outPipe) { chunk in out.mutate { $0.append(chunk) } }
        drain(errPipe) { chunk in
            err.mutate { $0.append(chunk) }
            onStderr?(String(decoding: chunk, as: UTF8.self))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { p in
                    live.mutate { $0.removeAll { $0 === p } }
                    DispatchQueue.global().async {
                        if group.wait(timeout: .now() + 3) == .timedOut {
                            try? outPipe.fileHandleForReading.close()
                            try? errPipe.fileHandleForReading.close()
                        }
                        if timedOut.get {
                            continuation.resume(throwing: MeetRecError("Превышен таймаут: \(executable)"))
                        } else if cancelled.get || shutdown.get {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: ShellResult(
                                status: p.terminationStatus, signaled: p.terminationReason == .uncaughtSignal,
                                stdout: out.get, stderr: String(decoding: err.get, as: UTF8.self)))
                        }
                    }
                }
                live.mutate { $0.append(process) }
                do {
                    try process.run()
                } catch {
                    live.mutate { $0.removeAll { $0 === process } }
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: MeetRecError("Не удалось запустить \(executable): \(error.localizedDescription)"))
                    return
                }
                if cancelled.get || shutdown.get { process.terminate() }
                if let stdin {
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timedOut.mutate { $0 = true }
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.mutate { $0 = true }
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
