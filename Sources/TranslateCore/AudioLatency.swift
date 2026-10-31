import Foundation

public struct AudioLatencySnapshot: Equatable {
    /// Experimental frame-offset diagnostic, retained for test reports only.
    /// Server frame progress is not reliably tied to source-media time, so this
    /// must not be shown as translation latency in the product UI.
    public var streamSeconds: Double?
    public var playbackQueueSeconds = 0.0
    public var firstAudioSeconds: Double?
    public var waitingForAudioSeconds: Double?
    public var receivedAudio = false
    public var isStale = false
    public init() {}
}

/// All times use a monotonic clock. Input frame times are retained across send
/// queue delays and capture gaps; wall-clock changes cannot affect the result.
public struct AudioLatencyTracker {
    private struct InputSpan {
        var start: Double
        var end: Double
        var capturedAt: Double
    }
    private var spans: [InputSpan] = []
    private var inputSeconds = 0.0
    private var firstSignalAt: Double?
    private var firstAudioAt: Double?
    private var firstAudioSeconds: Double?
    private var latestOutputAt: Double?
    private var latestStreamSeconds: Double?
    public init() {}

    public mutating func recordInput(bytes: Int, capturedAt: Double, hasSignal: Bool) {
        guard bytes > 0, bytes % 2 == 0, capturedAt.isFinite else { return }
        let duration = PCMFrames.seconds(bytes: bytes)
        spans.append(InputSpan(start: inputSeconds, end: inputSeconds + duration, capturedAt: capturedAt))
        inputSeconds += duration
        // Two minutes of 200 ms frames; memory use stays bounded on long sessions.
        if spans.count > 600 { spans.removeFirst(spans.count - 600) }
        if hasSignal, firstSignalAt == nil, firstAudioAt == nil { firstSignalAt = capturedAt - duration }
    }

    public mutating func recordOutput(elapsedMilliseconds: Int?, receivedAt: Double, hasSignal: Bool = true) {
        guard receivedAt.isFinite else { return }
        if firstAudioAt == nil, hasSignal {
            firstAudioAt = receivedAt
            if let firstSignalAt, receivedAt >= firstSignalAt { firstAudioSeconds = receivedAt - firstSignalAt }
        }
        latestOutputAt = receivedAt
        // Never keep an earlier valid number when the current event omits timing.
        latestStreamSeconds = nil
        guard let milliseconds = elapsedMilliseconds, milliseconds >= 0 else { return }
        let position = Double(milliseconds) / 1000
        guard let span = spans.first(where: { position >= $0.start - 0.000_001 && position <= $0.end + 0.000_001 }) else { return }
        let capturedAt = span.capturedAt - max(0, span.end - position)
        guard receivedAt >= capturedAt else { return }
        latestStreamSeconds = receivedAt - capturedAt
    }

    public func snapshot(now: Double, playbackQueueSeconds: Double) -> AudioLatencySnapshot {
        var result = AudioLatencySnapshot()
        result.streamSeconds = latestStreamSeconds
        result.playbackQueueSeconds = playbackQueueSeconds.isFinite ? max(0, playbackQueueSeconds) : 0
        result.firstAudioSeconds = firstAudioSeconds
        result.receivedAudio = latestOutputAt != nil
        if firstAudioAt == nil, let firstSignalAt, now.isFinite { result.waitingForAudioSeconds = max(0, now - firstSignalAt) }
        if let latestOutputAt { result.isStale = now - latestOutputAt > 3 }
        return result
    }

    public static func hasSignal(_ pcm: Data) -> Bool {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { return false }
        let energy = pcm.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(0.0) { sum, sample in
                let value = Double(sample) / 32768
                return sum + value * value
            }
        }
        return sqrt(energy / Double(pcm.count / 2)) > 0.001
    }
}
