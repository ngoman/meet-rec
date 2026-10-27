import Foundation

public struct MeetRecError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

public enum Json {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum Paths {
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["MEETREC_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: expandTilde(override))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetRec")
    }
    public static var sessionsDir: URL { appSupport.appendingPathComponent("sessions") }
    public static var configURL: URL { appSupport.appendingPathComponent("config.json") }
}
