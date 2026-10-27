import Foundation
import Testing
@testable import MeetRecCore

private func words(_ text: String, from start: Double, step: Double = 0.5) -> [Word] {
    text.split(separator: " ").enumerated().map {
        Word(start: start + Double($0.offset) * step, end: start + Double($0.offset + 1) * step, text: String($0.element))
    }
}

extension AllTests {
    @Suite struct DiarizationTests {
        @Test func parsesSherpaOutput() {
            let output = """
                Started
                0.318 -- 6.865 speaker_00
                7.017 -- 10.5 speaker_01
                bad line
                progress 50.00%
                Duration : 12.000 s
                RTF = 0.1
                """
            #expect(Diarization.parse(output) == [
                Turn(start: 0.318, end: 6.865, speaker: 0), Turn(start: 7.017, end: 10.5, speaker: 1),
            ])
            #expect(Diarization.parse("").isEmpty)
        }

        @Test func parsesProgress() {
            #expect(Diarization.lastProgress("progress 12.50%\nprogress 45.25%") == 0.4525)
            #expect(Diarization.lastProgress("Started") == nil)
        }

        @Test func assignsByMaxOverlap() {
            let turns = [Turn(start: 0, end: 5, speaker: 0), Turn(start: 5, end: 10, speaker: 1)]
            let segs = [
                Segment(start: 0.5, end: 4.5, text: "a"),
                Segment(start: 4.0, end: 8.0, text: "b"),
                Segment(start: 11, end: 12, text: "c"),
            ]
            #expect(Diarization.assign(segs, turns: turns).map(\.speaker) == [0, 1, 1])
        }

        @Test func splitsSegmentAcrossSpeakers() {
            let turns = [Turn(start: 0, end: 2.5, speaker: 0), Turn(start: 2.5, end: 5, speaker: 1)]
            let seg = Segment(start: 0, end: 5, text: "one two three four five six seven eight nine ten",
                              words: words("one two three four five six seven eight nine ten", from: 0))
            let out = Diarization.assign([seg], turns: turns)
            #expect(out.map(\.speaker) == [0, 1])
            #expect(out[0].segment.text == "one two three four five" && out[0].segment.start == 0 && out[0].segment.end == 2.5)
            #expect(out[1].segment.text == "six seven eight nine ten" && out[1].segment.end == 5)
        }

        @Test func splitTextComesFromOriginalSegment() {
            let turns = [Turn(start: 0, end: 1, speaker: 0), Turn(start: 1, end: 2, speaker: 1)]
            let seg = Segment(start: 0, end: 2, text: "привет мир", words: [
                Word(start: 0, end: 1, text: "пр\u{FFFD}"), Word(start: 1, end: 2, text: "мир"),
            ])
            #expect(Diarization.assign([seg], turns: turns).map(\.segment.text) == ["привет", "мир"])
        }

        @Test func doesNotSplitOnSmallOverlap() {
            let turns = [Turn(start: 0, end: 4.5, speaker: 0), Turn(start: 4.5, end: 5, speaker: 1)]
            let seg = Segment(start: 0, end: 5, text: "a b c d e f g h i j", words: words("a b c d e f g h i j", from: 0))
            #expect(Diarization.assign([seg], turns: turns).map(\.speaker) == [0])
        }

        @Test func splitWithoutWordsKeepsSegment() {
            let turns = [Turn(start: 0, end: 3, speaker: 0), Turn(start: 3, end: 5, speaker: 1)]
            let seg = Segment(start: 0, end: 5, text: "a b c d e f g h i j")
            #expect(Diarization.assign([seg], turns: turns).map(\.speaker) == [0])
        }

        @Test func smoothsSingleWordFlip() {
            let turns = [
                Turn(start: 0, end: 2, speaker: 0), Turn(start: 2, end: 2.5, speaker: 1), Turn(start: 2.5, end: 3, speaker: 0),
                Turn(start: 3, end: 6, speaker: 1),
            ]
            let seg = Segment(start: 0, end: 6, text: "", words: words("a b c d e f g h i j k l", from: 0))
            let out = Diarization.assign([seg], turns: turns)
            #expect(out.map(\.speaker) == [0, 1])
        }

        @Test func numbersByFirstAppearance() {
            let assigned = [
                (speaker: 2, segment: Segment(start: 5, end: 6, text: "b")),
                (speaker: 0, segment: Segment(start: 9, end: 10, text: "c")),
                (speaker: 1, segment: Segment(start: 1, end: 2, text: "a")),
                (speaker: 0, segment: Segment(start: 11, end: 12, text: "d")),
            ]
            let labeled = Diarization.label(assigned, label: "Собеседник", single: "Собеседники")
            #expect(labeled.map(\.speaker) == ["Собеседник 2", "Собеседник 3", "Собеседник 1", "Собеседник 3"])
        }

        @Test func singleClusterKeepsOthersName() {
            let assigned = [
                (speaker: 3, segment: Segment(start: 0, end: 1, text: "a")),
                (speaker: 3, segment: Segment(start: 2, end: 3, text: "b")),
            ]
            #expect(Diarization.label(assigned, label: "Собеседник", single: "Собеседники").map(\.speaker) == ["Собеседники", "Собеседники"])
        }

        @Test func mergesBySpeakerEquality() {
            let lines = Transcript.merge([
                (speaker: "Собеседник 1", seg: Segment(start: 0, end: 1, text: "a")),
                (speaker: "Собеседник 1", seg: Segment(start: 1.2, end: 2, text: "b")),
                (speaker: "Собеседник 2", seg: Segment(start: 2.1, end: 3, text: "c")),
            ])
            #expect(lines.map(\.speaker) == ["Собеседник 1", "Собеседник 2"] && lines[0].text == "a b")
        }

        @Test func parsesWhisperCppWordsAndFitsToSegment() throws {
            let json = #"""
                {"transcription":[{"offsets":{"from":7000,"to":9000},"text":" Hi there, friend.","tokens":[
                {"text":"[_BEG_]","offsets":{"from":0,"to":0}},
                {"text":" Hi","offsets":{"from":6000,"to":6500}},
                {"text":" the","offsets":{"from":6500,"to":7000}},
                {"text":"re","offsets":{"from":7000,"to":7500}},
                {"text":",","offsets":{"from":7500,"to":7500}},
                {"text":" friend","offsets":{"from":7500,"to":8000}},
                {"text":".","offsets":{"from":8000,"to":8000}},
                {"text":"[_TT_300]","offsets":{"from":8000,"to":8000}}]}]}
                """#
            let seg = try Transcript.parseWhisperCpp(Data(json.utf8))[0]
            #expect(seg.words.map(\.text) == ["Hi", "there,", "friend."])
            #expect(seg.words[0].start == 7 && seg.words[2].end == 9)
        }

        @Test func parsesWhisperWords() throws {
            let json = #"{"segments":[{"start":0,"end":2,"text":" a b","words":[{"word":" a","start":0,"end":1},{"word":" b","start":1,"end":2}]}]}"#
            #expect(try Transcript.parseWhisper(Data(json.utf8))[0].words == [Word(start: 0, end: 1, text: "a"), Word(start: 1, end: 2, text: "b")])
        }

        @Test func speakersNormalize() {
            #expect(Speakers.normalize("3") == "3" && Speakers.normalize("AUTO") == "auto")
            #expect(Speakers.normalize("0") == nil && Speakers.normalize("7") == nil && Speakers.normalize("x") == nil)
            #expect(Speakers.count("auto") == nil && Speakers.count("4") == 4)
        }

        @Test func configSpeakersAndProvider() throws {
            var config = Config()
            #expect(config.speakers == "1" && config.summaryProvider == "claude" && config.speakerLabel == "Собеседник")
            try config.set(key: "speakers", value: "auto")
            try config.set(key: "summaryProvider", value: "codex")
            #expect(config.speakers == "auto" && config.summaryProvider == "codex")
            #expect(throws: MeetRecError.self) { try config.set(key: "speakers", value: "9") }
            #expect(throws: MeetRecError.self) { try config.set(key: "summaryProvider", value: "gpt") }
        }

        @Test func sessionJSONBackwardCompatible() throws {
            let old = #"{"startedAt":"2026-01-01T10:00:00Z","sampleRate":48000,"state":"recorded","warnings":[]}"#
            let info = try Json.decoder.decode(SessionInfo.self, from: Data(old.utf8))
            #expect(info.speakers == nil)
            var withSpeakers = info
            withSpeakers.speakers = "auto"
            let back = try Json.decoder.decode(SessionInfo.self, from: Json.encoder.encode(withSpeakers))
            #expect(back.speakers == "auto")
        }

        @Test func codexArgumentsAreReadOnlyAndPipeStdin() {
            let args = Processor.codexArguments(cwd: "/tmp/c", output: "/tmp/o", model: "")
            #expect(args.starts(with: ["exec"]) && args.last == "-" && !args.contains("-m"))
            #expect(args.contains("--skip-git-repo-check") && args.contains("--ephemeral") && args.contains("--json"))
            #expect(zip(args, args.dropFirst()).contains { $0 == "-s" && $1 == "read-only" })
            for feature in ["shell_tool", "unified_exec", "browser_use", "computer_use", "apps", "plugins", "hooks"] {
                #expect(zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == feature })
            }
            #expect(zip(args, args.dropFirst()).contains { $0 == "-c" && $1 == "web_search=\"disabled\"" })
            #expect(Processor.codexArguments(cwd: "/c", output: "/o", model: "gpt-x").contains("gpt-x"))
        }

        @Test func codexEventClassifier() {
            #expect(CodexEvents.allowed(#"{"type":"thread.started","thread_id":"x"}"#))
            #expect(CodexEvents.allowed(#"{"type":"turn.completed","usage":{}}"#))
            #expect(CodexEvents.allowed(#"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"hi"}}"#))
            #expect(CodexEvents.allowed(#"{"type":"item.completed","item":{"id":"i","type":"reasoning","text":"hm"}}"#))
            #expect(CodexEvents.allowed("not json"))
            #expect(!CodexEvents.allowed(#"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#))
            #expect(!CodexEvents.allowed(#"{"type":"item.completed","item":{"type":"web_search","query":"x"}}"#))
            #expect(!CodexEvents.allowed(#"{"type":"item.completed","item":{"type":"mcp_tool_call"}}"#))
            #expect(!CodexEvents.allowed(#"{"type":"item.completed","item":{"type":"file_change"}}"#))
            #expect(CodexEvents.allowed(#"{"type":"item.completed","item":{"type":"todo_list","items":[]}}"#))
            #expect(CodexEvents.violation(#"{"type":"item.started","item":{"type":"command_execution"}}"#) == "command_execution")
            #expect(!CodexEvents.allowed(#"{"type":"item.completed"}"#))
            #expect(!CodexEvents.allowed(#"{"type":"something.new"}"#))
        }

        @Test func codexWatchdogHandlesSplitChunks() {
            let clean = CodexWatchdog()
            #expect(!clean.feed(#"{"type":"turn.sta"#) && !clean.feed("rted\"}\n") && !clean.tripped)
            let bad = CodexWatchdog()
            #expect(!bad.feed(#"{"type":"item.started","item":{"type":"comm"#))
            #expect(bad.feed(#"and_execution"}}"# + "\n") && bad.tripped && bad.offender == "command_execution")
        }

        @Test func codexFinalMessageIsLastAgentMessage() {
            let output = """
                {"type":"thread.started","thread_id":"x"}
                {"type":"item.completed","item":{"id":"0","type":"agent_message","text":"first"}}
                {"type":"item.completed","item":{"id":"1","type":"reasoning","text":"thinking"}}
                {"type":"item.completed","item":{"id":"2","type":"agent_message","text":"## Кратко\\n- да"}}
                {"type":"turn.completed"}
                """
            #expect(CodexEvents.finalMessage(output) == "## Кратко\n- да")
            #expect(CodexEvents.finalMessage(#"{"type":"turn.started"}"#) == nil)
        }

        @Test func detectsCodexAuthFailure() {
            #expect(Processor.codexAuthFailed("ERROR Your access token could not be refreshed. Please log out and sign in again."))
            #expect(!Processor.codexAuthFailed("network unreachable"))
        }
    }
}
