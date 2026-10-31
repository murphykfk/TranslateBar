import Foundation

@MainActor enum PlaybackSmokeTest {
    static func run() async {
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let source = root.appendingPathComponent(".build/live-translation.pcm")
            // Exercise the actual device playback path with a bounded, previously generated translation.
            let pcm = Data(try Data(contentsOf: source).prefix(24_000 * 2 * 8))
            guard pcm.count >= 48_000, pcm.count % 2 == 0 else { throw AppError.message("缺少可播放的译声测试文件。") }
            let playback = AudioPlayback()
            playback.followVideo = false
            try playback.enqueue(pcm)
            let initialQueue = playback.queuedSeconds
            try await Task.sleep(for: .milliseconds(500))
            let started = playback.isPlaying
            let laterQueue = playback.queuedSeconds
            try await Task.sleep(for: .seconds(Double(pcm.count) / 48_000 + 0.5))
            let rendered = playback.renderedFrames
            playback.stop()
            let stopped = !playback.isPlaying
            let drainedQueue = playback.queuedSeconds
            let success = started && stopped && rendered == pcm.count / 2 && initialQueue > laterQueue && initialQueue - laterQueue > 0.3 && drainedQueue == 0
            let report: [String: Any] = ["expected_frames": pcm.count / 2, "rendered_frames": rendered, "started": started, "success": success, "stopped": stopped, "initial_queue_seconds": initialQueue, "queue_after_half_second": laterQueue, "queue_after_stop": drainedQueue]
            let json = try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
            try json.write(to: root.appendingPathComponent(".build/playback-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: json, as: UTF8.self)); fflush(stdout)
            exit(success ? 0 : 1)
        } catch { Swift.print("PLAYBACK_PROBE_ERROR \(error.localizedDescription)"); fflush(stdout); exit(1) }
    }
}
