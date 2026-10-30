import CryptoKit
import Foundation

public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var body = Substring(text)
        if body.hasPrefix("v") { body = body.dropFirst() }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        parts = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static var current: String {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if let x = AppVersion(a), let y = AppVersion(b) { return x == y }
        return a == b
    }
}

public struct UpdateRelease: Equatable {
    public var version: String
    public var archiveURL: URL
    public var checksumURL: URL

    public init(version: String, archiveURL: URL, checksumURL: URL) {
        self.version = version
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
    }
}

public struct UpdateResult: Codable, Equatable {
    public var from: String
    public var to: String
    public var ok: Bool
    public var error: String?

    public init(from: String, to: String, ok: Bool, error: String? = nil) {
        self.from = from
        self.to = to
        self.ok = ok
        self.error = error
    }
}

public struct UpdateState: Codable, Equatable {
    public var lastCheck: Date?
    public var failedVersion: String?
    public var lastResult: UpdateResult?

    public init(lastCheck: Date? = nil, failedVersion: String? = nil, lastResult: UpdateResult? = nil) {
        self.lastCheck = lastCheck
        self.failedVersion = failedVersion
        self.lastResult = lastResult
    }

    public static var url: URL { Paths.appSupport.appendingPathComponent("update-state.json") }

    public static func load(from url: URL = UpdateState.url) -> UpdateState {
        guard let data = try? Data(contentsOf: url), let state = try? Json.decoder.decode(UpdateState.self, from: data) else {
            return UpdateState()
        }
        return state
    }

    @discardableResult
    public static func update(at url: URL = UpdateState.url, _ body: (inout UpdateState) -> Void) -> UpdateState {
        var state = load(from: url)
        body(&state)
        try? state.save(to: url)
        return state
    }

