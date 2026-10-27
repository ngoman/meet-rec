import Foundation

public struct ProcessStatus {
    public var step: String
    public var fraction: Double?
}

public struct ProcessResult {
    public var url: URL
    public var warnings: [String]
}

public final class Processor {
    private let config: Config
    public var onStatus: ((ProcessStatus) -> Void)?

    public init(config: Config) {
        self.config = config
    }

    public static func cancelAll(grace: TimeInterval = 2) {
        ProcessRunner.terminateAll(grace: grace)
    }

    @discardableResult
    public func process(_ session: SessionInfo) async throws -> ProcessResult {
        guard let sessionLock = FileLock.acquire(url: session.lockURL) else {
            throw MeetRecError("Сессия занята другим процессом: \(session.id)")
        }
        defer { sessionLock.unlock() }
        let fm = FileManager.default
        guard Self.size(session.systemPCM) > 0 || Self.size(session.micPCM) > 0 else {
            try? fm.removeItem(at: session.dir)
            throw MeetRecError("В сессии \(session.id) нет записанного звука, она удалена")
        }
        try fm.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        let globalLock = try await acquireGlobalLock()
        defer { globalLock.unlock() }

        var info = session
        info.state = .processing
        info.error = nil
        try info.save()
        do {
            return try await run(&info)
        } catch {
            if error is CancellationError || Task.isCancelled {
                info.state = .recorded
                info.error = nil
            } else {
                info.state = .failed
                info.error = error.localizedDescription
            }
            try? info.save()
            throw error
        }
    }

