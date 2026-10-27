import Foundation
import Testing
@testable import MeetRecCore

extension AllTests {
    @Suite struct TranscriptTests {
        @Test func filtersEmptyAndLowConfidence() {
            let segs = [
                Segment(start: 0, end: 1, text: ""),
                Segment(start: 1, end: 2, text: "шум", noSpeechProb: 0.8, avgLogprob: -1.5),
                Segment(start: 2, end: 3, text: "шум", noSpeechProb: 0.8, avgLogprob: -0.5),
                Segment(start: 3, end: 4, text: "нормально", noSpeechProb: 0.1, avgLogprob: -0.3),
            ]
            #expect(Transcript.filter(segs).map(\.text) == ["шум", "нормально"])
        }

        @Test func filtersHallucinationsOnlyWhenShort() {
            let long = "Редактор субтитров а это очень длинная настоящая фраза про субтитры в проекте"
            let segs = [
                Segment(start: 0, end: 1, text: "Продолжение следует..."),
                Segment(start: 1, end: 2, text: "Субтитры сделал DimaTorzok"),
                Segment(start: 2, end: 3, text: long),
            ]
            #expect(Transcript.filter(segs).map(\.text) == [long])
        }

        @Test func collapsesRepeatsOverTwo() {
            let two = [Segment(start: 0, end: 1, text: "да"), Segment(start: 1, end: 2, text: "да")]
            #expect(Transcript.collapseRepeats(two).count == 2)
            let four = two + [Segment(start: 2, end: 3, text: "да"), Segment(start: 3, end: 4, text: "да")]
            let out = Transcript.collapseRepeats(four)
            #expect(out.count == 1)
            #expect(out[0].end == 4)
        }

        @Test func removesEcho() {
            let system = [Segment(start: 10, end: 14, text: "Давайте обсудим релиз на пятницу")]
            let mic = [
                Segment(start: 10.2, end: 14, text: "давайте обсудим релиз на пятницу"),
                Segment(start: 10.2, end: 14, text: "совсем другое"),
                Segment(start: 20, end: 22, text: "давайте обсудим релиз на пятницу"),
            ]
            let kept = Transcript.removeEcho(mic: mic, system: system)
            #expect(kept.map(\.text) == ["совсем другое", "давайте обсудим релиз на пятницу"])
        }

        @Test func echoUsesContainmentOverSplitSystemSegments() {
            let system = [
                Segment(start: 10, end: 12, text: "Давайте обсудим релиз на пятницу и еще бюджет"),
                Segment(start: 12, end: 15, text: "потом разберем риски и сроки по проекту"),
            ]
            let echo = Segment(start: 10, end: 15, text: "обсудим релиз на пятницу разберем риски")
            let reply = Segment(start: 10, end: 15, text: "нет я не согласен с этим подходом")
            let partial = Segment(start: 14.5, end: 20, text: "обсудим релиз на пятницу")
            #expect(Transcript.removeEcho(mic: [echo, reply], system: system).map(\.text) == [reply.text])
            #expect(Transcript.removeEcho(mic: [partial], system: system).count == 1)
        }

        @Test func shortMicSegmentOnlyDroppedOnExactMatch() {
            let system = [Segment(start: 0, end: 10, text: "Да, давайте так и сделаем, я согласен с планом")]
            let mic = [Segment(start: 2, end: 3, text: "Да")]
            #expect(Transcript.removeEcho(mic: mic, system: system).count == 1)
            let exact = [Segment(start: 2, end: 3, text: "да!")]
            let same = [Segment(start: 0, end: 4, text: "Да")]
            #expect(Transcript.removeEcho(mic: exact, system: same).isEmpty)
        }

        @Test func mergesSameSpeakerWithShortGap() {
            let mic = [Segment(start: 0, end: 2, text: "раз"), Segment(start: 3, end: 4, text: "два"), Segment(start: 20, end: 21, text: "три")]
            let sys = [Segment(start: 10, end: 11, text: "ответ")]
            let lines = Transcript.merge(mic: mic, system: sys, myName: "Я", othersName: "Собеседники")
            #expect(lines.map(\.speaker) == ["Я", "Собеседники", "Я"])
            #expect(lines[0].text == "раз два")
            #expect(lines[0].end == 4)
        }

        @Test func formatsTimeAndMarkdown() {
            #expect(Transcript.formatTime(0) == "00:00:00")
            #expect(Transcript.formatTime(2832.9) == "00:47:12")
            #expect(Transcript.formatTime(3725) == "01:02:05")
            let lines = [TranscriptLine(speaker: "Я", start: 5, end: 6, text: "текст")]
            let md = Transcript.markdown(lines: lines, title: "план", startedAt: Date(timeIntervalSince1970: 0), duration: 2832)
            #expect(md.contains("Длительность: 00:47:12"))
            #expect(md.contains("**[00:00:05] Я:** текст"))
            #expect(md.hasPrefix("# Встреча "))
            #expect(md.contains(" план\n"))
        }

