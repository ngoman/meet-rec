import AVFoundation
import CoreAudio
import CSupport
import Foundation

private func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    guard status == noErr else { throw MeetRecError("Core Audio: ошибка \(status) при чтении свойства") }
    return value
}

func otherProcessOutputActive() -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return false }
    let own = ProcessInfo.processInfo.processIdentifier
    return objects.contains { object in
        guard let pid = try? audioProperty(object, kAudioProcessPropertyPID, pid_t(0)), pid != own else { return false }
        return ((try? audioProperty(object, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0
    }
}

final class SystemAudioTap {
    var onWarning: ((String) -> Void)?

    var outputActive: Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return active
    }

    var outputSeen: Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return seen
    }

    private let writer: TrackWriter
    private let control = DispatchQueue(label: "meetrec.tap.control")
    private let io = DispatchQueue(label: "meetrec.tap.io", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private lazy var restarter = Restarter(queue: control)
    private let outputLock = NSLock()
    private var active = false
    private var seen = false
    private var pollTimer: DispatchSourceTimer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var formatTap = AudioObjectID(kAudioObjectUnknown)
    private var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)

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
            try build()
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.control.async { self?.deviceChanged() }
            }
            listener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
            let timer = DispatchSource.makeTimerSource(queue: control)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.pollOutput() }
            timer.resume()
            pollTimer = timer
        }
    }

    private func pollOutput() {
        let now = otherProcessOutputActive()
        outputLock.lock()
        active = now
        if now { seen = true }
        outputLock.unlock()
    }

    func stop() {
        onControl {
            restarter.cancel()
            pollTimer?.cancel()
            pollTimer = nil
            if let listener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
                self.listener = nil
            }
            teardown()
        }
    }

    private func deviceChanged() {
        restarter.trigger(attempt: { [weak self] in
            guard let self else { return }
            self.teardown()
            try self.build()
        }, giveUp: { [weak self] error in
            self?.onWarning?("Системный звук потерян после смены устройства вывода: \(error.localizedDescription)")
        })
    }

    private func ownProcessObject() -> [AudioObjectID] {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private func build() throws {
        do {
            guard let ring = writer.makeRing() else { throw MeetRecError("Не удалось создать буфер захвата") }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject())
            let tapUUID = UUID()
            description.uuid = tapUUID
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr else { throw MeetRecError("Не удалось создать tap системного звука (\(status))") }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MeetRec Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw MeetRecError("Не удалось создать aggregate device (\(status))") }

            let formatBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.control.async { self?.deviceChanged() }
            }
            formatListener = formatBlock
            formatTap = tapID
            AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, control, formatBlock)

            var asbd = try audioProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            let aggregateRate = try audioProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
            if aggregateRate > 0, abs(aggregateRate - asbd.mSampleRate) > 1 { asbd.mSampleRate = aggregateRate }
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw MeetRecError("Неподдерживаемый формат системного звука")
            }
            writer.flushRing()
            writer.setRingFormat(format)

            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, io) { _, inData, inTime, _, _ in
                _ = MRRingWrite(ring, inTime.pointee.mHostTime, inData)
            }
            guard status == noErr else { throw MeetRecError("Не удалось создать IO proc (\(status))") }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw MeetRecError("Не удалось запустить захват системного звука (\(status))") }
        } catch {
            teardown()
            throw error
        }
    }

    private func teardown() {
        if let formatListener {
            AudioObjectRemovePropertyListenerBlock(formatTap, &formatAddress, control, formatListener)
            self.formatListener = nil
        }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        writer.flushRing()
    }
}
