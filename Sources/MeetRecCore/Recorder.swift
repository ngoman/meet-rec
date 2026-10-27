import AVFoundation
import Foundation

public final class Recorder {
    public private(set) var session: SessionInfo? {
        get {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            return storedSession
        }
        set {
            sessionLock.lock()
            storedSession = newValue
            sessionLock.unlock()
        }
    }
    public var onWarning: ((String) -> Void)?

    private var system: SystemAudioTap?
    private var mic: MicCapture?
    private var systemWriter: TrackWriter?
    private var micWriter: TrackWriter?
    private var lock: FileLock?
    private let warningsLock = NSLock()
    private var warnings: [String] = []
    private var stopped = false
    private let stopLock = NSLock()
    private let sessionLock = NSLock()
    private var storedSession: SessionInfo?

    public init() {}

    public var startedAt: Date? { session?.startedAt }
    public var systemDB: Float { systemWriter?.meter.db ?? -120 }
    public var micDB: Float { micWriter?.meter.db ?? -120 }
    public var systemOutputActive: Bool { system?.outputActive ?? false }

    private func warn(_ message: String) {
        warningsLock.lock()
        warnings.append(message)
        warningsLock.unlock()
        onWarning?(message)
    }

    private func warningsSnapshot() -> [String] {
        warningsLock.lock()
        defer { warningsLock.unlock() }
        return warnings
    }

    public func start(title: String?, speakers: String? = nil) async throws {
        let micAllowed = await Self.requestMicAccess()
        var info = try SessionStore.create(title: title)
        info.speakers = speakers
        guard let sessionLock = FileLock(url: info.lockURL) else {
            try? FileManager.default.removeItem(at: info.dir)
            throw MeetRecError("Не удалось заблокировать сессию \(info.id)")
        }
        lock = sessionLock
        do {
            try info.save()
            let t0 = mach_absolute_time()
            info.startedAt = Date()

            let sysWriter = try TrackWriter(url: info.systemPCM, t0: t0, label: "system", checkRate: true)
            let micWriter = try TrackWriter(url: info.micPCM, t0: t0, label: "mic")
            sysWriter.onWarning = { [weak self] in self?.warn($0) }
            micWriter.onWarning = { [weak self] in self?.warn($0) }
            systemWriter = sysWriter
            self.micWriter = micWriter

            if micAllowed {
                let capture = MicCapture(writer: micWriter)
                capture.onWarning = { [weak self] in self?.warn($0) }
                do {
                    try capture.start()
                    mic = capture
                } catch {
                    warn("Микрофон не записывается: \(error.localizedDescription)")
                }
            } else {
                warn("Нет доступа к микрофону: записан только системный звук")
            }

            let tap = SystemAudioTap(writer: sysWriter)
            tap.onWarning = { [weak self] in self?.warn($0) }
            do {
                try tap.start()
                system = tap
            } catch {
                warn("Системный звук не записывается: \(error.localizedDescription)")
            }

            guard system != nil || mic != nil else {
                throw MeetRecError("Не удалось начать запись: " + warningsSnapshot().joined(separator: "; "))
            }
            info.warnings = warningsSnapshot()
            try info.save()
            session = info
        } catch {
            system?.stop()
            mic?.stop()
            systemWriter?.close()
            micWriter?.close()
            system = nil
            mic = nil
            try? FileManager.default.removeItem(at: info.dir)
            lock = nil
            throw error
        }
    }

    public func setSpeakers(_ value: String) {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard var info = session, !stopped else { return }
        info.speakers = value
        try? info.save()
        session = info
    }

    @discardableResult
    public func stop() -> SessionInfo? {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard var info = session, !stopped else { return session }
        stopped = true
        info.systemOutputSeen = system?.outputSeen
        system?.stop()
        mic?.stop()
        systemWriter?.close()
        micWriter?.close()
        info.warnings = warningsSnapshot()
        info.endedAt = Date()
        info.systemSignal = systemWriter?.signalSeen
        info.micSignal = micWriter?.signalSeen
        info.state = .recorded
        try? info.save()
        session = info
        lock?.unlock()
        lock = nil
        return info
    }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