        @Test func parsesWhisperJSON() throws {
            let json = #"{"text":"x","segments":[{"id":0,"start":1.5,"end":3.0,"text":" привет ","no_speech_prob":0.01,"avg_logprob":-0.2,"words":[]}],"language":"ru"}"#
            let segs = try Transcript.parseWhisper(Data(json.utf8))
            #expect(segs == [Segment(start: 1.5, end: 3.0, text: "привет", noSpeechProb: 0.01, avgLogprob: -0.2)])
        }

        @Test func parsesWhisperCppJSON() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/whisper-cpp.json")
        let segs = try Transcript.parseWhisperCpp(Data(contentsOf: url))
        #expect(segs == [Segment(start: 0, end: 4.08, text: "Добрый день! Сегодня мы обсуждаем релиз новой версии приложения.")])
    }

    @Test func parsesWhisperCppInvalidUTF8() throws {
        var data = Data(#"{"transcription":[{"offsets":{"from":0,"to":1000},"text":" ab"#.utf8)
        data.append(0xFF)
        data.append(Data(#"cd"}]}"#.utf8))
        let segs = try Transcript.parseWhisperCpp(data)
        #expect(segs.count == 1 && segs[0].text.hasPrefix("ab") && segs[0].text.hasSuffix("cd"))
    }

    @Test func configSetValidates() throws {
        var config = Config()
        try config.set(key: "summary", value: "false")
        try config.set(key: "engine", value: "openai-whisper")
        try config.set(key: "outputDir", value: "~/x y")
        #expect(!config.summary && config.engine == "openai-whisper" && config.outputDir == "~/x y")
        #expect(throws: MeetRecError.self) { try config.set(key: "summary", value: "maybe") }
        #expect(throws: MeetRecError.self) { try config.set(key: "engine", value: "x") }
        #expect(throws: MeetRecError.self) { try config.set(key: "nope", value: "1") }
        #expect(throws: MeetRecError.self) { try config.set(key: "hotkey", value: "r") }
        #expect(Config().engine == "whisper.cpp" && Config().outputDir == "~/Documents/MeetRec")
    }

    @Test func resolvesBinaryFallback() {
        #expect(Config.resolveBinary("/nonexistent/dir/ffmpeg").hasSuffix("ffmpeg"))
        #expect(Config.resolveBinary("/bin/ls") == "/bin/ls")
    }

    @Test func silencePadding() {
            #expect(silenceFrames(expectedSeconds: 1.0, framesWritten: 48000) == 0)
            #expect(silenceFrames(expectedSeconds: 1.05, framesWritten: 48000) == 0)
            #expect(silenceFrames(expectedSeconds: 1.5, framesWritten: 48000) == 24000)
            #expect(silenceFrames(expectedSeconds: 0.5, framesWritten: 48000) == 0)
        }

        @Test func slug() {
            #expect(SessionStore.slug("Планерка: релиз 2.0!") == "Планерка-релиз-2-0")
            #expect(SessionStore.slug("???") == "")
        }

        @Test func slugTruncates() {
            let slug = SessionStore.slug(String(repeating: "а", count: 59) + " бвг")
            #expect(slug.count <= 60)
            #expect(!slug.hasSuffix("-"))
        }

        @Test func stderrTailSplitsCarriageReturns() {
            let text = (1...10).map { "\($0)%|bar" }.joined(separator: "\r") + "\nошибка"
            let tail = Processor.stderrTail(text)
            #expect(tail.split(separator: "\n").count == 5)
            #expect(tail.hasSuffix("ошибка"))
            #expect(Processor.stderrTail(String(repeating: "x", count: 5000)).count == 500)
        }

        @Test func parsesHotkey() {
            let key = Hotkey("ctrl+opt+cmd+r")
            #expect(key?.keyCode == 15)
            #expect(key?.modifiers == Hotkey.control | Hotkey.option | Hotkey.command)
            #expect(key?.display == "⌃⌥⌘R")
            #expect(Hotkey("Shift + Alt + 7")?.keyCode == 26)
            #expect(Hotkey("r") == nil)
            #expect(Hotkey("cmd+") == nil)
            #expect(Hotkey("cmd+f13") == nil)
            #expect(Hotkey("cmd+a+b") == nil)
            #expect(Hotkey("") == nil)
        }

        @Test func controlCodecRoundTrip() throws {
            let request = ControlRequest(cmd: "start", title: "план", noSummary: true)
            let data = try ControlCodec.encode(request)
            #expect(data.last == 0x0A)
            #expect(try ControlCodec.decode(ControlRequest.self, from: data.dropLast()) == request)
            var response = ControlResponse(id: "x")
            response.state = "idle"
            response.results = ["x": "/tmp/x"]
            let back = try ControlCodec.decode(ControlResponse.self, from: try ControlCodec.encode(response).dropLast())
            #expect(back == response)
            let failure = try ControlCodec.decode(ControlResponse.self, from: Data(#"{"ok":false,"error":"Запись уже идёт: a"}"#.utf8))
            #expect(!failure.ok && failure.error == "Запись уже идёт: a")
        }

        @Test func whisperPercent() {
            #expect(Processor.lastPercent(" 12%|█▏ | 10/80\r 45%|███ | 36/80") == 0.45)
            #expect(Processor.lastPercent("no progress") == nil)
            #expect(Processor.lastPercent("whisper_print_progress_callback: progress =  45%") == 0.45)
        }
    }
}