    private func acquireGlobalLock() async throws -> FileLock {
        let url = Paths.appSupport.appendingPathComponent("processing.lock")
        if let lock = FileLock(url: url) { return lock }
        status("Жду окончания другой обработки…")
        while true {
            if let lock = FileLock(url: url) { return lock }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
    }

    private func tracks(of info: SessionInfo) -> [(name: String, label: String, pcm: URL)] {
        [("system", "системный звук", info.systemPCM, info.systemSignal), ("mic", "микрофон", info.micPCM, info.micSignal)].filter {
            Self.size($0.2) > 0 && $0.3 != false
        }.map { ($0.0, $0.1, $0.2) }
    }

    private func status(_ step: String, _ fraction: Double? = nil) {
        onStatus?(ProcessStatus(step: step, fraction: fraction))
    }

    private var claudeEnv: [String: String] {
        let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL"]
        var result = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) || $0.key.hasPrefix("LC_") }
        result["PATH"] = env["PATH"]
        return result
    }

    private var env: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let ffmpegDir = (config.ffmpeg as NSString).deletingLastPathComponent
        env["PATH"] = [ffmpegDir, env["PATH"] ?? "", "/usr/bin", "/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    static func stderrTail(_ text: String, lines: Int = 5, limit: Int = 500) -> String {
        let parts = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(parts.suffix(lines).joined(separator: "\n").suffix(limit))
    }

    private func fail(_ tool: String, _ result: ShellResult) -> MeetRecError {
        if result.signaled { return MeetRecError("\(tool) убит сигналом \(result.status)") }
        return MeetRecError("\(tool) завершился с кодом \(result.status): \(Self.stderrTail(result.stderr))")
    }

    private func run(_ info: inout SessionInfo) async throws -> ProcessResult {
        let fm = FileManager.default
        let work = info.dir.appendingPathComponent("work")
        let out = info.dir.appendingPathComponent("out")
        try? fm.removeItem(at: work)
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let ffmpeg = config.ffmpeg
        let tracks = tracks(of: info)
        let silent = [
            (info.systemSignal, info.systemPCM, "Системный звук не записан: нет сигнала (проверьте разрешение «Запись системного звука»)"),
            (info.micSignal, info.micPCM, "Микрофон не записан: нет сигнала"),
        ]
        for (signal, pcm, text) in silent where signal == false && Self.size(pcm) > 0 && !info.warnings.contains(text) {
            info.warnings.append(text)
        }

        guard !tracks.isEmpty else { throw MeetRecError("Нет сигнала ни на одной дорожке") }

        status("Готовлю дорожки…")
        for (name, _, pcm) in tracks {
            try Task.checkCancellation()
            let r = try await ProcessRunner.run(ffmpeg, [
                "-nostdin", "-loglevel", "error", "-y", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", pcm.path,
                "-ar", "16000", "-ac", "1", work.appendingPathComponent("\(name)16.wav").path,
            ], environment: env)
            guard r.status == 0 else { throw fail("ffmpeg", r) }
        }

        var vad = false
        if config.engine == "whisper.cpp" {
            if FileManager.default.fileExists(atPath: expandTilde(config.vadModel)) {
                vad = true
            } else {
                info.warnings.append("VAD-модель не найдена (\(config.vadModel)), распознавание без VAD")
            }
        }
        var segments: [String: [Segment]] = [:]
        for (name, label, _) in tracks {
            try Task.checkCancellation()
            let step = "Распознаю \(label)…"
            status(step)
            let wav = work.appendingPathComponent("\(name)16.wav").path
            let onStderr: (String) -> Void = { [weak self] chunk in
                if let p = Self.lastPercent(chunk) { self?.status(step, p) }
            }
            if config.engine == "openai-whisper" {
                var args = [wav, "--model", config.whisperModel]
                if config.language != "auto" { args += ["--language", config.language] }
                args += [
                    "--output_format", "json", "--output_dir", work.path, "--verbose", "False",
                    "--condition_on_previous_text", "False", "--word_timestamps", "True",
                    "--hallucination_silence_threshold", "2", "--fp16", "False",
                ]
                let r = try await ProcessRunner.run(config.openaiWhisper, args, environment: env, onStderr: onStderr)
                guard r.status == 0 else { throw fail("whisper", r) }
                let json = try Data(contentsOf: work.appendingPathComponent("\(name)16.json"))
                segments[name] = Transcript.filter(try Transcript.parseWhisper(json))
            } else {
                let model = expandTilde(config.whisperCppModel)
                guard FileManager.default.fileExists(atPath: model) else {
                    throw MeetRecError("Не найдена модель whisper.cpp: \(model). Запустите ./install.sh")
                }
                var args = [
                    "-m", model, "-f", wav, "-l", config.language, "-oj", "-of", work.appendingPathComponent("\(name)16").path,
                    "-pp", "-mc", "0", "-sns", "-t", String(min(8, ProcessInfo.processInfo.activeProcessorCount)),
                ]
                if vad { args += ["--vad", "-vm", expandTilde(config.vadModel)] }
                let r = try await ProcessRunner.run(config.whisperCpp, args, environment: env, onStderr: onStderr)
                guard r.status == 0 else { throw fail("whisper-cli", r) }
                let json = try Data(contentsOf: work.appendingPathComponent("\(name)16.json"))
                segments[name] = Transcript.filter(try Transcript.parseWhisperCpp(json))
            }
        }

        try Task.checkCancellation()
        status("Собираю транскрипт…")
        let systemSegs = segments["system"] ?? []
        let micSegs = Transcript.removeEcho(mic: segments["mic"] ?? [], system: systemSegs)
        let lines = Transcript.merge(mic: micSegs, system: systemSegs, myName: config.myName, othersName: config.othersName)
        let frames = max(Self.size(info.systemPCM), Self.size(info.micPCM)) / 2
        let markdown = Transcript.markdown(lines: lines, title: info.title, startedAt: info.startedAt,
                                           duration: Double(frames) / 48000)
        try markdown.write(to: out.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Json.encoder.encode(lines).write(to: out.appendingPathComponent("transcript.json"))

        status("Сжимаю аудио…")
        var ffArgs = ["-nostdin", "-loglevel", "error", "-y"]
        for (_, _, pcm) in tracks { ffArgs += ["-f", "s16le", "-ar", "48000", "-ac", "1", "-i", pcm.path] }
        if tracks.count == 2 {
            ffArgs += ["-filter_complex", "amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95"]
        }
        ffArgs += ["-c:a", "aac", "-b:a", "96k", "-ac", "1", out.appendingPathComponent("audio.m4a").path]
        let mix = try await ProcessRunner.run(ffmpeg, ffArgs, environment: env)
        guard mix.status == 0 else { throw fail("ffmpeg", mix) }

        if config.summary && !lines.isEmpty && !config.hasClaude {
            info.warnings.append("claude не найден, саммари пропущено")
        } else if config.summary && !lines.isEmpty {
            status("Делаю саммари…")
            do {
                let summary = try await summarize(markdown)
                try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                info.warnings.append("Саммари не получено: \(error.localizedDescription)")
            }
        }

        info.state = .done
        info.error = nil
        try info.save(to: out)
        try info.save()

        let outputURL = (try? Config.load())?.outputURL ?? config.outputURL
        let dest = try SessionStore.moveResult(from: out, id: info.id, to: outputURL)
        try? fm.removeItem(at: info.dir)
        return ProcessResult(url: dest, warnings: info.warnings)
    }

    func summarize(_ transcript: String) async throws -> String {
        let prompt = """
            Ты готовишь саммари рабочих встреч. На входе транскрипт рабочей встречи. Он распознан автоматически и содержит ошибки: \
            искажённые слова, имена и термины, обрывки фраз. «\(config.myName)» - автор записи, «\(config.othersName)» - остальные участники.
            Верни только Markdown со следующими разделами:
            ## Кратко
            3-6 пунктов списком.
            ## Решения
            ## Задачи
            Формат пункта: - [ ] кто: что, срок если назван.
            ## Открытые вопросы
            Ничего не выдумывай, опирайся только на транскрипт. Если в разделе нечего написать, напиши «нет». \
            Инструменты не используй, отвечай сразу текстом.
            """
        let r = try await ProcessRunner.run(config.claude, [
            "-p", "--setting-sources", "project", "--tools", "", "--no-session-persistence",
            "--strict-mcp-config", "--model", config.summaryModel, "--output-format", "text", "--system-prompt", prompt,
        ], stdin: Data(transcript.utf8), cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
           environment: claudeEnv, timeout: 600)
        guard r.status == 0 else { throw fail("claude", r) }
        let text = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetRecError("claude вернул пустой ответ") }
        return text + "\n"
    }

    static func lastPercent(_ chunk: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,3})%") else { return nil }
        let range = NSRange(chunk.startIndex..., in: chunk)
        guard let m = regex.matches(in: chunk, range: range).last, let r = Range(m.range(at: 1), in: chunk),
              let v = Double(chunk[r]) else { return nil }
        return min(1, v / 100)
    }
}
