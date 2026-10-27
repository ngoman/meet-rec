import AVFoundation
import CSupport
import Foundation
import Testing
@testable import MeetRecCore

@Suite(.serialized) enum AllTests {}

private func tempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-\(UUID().uuidString.prefix(8))-\(name)")
}

private func writeRing(_ ring: OpaquePointer, host: UInt64, buffers: [[UInt8]?], sizes: [Int]? = nil) -> Bool {
    let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
    defer { free(list.unsafeMutablePointer) }
    var storage: [UnsafeMutableRawPointer] = []
    defer { storage.forEach { $0.deallocate() } }
    for (i, buffer) in buffers.enumerated() {
        let size = sizes?[i] ?? buffer?.count ?? 0
        if let buffer {
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 8)
            buffer.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: size) }
            storage.append(p)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(size), mData: p)
        } else {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(size), mData: nil)
        }
    }
    list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
    return MRRingWrite(ring, host, list.unsafeMutablePointer)
}

private func readRing(_ ring: OpaquePointer) -> (UInt64, [UInt8])? {
    var host: UInt64 = 0
    var bytes = 0
    var dst = [UInt8](repeating: 0, count: 1024)
    guard MRRingRead(ring, &host, &dst, dst.count, &bytes) else { return nil }
    return (host, Array(dst.prefix(bytes)))
}

extension AllTests {
    @Suite struct InfraTests {
        @Test func ringWrapsAround() throws {
            let ring = try #require(MRRingCreate(64))
            defer { MRRingFree(ring) }
            for round in 0..<10 {
                let payload = (0..<20).map { UInt8($0 + round) }
                #expect(writeRing(ring, host: UInt64(round), buffers: [payload]))
                let (host, data) = try #require(readRing(ring))
                #expect(host == UInt64(round))
                #expect(data == payload)
            }
            #expect(readRing(ring) == nil)
        }

        @Test func ringOverflowCountsDrops() throws {
            let ring = try #require(MRRingCreate(64))
            defer { MRRingFree(ring) }
            #expect(writeRing(ring, host: 1, buffers: [[UInt8](repeating: 1, count: 30)]))
            #expect(!writeRing(ring, host: 2, buffers: [[UInt8](repeating: 2, count: 30)]))
            #expect(MRRingDrops(ring) == 1)
            let (host, data) = try #require(readRing(ring))
            #expect(host == 1 && data.count == 30)
            #expect(writeRing(ring, host: 3, buffers: [[UInt8](repeating: 3, count: 30)]))
        }

        @Test func ringConcatenatesBuffersAndZeroFillsNull() throws {
            let ring = try #require(MRRingCreate(256))
            defer { MRRingFree(ring) }
            #expect(writeRing(ring, host: 5, buffers: [[1, 2, 3, 4, 5, 6, 7, 8], [9, 10, 11, 12]]))
            #expect(try #require(readRing(ring)).1 == Array(1...12))
            #expect(writeRing(ring, host: 6, buffers: [nil, [9, 10, 11, 12]], sizes: [8, 4]))
            let (_, data) = try #require(readRing(ring))
            #expect(data == [0, 0, 0, 0, 0, 0, 0, 0, 9, 10, 11, 12])
            #expect(writeRing(ring, host: 7, buffers: [[1, 2]]))
            #expect(try #require(readRing(ring)).1 == [1, 2])
        }

        @Test func fileLockConflicts() throws {
            let url = tempURL("lock")
            defer { try? FileManager.default.removeItem(at: url) }
            let first = try #require(FileLock(url: url))
            #expect(FileLock(url: url) == nil)
            #expect(FileLock.isLocked(url))
            first.unlock()
            first.unlock()
            let second = try #require(FileLock(url: url))
            second.unlock()
            #expect(!FileLock.isLocked(url))
        }

        @Test func controlServerAndClient() async throws {
            let path = tempURL("c.sock")
            let server = ControlServer(path: path) { request in
                if request.cmd == "slow" {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                return ControlResponse(id: request.title)
            }
            try server.start()
            defer { server.stop() }
            let response = try ControlClient.send(ControlRequest(cmd: "start", title: "план"), path: path, timeout: 5)
            #expect(response.ok && response.id == "план")
            #expect((try? server.start()) == nil)
            #expect(FileManager.default.fileExists(atPath: path.path))
            #expect(throws: ControlTimeoutError.self) {
                try ControlClient.send(ControlRequest(cmd: "slow"), path: path, timeout: 1)
            }
            server.stop()
            #expect(throws: AppUnavailableError.self) {
                try ControlClient.send(ControlRequest(cmd: "status"), path: path, timeout: 1)
            }
        }

