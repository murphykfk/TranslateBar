import Foundation
import TranslateCore

private final class CaptureSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var peak: Float = 0
    func append(_ bytes: Data, level: Float) { lock.lock(); defer { lock.unlock() }; data.append(bytes); peak = max(peak, level) }
    func result() -> (Data, Float) { lock.lock(); defer { lock.unlock() }; return (data, peak) }
}

@MainActor enum CaptureSmokeTest {
    static func run() async {
        let deadline = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            Swift.print("CAPTURE_PROBE_TIMEOUT"); fflush(stdout); exit(2)
        }
        defer { deadline.cancel() }
        do {
            guard let source = AudioHardware.sources().first(where: { $0.id == "com.murphy.TranslateBarFixture" }) else { throw AppError.message("测试音频源未运行。") }
            Swift.print("CAPTURE_SOURCE_PROCESSES \(source.processes.count)"); fflush(stdout)
            let recorder = ScreenAudioCapture(); let samples = CaptureSamples()
            recorder.onChunk = { samples.append($0, level: $1) }
            recorder.onFailure = { Swift.print("CAPTURE_CALLBACK_ERROR \($0.localizedDescription)"); fflush(stdout) }
            try await recorder.start(source: source, mute: false)
            try await Task.sleep(for: .seconds(4))
            recorder.stop()
            let (data, peak) = samples.result()
            let report: [String: Any] = ["bytes": data.count, "seconds": PCMFrames.seconds(bytes: data.count), "rms_peak": peak, "success": !data.isEmpty && peak > 0.001]
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            try data.write(to: root.appendingPathComponent(".build/captured-source.pcm"), options: .atomic)
            let json = try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
            try json.write(to: root.appendingPathComponent(".build/capture-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: json, as: UTF8.self)); fflush(stdout)
            try await Task.sleep(for: .milliseconds(500))
            exit(report["success"] as? Bool == true ? 0 : 1)
        } catch { Swift.print("CAPTURE_PROBE_ERROR \(error.localizedDescription)"); fflush(stdout); exit(1) }
    }
}
