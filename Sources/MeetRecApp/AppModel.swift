import AppKit
import MeetRecCore
import os
import SwiftUI

struct Meeting: Identifiable, Equatable {
    let id: String
    let url: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var title = ""
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var elapsed: TimeInterval = 0
    @Published var systemDB: Float = -120
    @Published var micDB: Float = -120
    @Published var systemSilent = false
    @Published var micSilent = false
    @Published var processingID: String?
    @Published var processingStep = ""
    @Published var processingFraction: Double?
    @Published var queued: [String] = []
    @Published var recent: [Meeting] = []
    @Published var pending: [SessionInfo] = []
    @Published var message: String? { didSet { permissionIssue = false } }
    @Published var permissionIssue = false
    @Published var hotkeyLabel: String?
    @Published var outputDirDisplay = ""
    @Published var summaryEnabled: Bool

    var isPickingFolder = false
    var isConfirmingQuit = false
    private var config: Config
    private var recorder: Recorder?
    private var lastSystemSignal = Date()
    private var lastMicSignal = Date()
    private var worker: Task<Void, Never>?
    private var timer: Timer?
    private var server: ControlServer?
    private var noSummary: Set<String> = []
    private var results: [String: String] = [:]
    private var errors: [String: String] = [:]
    private var warningsByID: [String: [String]] = [:]
    private var finished: [String] = []
    private var termSource: DispatchSourceSignal?
    private let logger = Logger(subsystem: "local.meetrec.app", category: "app")

    var iconName: String {
        if isRecording { return "record.circle.fill" }
        if processingID != nil { return "waveform" }
        return "record.circle"
    }

    var outputURL: URL { config.outputURL }

