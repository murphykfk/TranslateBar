import XCTest
import TranslateCore
@testable import TranslateBar

final class InteractionExperienceTests: XCTestCase {
    @MainActor func testPracticeReplacesOnlyCurrentParagraphAndCanUndo() async {
        let practice = TranslationPracticeController()
        practice.text = "Bear\n\n刘德华   "; practice.selection = NSRange(location: practice.text.utf16.count, length: 0)
        let before = practice.text
        practice.translate(input: true) { text, _ in XCTAssertEqual(text, "刘德华"); return .init(text: "Andy Lau", message: "done") }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(practice.text, "Bear\n\nAndy Lau")
        practice.undoReplacement(); XCTAssertEqual(practice.text, before)
    }
    @MainActor func testPracticeEmptyParagraphAfterReturnDoesNotTranslateEarlierText() async {
        let practice = TranslationPracticeController()
        practice.text = "Bear\n"; practice.selection = NSRange(location: 5, length: 0)
        practice.translate(input: true) { _, _ in XCTFail("Empty paragraph must not call the service"); return .init(text: "", message: "") }
        XCTAssertEqual(practice.text, "Bear\n"); XCTAssertFalse(practice.busy)
    }
    @MainActor func testDismissedFeedbackCannotBeRevivedByLateResponseOrTimer() {
        let notice = InputFeedbackState()
        let first = notice.begin(pid: 1)
        notice.dismiss()
        XCTAssertFalse(notice.update(first, message: "late", phase: .information))
        let second = notice.begin(pid: 2)
        notice.dismiss(first)
        XCTAssertEqual(notice.id, second)
        XCTAssertFalse(notice.update(first, message: "old failure", phase: .failure))
        XCTAssertTrue(notice.update(second, message: "done", phase: .information))
        XCTAssertEqual(notice.message, "done")
    }
    @MainActor func testPracticeNeverOverwritesTypingDuringTranslation() async {
        let practice = TranslationPracticeController()
        var continuation: CheckedContinuation<PracticeTranslation, Error>?
        practice.translate(input: true) { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        await Task.yield()
        practice.text = "new writing"
        continuation?.resume(returning: .init(text: "translated", message: "done"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(practice.text, "new writing")
        XCTAssertEqual(practice.result, "translated")
        XCTAssertFalse(practice.canUndo)
        XCTAssertFalse(practice.busy)
    }
    @MainActor func testResetRejectsLatePracticeResponseAndPreservesNewRequest() async {
        let practice = TranslationPracticeController()
        var continuation: CheckedContinuation<PracticeTranslation, Error>?
        practice.translate(input: true) { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        await Task.yield()
        practice.reset()
        practice.text = "second"
        practice.translate(input: true) { _, _ in .init(text: "second translation", message: "done") }
        for _ in 0..<5 { await Task.yield() }
        continuation?.resume(returning: .init(text: "stale", message: "old"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(practice.text, "second translation")
        XCTAssertEqual(practice.result, "second translation")
        XCTAssertEqual(practice.message, "done")
        XCTAssertFalse(practice.busy)
    }
    @MainActor func testPracticeSelectionUsesUTF16AndDoesNotReplaceSource() async {
        let practice = TranslationPracticeController()
        practice.text = "👋 你好 world"
        practice.selection = (practice.text as NSString).range(of: "你好")
        var received = ""
        practice.translate(input: false) { text, input in
            received = text; XCTAssertFalse(input)
            return .init(text: "hello", message: "done")
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(received, "你好")
        XCTAssertEqual(practice.text, "👋 你好 world")
        XCTAssertEqual(practice.result, "hello")
        XCTAssertFalse(practice.canUndo)
    }
    @MainActor func testPracticeUndoRequiresUnchangedReplacementAndInvalidSelectionDoesNotCallAPI() async {
        let practice = TranslationPracticeController()
        let original = practice.text
        practice.translate(input: true) { _, _ in .init(text: "translation", message: "done") }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(practice.canUndo)
        practice.text += " edited"
        practice.undoReplacement()
        XCTAssertEqual(practice.text, "translation edited")
        practice.text = "translation"
        practice.undoReplacement()
        XCTAssertEqual(practice.text, original)
        XCTAssertEqual(practice.selection.length, 0)
        XCTAssertTrue(practice.result.isEmpty)
        practice.selection = NSRange(location: 9999, length: 10)
        practice.translate(input: false) { _, _ in XCTFail("Invalid selection must not call the service"); return .init(text: "", message: "") }
        XCTAssertFalse(practice.busy)
    }
}
