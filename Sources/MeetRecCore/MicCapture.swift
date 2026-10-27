import AVFoundation
import CSupport
import Foundation
import os

final class MicCapture {
    var onWarning: ((String) -> Void)?

    private let writer: TrackWriter
    private let engine = AVAudioEngine()
    private let control = DispatchQueue(label: "meetrec.mic.control")
    private let queueKey = DispatchSpecificKey<Void>()
    private lazy var restarter = Restarter(queue: control)
    private var observer: NSObjectProtocol?

    init(writer: TrackWriter) {
        self.writer = writer
        control.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    private func onControl(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            control.sync(execute: body)
        }
    }

    func start() throws {
        try control.sync {
            do {
                try install()
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in
                    self?.control.async { self?.configurationChanged() }
                }
                try engine.start()
            } catch {
                tearDown()
                throw error
            }
        }
    }

    func stop() {
        onControl { tearDown() }
    }

    private func tearDown() {
        restarter.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func install() throws {
        let block: AVAudioNodeTapBlock = { [weak self] buffer, time in
            guard let self, let copy = copyBuffer(buffer) else { return }
            self.writer.append(copy, hostTime: time.isHostTimeValid ? time.hostTime : 0)
        }
        if let error = MRInstallTap(engine.inputNode, 0, 4096, nil, block) {
            Logger(subsystem: "local.meetrec.app", category: "mic").error("installTap: \(error.localizedDescription, privacy: .public)")
            throw MeetRecError("Нет доступного устройства ввода звука")
        }
    }

    private func configurationChanged() {
        restarter.trigger(attempt: { [weak self] in
            guard let self else { return }
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            try self.install()
            try self.engine.start()
        }, giveUp: { [weak self] error in
            self?.onWarning?("Микрофон потерян после смены устройства: \(error.localizedDescription)")
        })
    }
}