    init() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        var loadError: String?
        let loaded: Config
        do {
            loaded = try Config.load()
        } catch {
            loaded = Config()
            loadError = "Ошибка чтения конфига, используются значения по умолчанию: \(error.localizedDescription)"
        }
        config = loaded
        outputDirDisplay = (loaded.outputDir as NSString).abbreviatingWithTildeInPath
        SessionStore.cleanDone(outputURL: loaded.outputURL)
        summaryEnabled = loaded.summary
        message = loadError
        refresh()
        Notifier.shared.setup()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApplication.shared.terminate(nil) }
        term.resume()
        termSource = term
        setupHotkey()
        setupServer()
    }

    private func setupHotkey() {
        guard let hotkey = Hotkey(config.hotkey) else {
            message = "Неверный хоткей в конфиге: \(config.hotkey)"
            return
        }
        HotkeyManager.shared.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.toggleRecording() }
        }
        do {
            try HotkeyManager.shared.register(hotkey)
            hotkeyLabel = hotkey.display
            logger.info("hotkey \(hotkey.display, privacy: .public) registered")
        } catch {
            message = error.localizedDescription
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    private func setupServer() {
        let server = ControlServer { [weak self] request in
            guard let self else { return .failure("MeetRec завершается") }
            return await self.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            message = error.localizedDescription
        }
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func toggleRecording() {
        guard !isBusy else { return }
        Task {
            if isRecording {
                _ = try? await stopRecording()
            } else {
                do {
                    try await startRecording(title: title, noSummary: false)
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func startRecording(title: String?, noSummary skipSummary: Bool) async throws -> String {
        if isRecording { throw MeetRecError("Запись уже идет: \(recorder?.session?.id ?? "")") }
        if isBusy { throw MeetRecError("Запись запускается или останавливается") }
        isBusy = true
        defer { isBusy = false }
        message = nil
        let recorder = Recorder()
        recorder.onWarning = { [weak self] text in
            DispatchQueue.main.async { self?.message = text }
        }
        do {
            try await recorder.start(title: title)
        } catch {
            Notifier.shared.post("Не удалось начать запись", body: error.localizedDescription)
            throw error
        }
        guard let id = recorder.session?.id else { throw MeetRecError("Сессия не создана") }
        self.recorder = recorder
        if skipSummary { noSummary.insert(id) }
        lastSystemSignal = Date()
        lastMicSignal = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Notifier.shared.play("Tink")
        Notifier.shared.post("Запись начата")
        refresh()
        return id
    }

    @discardableResult
    func stopRecording() async throws -> String {
        guard let recorder, isRecording else { throw MeetRecError("Запись не идет") }
        if isBusy { throw MeetRecError("Запись запускается или останавливается") }
        isBusy = true
        defer { isBusy = false }
        timer?.invalidate()
        timer = nil
        let info = await Task.detached { recorder.stop() }.value
        self.recorder = nil
        isRecording = false
        systemDB = -120
        micDB = -120
        systemSilent = false
        micSilent = false
        title = ""
        Notifier.shared.play("Pop")
        guard let info else { throw MeetRecError("Сессия не создана") }
        Notifier.shared.post("Запись остановлена, обрабатываю")
        enqueue(info.id)
        return info.id
    }

    func enqueue(_ id: String) {
        guard !queued.contains(id) else { return }
        queued.append(id)
        refresh()
        guard worker == nil else { return }
        worker = Task {
            while let id = queued.first {
                await run(id)
                queued.removeFirst()
                refresh()
            }
            worker = nil
            processingID = nil
            refresh()
        }
    }

    private func run(_ id: String) async {
        reloadConfig()
        var runConfig = config
        if noSummary.contains(id) { runConfig.summary = false }
        do {
            let info = try SessionStore.resolve(id)
            let processor = Processor(config: runConfig)
            processor.onStatus = { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.update(\.processingStep, status.step)
                    self.update(\.processingFraction, status.fraction)
                }
            }
            processingID = id
            processingStep = "Подготовка…"
            processingFraction = nil
            let result = try await processor.process(info)
            remember(id, result: result.url.path, error: nil, warnings: result.warnings)
            if !result.warnings.isEmpty {
                message = result.warnings.joined(separator: "\n")
                permissionIssue = result.warnings.contains(Processor.systemPermissionWarning)
            }
            let body = ([result.url.lastPathComponent] + result.warnings.prefix(2)).joined(separator: "\n")
            Notifier.shared.post("Транскрипт готов", body: body, open: result.url.appendingPathComponent("transcript.md"))
        } catch is CancellationError {
        } catch {
            remember(id, result: nil, error: error.localizedDescription, warnings: [])
            message = "\(id): \(error.localizedDescription)"
            Notifier.shared.post("Ошибка обработки", body: "\(id): \(error.localizedDescription)")
        }
        processingID = nil
    }

    private func remember(_ id: String, result: String?, error: String?, warnings: [String]) {
        results[id] = result
        errors[id] = error
        warningsByID[id] = warnings
        finished.removeAll { $0 == id }
        finished.append(id)
        while finished.count > 20 {
            let old = finished.removeFirst()
            results[old] = nil
            errors[old] = nil
            warningsByID[old] = nil
        }
    }

    private func tick() {
        guard let recorder, let started = recorder.startedAt else { return }
        let now = Date()
        update(\.elapsed, now.timeIntervalSince(started))
        update(\.systemDB, recorder.systemDB)
        update(\.micDB, recorder.micDB)
        if systemDB > -60 { lastSystemSignal = now }
        if micDB > -60 { lastMicSignal = now }
        update(\.systemSilent, now.timeIntervalSince(lastSystemSignal) > 15 && recorder.systemOutputActive)
        update(\.micSilent, now.timeIntervalSince(lastMicSignal) > 15)
    }

    private func reloadConfig() {
        guard let fresh = try? Config.load() else { return }
        config = fresh
        update(\.summaryEnabled, fresh.summary)
        update(\.outputDirDisplay, (fresh.outputDir as NSString).abbreviatingWithTildeInPath)
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = config.outputURL
        NSApplication.shared.activate(ignoringOtherApps: true)
        isPickingFolder = true
        let response = panel.runModal()
        isPickingFolder = false
        NSApp.hide(nil)
        guard response == .OK, let url = panel.url else { return }
        do {
            config = try Config.update { $0.outputDir = url.path }
            update(\.outputDirDisplay, (config.outputDir as NSString).abbreviatingWithTildeInPath)
            refresh()
        } catch {
            message = "Не удалось сохранить конфиг: \(error.localizedDescription)"
        }
    }

    func refresh() {
        reloadConfig()
        let activeID = recorder?.session?.id
        let pendingNow = SessionStore.pending().filter {
            $0.id != activeID && !queued.contains($0.id) && $0.id != processingID
        }
        if pendingNow.map(\.id) != pending.map(\.id) || pendingNow.map(\.state) != pending.map(\.state) {
            pending = pendingNow
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: config.outputURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let meetings = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Meeting(id: $0.lastPathComponent, url: $0) }
            .sorted { $0.id > $1.id }
            .prefix(5).map { $0 }
        update(\.recent, meetings)
    }

    func setSummary(_ value: Bool) {
        do {
            config = try Config.update { $0.summary = value }
            summaryEnabled = value
        } catch {
            message = "Не удалось сохранить конфиг: \(error.localizedDescription)"
        }
    }

    func delete(_ id: String) {
        do {
            try SessionStore.delete(id: id)
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func open(_ meeting: Meeting) {
        NSWorkspace.shared.open(meeting.url.appendingPathComponent("transcript.md"))
    }

    func reveal(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: config.outputURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(config.outputURL)
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case "start":
            do {
                let id = try await startRecording(title: request.title, noSummary: request.noSummary ?? false)
                return ControlResponse(id: id)
            } catch {
                return .failure(error.localizedDescription)
            }
        case "stop":
            do {
                return ControlResponse(id: try await stopRecording())
            } catch {
                return .failure(error.localizedDescription)
            }
        case "status":
            return status()
        default:
            return .failure("Неизвестная команда: \(request.cmd)")
        }
    }

    private func status() -> ControlResponse {
        var r = ControlResponse()
        r.state = isRecording ? "recording" : (processingID != nil ? "processing" : "idle")
        if let recorder, isRecording {
            r.id = recorder.session?.id
            r.elapsed = recorder.startedAt.map { Date().timeIntervalSince($0) }
            r.systemDB = Double(recorder.systemDB)
            r.micDB = Double(recorder.micDB)
        }
        if let processingID {
            if !isRecording { r.id = processingID }
            r.step = processingStep
            r.progress = processingFraction
        }
        r.queue = queued
        r.processingID = processingID
        r.results = results
        r.errors = errors
        r.warnings = warningsByID
        r.hotkey = hotkeyLabel
        r.message = message
        return r
    }

    private func shutdown() {
        worker?.cancel()
        Processor.cancelAll(grace: 2)
        _ = recorder?.stop()
        server?.stop()
    }

    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }
}
