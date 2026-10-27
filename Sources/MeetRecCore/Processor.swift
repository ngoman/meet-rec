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
    public static let systemPermissionWarning = "Системный звук пустой. Если собеседники говорили, проверьте разрешение «Запись системного звука»"

    static func systemSilenceIsPermission(_ info: SessionInfo) -> Bool {
        info.systemSignal == false && info.systemOutputSeen == true
    }

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

    private var codexEnv: [String: String] {
        var result = claudeEnv
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] { result["CODEX_HOME"] = home }
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
            (Self.systemSilenceIsPermission(info), info.systemPCM, Self.systemPermissionWarning),
            (info.micSignal == false, info.micPCM, "Микрофон не записан: нет сигнала"),
        ]
        for (isSilent, pcm, text) in silent where isSilent && Self.size(pcm) > 0 && !info.warnings.contains(text) {
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
        let speakers = info.speakers ?? "1"
        var diarize = false
        if speakers != "1", tracks.contains(where: { $0.name == "system" }) {
            if config.diarizationReady {
                diarize = true
            } else {
                info.warnings.append("Различение собеседников недоступно: запустите ./install.sh")
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
                    "-m", model, "-f", wav, "-l", config.language, diarize && name == "system" ? "-ojf" : "-oj", "-of", work.appendingPathComponent("\(name)16").path,
                    "-pp", "-sns", "-mc", "128", "-t", String(min(8, ProcessInfo.processInfo.activeProcessorCount)),
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
        var systemLines = systemSegs.map { (speaker: config.othersName, seg: $0) }
        if diarize, !systemSegs.isEmpty {
            do {
                let turns = try await diarizeSystem(work.appendingPathComponent("system16.wav"), speakers: speakers)
                if turns.isEmpty { info.warnings.append("Различение собеседников не дало результата") }
                systemLines = Diarization.label(Diarization.assign(systemSegs, turns: turns),
                                                label: config.speakerLabel, single: config.othersName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                info.warnings.append("Различение собеседников не удалось: \(error.localizedDescription)")
            }
        }
        let lines = Transcript.merge(micSegs.map { (speaker: config.myName, seg: $0) } + systemLines)
        let multiple = Set(lines.map(\.speaker)).subtracting([config.myName]).count > 1
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

        let codex = config.summaryProvider == "codex"
        if config.summary && !lines.isEmpty && !(codex ? config.hasCodex : config.hasClaude) {
            info.warnings.append("\(codex ? "codex" : "claude") не найден, саммари пропущено")
        } else if config.summary && !lines.isEmpty {
            status("Делаю саммари…")
            do {
                let summary = try await summarize(markdown, multiple: multiple)
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

    private func diarizeSystem(_ wav: URL, speakers: String) async throws -> [Turn] {
        status("Различаю собеседников…")
        let threads = String(min(8, ProcessInfo.processInfo.activeProcessorCount))
        var args = [
            "--segmentation.pyannote-model=\(expandTilde(config.segmentationModel))",
            "--embedding.model=\(expandTilde(config.embeddingModel))",
            "--segmentation.num-threads=\(threads)", "--embedding.num-threads=\(threads)",
        ]
        if let count = Speakers.count(speakers) {
            args.append("--clustering.num-clusters=\(count)")
        } else {
            args.append("--clustering.cluster-threshold=\(config.clusterThreshold)")
        }
        args.append(wav.path)
        let r = try await ProcessRunner.run(expandTilde(config.diarizationBin), args, environment: env, timeout: 1800, onStderr: { [weak self] chunk in
            if let p = Diarization.lastProgress(chunk) { self?.status("Различаю собеседников…", p) }
        })
        guard r.status == 0 else { throw fail("sherpa-onnx", r) }
        return Diarization.parse(String(decoding: r.stdout, as: UTF8.self) + "\n" + r.stderr)
    }

    func summaryPrompt(multiple: Bool) -> String {
        let others = multiple
            ? "«\(config.speakerLabel) 1», «\(config.speakerLabel) 2» и так далее - разные остальные участники, нумерация условная, " +
              "различение голосов автоматическое и может ошибаться."
            : "«\(config.othersName)» - остальные участники."
        return """
            Ты готовишь саммари рабочих встреч. На входе транскрипт рабочей встречи. Он распознан автоматически и содержит ошибки: \
            искаженные слова, имена и термины, обрывки фраз. «\(config.myName)» - автор записи, \(others)
            Верни только Markdown со следующими разделами:
            ## Кратко
            3-6 пунктов списком.
            ## Решения
            ## Задачи
            Формат пункта: - [ ] кто: что, срок если назван.
            ## Открытые вопросы
            Ничего не выдумывай, опирайся только на транскрипт. Если в разделе нечего написать, напиши «нет». \
            Инструменты не используй, команды не выполняй, файлы не читай, отвечай сразу текстом.
            """
    }

    func summarize(_ transcript: String, multiple: Bool = false) async throws -> String {
        let prompt = summaryPrompt(multiple: multiple)
        if config.summaryProvider == "codex" { return try await summarizeWithCodex(prompt, transcript) }
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

    static let codexDisabledFeatures = [
        "shell_tool", "unified_exec", "unified_exec_tty", "view_image", "apps", "plugins", "remote_plugin", "browser_use",
        "browser_use_external", "browser_use_full_cdp_access", "computer_use", "in_app_browser", "image_generation",
        "multi_agent", "skill_search", "sleep_tool", "hooks", "goals", "in_app_local_automation", "tool_suggest",
        "skill_mcp_dependency_install",
    ]

    static func codexArguments(cwd: String, output: String, model: String) -> [String] {
        var args = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "-s", "read-only", "--color", "never", "--json", "-C", cwd, "-o", output, "-c", "web_search=\"disabled\"",
        ]
        for feature in codexDisabledFeatures { args += ["--disable", feature] }
        if !model.isEmpty { args += ["-m", model] }
        return args + ["-"]
    }

    static func codexAuthFailed(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return ["sign in again", "log out and sign in", "not logged in", "unauthorized", "codex login"].contains { lower.contains($0) }
    }

    private func summarizeWithCodex(_ prompt: String, _ transcript: String) async throws -> String {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meetrec-codex-\(UUID().uuidString)")
        let cwd = dir.appendingPathComponent("cwd")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let output = dir.appendingPathComponent("last.txt")
        let input = prompt + "\n\nТранскрипт встречи:\n\n" + transcript
        let watchdog = CodexWatchdog()
        let r = try await ProcessRunner.run(
            config.codex, Self.codexArguments(cwd: cwd.path, output: output.path, model: config.codexModel),
            stdin: Data(input.utf8), cwd: cwd, environment: codexEnv, timeout: 600, onStdout: { watchdog.feed($0) })
        if let offender = watchdog.offender {
            throw MeetRecError("Codex попытался выполнить действие (\(offender)), саммари отброшено")
        }
        guard r.status == 0 else {
            if Self.codexAuthFailed(r.stderr) { throw MeetRecError("codex не авторизован, выполните: codex login") }
            if r.stderr.contains("Unknown feature flag") {
                throw MeetRecError("эта версия codex не поддерживает отключение инструментов, саммари пропущено: \(Self.stderrTail(r.stderr))")
            }
            throw fail("codex", r)
        }
        let message = CodexEvents.finalMessage(String(decoding: r.stdout, as: UTF8.self))
            ?? (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetRecError("codex вернул пустой ответ") }
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
