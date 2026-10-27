import Foundation

public struct Word: Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Segment: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var noSpeechProb: Double
    public var avgLogprob: Double
    public var words: [Word]

    public init(start: Double, end: Double, text: String, noSpeechProb: Double = 0, avgLogprob: Double = 0, words: [Word] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
        self.words = words
    }
}

public struct TranscriptLine: Codable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Transcript {
    static let hallucinations = [
        "субтитры", "продолжение следует", "спасибо за просмотр", "редактор субтитров",
        "dimatorzok", "подписывайтесь на канал", "amara.org",
    ]

    public static func parseWhisper(_ data: Data) throws -> [Segment] {
        struct Raw: Decodable {
            struct Seg: Decodable {
                struct W: Decodable {
                    var word: String
                    var start: Double
                    var end: Double
                }
                var start: Double
                var end: Double
                var text: String
                var no_speech_prob: Double?
                var avg_logprob: Double?
                var words: [W]?
            }
            var segments: [Seg]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.segments.map {
            Segment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    noSpeechProb: $0.no_speech_prob ?? 0, avgLogprob: $0.avg_logprob ?? 0,
                    words: ($0.words ?? []).map {
                        Word(start: $0.start, end: $0.end, text: $0.word.trimmingCharacters(in: .whitespacesAndNewlines))
                    }.filter { !$0.text.isEmpty })
        }
    }

    public static func parseWhisperCpp(_ data: Data) throws -> [Segment] {
        struct Raw: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable {
                    var from: Double
                    var to: Double
                }
                struct Token: Decodable {
                    var text: String
                    var offsets: Offsets
                }
                var offsets: Offsets
                var text: String
                var tokens: [Token]?
            }
            var transcription: [Item]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(String(decoding: data, as: UTF8.self).utf8))
        return raw.transcription.map {
            Segment(start: $0.offsets.from / 1000, end: $0.offsets.to / 1000,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), words: fit(words(from: ($0.tokens ?? []).map { ($0.text, $0.offsets.from, $0.offsets.to) }),
                                start: $0.offsets.from / 1000, end: $0.offsets.to / 1000))
        }
    }

    private static func fit(_ words: [Word], start: Double, end: Double) -> [Word] {
        guard let first = words.first, let last = words.last, last.end > first.start, end > start else { return words }
        let scale = (end - start) / (last.end - first.start)
        return words.map {
            Word(start: start + ($0.start - first.start) * scale, end: start + ($0.end - first.start) * scale, text: $0.text)
        }
    }

    private static func words(from tokens: [(text: String, from: Double, to: Double)]) -> [Word] {
        var out: [Word] = []
        var current: Word?
        for t in tokens where !t.text.hasPrefix("[_") {
            if t.text.hasPrefix(" "), let word = current {
                out.append(word)
                current = nil
            }
            let piece = t.text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if var word = current {
                word.text += piece
                word.end = t.to / 1000
                current = word
            } else {
                current = Word(start: t.from / 1000, end: t.to / 1000, text: piece)
            }
        }
        if let word = current { out.append(word) }
        return out
    }

    public static func filter(_ segments: [Segment]) -> [Segment] {
        let kept = segments.filter { s in
            if s.text.isEmpty { return false }
            if s.noSpeechProb > 0.6 && s.avgLogprob < -1.0 { return false }
            let lower = s.text.lowercased()
            let words = lower.split(whereSeparator: { $0.isWhitespace }).count
            if words < 8 && hallucinations.contains(where: { lower.contains($0) }) { return false }
            return true
        }
        return collapseRepeats(kept)
    }

    public static func collapseRepeats(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var i = 0
        while i < segments.count {
            var j = i
            while j + 1 < segments.count && segments[j + 1].text == segments[i].text { j += 1 }
            if j - i + 1 > 2 {
                var s = segments[i]
                s.end = segments[j].end
                out.append(s)
            } else {
                out.append(contentsOf: segments[i...j])
            }
            i = j + 1
        }
        return out
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    public static func removeEcho(mic: [Segment], system: [Segment]) -> [Segment] {
        mic.filter { m in
            let duration = m.end - m.start
            let micTokens = tokens(m.text)
            guard duration > 0, !micTokens.isEmpty else { return true }
            let overlapping = system.filter { min(m.end, $0.end) > max(m.start, $0.start) }
            guard !overlapping.isEmpty else { return true }
            var covered = 0.0
            var cursor = m.start
            let intervals = overlapping.map { (max(m.start, $0.start), min(m.end, $0.end)) }.sorted { $0.0 < $1.0 }
            for (start, end) in intervals {
                let from = max(start, cursor)
                if end > from {
                    covered += end - from
                    cursor = end
                }
            }
            guard covered > duration * 0.5 else { return true }
            if micTokens.count < 3 {
                let normal = normalized(m.text)
                return !overlapping.contains { normalized($0.text) == normal }
            }
            let systemTokens = overlapping.reduce(into: Set<String>()) { $0.formUnion(tokens($1.text)) }
            let containment = Double(micTokens.intersection(systemTokens).count) / Double(micTokens.count)
            return containment < 0.6
        }
    }

    public static func merge(mic: [Segment], system: [Segment], myName: String, othersName: String) -> [TranscriptLine] {
        merge(mic.map { (speaker: myName, seg: $0) } + system.map { (speaker: othersName, seg: $0) })
    }

    public static func merge(_ all: [(speaker: String, seg: Segment)]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        let sorted = all.sorted { $0.seg.start != $1.seg.start ? $0.seg.start < $1.seg.start : $0.seg.end < $1.seg.end }
        for item in sorted {
            if var last = lines.last, last.speaker == item.speaker, item.seg.start - last.end < 1.5,
               max(last.end, item.seg.end) - last.start <= 30 {
                last.end = max(last.end, item.seg.end)
                last.text += " " + item.seg.text
                lines[lines.count - 1] = last
            } else {
                lines.append(TranscriptLine(speaker: item.speaker, start: item.seg.start, end: item.seg.end, text: item.seg.text))
            }
        }
        return lines
    }

    public static func formatTime(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    public static func markdown(lines: [TranscriptLine], title: String?, startedAt: Date, duration: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var head = "# Встреча " + f.string(from: startedAt)
        if let title, !title.isEmpty { head += " " + title }
        var out = head + "\n\nДлительность: " + formatTime(duration) + "\n"
        for l in lines {
            out += "\n**[\(formatTime(l.start))] \(l.speaker):** \(l.text)\n"
        }
        return out
    }
}

public func silenceFrames(expectedSeconds: Double, framesWritten: Int, sampleRate: Int = 48000) -> Int {
    let gap = Int(expectedSeconds * Double(sampleRate)) - framesWritten
    return Double(gap) / Double(sampleRate) > 0.1 ? gap : 0
}
