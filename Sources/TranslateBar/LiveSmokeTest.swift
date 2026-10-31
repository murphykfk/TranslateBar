import Foundation
import TranslateCore

@MainActor enum LiveSmokeTest {
    static func run() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reportURL = root.appendingPathComponent(".build/live-smoke-report.json")
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "success": false]
        var heldIDs: [UUID] = []
        let budget = BudgetController()
        var configuration = (try? LocalFiles.read(AppSettings.self, from: LocalFiles.directory.appendingPathComponent("settings.json")))?.budget ?? BudgetConfiguration()
        // This test also obeys the user's existing budget. It never raises a configured limit.
        if !configuration.enabled { configuration.enabled = true; configuration.limit = 0.10; configuration.buffer = 0 }
        do {
            guard let key = KeyStore.environmentKey(in: root) ?? KeyStore.read(), !key.isEmpty else { throw AppError.message("未找到测试密钥。") }
            if !CommandLine.arguments.contains("--audio-only") {
                let text = "The meeting starts at ten tomorrow morning."
                let model = TextModel.nano
                let textID = try budget.reserve(model.reservation(text: text, instructions: OpenAIClient.instructions(target: "简体中文"), maxOutput: 128), kind: .text, model: model.rawValue, configuration: configuration)
                heldIDs.append(textID)
                let translation = try await OpenAIClient.translate(text, target: "简体中文", model: model, key: key, maxOutput: 128)
                try budget.settle(textID, amount: model.cost(input: translation.inputTokens, cached: translation.cachedTokens, output: translation.outputTokens), input: translation.inputTokens, output: translation.outputTokens)
                guard translation.completed, !translation.text.isEmpty else { throw AppError.message("文字测试没有完整返回译文。") }
                report["text"] = ["model": model.rawValue, "output": translation.text, "input_tokens": translation.inputTokens, "output_tokens": translation.outputTokens]
                print("TEXT_TRANSLATION_OK", flush: true)
            }
            guard let index = CommandLine.arguments.firstIndex(of: "--audio-file"), CommandLine.arguments.indices.contains(index + 1) else { throw AppError.message("缺少 --audio-file 测试音频参数。") }
            var pcm = try PCMConverter.file(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            guard pcm.count <= PCMFrames.bytesPerSecond * 20 else { throw AppError.message("测试音频最长 20 秒。") }
            pcm.append(Data(repeating: 0, count: PCMFrames.bytesPerSecond * 4))
            if pcm.count % PCMFrames.chunkBytes != 0 { pcm.append(Data(repeating: 0, count: PCMFrames.chunkBytes - pcm.count % PCMFrames.chunkBytes)) }
            let audioID = try budget.reserve(PCMFrames.cost(bytes: pcm.count), kind: .audio, model: "gpt-realtime-translate", configuration: configuration)
            heldIDs.append(audioID)
            let connection = RealtimeSession()
            var outputAudio = Data(); var outputText = ""; var closed = false; var failure: Error?
            var latency = AudioLatencyTracker(); var measuredDelays: [Double] = []; var outputEvents = 0; var timedEvents = 0
            var frameTrace: [[String: Any]] = []
            var formatTrace: [[String: Any]] = []; var inputTrace: [[String: Any]] = []
            let testStarted = ProcessInfo.processInfo.systemUptime
            connection.onAudioFormat = { if formatTrace.count < 5 { formatTrace.append($0) } }
            connection.onAudio = { data, elapsed in
                outputAudio.append(data)
                guard !data.isEmpty else { return }
                outputEvents += 1
                let now = ProcessInfo.processInfo.systemUptime
                let hasSignal = AudioLatencyTracker.hasSignal(data)
                latency.recordOutput(elapsedMilliseconds: elapsed, receivedAt: now, hasSignal: hasSignal)
                if elapsed != nil { timedEvents += 1 }
                if let value = latency.snapshot(now: now, playbackQueueSeconds: 0).streamSeconds { measuredDelays.append(value) }
                if frameTrace.count < 200 { frameTrace.append(["elapsed_ms": elapsed as Any? ?? NSNull(), "audio_bytes": data.count, "has_signal": hasSignal, "received_seconds": now - testStarted]) }
            }
            connection.onTranscript = { outputText += $0 }
            connection.onFailure = { failure = $0 }
            connection.onClosed = { closed = true }
            try await connection.connect(key: key, language: "zh")
            print("REALTIME_CONNECTED", flush: true)
            var sent = 0
            let inputClock = ContinuousClock()
            let inputStart = inputClock.now
            do {
                for offset in stride(from: 0, to: pcm.count, by: PCMFrames.chunkBytes) {
                    if let failure { throw failure }
                    let chunk = pcm.subdata(in: offset..<min(pcm.count, offset + PCMFrames.chunkBytes))
                    let signal = AudioLatencyTracker.hasSignal(chunk)
                    latency.recordInput(bytes: chunk.count, capturedAt: ProcessInfo.processInfo.systemUptime, hasSignal: signal)
                    sent += chunk.count
                    let beforeSend = ProcessInfo.processInfo.systemUptime
                    try await connection.append(chunk)
                    inputTrace.append(["input_end_seconds": PCMFrames.seconds(bytes: sent), "sent_seconds": ProcessInfo.processInfo.systemUptime - testStarted, "send_duration_ms": (ProcessInfo.processInfo.systemUptime - beforeSend) * 1000])
                    try await inputClock.sleep(until: inputStart.advanced(by: .milliseconds(Int64(sent / PCMFrames.chunkBytes) * 200)), tolerance: .milliseconds(2))
                }
                await connection.finish()
                for _ in 0..<160 { if closed { break }; try await Task.sleep(for: .milliseconds(100)) }
                if let failure { throw failure }
                guard !outputAudio.isEmpty, !outputText.isEmpty else { throw AppError.message("实时接口未返回完整语音与字幕。") }
                try budget.settle(audioID, amount: PCMFrames.cost(bytes: sent), seconds: PCMFrames.seconds(bytes: sent))
                try outputAudio.write(to: root.appendingPathComponent(".build/live-translation.pcm"), options: .atomic)
                report["audio"] = ["model": "gpt-realtime-translate", "input_seconds": PCMFrames.seconds(bytes: sent), "output_audio_bytes": outputAudio.count, "output_seconds": PCMFrames.seconds(bytes: outputAudio.count), "transcript": outputText, "connection_closed": closed, "estimated_usd": PCMFrames.cost(bytes: sent)]
                var timing: [String: Any] = ["audio_events": outputEvents, "events_with_timing": timedEvents, "measured_events": measuredDelays.count, "scope": "First audible response is measured. Stream offset fields are experimental diagnostics, not actual translation latency; server frame progress is not source-media time."]
                if let first = latency.snapshot(now: ProcessInfo.processInfo.systemUptime, playbackQueueSeconds: 0).firstAudioSeconds { timing["first_audio_seconds"] = first }
                if !measuredDelays.isEmpty {
                    let sorted = measuredDelays.sorted()
                    timing["median_stream_seconds"] = sorted[sorted.count / 2]
                    timing["min_stream_seconds"] = sorted.first!
                    timing["max_stream_seconds"] = sorted.last!
                }
                report["latency"] = timing
                report["frame_trace"] = frameTrace
                report["format_trace"] = formatTrace; report["input_trace"] = inputTrace
                report["success"] = true
                connection.cancel()
                print("REALTIME_TRANSLATION_OK", flush: true)
            } catch {
                connection.cancel()
                try? budget.settle(audioID, amount: PCMFrames.cost(bytes: sent), seconds: PCMFrames.seconds(bytes: sent))
                throw error
            }
        } catch {
            for id in heldIDs where budget.book.record(id: id)?.status == .reserved { budget.uncertain(id) }
            report["error"] = error.localizedDescription
            print("SMOKE_TEST_FAILED: \(error.localizedDescription)", flush: true)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
        print("REPORT: \(reportURL.path)")
        exit(report["success"] as? Bool == true ? 0 : 1)
    }
}

private func print(_ text: String, flush: Bool) {
    Swift.print(text)
    if flush { fflush(stdout) }
}
