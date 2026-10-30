import Foundation
import MeetRecCore

func log(_ message: String) {
    fputs(message + "\n", stderr)
}

func die(_ message: String, code: Int32 = 1) -> Never {
    log("meetrec: \(message)")
    exit(code)
}

func usage() -> Never {
    log("""
        Использование:
          meetrec start [--title T] [--no-summary] [--speakers N|auto]
                                                     запись через приложение MeetRec (рекомендуется)
          meetrec stop [--wait]
          meetrec status [--json]
          meetrec update
          meetrec version
          meetrec record [--title T] [--no-summary] [--speakers N|auto]
                                                     запись прямо из CLI, до Ctrl+C
          meetrec process <id|path> [--speakers N|auto] | --pending
          meetrec list
          meetrec config [set <key> <value>]

        Из терминала команда record пишет системный звук только если у терминала есть доступ к нему.
        Команды start и stop работают через приложение MeetRec и лишены этого ограничения.
        """)
    exit(1)
}

signal(SIGPIPE, SIG_IGN)

var signalSources: [DispatchSourceSignal] = []
var currentSession: SessionInfo?

func speakersArgument(_ args: [String], _ i: inout Int) -> String {
    i += 1
    guard i < args.count else { usage() }
    guard let value = Speakers.normalize(args[i]) else { die("--speakers: допустимо 1-6 или auto") }
    return value
}

func report(_ result: ProcessResult) {
    for warning in result.warnings { log("Предупреждение: \(warning)") }
    print(result.url.path)
}

func processSession(_ info: SessionInfo, config: Config) async throws -> ProcessResult {
    let processor = Processor(config: config)
    var lastStep = ""
    processor.onStatus = { status in
        guard status.step != lastStep else { return }
        lastStep = status.step
        log(status.step)
    }
    return try await processor.process(info)
}

@MainActor func record(_ args: [String]) async throws {
    var title: String?
    var config = try Config.load()
    var speakers = config.speakers
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--title":
            i += 1
            guard i < args.count else { usage() }
            title = args[i]
        case "--no-summary": config.summary = false
        case "--speakers": speakers = speakersArgument(args, &i)
        default: usage()
        }
        i += 1
    }

    for sig in [SIGINT, SIGHUP, SIGTERM] { signal(sig, SIG_IGN) }
    let (stream, stopSignal) = AsyncStream.makeStream(of: Void.self)
    var signalCount = 0
    for sig in [SIGINT, SIGHUP, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            signalCount += 1
            if signalCount == 1 {
                stopSignal.yield()
                return
            }
            Processor.cancelAll(grace: 2)
            if var info = currentSession, FileManager.default.fileExists(atPath: info.dir.path) {
                info.state = .recorded
                try? info.save()
            }
            log("Прервано")
            exit(130)
        }
        source.resume()
        signalSources.append(source)
    }

    let recorder = Recorder()
    recorder.onWarning = { log("Предупреждение: \($0)") }
    try await recorder.start(title: title, speakers: speakers)
    currentSession = recorder.session
    if signalCount > 0 {
        if let id = recorder.stop()?.id { try? SessionStore.delete(id: id) }
        log("Прервано до начала записи")
        exit(130)
    }
    log("Запись идет, остановка по Ctrl+C")

    let started = Date()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        log("\(Transcript.formatTime(Date().timeIntervalSince(started)))  sys \(Int(recorder.systemDB)) dB  mic \(Int(recorder.micDB)) dB")
    }
    timer.resume()
    for await _ in stream { break }
    timer.cancel()

    guard let info = recorder.stop() else { die("сессия не создана") }
    currentSession = info
    log("Запись остановлена, обработка")
    report(try await processSession(info, config: config))
}

func process(_ args: [String]) async throws {
    let config = try Config.load()
    if args == ["--pending"] {
        var failed = false
        SessionStore.cleanDone(outputURL: config.outputURL)
        for info in SessionStore.pending() {
            log("Сессия \(info.id)")
            do {
                report(try await processSession(info, config: config))
            } catch {
                log("meetrec: \(info.id): \(error.localizedDescription)")
                failed = true
            }
        }
        if failed { exit(1) }
    } else if args.count == 1 || (args.count == 3 && args[1] == "--speakers") {
        var info = try SessionStore.resolve(args[0])
        if args.count == 3 {
            guard let value = Speakers.normalize(args[2]) else { die("--speakers: допустимо 1-6 или auto") }
            info.speakers = value
        }
        report(try await processSession(info, config: config))
    } else {
        usage()
    }
}

func list() {
    for info in SessionStore.list() {
        var line = "\(info.id)  \(info.state.rawValue)"
        if info.isBusy { line += "  (занята)" }
        if let error = info.error { line += "  \(error)" }
        print(line)
    }
}

