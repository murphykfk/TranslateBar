import XCTest
@testable import TranslateCore

final class APIKeyInputTests: XCTestCase {
    func testCopiedKeysAreNormalizedWithoutAssumingAnExactKeyFormat() throws {
        XCTAssertEqual(try APIKeyInput.normalized(" \n sk-proj-test_abc-123 \r\n"), "sk-proj-test_abc-123")
        XCTAssertEqual(try APIKeyInput.normalized("Bearer sk-test-123"), "sk-test-123")
        XCTAssertEqual(try APIKeyInput.normalized("'sk-test-123'"), "sk-test-123")
        XCTAssertEqual(try APIKeyInput.normalized("\"sk-test-123\""), "sk-test-123")
        XCTAssertEqual(try APIKeyInput.normalized("future-format.token"), "future-format.token")
    }
    func testEmptyKeysAndAccidentalHeaderOrFileContentAreRejectedLocally() {
        for input in ["", " \n ", "sk-secret\r\nX-Header: value", "sk secret", "sk-\u{200b}secret", "OPENAI_API_KEY=sk-secret", "https://api.openai.com", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try APIKeyInput.normalized(input))
        }
    }
}
