import XCTest
@testable import TranslateCore

final class AudioLatencyTests: XCTestCase {
    func testSilentOutputDoesNotEndFirstSpeechWait() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: true)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 11, hasSignal: false)
        let waiting = tracker.snapshot(now: 12, playbackQueueSeconds: 0)
        XCTAssertTrue(waiting.receivedAudio)
        XCTAssertNil(waiting.firstAudioSeconds)
        XCTAssertEqual(waiting.waitingForAudioSeconds!, 2, accuracy: 0.0001)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 13, hasSignal: true)
        XCTAssertEqual(tracker.snapshot(now: 13, playbackQueueSeconds: 0).firstAudioSeconds!, 3, accuracy: 0.0001)
        XCTAssertFalse(AudioLatencyTracker.hasSignal(Data(repeating: 0, count: PCMFrames.chunkBytes)))
        let audible = [Int16](repeating: 4000, count: 4800).withUnsafeBytes { Data($0) }
        XCTAssertTrue(AudioLatencyTracker.hasSignal(audible))
    }

    func testWaitStartsAtSoundRatherThanSessionOrInitialSilence() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: false)
        XCTAssertNil(tracker.snapshot(now: 12, playbackQueueSeconds: 0).waitingForAudioSeconds)
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 12.2, hasSignal: true)
        XCTAssertEqual(tracker.snapshot(now: 13, playbackQueueSeconds: 0).waitingForAudioSeconds!, 1, accuracy: 0.0001)
        tracker.recordOutput(elapsedMilliseconds: 400, receivedAt: 14)
        let snapshot = tracker.snapshot(now: 14, playbackQueueSeconds: 0.5)
        XCTAssertEqual(snapshot.firstAudioSeconds!, 2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.streamSeconds!, 1.8, accuracy: 0.0001)
        XCTAssertEqual(snapshot.playbackQueueSeconds, 0.5)
        XCTAssertNil(snapshot.waitingForAudioSeconds)
    }

    func testFrameMappingIncludesLocalSendDelayAndPreservesCaptureGaps() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 100.2, hasSignal: true)
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 105.2, hasSignal: true)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 106)
        XCTAssertEqual(tracker.snapshot(now: 106, playbackQueueSeconds: 0).streamSeconds!, 5.8, accuracy: 0.0001)
        tracker.recordOutput(elapsedMilliseconds: 400, receivedAt: 106.2)
        XCTAssertEqual(tracker.snapshot(now: 106.2, playbackQueueSeconds: 0).streamSeconds!, 1, accuracy: 0.0001)
    }

    func testMissingInvalidOrFutureMetadataNeverReusesPreviousMeasurement() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: true)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 11)
        XCTAssertNotNil(tracker.snapshot(now: 11, playbackQueueSeconds: 0).streamSeconds)
        for value in [nil, -1, 400, Int.max] as [Int?] {
            tracker.recordOutput(elapsedMilliseconds: value, receivedAt: 12)
            XCTAssertNil(tracker.snapshot(now: 12, playbackQueueSeconds: 0).streamSeconds)
        }
        XCTAssertEqual(tracker.snapshot(now: 12, playbackQueueSeconds: 0).firstAudioSeconds!, 1, accuracy: 0.0001)
    }

    func testPauseMarksLastMeasurementStaleWithoutInflatingIt() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: true)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 11)
        let fresh = tracker.snapshot(now: 11.2, playbackQueueSeconds: 1)
        let stale = tracker.snapshot(now: 15, playbackQueueSeconds: 0)
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.streamSeconds, fresh.streamSeconds)
        XCTAssertEqual(stale.playbackQueueSeconds, 0)
    }

    func testRepeatedTimestampIsAlignmentMetadataRatherThanDuplicateIdentifier() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: true)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 11)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 11.4)
        XCTAssertEqual(tracker.snapshot(now: 11.4, playbackQueueSeconds: 0).streamSeconds!, 1.2, accuracy: 0.0001)
    }

    func testLongSessionDiscardsOldFramesButKeepsRecentTiming() {
        var tracker = AudioLatencyTracker()
        for index in 1...1000 { tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10 + Double(index) * 0.2, hasSignal: true) }
        tracker.recordOutput(elapsedMilliseconds: 200_000, receivedAt: 211)
        XCTAssertEqual(tracker.snapshot(now: 211, playbackQueueSeconds: 0).streamSeconds!, 1, accuracy: 0.0001)
        tracker.recordOutput(elapsedMilliseconds: 200, receivedAt: 211.2)
        XCTAssertNil(tracker.snapshot(now: 211.2, playbackQueueSeconds: 0).streamSeconds)
    }

    func testNewSessionAndOutputWithoutSignalDoNotInventFirstSpeechLatency() {
        var tracker = AudioLatencyTracker()
        tracker.recordInput(bytes: PCMFrames.chunkBytes, capturedAt: 10.2, hasSignal: false)
        tracker.recordOutput(elapsedMilliseconds: nil, receivedAt: 11)
        XCTAssertTrue(tracker.snapshot(now: 11, playbackQueueSeconds: 0).receivedAudio)
        XCTAssertNil(tracker.snapshot(now: 11, playbackQueueSeconds: 0).firstAudioSeconds)
        tracker = AudioLatencyTracker()
        XCTAssertEqual(tracker.snapshot(now: 20, playbackQueueSeconds: 0), AudioLatencySnapshot())
    }

    func testLatencySettingMigratesOldPreferencesAndPersistsSwitch() throws {
        let old = Data("{\"muteOriginal\":true,\"audioSourceBundleID\":\"com.google.Chrome\"}".utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertTrue(settings.showAudioLatency)
        XCTAssertTrue(settings.muteOriginal)
        XCTAssertEqual(settings.audioSourceBundleID, "com.google.Chrome")
        settings.showAudioLatency = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.showAudioLatency)
    }
}
