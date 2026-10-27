import Foundation

public struct ControlRequest: Codable, Equatable {
    public var cmd: String
    public var title: String?
    public var noSummary: Bool?
    public var speakers: String?

    public init(cmd: String, title: String? = nil, noSummary: Bool? = nil, speakers: String? = nil) {
        self.cmd = cmd
        self.title = title
        self.noSummary = noSummary
        self.speakers = speakers
    }
}

public struct ControlResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    public var id: String?
    public var state: String?
    public var elapsed: Double?
    public var systemDB: Double?
    public var micDB: Double?
    public var step: String?
    public var progress: Double?
    public var queue: [String]?
    public var results: [String: String]?
    public var errors: [String: String]?
    public var processingID: String?
    public var warnings: [String: [String]]?
    public var hotkey: String?
    public var message: String?

    public init(ok: Bool = true, error: String? = nil, id: String? = nil) {
        self.ok = ok
        self.error = error
        self.id = id
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

public enum ControlCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([0x0A])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

public struct ControlTimeoutError: LocalizedError {
    public let seconds: Int
    public var errorDescription: String? { "Приложение не ответило за \(seconds) с, проверьте meetrec status" }
}

public struct AppUnavailableError: LocalizedError {
    public init() {}
    public var errorDescription: String? { "MeetRec не запущен или не отвечает" }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        throw MeetRecError("Слишком длинный путь сокета: \(path)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
    }
    return addr
}

private func withSockaddr<R>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func setTimeout(_ fd: Int32, _ seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func readLine(_ fd: Int32, limit: Int = 65536, timedOut: UnsafeMutablePointer<Bool>? = nil) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < limit {
        let n = read(fd, &byte, 1)
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { timedOut?.pointee = true }
        if n <= 0 { return data.isEmpty ? nil : data }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    return nil
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}

public enum ControlClient {
    public static var socketURL: URL { Paths.appSupport.appendingPathComponent("control.sock") }

    public static func send(_ request: ControlRequest, path: URL = socketURL, timeout: Int = 120) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MeetRecError("Не удалось создать сокет") }
        defer { close(fd) }
        setTimeout(fd, timeout)
        var addr = try makeAddress(path.path)
        if withSockaddr(&addr, { connect(fd, $0, $1) }) != 0 {
            if errno == ECONNREFUSED || errno == ENOENT { throw AppUnavailableError() }
            throw MeetRecError("Не удалось подключиться к MeetRec: \(String(cString: strerror(errno)))")
        }
        writeAll(fd, try ControlCodec.encode(request))
        var timedOut = false
        guard let line = readLine(fd, limit: 1 << 20, timedOut: &timedOut) else {
            if timedOut { throw ControlTimeoutError(seconds: timeout) }
            throw MeetRecError("MeetRec закрыл соединение без ответа")
        }
        return try ControlCodec.decode(ControlResponse.self, from: line)
    }
}

public final class ControlServer {
    private let path: URL
    private let handler: (ControlRequest) async -> ControlResponse
    private var listenFD: Int32 = -1
    private var stopped = false

    public init(path: URL = ControlClient.socketURL, handler: @escaping (ControlRequest) async -> ControlResponse) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var addr = try makeAddress(path.path)
        if (try? ControlClient.send(ControlRequest(cmd: "ping"), path: path, timeout: 2)) != nil {
            throw MeetRecError("MeetRec уже запущен")
        }
        unlink(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MeetRecError("Не удалось создать сокет") }
        let bound = withSockaddr(&addr) { bind(fd, $0, $1) }
        guard bound == 0, chmod(path.path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw MeetRecError("Не удалось открыть сокет управления: \(String(cString: strerror(errno)))")
        }
        listenFD = fd
        DispatchQueue(label: "meetrec.control.accept").async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        stopped = true
        guard listenFD >= 0 else { return }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        listenFD = -1
        unlink(path.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while !stopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if stopped { return }
                if errno != EINTR { usleep(100_000) }
                continue
            }
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        setTimeout(client, 5)
        guard let line = readLine(client) else {
            close(client)
            return
        }
        guard let request = try? ControlCodec.decode(ControlRequest.self, from: line) else {
            writeAll(client, (try? ControlCodec.encode(ControlResponse.failure("Неверный запрос"))) ?? Data())
            close(client)
            return
        }
        let handler = handler
        Task {
            let response = await handler(request)
            writeAll(client, (try? ControlCodec.encode(response)) ?? Data())
            close(client)
        }
    }
}
