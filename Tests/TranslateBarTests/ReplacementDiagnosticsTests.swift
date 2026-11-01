import XCTest
@testable import TranslateBar

final class ReplacementDiagnosticsTests: XCTestCase {
    @MainActor func testExistingFailureCanBeExportedWithOnlyTheReportSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostic.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value: [String: Any] = [
            "date": "2026-01-01T00:00:00Z", "version": "0.4.7", "richText": false, "succeeded": false,
            "failure": "input_capture_failed", "checks": [["stage": "word_body_guard", "counts": ["enabled": 0, "editable": -1, "role_supported": 1, "modal": 0]]],
            "original_text": "PRIVATE_DOCUMENT_SENTINEL", "api_key": "PRIVATE_CREDENTIAL_SENTINEL"
        ]
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        let exported = try XCTUnwrap(ReplacementDiagnostics.lastFailureJSON(from: url))
        XCTAssertFalse(exported.contains("PRIVATE_DOCUMENT_SENTINEL"))
        XCTAssertFalse(exported.contains("PRIVATE_CREDENTIAL_SENTINEL"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["date", "version", "richText", "succeeded", "failure", "checks"])
        let checks = try XCTUnwrap(decoded["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["counts"] as? [String: Int], ["enabled": 0, "editable": -1, "role_supported": 1, "modal": 0])
        XCTAssertEqual(decoded["version"] as? String, "0.4.7")
    }
    @MainActor func testMissingFailureDoesNotCreateAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.json")
        XCTAssertNil(try ReplacementDiagnostics.lastFailureJSON(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
    @MainActor func testMalformedAndOversizedFilesAreNotCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("diagnostic.json")
        try Data("not a diagnostic report".utf8).write(to: url)
        XCTAssertThrowsError(try ReplacementDiagnostics.lastFailureJSON(from: url))
        try Data(repeating: 32, count: 64 * 1024 + 1).write(to: url)
        XCTAssertThrowsError(try ReplacementDiagnostics.lastFailureJSON(from: url))
    }
}