        @Test func trackWriterDetectsSilentTrack() throws {
            let url = tempURL("silent.pcm")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try TrackWriter(url: url, t0: mach_absolute_time(), label: "silent")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            b.frameLength = 4800
            for i in 0..<4800 { b.floatChannelData![0][i] = 0 }
            writer.append(b, hostTime: 0)
            writer.close()
            #expect(!writer.signalSeen)
        }

        @Test func trackWriterPadsSilenceByHostTime() throws {
            let url = tempURL("track.pcm")
            defer { try? FileManager.default.removeItem(at: url) }
            let t0 = mach_absolute_time()
            let writer = try TrackWriter(url: url, t0: t0, label: "test")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            func buffer(_ frames: Int) -> AVAudioPCMBuffer {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                b.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames { b.floatChannelData![0][i] = 0.5 }
                return b
            }
            func host(_ seconds: Double) -> UInt64 { t0 + AVAudioTime.hostTime(forSeconds: seconds) }
            writer.append(buffer(4800), hostTime: host(0))
            writer.append(buffer(4800), hostTime: host(0.105))
            writer.append(buffer(4800), hostTime: host(1.0))
            writer.append(buffer(4800), hostTime: host(0.5))
            writer.close()
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            let frames = size / 2
            #expect(abs(frames - (48000 + 4800 + 4800)) < 200)
            #expect(writer.signalSeen)
        }
    }
}

extension AllTests {
    @Suite struct RegressionTests {
        @Test func appInstanceCreatesMissingDirectory() throws {
            let dir = tempURL("support").appendingPathComponent("MeetRec")
            defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            guard case .acquired(let lock) = AppInstance.acquire(in: dir) else {
                Issue.record("lock not acquired")
                return
            }
            guard case .alreadyRunning = AppInstance.acquire(in: dir) else {
                Issue.record("second instance not detected")
                return
            }
            lock.unlock()
            let unusable = URL(fileURLWithPath: "/dev/null/x")
            guard case .unavailable = AppInstance.acquire(in: unusable) else {
                Issue.record("expected unavailable")
                return
            }
        }

        @Test func cleanDoneFinishesPendingMove() throws {
            let support = tempURL("home")
            let output = tempURL("out")
            setenv("MEETREC_SUPPORT_DIR", support.path, 1)
            defer {
                unsetenv("MEETREC_SUPPORT_DIR")
                try? FileManager.default.removeItem(at: support)
                try? FileManager.default.removeItem(at: output)
            }
            let fm = FileManager.default
            var kept = SessionInfo(id: "2026-01-01_1000_a", startedAt: Date(), title: nil)
            kept.state = .done
            try kept.save()
            try fm.createDirectory(at: kept.dir.appendingPathComponent("out"), withIntermediateDirectories: true)
            try "x".write(to: kept.dir.appendingPathComponent("out/transcript.md"), atomically: true, encoding: .utf8)
            var plain = SessionInfo(id: "2026-01-01_1001_b", startedAt: Date(), title: nil)
            plain.state = .done
            try plain.save()

            SessionStore.cleanDone(outputURL: output)
            #expect(fm.fileExists(atPath: output.appendingPathComponent("2026-01-01_1000_a/transcript.md").path))
            #expect(!fm.fileExists(atPath: kept.dir.path))
            #expect(!fm.fileExists(atPath: plain.dir.path))

            try fm.createDirectory(at: output.appendingPathComponent("2026-01-01_1002_c"), withIntermediateDirectories: true)
            let moved = try SessionStore.moveResult(from: {
                let u = tempURL("res")
                try? fm.createDirectory(at: u, withIntermediateDirectories: true)
                return u
            }(), id: "2026-01-01_1002_c", to: output)
            #expect(moved.lastPathComponent == "2026-01-01_1002_c-2")
        }

        @Test func shutdownCancelsRunningProcess() async throws {
            let task = Task { try await ProcessRunner.run("/bin/sleep", ["10"]) }
            try await Task.sleep(nanoseconds: 300_000_000)
            ProcessRunner.terminateAll(grace: 1)
            defer { ProcessRunner.resetShutdown() }
            do {
                _ = try await task.value
                Issue.record("expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
    }
}
