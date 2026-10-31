import AppKit
import AVFoundation
import ScreenCaptureKit
import TranslateCore

private final class StreamAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var streamID: ObjectIdentifier?
    private var chunkHandler: (@Sendable (Data, Float) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var converter: PCMConverter?
    private var pending = Data()
    var onChunk: (@Sendable (Data, Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return chunkHandler }
        set { lock.lock(); chunkHandler = newValue; lock.unlock() }
    }
    var onFailure: (@Sendable (Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return failureHandler }
        set { lock.lock(); failureHandler = newValue; lock.unlock() }
    }
    func setStream(_ stream: SCStream?) { lock.lock(); streamID = stream.map(ObjectIdentifier.init); lock.unlock() }
    func accepts(_ stream: SCStream) -> Bool { lock.lock(); defer { lock.unlock() }; return streamID == ObjectIdentifier(stream) }
    func reset() { converter = nil; pending.removeAll() }
    func consume(_ sample: CMSampleBuffer, stream: SCStream) {
        guard accepts(stream), CMSampleBufferDataIsReady(sample), let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count < 1_000_000, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard status == noErr else { if accepts(stream) { onFailure?(AppError.message("无法读取系统音频缓冲（\(status)）。")) }; return }
        do {
            if converter?.input != format { converter = try PCMConverter(input: format) }
            guard let converter else { return }
            pending.append(try converter.convert(buffer))
            while pending.count >= PCMFrames.chunkBytes {
                let chunk = Data(pending.prefix(PCMFrames.chunkBytes)); pending.removeFirst(PCMFrames.chunkBytes)
                let level: Float = chunk.withUnsafeBytes { raw in
                    let values = raw.bindMemory(to: Int16.self)
                    return Float(sqrt(values.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(values.count)))
                }
                if accepts(stream) { onChunk?(chunk, level) }
            }
        } catch { if accepts(stream) { onFailure?(error) } }
    }
}

@MainActor final class ScreenAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    nonisolated private let sink = StreamAudioSink()
    nonisolated private let queue = DispatchQueue(label: "com.murphy.TranslateBar.screen-audio", qos: .userInitiated)
    private let sourceMute = SourceAudioMute()
    private var stream: SCStream?
    private var generation = UUID()
    var onChunk: (@Sendable (Data, Float) -> Void)? { get { sink.onChunk } set { sink.onChunk = newValue } }
    var onFailure: (@Sendable (Error) -> Void)? { get { sink.onFailure } set { sink.onFailure = newValue } }
    var muteProcessID: pid_t? { sourceMute.activeProcessID }

    func start(source: AudioSource, mute: Bool) async throws {
        stop()
        let token = UUID(); generation = token
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw AppError.message("请在系统设置的“录屏与系统录音”中授权 TranslateBar，再重试。实际仅接收所选应用音频。") }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let applications = content.applications.filter { $0.bundleIdentifier == source.id || $0.bundleIdentifier.hasPrefix(source.id + ".") }
        guard !applications.isEmpty, let display = content.displays.first else { throw AppError.message("未找到所选应用的可捕获内容，请先打开浏览器并播放视频。") }
        let filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000; configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 3; configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream; sink.setStream(stream)
        queue.async { [sink] in sink.reset() }
        // Deliberately register audio output only. No screen frames are received, saved or uploaded.
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if mute {
                sourceMute.onFailure = { [weak self] error in self?.onFailure?(error) }
                try await sourceMute.start(source: source)
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        } catch {
            if generation == token { stop() }
            throw error
        }
    }
    func stop() {
        generation = UUID(); sink.setStream(nil); sourceMute.onFailure = nil; sourceMute.stop()
        let old = stream; stream = nil
        if let old { Task { try? await old.stopCapture() } }
        queue.async { [sink] in sink.reset() }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { sink.consume(sampleBuffer, stream: stream) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        if sink.accepts(stream) { sink.onFailure?(error) }
    }
}