func send(_ request: ControlRequest) -> ControlResponse {
    do {
        let response = try ControlClient.send(request)
        guard response.ok else { die(response.error ?? "неизвестная ошибка") }
        return response
    } catch is AppUnavailableError {
        die("MeetRec не запущен или не отвечает", code: 2)
    } catch let error as ControlTimeoutError {
        die(error.localizedDescription)
    } catch {
        die(error.localizedDescription)
    }
}

func launchApp() {
    func alive() -> Bool {
        (try? ControlClient.send(ControlRequest(cmd: "status"), timeout: 1)) != nil
    }
    if alive() { return }
    func open(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    guard open(["-g", expandTilde("~/Applications/MeetRec.app")]) || open(["-g", "-b", "local.meetrec.app"]) else {
        die("не удалось запустить MeetRec", code: 2)
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if alive() { return }
        usleep(250_000)
    }
    die("MeetRec не ответил за 10 секунд", code: 2)
}

func start(_ args: [String]) {
    var request = ControlRequest(cmd: "start")
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--title":
            i += 1
            guard i < args.count else { usage() }
            request.title = args[i]
        case "--no-summary": request.noSummary = true
        case "--speakers": request.speakers = speakersArgument(args, &i)
        default: usage()
        }
        i += 1
    }
    launchApp()
    print(send(request).id ?? "")
}

func stop(_ args: [String]) {
    guard args.isEmpty || args == ["--wait"] else { usage() }
    guard let id = send(ControlRequest(cmd: "stop")).id else { die("приложение не вернуло id сессии") }
    guard !args.isEmpty else {
        print(id)
        return
    }
    var lastStep = ""
    while true {
        let status = send(ControlRequest(cmd: "status"))
        if let path = status.results?[id] {
            for warning in status.warnings?[id] ?? [] { log("Предупреждение: \(warning)") }
            print(path)
            return
        }
        if let error = status.errors?[id] { die(error) }
        guard let position = status.queue?.firstIndex(of: id) else { die("статус обработки сессии \(id) неизвестен") }
        let step = status.processingID == id ? status.processingLine : "В очереди, впереди \(position)"
        if step != lastStep {
            lastStep = step
            log(step)
        }
        sleep(1)
    }
}

extension ControlResponse {
    var processingLine: String {
        guard let step else { return "В очереди" }
        guard let progress else { return step }
        return "\(step) \(Int(progress * 100))%"
    }
}

func status(_ args: [String]) {
    let json = args == ["--json"]
    guard args.isEmpty || json else { usage() }
    let r = send(ControlRequest(cmd: "status"))
    if json {
        print(String(decoding: (try? ControlCodec.encode(r)) ?? Data(), as: UTF8.self), terminator: "")
        return
    }
    switch r.state {
    case "recording":
        print("Запись: \(r.id ?? "")  \(Transcript.formatTime(r.elapsed ?? 0))  sys \(Int(r.systemDB ?? -120)) dB  mic \(Int(r.micDB ?? -120)) dB")
    case "processing":
        print("Обработка: \(r.id ?? "")  \(r.processingLine)")
    default:
        print("Простой")
    }
    if r.state == "recording", r.step != nil { print("Обработка: \(r.processingLine)") }
    print(r.hotkey.map { "Хоткей: \($0)" } ?? "Хоткей не активен")
    if let message = r.message { print("Сообщение: \(message)") }
    if let version = r.version { print("Версия: \(version)" + (r.updateStatus.map { "  \($0)" } ?? "")) }
    if let note = r.updateNote { print("Обновление: \(note)") }
    if let queue = r.queue, !queue.isEmpty { print("Очередь: \(queue.joined(separator: ", "))") }
}

func update(_ args: [String]) {
    guard args.isEmpty else { usage() }
    print(send(ControlRequest(cmd: "update")).message ?? "")
}

func applyUpdate(_ args: [String]) {
    guard args.count == 5, let pid = Int32(args[2]) else { usage() }
    let ok = UpdateInstaller().apply(
        staged: URL(fileURLWithPath: args[0]), installed: URL(fileURLWithPath: args[1]), pid: pid, from: args[3], to: args[4])
    exit(ok ? 0 : 1)
}

func config(_ args: [String]) throws {
    if args.isEmpty {
        print(String(decoding: try Json.encoder.encode(try Config.load()), as: UTF8.self))
    } else if args.count == 3, args[0] == "set" {
        _ = try Config.update { try $0.set(key: args[1], value: args[2]) }
    } else {
        usage()
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())
do {
    switch command {
    case "record": try await record(rest)
    case "process": try await process(rest)
    case "list": list()
    case "config": try config(rest)
    case "start": start(rest)
    case "stop": stop(rest)
    case "status": status(rest)
    case "update": update(rest)
    case "version": print(AppVersion.current)
    case "_apply-update": applyUpdate(rest)
    default: usage()
    }
} catch {
    die(error.localizedDescription)
}
