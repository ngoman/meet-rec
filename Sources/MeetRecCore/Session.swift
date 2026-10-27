import Foundation

public enum SessionState: String, Codable {
    case recording, recorded, processing, failed, done
}

public final class FileLock {
    private var fd: Int32
    private let mutex = NSLock()

    public init?(url: URL) {
        let (fd, _) = FileLock.lockFD(url)
        guard fd >= 0 else { return nil }
        self.fd = fd
    }

    private static func lockFD(_ url: URL) -> (Int32, Int32) {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return (-1, errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            return (-1, error)
        }
        return (fd, 0)
    }

    public static func attempt(url: URL) -> (lock: FileLock?, errno: Int32) {
        let (fd, error) = lockFD(url)
        guard fd >= 0 else { return (nil, error) }
        return (FileLock(fd: fd), 0)
    }

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        unlock()
    }

    public static func acquire(url: URL, retry: TimeInterval = 0.2) -> FileLock? {
        let deadline = Date().addingTimeInterval(retry)
        while true {
            if let lock = FileLock(url: url) { return lock }
            if Date() >= deadline { return nil }
            usleep(20_000)
        }
    }

    public func unlock() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    public static func isLocked(_ url: URL) -> Bool {
        FileLock(url: url) == nil
    }
}

public struct SessionInfo: Codable {
    public var id = ""
    public var startedAt: Date
    public var endedAt: Date?
    public var sampleRate = 48000
    public var title: String?
    public var state: SessionState
    public var error: String?
    public var warnings: [String] = []
    public var systemSignal: Bool?
    public var micSignal: Bool?
    public var systemOutputSeen: Bool?
    public var speakers: String?

    enum CodingKeys: String, CodingKey {
        case startedAt, endedAt, sampleRate, title, state, error, warnings, systemSignal, micSignal, systemOutputSeen, speakers
    }

    public init(id: String, startedAt: Date, title: String?) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.state = .recording
    }

    public var dir: URL { Paths.sessionsDir.appendingPathComponent(id) }
    public var systemPCM: URL { dir.appendingPathComponent("system.pcm") }
    public var micPCM: URL { dir.appendingPathComponent("mic.pcm") }
    public var lockURL: URL { dir.appendingPathComponent(".lock") }
    public var isBusy: Bool { FileLock.isLocked(lockURL) }

    public func save(to directory: URL? = nil) throws {
        let target = directory ?? dir
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Json.encoder.encode(self).write(to: target.appendingPathComponent("session.json"), options: .atomic)
    }
}

public enum SessionStore {
    public static func slug(_ title: String) -> String {
        var out = ""
        var lastDash = true
        for ch in title {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        out = String(out.prefix(60))
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    public static func makeID(date: Date, title: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        var id = f.string(from: date)
        if let title, case let s = slug(title), !s.isEmpty { id += "_" + s }
        return id
    }

    public static func create(title: String?, date: Date = Date()) throws -> SessionInfo {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = makeID(date: date, title: trimmed)
        try FileManager.default.createDirectory(at: Paths.sessionsDir, withIntermediateDirectories: true)
        var id = base
        var n = 2
        while true {
            do {
                try FileManager.default.createDirectory(at: Paths.sessionsDir.appendingPathComponent(id),
                                                        withIntermediateDirectories: false)
                break
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                id = "\(base)-\(n)"
                n += 1
            }
        }
        return SessionInfo(id: id, startedAt: date, title: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    public static func load(dir: URL) throws -> SessionInfo {
        var info = try Json.decoder.decode(SessionInfo.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        info.id = dir.lastPathComponent
        return info
    }

    public static func list() -> [SessionInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { try? load(dir: $0) }.sorted { $0.id < $1.id }
    }

    public static func pending() -> [SessionInfo] {
        list().filter { $0.state != .done && !$0.isBusy }.map {
            var info = $0
            if info.state == .processing { info.state = .recorded }
            return info
        }
    }

    public static func resolve(_ arg: String) throws -> SessionInfo {
        let dir = arg.contains("/")
            ? URL(fileURLWithPath: expandTilde(arg))
            : Paths.sessionsDir.appendingPathComponent(arg)
        let resolved = dir.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == Paths.sessionsDir.resolvingSymlinksInPath().path else {
            throw MeetRecError("Путь вне каталога сессий: \(dir.path)")
        }
        do {
            return try load(dir: resolved)
        } catch {
            throw MeetRecError("Сессия не найдена: \(dir.path)")
        }
    }

    public static func delete(id: String) throws {
        let dir = Paths.sessionsDir.appendingPathComponent(id)
        guard let lock = FileLock.acquire(url: dir.appendingPathComponent(".lock")) else {
            throw MeetRecError("Сессия занята: \(id)")
        }
        defer { lock.unlock() }
        try FileManager.default.removeItem(at: dir)
    }

    public static func cleanDone(outputURL: URL) {
        for info in list() where info.state == .done {
            guard let lock = FileLock.acquire(url: info.lockURL) else { continue }
            let out = info.dir.appendingPathComponent("out")
            if FileManager.default.fileExists(atPath: out.path) {
                guard (try? moveResult(from: out, id: info.id, to: outputURL)) != nil else {
                    lock.unlock()
                    continue
                }
            }
            try? FileManager.default.removeItem(at: info.dir)
            lock.unlock()
        }
    }

    @discardableResult
    public static func moveResult(from out: URL, id: String, to outputURL: URL) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            throw MeetRecError("Не удалось создать папку встреч \(outputURL.path): \(error.localizedDescription)")
        }
        var dest = outputURL.appendingPathComponent(id)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = outputURL.appendingPathComponent("\(id)-\(n)")
            n += 1
        }
        try fm.moveItem(at: out, to: dest)
        return dest
    }
}

public enum AppInstance {
    public enum Result {
        case acquired(FileLock)
        case alreadyRunning
        case unavailable(Int32)
    }

    public static func acquire(in directory: URL = Paths.appSupport) -> Result {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attempt = FileLock.attempt(url: directory.appendingPathComponent("app.lock"))
        if let lock = attempt.lock { return .acquired(lock) }
        return attempt.errno == EWOULDBLOCK ? .alreadyRunning : .unavailable(attempt.errno)
    }
}
