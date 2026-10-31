import AVFoundation
import Foundation
import TranslateCore

private final class ToneOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 0.0
    private var expectedSampleTime: AVAudioFramePosition?
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        lock.lock(); defer { lock.unlock() }
        sampleRate = buffer.format.sampleRate
        // Paused nodes may omit tap buffers rather than emitting zero samples.
        // Preserve their timeline gaps instead of concatenating them away.
        if time.isSampleTimeValid {
            if let expectedSampleTime, time.sampleTime > expectedSampleTime {
                samples.append(contentsOf: repeatElement(Float(0), count: min(Int(sampleRate), Int(time.sampleTime - expectedSampleTime))))
            }
            expectedSampleTime = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    func statistics() -> [String: Any] {
        lock.lock(); let values = samples; let rate = sampleRate; lock.unlock()
        guard rate > 0 else { return ["captured_frames": 0, "max_internal_silent_gap_ms": -1] }
        let window = max(1, Int(rate * 0.005))
        var active: [Bool] = []
        for index in stride(from: 0, through: max(0, values.count - window), by: window) {
            guard index + window <= values.count else { break }
            let energy = values[index..<(index + window)].reduce(0.0) { $0 + Double($1 * $1) }
            active.append(sqrt(energy / Double(window)) > 0.02)
        }
        guard let first = active.firstIndex(of: true), let last = active.lastIndex(of: true) else { return ["captured_frames": values.count, "max_internal_silent_gap_ms": -1] }
        var run = 0, maximum = 0
        for voiced in active[first...last] { run = voiced ? 0 : run + 1; maximum = max(maximum, run) }
        return ["captured_frames": values.count, "sample_rate": rate, "max_internal_silent_gap_ms": Double(maximum * window) / rate * 1000]
    }
}

@MainActor enum AudioQualitySmokeTest {
    static func run() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var report: [String: Any] = ["success": false, "scope": "Synthetic continuous tone, variable packet arrival times, own-app mixer output only; no API or user audio recorded."]
        do {
            let immediate = try await measure(startupBuffer: 0)
            let buffered = try await measure(startupBuffer: 0.16)
            report["without_jitter_buffer"] = immediate
            report["with_jitter_buffer"] = buffered
            let gap = buffered["max_internal_silent_gap_ms"] as? Double ?? -1
            guard gap >= 0, gap <= 5 else { throw AppError.message("缓冲播放出现了不应有的静音缺口。") }
            let playback = AudioPlayback()
            try playback.enqueue(Data(repeating: 1, count: PCMFrames.chunkBytes))
            playback.stop()
            try await Task.sleep(for: .milliseconds(250))
            guard !playback.isPlaying, playback.queuedSeconds == 0, playback.renderedFrames == 0 else { throw AppError.message("停止后仍启动了迟到的音频。") }
            report["stop_during_priming_passed"] = true
            report["success"] = true
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(".build/audio-quality-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self))
        }
        fflush(stdout); exit(report["success"] as? Bool == true ? 0 : 1)
    }
    private static func measure(startupBuffer: Double) async throws -> [String: Any] {
        let collector = ToneOutputCollector()
        let playback = AudioPlayback(startupBufferSeconds: startupBuffer, outputObserver: { collector.append($0, at: $1) })
        playback.volume = 0.3
        defer { playback.stop() }
        let clock = ContinuousClock(); let start = clock.now
        let arrivals: [Int64] = [0, 500, 800, 1300, 1600]
        for (index, arrival) in arrivals.enumerated() {
            try await clock.sleep(until: start.advanced(by: .milliseconds(arrival)))
            var samples = [Int16](repeating: 0, count: 9600)
            for frame in samples.indices { samples[frame] = Int16(sin(2 * .pi * 440 * Double(index * 9600 + frame) / 24_000) * 8000) }
            try playback.enqueue(samples.withUnsafeBytes { Data($0) })
        }
        for _ in 0..<30 {
            if playback.renderedFrames == 48_000 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard playback.renderedFrames == 48_000 else { throw AppError.message("测试音频未完整播放。") }
        try await Task.sleep(for: .milliseconds(120))
        var report = collector.statistics()
        report["scheduled_frames"] = playback.scheduledFrames; report["rendered_frames"] = playback.renderedFrames
        report["playback_rate"] = playback.playbackRate
        return report
    }
}
