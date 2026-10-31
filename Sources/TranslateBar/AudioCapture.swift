import AppKit
import AVFoundation
import CoreAudio
import TranslateCore

struct AudioSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var processes: [AudioObjectID]
    var bundleIDs: [String] = []
}

enum AudioHardware {
    static func processIDs(matching bundleID: String, allowedBundleIDs: Set<String>? = nil) -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            guard let name = string(id, selector: kAudioProcessPropertyBundleID) else { return false }
            if let allowedBundleIDs { return allowedBundleIDs.contains(name) }
            return name == bundleID || name.hasPrefix(bundleID + ".")
        }
    }
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector); var size = UInt32(MemoryLayout<T>.size); var value = initial
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw AppError.message("无法读取音频设备属性（\(status)）。") }
        return value
    }
    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector); var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func sources() -> [AudioSource] {
        var address = address(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        let owners = applications.compactMap { application -> (String, String)? in
            guard let id = application.bundleIdentifier else { return nil }
            return (id, application.localizedName ?? id)
        }.sorted { $0.0.count > $1.0.count }
        var groups: [String: AudioSource] = [:]
        for (id, name) in owners { groups[id] = AudioSource(id: id, name: name, processes: [], bundleIDs: [id]) }
        for id in ids {
            guard let bundleID = string(id, selector: kAudioProcessPropertyBundleID), !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { continue }
            let pid: pid_t = (try? scalar(id, selector: kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            guard let owner = owners.first(where: { bundleID == $0.0 || bundleID.hasPrefix($0.0 + ".") }) else { continue }
            groups[owner.0]?.processes.append(id)
            if groups[owner.0]?.bundleIDs.contains(bundleID) == false { groups[owner.0]?.bundleIDs.append(bundleID) }
        }
        return groups.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

final class PCMConverter {
    private let converter: AVAudioConverter
    let input: AVAudioFormat
    let output: AVAudioFormat
    init(input: AVAudioFormat) throws {
        self.input = input
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true), let converter = AVAudioConverter(from: input, to: output) else { throw AppError.message("无法转换音频格式。") }
        self.output = output; self.converter = converter
        converter.primeMethod = .none
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / input.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw AppError.message("无法分配音频缓冲。") }
        var offset: AVAudioFrameCount = 0; var error: NSError?
        let status = converter.convert(to: converted, error: &error) { requested, state in
            guard offset < buffer.frameLength else { state.pointee = .noDataNow; return nil }
            let count = min(requested, buffer.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: self.input, frameCapacity: count) else { state.pointee = .noDataNow; return nil }
            slice.frameLength = count
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            let bytesPerFrame = Int(self.input.streamDescription.pointee.mBytesPerFrame)
            for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
                if let source = sourceBuffers[index].mData, let destination = destinationBuffers[index].mData { memcpy(destination, source.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame) }
            }
            offset += count; state.pointee = .haveData; return slice
        }
        if let error { throw error }
        guard status != .error, let pointer = converted.int16ChannelData?[0] else { throw AppError.message("音频转换失败。") }
        return Data(bytes: pointer, count: Int(converted.frameLength) * 2)
    }
    func finish() throws -> Data {
        var result = Data()
        for _ in 0..<16 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096) else { throw AppError.message("无法分配音频尾帧缓冲。") }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if let error { throw error }
            if buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] { result.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2)) }
            if status == .endOfStream || buffer.frameLength == 0 { break }
        }
        return result
    }
    static func file(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let converter = try PCMConverter(input: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw AppError.message("无法读取测试音频。") }
        var result = Data()
        while file.framePosition < file.length { try file.read(into: buffer); result.append(try converter.convert(buffer)) }
        result.append(try converter.finish())
        return result
    }
}

