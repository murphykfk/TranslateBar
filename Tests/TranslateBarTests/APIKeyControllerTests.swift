import Foundation
import XCTest
@testable import TranslateBar

private final class TestCredentialStorage: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var failLoad = false
    var failSave = false
    var failRemove = false
    var loadStarted: XCTestExpectation?
    var loadGate: DispatchSemaphore?
    init(_ value: String? = nil) { stored = value }
    func load(allowInteraction: Bool) throws -> String? {
        loadStarted?.fulfill(); _ = loadGate?.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        if failLoad { throw AppError.message("钥匙串未解锁。") }
        return stored
    }
    func save(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failSave { throw AppError.message("保存失败。") }
        stored = value
    }
    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove { throw AppError.message("移除失败。") }
        stored = nil
    }
}

final class APIKeyControllerTests: XCTestCase {
    @MainActor func testFirstRunWithoutKeyIsSetupStateRatherThanStorageError() async {
        let controller = APIKeyController(storage: TestCredentialStorage())
        await controller.load()
        XCTAssertTrue(controller.didLoad)
        XCTAssertFalse(controller.configured)
        XCTAssertFalse(controller.busy)
        XCTAssertNil(controller.error)
    }
    @MainActor func testSavedKeyLoadsInAnotherController() async {
        let store = TestCredentialStorage()
        let first = APIKeyController(storage: store)
        let saved = await first.save("  sk-test-user-key  ")
        XCTAssertTrue(saved)
        let second = APIKeyController(storage: store)
        await second.load()
        XCTAssertEqual(second.value, "sk-test-user-key")
        XCTAssertTrue(second.configured)
        XCTAssertFalse(second.message.contains(second.value))
    }
    @MainActor func testFailedReplacementKeepsWorkingKeyAndRevision() async {
        let store = TestCredentialStorage("sk-test-working")
        let controller = APIKeyController(storage: store)
        await controller.load(); let revision = controller.revision
        store.failSave = true
        let saved = await controller.save("sk-test-replacement")
        XCTAssertFalse(saved)
        XCTAssertEqual(controller.value, "sk-test-working")
        XCTAssertEqual(controller.revision, revision)
        XCTAssertTrue(controller.configured)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.requiresStorageRetry)
        XCTAssertFalse(controller.message.contains("sk-test-"))
    }
    @MainActor func testInvalidPasteDoesNotModifyStoredKey() async {
        let store = TestCredentialStorage("sk-test-working")
        let controller = APIKeyController(storage: store)
        await controller.load()
        let saved = await controller.save("OPENAI_API_KEY=sk-test-wrong")
        XCTAssertFalse(saved)
        XCTAssertEqual(try store.load(allowInteraction: false), "sk-test-working")
        XCTAssertEqual(controller.value, "sk-test-working")
        XCTAssertFalse(controller.requiresStorageRetry)
        controller.clearInputError()
        XCTAssertNil(controller.error)
    }
    @MainActor func testFailedRemovalKeepsKeyAndSuccessfulRemovalPersists() async {
        let store = TestCredentialStorage("sk-test-working")
        let controller = APIKeyController(storage: store)
        await controller.load(); store.failRemove = true
        let failed = await controller.remove()
        XCTAssertFalse(failed); XCTAssertTrue(controller.configured)
        store.failRemove = false
        let removed = await controller.remove()
        XCTAssertTrue(removed); XCTAssertFalse(controller.configured); XCTAssertTrue(controller.value.isEmpty)
        let restarted = APIKeyController(storage: store); await restarted.load()
        XCTAssertFalse(restarted.configured)
    }
    @MainActor func testLockedStoreCanBeRetried() async {
        let store = TestCredentialStorage("sk-test-working"); store.failLoad = true
        let controller = APIKeyController(storage: store)
        await controller.load()
        XCTAssertTrue(controller.didLoad); XCTAssertFalse(controller.configured); XCTAssertNotNil(controller.error)
        store.failLoad = false; await controller.load(allowInteraction: true)
        XCTAssertTrue(controller.configured); XCTAssertNil(controller.error)
    }
    @MainActor func testStartupLoadCannotOverwriteASubsequentSave() async {
        let store = TestCredentialStorage("sk-test-old")
        let started = expectation(description: "load started")
        let gate = DispatchSemaphore(value: 0); store.loadStarted = started; store.loadGate = gate
        let controller = APIKeyController(storage: store)
        let loading = Task { await controller.load() }
        await fulfillment(of: [started], timeout: 2)
        let premature = await controller.save("sk-test-new")
        XCTAssertFalse(premature); XCTAssertTrue(controller.busy)
        gate.signal(); await loading.value
        store.loadGate = nil; store.loadStarted = nil
        let saved = await controller.save("sk-test-new")
        XCTAssertTrue(saved); XCTAssertEqual(controller.value, "sk-test-new")
    }
    func testRealKeychainRoundTripInIsolatedTestService() throws {
        let store = KeychainCredentialStorage(service: "com.murphy.TranslateBar.tests.\(UUID().uuidString)")
        defer { try? store.remove() }
        XCTAssertNil(try store.load())
        try store.save("sk-test-first")
        XCTAssertEqual(try store.load(), "sk-test-first")
        try store.save("sk-test-replaced")
        XCTAssertEqual(try store.load(), "sk-test-replaced")
        try store.remove()
        XCTAssertNil(try store.load())
    }
}