    public func save(to url: URL = UpdateState.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Json.encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum UpdatePolicy {
    public static let interval: TimeInterval = 24 * 3600
    public static let restartIdle: TimeInterval = 120
    public static let restartQuiet: TimeInterval = 120

    public static func canRestart(idle: TimeInterval, sinceWork: TimeInterval?, explicit: Bool) -> Bool {
        (explicit || idle >= restartIdle) && (sinceWork == nil || sinceWork! >= restartQuiet)
    }

    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    public static func shouldInstall(candidate: String, current: String, failedVersion: String?, manual: Bool) -> Bool {
        guard let candidate = AppVersion(candidate), let current = AppVersion(current), candidate > current else { return false }
        if !manual, let failed = failedVersion.flatMap({ AppVersion($0) }), failed == candidate { return false }
        return true
    }
}

private struct Feed: Decodable {
    struct Asset: Decodable {
        var name: String
        var browserDownloadUrl: String
    }

    var tagName: String?
    var draft: Bool?
    var prerelease: Bool?
    var assets: [Asset]?
}

public enum Updater {
    static let githubPrefix = "https://github.com/ngoman/meet-rec/releases/download/"
    static let designatedRequirement = #"designated => identifier "local.meetrec.app""#
    static let bundleID = "local.meetrec.app"

    public static var feedOverride: URL? {
        guard let value = ProcessInfo.processInfo.environment["MEETREC_UPDATE_FEED"], !value.isEmpty,
              let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return url }
        if scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") { return url }
        return nil
    }

    public static var feedURL: URL {
        feedOverride ?? URL(string: "https://api.github.com/repos/ngoman/meet-rec/releases/latest")!
    }

    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    public static var updatesDir: URL { Paths.appSupport.appendingPathComponent("updates") }
    public static var stagedDir: URL { updatesDir.appendingPathComponent("staged") }
    public static var stagedApp: URL { stagedDir.appendingPathComponent("MeetRec.app") }

    public static func latestRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MeetRec/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw MeetRecError("GitHub ответил кодом \(http.statusCode)") }
        }
        return try parseRelease(data: data, arch: arch, requireGitHub: feedOverride == nil)
    }

    public static func parseRelease(data: Data, arch: String, requireGitHub: Bool) throws -> UpdateRelease? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let feed = try? decoder.decode(Feed.self, from: data) else {
            throw MeetRecError("Не удалось разобрать ответ GitHub")
        }
        if feed.draft == true || feed.prerelease == true { return nil }
        guard let version = feed.tagName.flatMap({ AppVersion($0) }) else { return nil }
        let assets = feed.assets ?? []
        func find(_ name: String) throws -> URL? {
            guard let asset = assets.first(where: { $0.name == name }) else { return nil }
            guard let url = URL(string: asset.browserDownloadUrl) else {
                throw MeetRecError("Неверная ссылка на файл обновления: \(name)")
            }
            if requireGitHub, !url.absoluteString.hasPrefix(githubPrefix) {
                throw MeetRecError("Ссылка на обновление ведет не на GitHub релиз: \(name)")
            }
            return url
        }
        guard let archive = try find("MeetRec-\(arch).zip"), let checksum = try find("MeetRec-\(arch).zip.sha256") else {
            return nil
        }
        return UpdateRelease(version: version.description, archiveURL: archive, checksumURL: checksum)
    }

    public static func preflight(installed: URL) throws {
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw MeetRecError("Нет прав на запись в \(parent.path), обновить не получится")
        }
        try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        let app = try installed.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let support = try Paths.appSupport.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let app, let support, app.isEqual(support) else {
            throw MeetRecError("Приложение и данные MeetRec лежат на разных дисках, обновить не получится")
        }
    }

    public static func cleanStaging() {
        try? FileManager.default.removeItem(at: updatesDir)
    }

    public static func stage(_ release: UpdateRelease, onStep: (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: updatesDir)
        let download = updatesDir.appendingPathComponent("download")
        do {
            try fm.createDirectory(at: download, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
            onStep("Скачиваю версию \(release.version)…")
            let zip = download.appendingPathComponent("MeetRec.zip")
            let sum = download.appendingPathComponent("MeetRec.zip.sha256")
            try await fetch(release.archiveURL, to: zip)
            try Task.checkCancellation()
            try await fetch(release.checksumURL, to: sum)
            try Task.checkCancellation()

            onStep("Готовлю версию \(release.version)…")
            let expected = try String(contentsOf: sum, encoding: .utf8)
                .split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
            guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
                throw MeetRecError("Файл контрольной суммы обновления поврежден")
            }
            guard try sha256(of: zip) == expected else {
                throw MeetRecError("Контрольная сумма обновления не совпала")
            }
            try Task.checkCancellation()

            let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, stagedDir.path], timeout: 300)
            guard unzip.status == 0 else { throw MeetRecError("Не удалось распаковать обновление: \(Processor.stderrTail(unzip.stderr))") }
            guard try fm.contentsOfDirectory(atPath: stagedDir.path) == ["MeetRec.app"] else {
                throw MeetRecError("В архиве обновления неожиданное содержимое")
            }
            try? fm.removeItem(at: download)
            _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path], timeout: 60)
            try Task.checkCancellation()

            let verify = try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--strict", stagedApp.path], timeout: 60)
            guard verify.status == 0 else { throw MeetRecError("Подпись обновления недействительна: \(Processor.stderrTail(verify.stderr))") }
            let requirement = try await ProcessRunner.run("/usr/bin/codesign", ["-d", "-r-", stagedApp.path], timeout: 60)
            guard (String(decoding: requirement.stdout, as: UTF8.self) + requirement.stderr).contains(designatedRequirement) else {
                throw MeetRecError("Обновление подписано без фиксированного требования, разрешения macOS сбросились бы")
            }
            try Task.checkCancellation()

            let info = NSDictionary(contentsOf: stagedApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == bundleID,
                  let plistVersion = info?["CFBundleShortVersionString"] as? String,
                  AppVersion.same(plistVersion, release.version) else {
                throw MeetRecError("Версия или идентификатор в обновлении не совпадают с релизом")
            }
            let probe = try await ProcessRunner.run(
                stagedApp.appendingPathComponent("Contents/MacOS/meetrec").path, ["version"], timeout: 30)
            let printed = String(decoding: probe.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.status == 0, AppVersion.same(printed, release.version) else {
                throw MeetRecError("Новая версия не запускается")
            }
            try Task.checkCancellation()

            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            let deps = try await ProcessRunner.run(
                "/bin/bash", [stagedApp.appendingPathComponent("Contents/Resources/deps.sh").path],
                environment: env, timeout: 1800, killGroup: true)
            guard deps.status == 0 else { throw MeetRecError("Не удалось обновить зависимости: \(Processor.stderrTail(deps.stderr))") }
            try Task.checkCancellation()
            return stagedApp
        } catch {
            try? fm.removeItem(at: updatesDir)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func fetch(_ url: URL, to dest: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("MeetRec/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: temp)
            throw MeetRecError("Не удалось скачать \(url.lastPathComponent): код \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func spawnApply(staged: URL, installed: URL, from: String, to: String) throws {
        try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        let logURL = Paths.appSupport.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = installed.appendingPathComponent("Contents/MacOS/meetrec")
        process.arguments = ["_apply-update", staged.path, installed.path, String(getpid()), from, to]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }
}

public struct UpdateInstaller {
    public var stateURL = UpdateState.url
    public var backup = Paths.appSupport.appendingPathComponent("update-rollback/MeetRec.app")
    public var exitWait: TimeInterval = 20
    public var exitGiveUp: TimeInterval = 600
    public var probeTimeout: TimeInterval = 30
    public var probeInterval: TimeInterval = 0.5
    public var isAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno != ESRCH }
    public var launch: (URL) -> Void = UpdateInstaller.open
    public var probe: () -> String? = { try? ControlClient.send(ControlRequest(cmd: "status"), timeout: 2).version }
    public var register: (URL) -> Void = UpdateInstaller.lsregister
    public var terminateNew: (URL) -> Void = UpdateInstaller.terminate
    public var sessionBusy: () -> Bool = { SessionStore.list().contains { $0.isBusy } }
    public var isNewRunning: (URL) -> Bool = { !UpdateInstaller.runningPIDs($0).isEmpty }
    public var busyWait: TimeInterval = 6 * 3600
    public var busyInterval: TimeInterval = 5
    public var log: (String) -> Void = { fputs("\(ISO8601DateFormatter().string(from: Date())) \($0)\n", stderr) }

    public init() {}

    @discardableResult
    public func apply(staged: URL, installed: URL, pid: Int32, from: String, to: String) -> Bool {
        func record(_ error: String?, failed: Bool) {
            UpdateState.update(at: stateURL) {
                if failed { $0.failedVersion = to } else if error == nil { $0.failedVersion = nil }
                $0.lastResult = UpdateResult(from: from, to: to, ok: error == nil, error: error)
            }
            log(error.map { "Обновление \(from) до \(to) не удалось: \($0)" } ?? "Обновление \(from) до \(to) установлено")
        }

        let fm = FileManager.default
        func removeBackup() {
            try? fm.removeItem(at: backup)
            rmdir(backup.deletingLastPathComponent().path)
        }
        let started = Date()
        var timedOut = false
        while isAlive(pid) {
            let waited = Date().timeIntervalSince(started)
            if waited >= exitGiveUp {
                log("Старый процесс так и не завершился")
                return false
            }
            if waited >= exitWait, !timedOut {
                timedOut = true
                record("Приложение не завершилось за \(Int(exitWait)) с", failed: false)
            }
            usleep(100_000)
        }
        if timedOut {
            launch(installed)
            return false
        }

        try? fm.removeItem(at: backup)
        do {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staged, to: backup)
        } catch {
            record("Не удалось подготовить замену: \(error.localizedDescription)", failed: false)
            launch(installed)
            return false
        }
        let swapError = Self.swap(backup, installed)
        guard swapError == 0 else {
            removeBackup()
            record("Не удалось заменить приложение: \(String(cString: strerror(swapError)))", failed: false)
            launch(installed)
            return false
        }
        register(installed)
        launch(installed)

        let probeDeadline = Date().addingTimeInterval(probeTimeout)
        while true {
            if let running = probe(), AppVersion.same(running, to) {
                removeBackup()
                record(nil, failed: false)
                return true
            }
            if Date() >= probeDeadline { break }
            usleep(UInt32(probeInterval * 1_000_000))
        }

        func answered() -> Bool {
            guard let running = probe(), AppVersion.same(running, to) else { return false }
            removeBackup()
            record(nil, failed: false)
            return true
        }
        if isNewRunning(installed), sessionBusy() {
            let busyDeadline = Date().addingTimeInterval(busyWait)
            var free = 0
            while true {
                if answered() { return true }
                if Date() >= busyDeadline {
                    record("Новая версия не ответила за \(Int(probeTimeout)) с, но идет запись или обработка, откат не выполнен. Копия старой версии: \(backup.path)", failed: false)
                    return false
                }
                usleep(UInt32(busyInterval * 1_000_000))
                if !isNewRunning(installed) { break }
                free = sessionBusy() ? 0 : free + 1
                if free >= 2 { break }
            }
        }
        if answered() { return true }
        terminateNew(installed)
        var message = "Новая версия не запустилась за \(Int(probeTimeout)) с, возвращена версия \(from)"
        let backError = Self.swap(backup, installed)
        if backError == 0 {
            removeBackup()
        } else {
            message = "Новая версия не запустилась, откат не удался: \(String(cString: strerror(backError))). Копия старой версии: \(backup.path)"
        }
        record(message, failed: true)
        register(installed)
        launch(installed)
        return false
    }

    static func swap(_ a: URL, _ b: URL) -> Int32 {
        renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    @discardableResult
    static func capture(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func open(_ app: URL) {
        var arguments = ["-g", "-n"]
        let env = ProcessInfo.processInfo.environment
        for key in ["MEETREC_SUPPORT_DIR", "MEETREC_UPDATE_FEED"] {
            if let value = env[key], !value.isEmpty { arguments += ["--env", "\(key)=\(value)"] }
        }
        arguments.append(app.path)
        capture("/usr/bin/open", arguments)
    }

    static func lsregister(_ app: URL) {
        capture("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
    }

    static func runningPIDs(_ app: URL) -> [Int32] {
        let executable = app.appendingPathComponent("Contents/MacOS/MeetRecApp")
        let paths = [executable.path, executable.resolvingSymlinksInPath().path]
        return capture("/usr/bin/pgrep", ["-x", "MeetRecApp"]).output
            .split(whereSeparator: { $0.isNewline }).compactMap { Int32($0) }
            .filter { $0 != getpid() }
            .filter { paths.contains(capture("/bin/ps", ["-o", "comm=", "-p", String($0)]).output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func terminate(_ app: URL) {
        func pids() -> [Int32] { runningPIDs(app) }
        pids().forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while !pids().isEmpty, Date() < deadline { usleep(100_000) }
        pids().forEach { kill($0, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(2)
        while !pids().isEmpty, Date() < killDeadline { usleep(100_000) }
    }
}
