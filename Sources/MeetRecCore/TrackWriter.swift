import AVFoundation
import CSupport
import Foundation

final class LevelMeter {
    private let lock = NSLock()
    private var sumSquares = 0.0
    private var count = 0
    private var current: Float = -120
    private var updatedAt: UInt64 = 0

    var db: Float {
        lock.lock()
        defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds - updatedAt > 1_000_000_000 ? -120 : current
    }

    func add(_ samples: UnsafeBufferPointer<Int16>) {
        for s in samples {
            let v = Double(s) / 32768
            sumSquares += v * v
        }
        count += samples.count
        guard count >= 4800 else { return }
        let rms = (sumSquares / Double(count)).squareRoot()
        let value = Float(max(-120, 20 * log10(max(rms, 1e-9))))
        sumSquares = 0
        count = 0
        lock.lock()
        current = value
        updatedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }
}

func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
    dst.frameLength = src.frameLength
    let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
    let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
    for i in 0..<min(s.count, d.count) {
        if let sp = s[i].mData, let dp = d[i].mData {
            memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
        }
    }
    return dst
}

final class TrackWriter {
    static let sampleRate = 48000
    private static let silence = Data(count: sampleRate * 2)
    private static let scratchSize = 1 << 20

    let meter = LevelMeter()
    var onWarning: ((String) -> Void)?
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let t0: UInt64
    private let checkRate: Bool
    private var framesWritten = 0
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var failed = false
    private let signalLock = NSLock()
    private var seenSignal = false
    private var closed = false
    private var rateStart: UInt64 = 0
    private var rateFrames = 0
    private var rateChecked = false
    private var rateWarned = false
    private var rateLastEnd = 0.0
    private var rateFormat: AVAudioFormat?
    private var lastDrops: UInt64 = 0
    private var ring: OpaquePointer?
    private var ringFormat: AVAudioFormat?
    private var timer: DispatchSourceTimer?
    private let scratch = UnsafeMutableRawPointer.allocate(byteCount: TrackWriter.scratchSize, alignment: 16)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(TrackWriter.sampleRate),
                                          channels: 1, interleaved: true)!

    init(url: URL, t0: UInt64, label: String, checkRate: Bool = false) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        queue = DispatchQueue(label: "meetrec.writer.\(label)")
        self.t0 = t0
        self.checkRate = checkRate
    }

    deinit {
        MRRingFree(ring)
        scratch.deallocate()
    }

    var signalSeen: Bool {
        signalLock.lock()
        defer { signalLock.unlock() }
        return seenSignal
    }

    func makeRing() -> OpaquePointer? {
        queue.sync {
            if ring == nil {
                ring = MRRingCreate(1 << 22)
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(20))
                t.setEventHandler { [weak self] in self?.drainRing() }
                t.resume()
                timer = t
            }
            return ring
        }
    }

    func setRingFormat(_ format: AVAudioFormat) {
        queue.sync { ringFormat = format }
    }

    func flushRing() {
        queue.sync { drainRing() }
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        queue.async { self.write(buffer, hostTime: hostTime) }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            drainRing()
            closed = true
            timer?.cancel()
            timer = nil
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private func drainRing() {
        guard !closed, let ring, let format = ringFormat else { return }
        let asbd = format.streamDescription.pointee
        let frameBytes = Int(asbd.mBytesPerFrame) * (format.isInterleaved ? 1 : Int(format.channelCount))
        guard frameBytes > 0 else { return }
        var host: UInt64 = 0
        var bytes = 0
        defer {
            let drops = MRRingDrops(ring)
            if drops > lastDrops {
                if lastDrops == 0 { onWarning?("Системный звук: переполнение буфера захвата, часть данных потеряна") }
                lastDrops = drops
            }
        }
        while MRRingRead(ring, &host, scratch, TrackWriter.scratchSize, &bytes) {
            let frames = bytes / frameBytes
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            var offset = 0
            for i in 0..<list.count {
                let n = Int(list[i].mDataByteSize)
                if let data = list[i].mData, offset + n <= bytes { memcpy(data, scratch + offset, n) }
                offset += n
            }
            write(buffer, hostTime: host)
        }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        onWarning?("Ошибка записи дорожки: \(error.localizedDescription)")
    }

    private func writeSilence(_ frames: Int) throws {
        var left = frames
        while left > 0 {
            let n = min(left, TrackWriter.sampleRate)
            try handle.write(contentsOf: n == TrackWriter.sampleRate ? TrackWriter.silence : TrackWriter.silence.prefix(n * 2))
            framesWritten += n
            left -= n
        }
    }

    private func checkRate(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard checkRate, !rateWarned, hostTime != 0 else { return }
        let now = AVAudioTime.seconds(forHostTime: hostTime)
        let nominal = buffer.format.sampleRate
        let duration = Double(buffer.frameLength) / nominal
        if rateFormat != buffer.format || (rateStart != 0 && abs(now - rateLastEnd) > duration * 3) {
            rateFormat = buffer.format
            rateStart = 0
            rateFrames = 0
            rateChecked = false
        }
        rateLastEnd = now + duration
        guard !rateChecked else { return }
        if rateStart == 0 {
            rateStart = hostTime
        } else {
            let elapsed = now - AVAudioTime.seconds(forHostTime: rateStart)
            if elapsed >= 2 {
                rateChecked = true
                let estimated = Double(rateFrames) / elapsed
                if abs(estimated / nominal - 1) > 0.02 {
                    rateWarned = true
                    onWarning?("Частота системного звука \(Int(estimated)) Гц вместо \(Int(nominal)) Гц, дорожка может быть искажена")
                }
            }
        }
        rateFrames += Int(buffer.frameLength)
    }

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard !failed, !closed else { return }
        do {
            checkRate(buffer, hostTime: hostTime)
            if hostTime != 0 {
                let seconds = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: t0)
                let pad = silenceFrames(expectedSeconds: seconds, framesWritten: framesWritten)
                if pad > 0 { try writeSilence(pad) }
            }
            guard let out = convert(buffer), out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            let view = UnsafeBufferPointer(start: samples, count: Int(out.frameLength))
            meter.add(view)
            if !signalSeen, view.contains(where: { $0 >= 2 || $0 <= -2 }) {
                signalLock.lock()
                seenSignal = true
                signalLock.unlock()
            }
            try handle.write(contentsOf: Data(buffer: view))
            framesWritten += Int(out.frameLength)
        } catch {
            fail(error)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converterInput != input.format {
            converter = AVAudioConverter(from: input.format, to: outFormat)
            converter?.downmix = input.format.channelCount > 1
            converterInput = input.format
        }
        guard let converter else { return nil }
        let ratio = Double(TrackWriter.sampleRate) / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? out : nil
    }
}
