import Foundation

private final class MuteCaptureMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0
    private var baseline: Float = 0
    private var muted: Float = 0
    private var failure: String?
    func setPhase(_ value: Int) { lock.lock(); phase = value; lock.unlock() }
    func add(_ level: Float) {
        lock.lock(); defer { lock.unlock() }
        if phase == 0 { baseline = max(baseline, level) }
        if phase == 1 { muted = max(muted, level) }
    }
    func fail(_ error: Error) { lock.lock(); failure = error.localizedDescription; lock.unlock() }
    func result() -> (Float, Float, String?) { lock.lock(); defer { lock.unlock() }; return (baseline, muted, failure) }
}

// Exercises the production mute worker and capture path without an API call.
@MainActor enum MuteSmokeTest {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 22) { Swift.print("MUTE_PROBE_TIMEOUT"); fflush(stdout); exit(2) }
        do {
            let bundleID = CommandLine.arguments.contains("--chrome") ? "com.google.Chrome" : "com.murphy.TranslateBarFixture"
            guard let source = AudioHardware.sources().first(where: { $0.id == bundleID }) else { throw AppError.message("未找到测试应用。") }
            let capture = ScreenAudioCapture(); let measurement = MuteCaptureMeasurement()
            capture.onChunk = { _, level in measurement.add(level) }
            capture.onFailure = { measurement.fail($0) }
            try await capture.start(source: source, mute: false)
            defer { capture.stop() }
            Swift.print("BASELINE_READY"); fflush(stdout)
            try await Task.sleep(for: .seconds(1))
            measurement.setPhase(2); capture.stop()
            try await Task.sleep(for: .milliseconds(200))
            try await capture.start(source: source, mute: true)
            guard let workerPID = capture.muteProcessID else { throw AppError.message("静音控制未就绪。") }
            Swift.print("MUTE_WORKER_READY"); fflush(stdout)
            try await Task.sleep(for: .milliseconds(600))
            measurement.setPhase(1)
            try await Task.sleep(for: .seconds(2))
            measurement.setPhase(2); capture.stop()
            try await Task.sleep(for: .milliseconds(1500))
            let workerExited = kill(workerPID, 0) != 0
            let (baseline, muted, failure) = measurement.result()
            let report: [String: Any] = ["screen_capture_baseline_peak": baseline, "screen_capture_peak_while_muted": muted,
                                         "worker_ready_after_audio_callback": true, "worker_exited_on_stop": workerExited,
                                         "success": baseline > 0.001 && muted > 0.001 && workerExited && failure == nil,
                                         "error": failure ?? ""]
            let data = try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/mute-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self)); fflush(stdout)
            exit(report["success"] as? Bool == true ? 0 : 1)
        } catch { Swift.print("MUTE_PROBE_ERROR \(error.localizedDescription)"); fflush(stdout); exit(1) }
    }
}
