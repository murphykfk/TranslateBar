import CoreAudio
import Foundation

private final class MuteRenderState {
    let firstBuffer = DispatchSemaphore(value: 0)
    var receivedBuffer = false
}

private let muteRender: AudioDeviceIOProc = { _, _, _, _, output, _, context in
    guard let context else { return noErr }
    let state = Unmanaged<MuteRenderState>.fromOpaque(context).takeUnretainedValue()
    for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
    if !state.receivedBuffer { state.receivedBuffer = true; state.firstBuffer.signal() }
    return noErr
}

// Used only on a serial control queue, with a separate realtime IO callback.
final class ProcessMuteDriver {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var state = MuteRenderState()
    private var bundleID = ""
    private var processes: [AudioObjectID] = []
    private var allowedBundleIDs: Set<String>?
    func start(bundleID: String, bundleIDs: [String]? = nil) throws {
        stop()
        self.bundleID = bundleID
        allowedBundleIDs = bundleIDs.map { Set($0 + [bundleID]) }
        processes = AudioHardware.processIDs(matching: bundleID, allowedBundleIDs: allowedBundleIDs).sorted()
        guard !processes.isEmpty else { throw AppError.message("请先播放视频，再开始译声，以便找到浏览器的音频进程。") }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID(); description.name = "TranslateBar Source Mute"; description.isPrivate = true
        // A real, running reader is required. Stopping or losing this process restores audio.
        description.muteBehavior = .mutedWhenTapped
        configureBundles(description)
        self.description = description
        do {
            try check(AudioHardwareCreateProcessTap(description, &tap), "创建原声控制")
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TranslateBar Audio Control", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "创建原声控制设备")
            state = MuteRenderState()
            try check(AudioDeviceCreateIOProcID(device, muteRender, Unmanaged.passUnretained(state).toOpaque(), &io), "注册原声控制回调")
            try check(AudioDeviceStart(device, io), "启动原声控制")
            guard state.firstBuffer.wait(timeout: .now() + 2) == .success else { throw AppError.message("原声控制没有收到音频回调，请重试。") }
        } catch { stop(); throw error }
    }
    func refresh() throws {
        guard tap != 0, let description else { return }
        let latest = AudioHardware.processIDs(matching: bundleID, allowedBundleIDs: allowedBundleIDs).sorted()
        if !latest.isEmpty, latest != processes {
            processes = latest; description.processes = latest; configureBundles(description)
            var address = AudioHardware.address(kAudioTapPropertyDescription)
            var pointer = Unmanaged.passUnretained(description).toOpaque()
            try check(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &pointer), "更新浏览器音频进程")
        }
        let running = try AudioHardware.scalar(device, selector: kAudioDevicePropertyDeviceIsRunning, initial: UInt32(0))
        guard running != 0 else { throw AppError.message("原声静音控制已中断，译声已停止，请重新开始。") }
    }
    private func configureBundles(_ description: CATapDescription) {
        if #available(macOS 26.0, *) {
            let identifiers = processes.compactMap { AudioHardware.string($0, selector: kAudioProcessPropertyBundleID) }
            description.bundleIDs = Array(allowedBundleIDs ?? Set(identifiers + [bundleID] + description.bundleIDs))
            description.isProcessRestoreEnabled = true
        }
    }
    func stop() {
        if let io {
            AudioDeviceStop(device, io)
            AudioDeviceDestroyIOProcID(device, io)
            self.io = nil
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        description = nil
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AppError.message("\(operation)失败（\(status)）。") }
    }
}

enum MuteWorker {
    static func run(bundleID: String, bundleIDs: [String]? = nil) {
        // This helper never reads a key or sends audio to the network.
        let deadline = DispatchWorkItem { Swift.print("ERROR 原声控制启动超时。"); fflush(stdout); exit(2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        let queue = DispatchQueue(label: "com.murphy.TranslateBar.mute-control")
        let driver = ProcessMuteDriver()
        do { try queue.sync { try driver.start(bundleID: bundleID, bundleIDs: bundleIDs) } }
        catch { Swift.print("ERROR \(error.localizedDescription)"); fflush(stdout); exit(1) }
        deadline.cancel()
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler {
            do { try driver.refresh() }
            catch { Swift.print("ERROR \(error.localizedDescription)"); fflush(stdout); driver.stop(); exit(1) }
        }
        monitor.resume()
        Swift.print("READY"); fflush(stdout)
        // EOF also arrives if the parent crashes, so the muted source cannot remain stranded.
        _ = FileHandle.standardInput.readDataToEndOfFile()
        monitor.cancel()
        queue.sync { driver.stop() }
        exit(0)
    }
}

@MainActor final class SourceAudioMute {
    var onFailure: ((Error) -> Void)?
    private let executable: URL?
    private let startupTimeout: Duration
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var ready: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var pending = Data()
    private var becameReady = false
    var activeProcessID: pid_t? { becameReady && process?.isRunning == true ? process?.processIdentifier : nil }
    init(executable: URL? = Bundle.main.executableURL, startupTimeout: Duration = .seconds(12)) {
        self.executable = executable; self.startupTimeout = startupTimeout
    }
    func start(source: AudioSource) async throws {
        stop()
        guard let executable else { throw AppError.message("无法找到原声控制程序。") }
        let token = UUID(); generation = token
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = executable; process.arguments = ["--mute-worker", source.id, "--bundle-ids"] + Array(Set(source.bundleIDs + [source.id])).sorted()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        self.process = process; self.input = input; self.output = output; pending.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in self?.consume(data, token: token) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.fail(AppError.message("原声静音控制意外退出，译声已停止。"), token: token) }
        }
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            do { try process.run() }
            catch { fail(AppError.message("无法启动原声控制：\(error.localizedDescription)"), token: token); return }
            deadline = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.startupTimeout)
                guard !Task.isCancelled else { return }
                self.fail(AppError.message("原声静音启动超时，未开始 API 译声。请重试。"), token: token)
            }
        }
        try Task.checkCancellation()
    }
    private func consume(_ data: Data, token: UUID) {
        guard generation == token else { return }
        guard !data.isEmpty else { fail(AppError.message("原声控制连接已断开，译声已停止。"), token: token); return }
        pending.append(data)
        guard pending.count < 65_536 else { fail(AppError.message("原声控制返回了无效数据。"), token: token); return }
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self)
            pending.removeSubrange(...end)
            if line == "READY" { becameReady = true; deadline?.cancel(); ready?.resume(); ready = nil }
            else if line.hasPrefix("ERROR ") { fail(AppError.message(String(line.dropFirst(6))), token: token); return }
        }
    }
    private func fail(_ error: Error, token: UUID) {
        guard generation == token else { return }
        let continuation = ready; ready = nil; let callback = onFailure
        stop()
        if let continuation { continuation.resume(throwing: error) } else { callback?(error) }
    }
    func stop() {
        generation = UUID(); becameReady = false; deadline?.cancel(); deadline = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        let old = process; process = nil
        let oldInput = input; input = nil
        let oldOutput = output; output = nil
        old?.terminationHandler = nil
        oldOutput?.fileHandleForReading.readabilityHandler = nil
        try? oldInput?.fileHandleForWriting.close()
        guard let old else { return }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(800))
            if old.isRunning { old.terminate() }
            try? await Task.sleep(for: .milliseconds(400))
            if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            try? oldOutput?.fileHandleForReading.close()
        }
    }
}