@MainActor final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var queuedFrames = 0
    private var queueClock = PlaybackQueueClock(paused: true)
    private var compactor = TranslationSilenceCompactor()
    private var generation = UUID()
    private var startupTask: Task<Void, Never>?
    private var startsAt: Double?
    private let startupBufferSeconds: Double
    private var lastRateChangeAt = 0.0
    private(set) var renderedFrames = 0
    private(set) var scheduledFrames = 0
    var isPlaying: Bool { engine.isRunning && player.isPlaying }
    var followVideo = false {
        didSet { if oldValue != followVideo { stop(); configureGraph() } }
    }
    var playbackRate: Double { queueClock.rate }
    var removedSilenceSeconds: Double { Double(compactor.removedFrames) / 24_000 }
    /// Estimate the remaining audio between device completion callbacks, which
    /// otherwise only update once a whole (variable-sized) buffer has played.
    var queuedSeconds: Double {
        guard engine.isRunning, queuedFrames > 0 else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        let priming = startsAt.map { max(0, $0 - now) } ?? 0
        return priming + min(Double(queuedFrames) / 24_000, queueClock.remainingMediaSeconds(at: now)) / queueClock.rate
    }
    var volume: Float = 0.85 { didSet { player.volume = volume } }
    init(startupBufferSeconds: Double = 0.16, outputObserver: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? = nil) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
        engine.attach(player); engine.attach(timePitch)
        timePitch.pitch = 0
        configureGraph()
        // Used only by the synthetic audio-quality diagnostic. Normal app
        // instances have no tap and never record their output.
        if let outputObserver { engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in outputObserver(buffer, time) } }
    }
    private func configureGraph() {
        engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(timePitch)
        if followVideo {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        } else {
            // The quality path completely bypasses time stretching at 1x.
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }
    func enqueue(_ data: Data) throws {
        let data = followVideo ? compactor.process(data) : data
        let frames = data.count / 2
        guard frames > 0 else { return }
        guard queuedFrames + frames < 24_000 * 20 else { throw AppError.message("译声播放延迟过大，已停止，请重新开始。") }
        if !engine.isRunning { renderedFrames = 0; scheduledFrames = 0; try engine.start(); player.volume = volume }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channel = buffer.floatChannelData?[0] else { throw AppError.message("无法播放译声音频。") }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { channel[index] = Float(samples[index]) / 32768 }
        }
        queuedFrames += frames
        scheduledFrames += frames
        queueClock.enqueue(seconds: Double(frames) / 24_000, at: ProcessInfo.processInfo.systemUptime)
        updateFollowRate()
        let token = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                self.renderedFrames += frames
                if self.queuedFrames == 0 {
                    self.player.pause()
                    self.queueClock = PlaybackQueueClock(paused: true)
                }
            }
        }
        if !player.isPlaying && startupTask == nil {
            startsAt = ProcessInfo.processInfo.systemUptime + startupBufferSeconds
            if startupBufferSeconds == 0 { beginPlayback() }
            else {
                startupTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.startupBufferSeconds))
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.beginPlayback()
                }
            }
        }
    }
    private func beginPlayback() {
        startupTask = nil; startsAt = nil
        guard queuedFrames > 0, engine.isRunning else { return }
        queueClock.resume(at: ProcessInfo.processInfo.systemUptime)
        player.play()
    }
    func updateFollowRate() {
        let now = ProcessInfo.processInfo.systemUptime
        let rate = AudioFollowPolicy.rate(queuedMediaSeconds: queueClock.remainingMediaSeconds(at: now), enabled: followVideo, currentRate: queueClock.rate)
        guard abs(rate - queueClock.rate) > 0.0001 else { return }
        guard !followVideo || now - lastRateChangeAt >= 1 else { return }
        queueClock.setRate(rate, at: now); timePitch.rate = Float(rate); lastRateChangeAt = now
    }
    func stop() {
        generation = UUID(); startupTask?.cancel(); startupTask = nil; startsAt = nil
        player.stop(); engine.stop(); queuedFrames = 0
        queueClock = PlaybackQueueClock(paused: true); compactor = TranslationSilenceCompactor(); timePitch.rate = 1; lastRateChangeAt = 0
    }
}
