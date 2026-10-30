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
    @Published var summaryChoice: String
    @Published var summaryHint: String?
    @Published var speakers: String
    @Published var autoUpdate: Bool
    @Published var updateAvailable: String?
    @Published var updateStatus: String?
    @Published var updateNote: String?
    @Published var isUpdating = false

    let appVersion = AppVersion.current
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
    private var updateTask: Task<Void, Never>? { didSet { isUpdating = updateTask != nil } }
    private var updateTimer: Timer?
    private var updateExplicit = false
    private var updateInstalling = false
    private var stagedExplicit = false
    private var retryScheduled = false
    private var lastWorkFinished: Date?
    private static let upToDate = "Установлена последняя версия"
    private static let busyLater = "Идет запись или обработка, обновление позже"
    private static let noUpdates = "Подходящих обновлений нет"
    private var knownRelease: UpdateRelease?
    private var stagedRelease: UpdateRelease?
    private var stageBlocked = false
    private let updatesSupported = Bundle.main.bundleURL.pathExtension == "app"
    private let logger = Logger(subsystem: "local.meetrec.app", category: "app")

    var iconFraction: Double? {
        processingFraction.map { ($0 * 100).rounded() / 100 }
    }

    var outputURL: URL { config.outputURL }

    var canStartUpdate: Bool {
        !isRecording && !isBusy && processingID == nil && queued.isEmpty && !isUpdating
    }

    private var canUpdateNow: Bool {
        !isRecording && !isBusy && processingID == nil && queued.isEmpty && worker == nil
            && !SessionStore.list().contains { $0.isBusy }
    }

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
        summaryChoice = Self.summaryChoice(loaded)
        summaryHint = Self.summaryHint(loaded)
        speakers = loaded.speakers
        autoUpdate = loadError == nil && loaded.autoUpdate
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
        setupUpdates()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastWorkFinished = Date() }
        }
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

    private func setupUpdates() {
        Updater.cleanStaging()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.consumeUpdateResult() }
        }
        guard updatesSupported else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTick()
                self?.updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTick() }
                }
            }
        }
    }

    private func consumeUpdateResult() {
        guard UpdateState.load().lastResult != nil else { return }
        var result: UpdateResult?
        UpdateState.update {
            result = $0.lastResult
            $0.lastResult = nil
        }
        guard let result else { return }
        if result.ok {
            Notifier.shared.post("MeetRec обновлен", body: result.to)
        } else {
            updateNote = "Не удалось обновиться до \(result.to): \(result.error ?? "неизвестная ошибка")"
        }
    }

    func updateTick() {
        reloadConfig()
        consumeUpdateResult()
        if updateStatus == Self.busyLater { updateStatus = nil }
        if updateStatus == Self.upToDate || updateStatus == Self.noUpdates, appDelegate?.isPanelOpen != true { updateStatus = nil }
        guard updatesSupported else { return }
        if stagedRelease != nil {
            tryApply()
            return
        }
        guard updateTask == nil, canUpdateNow else { return }
        if autoUpdate, !stageBlocked, let release = knownRelease,
           UpdatePolicy.shouldInstall(candidate: release.version, current: appVersion, failedVersion: UpdateState.load().failedVersion, manual: false) {
            startUpdate(release: release, manual: false, explicit: false, install: true)
        } else if UpdatePolicy.isCheckDue(lastCheck: UpdateState.load().lastCheck) {
            startUpdate(release: nil, manual: false, explicit: false, install: autoUpdate)
        }
    }

    private func startUpdate(release: UpdateRelease?, manual: Bool, explicit: Bool, install: Bool) {
        guard updatesSupported, updateTask == nil, canUpdateNow else { return }
        updateExplicit = explicit
        updateInstalling = install
        if manual { updateNote = nil }
        updateTask = Task {
            await runUpdate(release: release, manual: manual, install: install)
            updateTask = nil
            tryApply()
        }
    }

    private func runUpdate(release: UpdateRelease?, manual: Bool, install: Bool) async {
        var target = release
        if target == nil {
            updateStatus = "Проверяю обновления…"
            do {
                let latest = try await Updater.latestRelease()
                UpdateState.update { $0.lastCheck = Date() }
                if let latest, UpdatePolicy.shouldInstall(
                    candidate: latest.version, current: appVersion, failedVersion: UpdateState.load().failedVersion, manual: manual) {
                    target = latest
                    knownRelease = latest
                    stageBlocked = false
                    updateAvailable = latest.version
                } else {
                    knownRelease = nil
                    updateAvailable = nil
                    updateStatus = manual ? (latest == nil ? Self.noUpdates : Self.upToDate) : nil
                    return
                }
            } catch {
                updateStatus = nil
                if Task.isCancelled || error is CancellationError { return }
                logger.error("update check: \(error.localizedDescription, privacy: .public)")
                if manual { updateNote = "Не удалось проверить обновления: \(error.localizedDescription)" }
                return
            }
            guard install else {
                updateStatus = nil
                return
            }
        }
        guard let target else { return }
        stagedRelease = nil
        do {
            try Updater.preflight(installed: Bundle.main.bundleURL)
            updateStatus = "Скачиваю версию \(target.version)…"
            _ = try await Updater.stage(target) { step in
                DispatchQueue.main.async { [weak self] in
                    guard self?.updateTask != nil else { return }
                    self?.updateStatus = step
                }
            }
            updateStatus = nil
            reloadConfig()
            if Task.isCancelled {
                Updater.cleanStaging()
                return
            }
            stagedRelease = target
            stagedExplicit = updateExplicit
        } catch {
            updateStatus = nil
            if Task.isCancelled || error is CancellationError { return }
            stageBlocked = true
            logger.error("update stage: \(error.localizedDescription, privacy: .public)")
            updateNote = "Не удалось обновиться до \(target.version): \(error.localizedDescription)"
        }
    }

    private func dropStaged() {
        stagedRelease = nil
        Updater.cleanStaging()
        updateStatus = nil
    }

    private func restartBlocker(_ version: String) -> String? {
        if !canUpdateNow { return "Версия \(version) установится после записи и обработки" }
        if isPickingFolder || isConfirmingQuit || appDelegate?.isPanelOpen == true || NSApp.modalWindow != nil {
            return "Версия \(version) установится, когда панель закроется"
        }
        if !title.isEmpty { return "Версия \(version) установится, когда поле названия будет пустым" }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let sinceWork = lastWorkFinished.map { Date().timeIntervalSince($0) }
        if !UpdatePolicy.canRestart(idle: idle, sinceWork: sinceWork, explicit: stagedExplicit) {
            if stagedExplicit || idle >= UpdatePolicy.restartIdle { return "Версия \(version) установится через пару минут" }
            return "Версия \(version) установится при простое Mac"
        }
        return nil
    }

    private func tryApply() {
        guard updateTask == nil, let release = stagedRelease else { return }
        guard FileManager.default.fileExists(atPath: Updater.stagedApp.path) else {
            dropStaged()
            return
        }
        if let reason = restartBlocker(release.version) {
            updateStatus = reason
            if !retryScheduled {
                retryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.retryScheduled = false
                        self?.updateTick()
                    }
                }
            }
            return
        }
        do {
            try Updater.spawnApply(staged: Updater.stagedApp, installed: Bundle.main.bundleURL, from: appVersion, to: release.version)
            NSApplication.shared.terminate(nil)
        } catch {
            stageBlocked = true
            dropStaged()
            updateNote = "Не удалось обновиться до \(release.version): \(error.localizedDescription)"
        }
    }

    private func applyAutoUpdate(_ value: Bool) {
        autoUpdate = value
        if value {
            updateTick()
        } else if updateTask != nil {
            if !updateExplicit { updateTask?.cancel() }
        } else if stagedRelease != nil, !stagedExplicit {
            dropStaged()
        }
    }

    func setAutoUpdate(_ value: Bool) {
        do {
            config = try Config.update { $0.autoUpdate = value }
        } catch {
            message = "Не удалось сохранить конфиг: \(error.localizedDescription)"
            return
        }
        applyAutoUpdate(value)
    }

    func checkForUpdates() {
        guard updatesSupported else {
            updateNote = "Обновления работают только из установленного приложения MeetRec.app"
            return
        }
        guard canUpdateNow else {
            updateStatus = Self.busyLater
            return
        }
        if stagedRelease != nil {
            tryApply()
            return
        }
        startUpdate(release: nil, manual: true, explicit: false, install: autoUpdate)
    }

    func installAvailableUpdate() {
        guard let release = knownRelease else { return }
        guard canUpdateNow else {
            updateStatus = Self.busyLater
            return
        }
        if stagedRelease != nil {
            stagedExplicit = true
            tryApply()
            return
        }
        startUpdate(release: release, manual: true, explicit: true, install: true)
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
                    try await startRecording(title: title, noSummary: false, speakers: nil)
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func startRecording(title: String?, noSummary skipSummary: Bool, speakers: String?) async throws -> String {
        if isRecording { throw MeetRecError("Запись уже идет: \(recorder?.session?.id ?? "")") }
        if isBusy { throw MeetRecError("Запись запускается или останавливается") }
        isBusy = true
        defer { isBusy = false }
        updateTask?.cancel()
        message = nil
        let recorder = Recorder()
        recorder.onWarning = { [weak self] text in
            DispatchQueue.main.async { self?.message = text }
        }
        do {
            try await recorder.start(title: title, speakers: speakers ?? config.speakers)
        } catch {
            Notifier.shared.post("Не удалось начать запись", body: error.localizedDescription)
            throw error
        }
        guard let id = recorder.session?.id else { throw MeetRecError("Сессия не создана") }
        self.recorder = recorder
        self.speakers = recorder.session?.speakers ?? config.speakers
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
        lastWorkFinished = Date()
        speakers = config.speakers
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
        updateTask?.cancel()
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
            lastWorkFinished = Date()
            refresh()
            updateTick()
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
        update(\.summaryChoice, Self.summaryChoice(fresh))
        update(\.summaryHint, Self.summaryHint(fresh))
        if fresh.autoUpdate != autoUpdate { applyAutoUpdate(fresh.autoUpdate) }
        if !isRecording { update(\.speakers, fresh.speakers) }
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

    private static func summaryChoice(_ config: Config) -> String {
        config.summary ? config.summaryProvider : "off"
    }

    private static func summaryHint(_ config: Config) -> String? {
        guard config.summary else { return nil }
        if config.summaryProvider == "codex" {
            return config.hasCodex ? nil : "Codex CLI не найден: brew install --cask codex, затем codex login"
        }
        return config.hasClaude ? nil : "Claude Code не найден"
    }

    func setSummary(_ value: String) {
        do {
            config = try Config.update {
                $0.summary = value != "off"
                if value != "off" { $0.summaryProvider = value }
            }
            summaryChoice = Self.summaryChoice(config)
            summaryHint = Self.summaryHint(config)
        } catch {
            message = "Не удалось сохранить конфиг: \(error.localizedDescription)"
        }
    }

    func setSpeakers(_ value: String) {
        guard let value = Speakers.normalize(value) else { return }
        do {
            config = try Config.update { $0.speakers = value }
            speakers = value
            recorder?.setSpeakers(value)
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
                let id = try await startRecording(title: request.title, noSummary: request.noSummary ?? false, speakers: request.speakers)
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
        case "update":
            guard updatesSupported else { return .failure("Обновления работают только из установленного приложения MeetRec.app") }
            guard canUpdateNow else { return .failure("Идет запись или обработка, сейчас обновить нельзя") }
            var r = ControlResponse()
            if let release = stagedRelease {
                stagedExplicit = true
                r.message = "Версия \(release.version) готова, применяю"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated { self?.tryApply() }
                }
            } else if updateTask != nil {
                if updateInstalling { updateExplicit = true }
                r.message = updateInstalling ? "Обновление уже выполняется" : "Идет проверка обновлений без установки, повторите позже"
            } else {
                r.message = "Проверяю обновления"
                startUpdate(release: nil, manual: true, explicit: true, install: true)
            }
            return r
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
        r.version = appVersion
        r.updateStatus = updateStatus
        r.updateAvailable = updateAvailable
        r.updateNote = updateNote
        return r
    }

    private func shutdown() {
        updateTask?.cancel()
        updateTimer?.invalidate()
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
