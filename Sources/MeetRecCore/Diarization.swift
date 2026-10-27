import Foundation

public enum Speakers {
    public static func normalize(_ value: String) -> String? {
        let lower = value.lowercased()
        if lower == "auto" { return lower }
        guard let n = Int(lower), (1...6).contains(n) else { return nil }
        return String(n)
    }

    public static func count(_ value: String) -> Int? {
        Int(value)
    }
}

public struct Turn: Equatable {
    public var start: Double
    public var end: Double
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public enum Diarization {
    static let splitShare = 0.3
    static let splitMinSeconds = 0.8

    public static func parse(_ output: String) -> [Turn] {
        guard let regex = try? NSRegularExpression(pattern: "^\\s*(\\d+(?:\\.\\d+)?)\\s*-+\\s*(\\d+(?:\\.\\d+)?)\\s+speaker_(\\d+)\\s*$") else { return [] }
        return output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let text = String(line)
            guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
                  let c = Range(m.range(at: 3), in: text),
                  let start = Double(text[a]), let end = Double(text[b]), let speaker = Int(text[c]) else { return nil }
            return Turn(start: start, end: end, speaker: speaker)
        }.sorted { $0.start < $1.start }
    }

    public static func lastProgress(_ chunk: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "progress (\\d{1,3}(?:\\.\\d+)?)%") else { return nil }
        let range = NSRange(chunk.startIndex..., in: chunk)
        guard let m = regex.matches(in: chunk, range: range).last, let r = Range(m.range(at: 1), in: chunk),
              let v = Double(chunk[r]) else { return nil }
        return min(1, v / 100)
    }

    static func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        max(0, min(a.1, b.1) - max(a.0, b.0))
    }

    static func shares(from start: Double, to end: Double, turns: [Turn]) -> [(speaker: Int, seconds: Double)] {
        var totals: [Int: Double] = [:]
        for t in turns {
            let o = overlap((start, end), (t.start, t.end))
            if o > 0 { totals[t.speaker, default: 0] += o }
        }
        return totals.map { (speaker: $0.key, seconds: $0.value) }.sorted {
            $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.speaker < $1.speaker
        }
    }

    static func speaker(from start: Double, to end: Double, turns: [Turn]) -> Int? {
        if let best = shares(from: start, to: end, turns: turns).first { return best.speaker }
        let middle = (start + end) / 2
        return turns.min {
            abs(($0.start + $0.end) / 2 - middle) < abs(($1.start + $1.end) / 2 - middle)
        }?.speaker
    }

    public static func assign(_ segments: [Segment], turns: [Turn]) -> [(speaker: Int, segment: Segment)] {
        var out: [(speaker: Int, segment: Segment)] = []
        for s in segments {
            guard let main = speaker(from: s.start, to: s.end, turns: turns) else {
                out.append((0, s))
                continue
            }
            let shares = shares(from: s.start, to: s.end, turns: turns)
            let duration = s.end - s.start
            guard s.words.count > 1, shares.count > 1,
                  shares[1].seconds >= duration * splitShare, shares[1].seconds >= splitMinSeconds else {
                out.append((main, s))
                continue
            }
            out.append(contentsOf: split(s, main: main, turns: turns))
        }
        return out
    }

    static func split(_ s: Segment, main: Int, turns: [Turn]) -> [(speaker: Int, segment: Segment)] {
        var owners = s.words.map { speaker(from: $0.start, to: $0.end, turns: turns) ?? main }
        if owners.count > 2 {
            for i in 1..<(owners.count - 1) where owners[i - 1] == owners[i + 1] { owners[i] = owners[i - 1] }
        }
        let original = s.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let texts = original.count == s.words.count ? original : s.words.map(\.text)
        var out: [(speaker: Int, segment: Segment)] = []
        var from = 0
        for i in 1...owners.count where i == owners.count || owners[i] != owners[from] {
            let words = Array(s.words[from..<i])
            var piece = s
            piece.start = words[0].start
            piece.end = words[words.count - 1].end
            piece.text = texts[from..<i].joined(separator: " ")
            piece.words = words
            out.append((owners[from], piece))
            from = i
        }
        return out
    }

    public static func label(_ assigned: [(speaker: Int, segment: Segment)], label: String, single: String) -> [(speaker: String, seg: Segment)] {
        var order: [Int] = []
        for item in assigned.sorted(by: { $0.segment.start < $1.segment.start }) where !order.contains(item.speaker) {
            order.append(item.speaker)
        }
        return assigned.map { item in
            let name = order.count > 1 ? "\(label) \((order.firstIndex(of: item.speaker) ?? 0) + 1)" : single
            return (name, item.segment)
        }
    }
}
