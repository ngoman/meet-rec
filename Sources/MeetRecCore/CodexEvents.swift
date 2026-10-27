import Foundation

enum CodexEvents {
    static let eventTypes: Set<String> = ["thread.started", "turn.started", "turn.completed", "turn.failed", "error"]
    static let itemEventTypes: Set<String> = ["item.started", "item.updated", "item.completed"]
    static let itemTypes: Set<String> = ["agent_message", "reasoning", "error", "todo_list"]

    static func violation(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if eventTypes.contains(type) { return nil }
        guard itemEventTypes.contains(type), let item = object["item"] as? [String: Any],
              let itemType = item["type"] as? String else { return type }
        return itemTypes.contains(itemType) ? nil : itemType
    }

    static func allowed(_ line: String) -> Bool {
        violation(line) == nil
    }

    static func finalMessage(_ output: String) -> String? {
        var last: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "item.completed", let item = object["item"] as? [String: Any],
                  item["type"] as? String == "agent_message", let text = item["text"] as? String else { continue }
            last = text
        }
        return last
    }
}

final class CodexWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var violation: String?

    var tripped: Bool { offender != nil }

    var offender: String? {
        lock.lock()
        defer { lock.unlock() }
        return violation
    }

    func feed(_ chunk: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if violation == nil { violation = CodexEvents.violation(line) }
        }
        return violation != nil
    }
}
