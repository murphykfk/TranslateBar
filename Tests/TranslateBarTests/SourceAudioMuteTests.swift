import Darwin
import XCTest
@testable import TranslateBar

final class SourceAudioMuteTests: XCTestCase {
    private func script(_ body: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuteWorkerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("worker.sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (root, url)
    }
    private let source = AudioSource(id: "test.source", name: "test", processes: [])
    @MainActor private func waitForExit(_ pid: pid_t) async -> Bool {
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    @MainActor func testReadyWorkerStopsOnEOFWithoutReportingFailure() async throws {
        let (root, url) = try script("printf 'READY\\n'\n/bin/cat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let mute = SourceAudioMute(executable: url)
        var failures = 0; mute.onFailure = { _ in failures += 1 }
        try await mute.start(source: source)
        let pid = try XCTUnwrap(mute.activeProcessID)
        mute.stop()
        XCTAssertNil(mute.activeProcessID)
        let exited = await waitForExit(pid)
        XCTAssertTrue(exited)
        XCTAssertEqual(failures, 0)
    }
    @MainActor func testWorkerStartupErrorDoesNotReportReady() async throws {
        let (root, url) = try script("printf 'ERROR Unable to mute\\n'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let mute = SourceAudioMute(executable: url)
        do { try await mute.start(source: source); XCTFail("Startup should fail") } catch { XCTAssertNil(mute.activeProcessID) }
        mute.stop()
    }
    @MainActor func testUnexpectedExitReportsFailureAfterReady() async throws {
        let (root, url) = try script("printf 'READY\\n'\n/bin/sleep 0.2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let mute = SourceAudioMute(executable: url)
        let failure = expectation(description: "worker failure delivered")
        mute.onFailure = { _ in failure.fulfill() }
        try await mute.start(source: source)
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertNil(mute.activeProcessID)
        mute.stop()
    }
    @MainActor func testUnresponsiveWorkerIsKilledAfterStop() async throws {
        let (root, url) = try script("trap '' TERM\nprintf 'READY\\n'\nread waiting < \"$0.fifo\"\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkfifo(url.path + ".fifo", mode_t(0o600)), 0)
        let mute = SourceAudioMute(executable: url)
        try await mute.start(source: source)
        let pid = try XCTUnwrap(mute.activeProcessID)
        mute.stop()
        let exited = await waitForExit(pid)
        XCTAssertTrue(exited)
    }
    @MainActor func testStartupTimeoutCleansUpWorker() async throws {
        let (root, url) = try script("printf '%s' \"$$\" > \"$0.pid\"\nread waiting < \"$0.fifo\"\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkfifo(url.path + ".fifo", mode_t(0o600)), 0)
        let mute = SourceAudioMute(executable: url, startupTimeout: .milliseconds(100))
        do { try await mute.start(source: source); XCTFail("Startup should time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let pid = try XCTUnwrap(pid_t(try String(contentsOfFile: url.path + ".pid", encoding: .utf8)))
        let exited = await waitForExit(pid)
        XCTAssertTrue(exited)
    }
}
