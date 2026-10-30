import Foundation

public struct Config: Codable {
    public var outputDir = "~/Documents/MeetRec"
    public var language = "ru"
    public var engine = "whisper.cpp"
    public var whisperCppBin = "/opt/homebrew/bin/whisper-cli"
    public var whisperCppModel = "~/Library/Application Support/MeetRec/models/ggml-large-v3-turbo-q5_0.bin"
    public var vadModel = "~/Library/Application Support/MeetRec/models/ggml-silero-v5.1.2.bin"
    public var whisperModel = "small"
    public var whisperBin = "/opt/homebrew/bin/whisper"
    public var ffmpegBin = "/opt/homebrew/bin/ffmpeg"
    public var claudeBin = "~/.local/bin/claude"
    public var codexBin = "/opt/homebrew/bin/codex"
    public var diarizationBin = "~/Library/Application Support/MeetRec/sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization"
    public var segmentationModel = "~/Library/Application Support/MeetRec/models/sherpa-onnx-pyannote-segmentation-3-0.onnx"
    public var embeddingModel = "~/Library/Application Support/MeetRec/models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    public var clusterThreshold = 0.5
    public var speakers = "1"
    public var summary = true
    public var summaryProvider = "claude"
    public var summaryModel = "sonnet"
    public var codexModel = ""
    public var myName = "Я"
    public var othersName = "Собеседники"
    public var speakerLabel = "Собеседник"
    public var hotkey = "ctrl+opt+cmd+r"
    public var autoUpdate = true

    public init() {}

    public var outputURL: URL { URL(fileURLWithPath: expandTilde(outputDir)) }

    public static func resolveBinary(_ path: String, extraDirs: [String] = []) -> String {
        let expanded = expandTilde(path)
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: expanded) { return expanded }
        let name = (expanded as NSString).lastPathComponent
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + extraDirs.map(expandTilde)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return expanded
    }

    public var ffmpeg: String { Config.resolveBinary(ffmpegBin) }
    public var whisperCpp: String { Config.resolveBinary(whisperCppBin) }
    public var openaiWhisper: String {
        let python = ((try? FileManager.default.contentsOfDirectory(atPath: expandTilde("~/Library/Python"))) ?? [])
            .map { "~/Library/Python/\($0)/bin" }
        return Config.resolveBinary(whisperBin, extraDirs: python)
    }
    public var claude: String { Config.resolveBinary(claudeBin, extraDirs: ["~/.local/bin", "~/.claude/local"]) }
    public var hasClaude: Bool { FileManager.default.isExecutableFile(atPath: claude) }
    public var codex: String {
        Config.resolveBinary(codexBin, extraDirs: ["~/.local/bin", "~/.npm-global/bin", "~/.volta/bin", "~/.bun/bin"])
    }
    public var hasCodex: Bool { FileManager.default.isExecutableFile(atPath: codex) }
    public var diarizationReady: Bool {
        FileManager.default.isExecutableFile(atPath: expandTilde(diarizationBin))
            && FileManager.default.fileExists(atPath: expandTilde(segmentationModel))
            && FileManager.default.fileExists(atPath: expandTilde(embeddingModel))
    }

    public static func update(_ body: (inout Config) throws -> Void) throws -> Config {
        var config = try load()
        try body(&config)
        try config.save()
        return config
    }

    public static let keys = [
        "outputDir", "language", "engine", "whisperCppBin", "whisperCppModel", "vadModel", "whisperModel",
        "whisperBin", "ffmpegBin", "claudeBin", "codexBin", "diarizationBin", "segmentationModel", "embeddingModel",
        "clusterThreshold", "speakers", "summary", "summaryProvider", "summaryModel", "codexModel", "myName", "othersName",
        "speakerLabel", "hotkey", "autoUpdate",
    ]

    public mutating func set(key: String, value: String) throws {
        func text() throws -> String {
            guard !value.isEmpty else { throw MeetRecError("Пустое значение для \(key)") }
            return value
        }
        switch key {
        case "outputDir":
            guard value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") else {
                throw MeetRecError("outputDir: нужен абсолютный путь или путь с ~")
            }
            outputDir = value
        case "language": language = try text()
        case "engine":
            guard ["whisper.cpp", "openai-whisper"].contains(value) else {
                throw MeetRecError("engine: допустимо whisper.cpp или openai-whisper")
            }
            engine = value
        case "whisperCppBin": whisperCppBin = try text()
        case "whisperCppModel": whisperCppModel = try text()
        case "vadModel": vadModel = try text()
        case "whisperModel": whisperModel = try text()
        case "whisperBin": whisperBin = try text()
        case "ffmpegBin": ffmpegBin = try text()
        case "claudeBin": claudeBin = try text()
        case "codexBin": codexBin = try text()
        case "diarizationBin": diarizationBin = try text()
        case "segmentationModel": segmentationModel = try text()
        case "embeddingModel": embeddingModel = try text()
        case "clusterThreshold":
            guard let number = Double(value), number > 0, number < 2 else {
                throw MeetRecError("clusterThreshold: допустимо число больше 0 и меньше 2")
            }
            clusterThreshold = number
        case "speakers":
            guard let normalized = Speakers.normalize(value) else {
                throw MeetRecError("speakers: допустимо 1-6 или auto")
            }
            speakers = normalized
        case "summaryProvider":
            guard ["claude", "codex"].contains(value) else {
                throw MeetRecError("summaryProvider: допустимо claude или codex")
            }
            summaryProvider = value
        case "codexModel": codexModel = value
        case "summary":
            switch value.lowercased() {
            case "true", "yes", "1", "on": summary = true
            case "false", "no", "0", "off": summary = false
            default: throw MeetRecError("summary: допустимо true или false")
            }
        case "autoUpdate":
            switch value.lowercased() {
            case "true", "yes", "1", "on": autoUpdate = true
            case "false", "no", "0", "off": autoUpdate = false
            default: throw MeetRecError("autoUpdate: допустимо true или false")
            }
        case "summaryModel": summaryModel = try text()
        case "myName": myName = try text()
        case "othersName": othersName = try text()
        case "speakerLabel": speakerLabel = try text()
        case "hotkey":
            guard Hotkey(value) != nil else { throw MeetRecError("hotkey: неверная комбинация, пример ctrl+opt+cmd+r") }
            hotkey = value
        default:
            throw MeetRecError("Неизвестный ключ \(key). Допустимые: \(Config.keys.joined(separator: ", "))")
        }
    }

    public static func load() throws -> Config {
        let url = Paths.configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = Config()
            try config.save()
            return config
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] ?? [:]
        let user = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let merged = defaults.merging(user) { $1 }
        return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try Json.encoder.encode(self).write(to: Paths.configURL, options: .atomic)
    }
}
