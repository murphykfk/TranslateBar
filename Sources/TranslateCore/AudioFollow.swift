import Foundation

/// Trim leading digital silence only. Once audio begins, preserve every sample
/// and every pause so consonant releases and syllable timing remain intact.
public struct TranslationSilenceCompactor {
    private var heardAudio = false
    public private(set) var removedFrames = 0
    public init() {}

    public mutating func process(_ pcm: Data) -> Data {
        guard !heardAudio, !pcm.isEmpty, pcm.count % 2 == 0 else { return pcm }
        var output = Data(); output.reserveCapacity(pcm.count)
        pcm.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for start in stride(from: 0, to: samples.count, by: 240) {
                let end = min(start + 240, samples.count)
                let silent = !heardAudio && samples[start..<end].allSatisfy { $0 == 0 }
                let count = end - start
                if silent {
                    removedFrames += count
                } else {
                    heardAudio = true
                    output.append(pcm.subdata(in: (start * 2)..<(end * 2)))
                }
            }
        }
        return output
    }
}

public enum AudioFollowPolicy {
    public static func rate(queuedMediaSeconds: Double, enabled: Bool, currentRate: Double = 1) -> Double {
        guard enabled, queuedMediaSeconds.isFinite else { return 1 }
        // Experimental catch-up stays inactive for normal 400 ms packets.
        if queuedMediaSeconds >= 1.2 { return 1.08 }
        if queuedMediaSeconds <= 0.5 { return 1 }
        return min(1.08, max(1, currentRate))
    }
}

/// Track media duration separately from wall time so rate changes do not make
/// the queue estimate stale or count already consumed audio again.
public struct PlaybackQueueClock {
    private var mediaSeconds = 0.0
    private var updatedAt: Double?
    private var paused: Bool
    public private(set) var rate = 1.0
    public init(paused: Bool = false) { self.paused = paused }
    public func remainingMediaSeconds(at now: Double) -> Double {
        guard let updatedAt else { return 0 }
        if paused { return mediaSeconds }
        return max(0, mediaSeconds - max(0, now - updatedAt) * rate)
    }
    public mutating func enqueue(seconds: Double, at now: Double) {
        mediaSeconds = remainingMediaSeconds(at: now) + max(0, seconds)
        updatedAt = now
    }
    public mutating func setRate(_ value: Double, at now: Double) {
        mediaSeconds = remainingMediaSeconds(at: now); updatedAt = now
        rate = value.isFinite ? min(1.2, max(1, value)) : 1
    }
    public mutating func pause(at now: Double) {
        mediaSeconds = remainingMediaSeconds(at: now); updatedAt = now; paused = true
    }
    public mutating func resume(at now: Double) { updatedAt = now; paused = false }
}
