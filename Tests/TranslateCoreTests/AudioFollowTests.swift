import XCTest
@testable import TranslateCore

final class AudioFollowTests: XCTestCase {
    private func pcm(_ values: [Int16]) -> Data { values.withUnsafeBytes { Data($0) } }
    private func samples(_ data: Data) -> [Int16] { data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }

    func testLeadingSilenceDoesNotDelayFirstSpeech() {
        var compactor = TranslationSilenceCompactor()
        XCTAssertTrue(compactor.process(Data(repeating: 0, count: 48_000)).isEmpty)
        let speech = pcm([Int16](repeating: 2000, count: 4800))
        XCTAssertEqual(compactor.process(speech), speech)
        XCTAssertEqual(compactor.removedFrames, 24_000)
    }

    func testAllPausesAfterFirstAudioArePreservedAcrossNetworkChunks() {
        var compactor = TranslationSilenceCompactor()
        let speech = pcm([Int16](repeating: 500, count: 240))
        XCTAssertEqual(compactor.process(speech), speech)
        let silence = Data(repeating: 0, count: 4800 * 2)
        XCTAssertEqual(compactor.process(silence), silence)
        XCTAssertEqual(compactor.process(silence), silence)
        XCTAssertEqual(compactor.process(speech), speech)
        XCTAssertEqual(compactor.process(silence), silence)
        XCTAssertEqual(compactor.removedFrames, 0)
    }

    func testAllNonzeroSamplesIncludingVeryQuietSpeechArePreserved() {
        var compactor = TranslationSilenceCompactor()
        let original = [Int16](repeating: 0, count: 1000) + [1, -1, 2, -3, 2000, -3000] + [Int16](repeating: 0, count: 12_000) + [1, 7, 30, -1]
        var result = Data()
        let data = pcm(original)
        for start in stride(from: 0, to: data.count, by: 742) {
            result.append(compactor.process(data.subdata(in: start..<min(start + 742, data.count))))
        }
        XCTAssertEqual(samples(result).filter { $0 != 0 }, original.filter { $0 != 0 })
        XCTAssertLessThan(result.count, data.count)
    }

    func testShortNaturalPauseAndInvalidInputRemainUnchanged() {
        var compactor = TranslationSilenceCompactor()
        let original = pcm([100, -100] + [Int16](repeating: 0, count: 1000) + [20, -20])
        XCTAssertEqual(compactor.process(original), original)
        XCTAssertEqual(compactor.process(Data([1])), Data([1]))
    }

    func testCatchUpRateIsBoundedAndReturnsToNormalAfterDraining() {
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 0.3, enabled: true), 1)
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 1.0, enabled: true), 1)
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 20, enabled: true), 1.08, accuracy: 1e-8)
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 0.8, enabled: true, currentRate: 1.08), 1.08, accuracy: 1e-8)
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 20, enabled: false), 1)
        XCTAssertEqual(AudioFollowPolicy.rate(queuedMediaSeconds: 0, enabled: true), 1)
    }

    func testRateChangesAccountForAudioAlreadyConsumed() {
        var clock = PlaybackQueueClock()
        clock.enqueue(seconds: 4, at: 100)
        clock.setRate(1.2, at: 101)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 102), 1.8, accuracy: 1e-8)
        clock.setRate(1, at: 102)
        clock.enqueue(seconds: 1, at: 103)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 103), 1.8, accuracy: 1e-8)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 105), 0)
        clock.enqueue(seconds: 0.2, at: 110)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 110), 0.2, accuracy: 1e-8)
    }

    func testFollowSettingMigrationAndPersistencePreserveAudioPreferences() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"audioVolume\":0.6,\"muteOriginal\":true}".utf8))
        XCTAssertFalse(settings.followVideo)
        XCTAssertEqual(settings.audioVolume, 0.6)
        settings.followVideo = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.followVideo)
        XCTAssertTrue(restored.muteOriginal)
    }

    func testPriorAggressiveModeIsDisabledOnceButLaterExplicitChoicePersists() throws {
        let old = Data("{\"followVideo\":true,\"audioVolume\":0.7}".utf8)
        var migrated = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertFalse(migrated.followVideo)
        XCTAssertEqual(migrated.audioVolume, 0.7)
        migrated.followVideo = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated))
        XCTAssertTrue(restored.followVideo)
    }

    func testPrimingAndPausingDoNotConsumeQueuedSpeech() {
        var clock = PlaybackQueueClock(paused: true)
        clock.enqueue(seconds: 0.4, at: 10)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 10.16), 0.4, accuracy: 1e-8)
        clock.resume(at: 10.16)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 10.26), 0.3, accuracy: 1e-8)
        clock.pause(at: 10.26)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 12), 0.3, accuracy: 1e-8)
        clock.setRate(1.08, at: 12)
        clock.resume(at: 12)
        XCTAssertEqual(clock.remainingMediaSeconds(at: 12.1), 0.192, accuracy: 1e-8)
    }
}
