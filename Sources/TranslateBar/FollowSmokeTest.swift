import Foundation
import TranslateCore

@MainActor enum FollowSmokeTest {
    static func run() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var report: [String: Any] = ["success": false]
        do {
            let raw = Data(try Data(contentsOf: root.appendingPathComponent(".build/live-translation.pcm")).prefix(8 * PCMFrames.bytesPerSecond))
            guard raw.count >= PCMFrames.bytesPerSecond else { throw AppError.message("缺少真实译声测试音频。") }
            var compactor = TranslationSilenceCompactor()
            let compacted = compactor.process(raw)
            let originalSpeech = nonzeroSamples(raw), retainedSpeech = nonzeroSamples(compacted)
            guard originalSpeech == retainedSpeech, !compacted.isEmpty else { throw AppError.message("静音压缩改变了有效音频。") }
            let baseline = try await play(raw, follow: false)
            let optimized = try await play(raw, follow: true)
            report["baseline"] = baseline; report["optimized"] = optimized
            report["input_audio_seconds"] = PCMFrames.seconds(bytes: raw.count)
            report["retained_audio_seconds"] = PCMFrames.seconds(bytes: compacted.count)
            report["nonzero_samples_preserved"] = originalSpeech.count
            report["speech_samples_identical"] = true
            report["removed_digital_silence_seconds"] = Double(compactor.removedFrames) / 24_000
            report["scope"] = "Same recorded response replayed through the real output device; not total model or video latency."
            report["success"] = true
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(".build/follow-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self))
        }
        fflush(stdout); exit(report["success"] as? Bool == true ? 0 : 1)
    }
    private static func nonzeroSamples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).filter { $0 != 0 } }
    }
    private static func play(_ pcm: Data, follow: Bool) async throws -> [String: Any] {
        let playback = AudioPlayback(); playback.followVideo = follow
        try playback.enqueue(pcm)
        let started = ProcessInfo.processInfo.systemUptime
        let expectedFrames = playback.scheduledFrames
        let initialRate = playback.playbackRate
        var maximumRate = initialRate
        defer { playback.stop() }
        while playback.renderedFrames < expectedFrames && ProcessInfo.processInfo.systemUptime - started < 12 {
            try await Task.sleep(for: .milliseconds(100))
            playback.updateFollowRate(); maximumRate = max(maximumRate, playback.playbackRate)
        }
        guard playback.renderedFrames == expectedFrames else { throw AppError.message("设备未完整播放保留的音频。") }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let removed = playback.removedSilenceSeconds
        playback.stop()
        guard playback.queuedSeconds == 0, playback.playbackRate == 1 else { throw AppError.message("播放停止后队列或语速未恢复。") }
        return ["wall_seconds": elapsed, "scheduled_frames": expectedFrames, "rendered_frames": playback.renderedFrames, "initial_rate": initialRate, "maximum_rate": maximumRate, "removed_silence_seconds": removed, "queue_after_stop": playback.queuedSeconds, "rate_after_stop": playback.playbackRate]
    }
}
