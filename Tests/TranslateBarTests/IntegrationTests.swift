import AVFoundation
import XCTest
import TranslateCore
@testable import TranslateBar

final class IntegrationTests: XCTestCase {
    func testTemporaryPasteRestoresAllClipboardItemsAndFormats() async throws {
        await MainActor.run {
            let board = NSPasteboard(name: .init("TranslateBarTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let first = NSPasteboardItem(); first.setString("original", forType: .string)
            let customType = NSPasteboard.PasteboardType("com.murphy.translatebar.test-binary")
            first.setData(Data([0, 255, 4]), forType: customType)
            let second = NSPasteboardItem(); second.setString("second", forType: .string)
            board.writeObjects([first, second])
            let transaction = TemporaryClipboard(text: "elephant", pasteboard: board)
            XCTAssertEqual(board.string(forType: .string), "elephant")
            transaction.restore()
            XCTAssertEqual(board.pasteboardItems?.count, 2)
            XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "original")
            XCTAssertEqual(board.pasteboardItems?.first?.data(forType: customType), Data([0, 255, 4]))
            XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "second")
        }
    }
    func testTemporaryPastePreservesNewerClipboardContents() async throws {
        await MainActor.run {
            let board = NSPasteboard(name: .init("TranslateBarTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString("original", forType: .string)
            let transaction = TemporaryClipboard(text: "elephant", pasteboard: board)
            board.clearContents(); board.setString("copied while translating", forType: .string)
            transaction.restore()
            XCTAssertEqual(board.string(forType: .string), "copied while translating")
        }
    }
    func testCorruptedLedgerBlocksReservations() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("usage.json")
            try Data("corrupted ledger".utf8).write(to: url)
            let controller = BudgetController(url: url)
            XCTAssertThrowsError(try controller.reserve(0.001, kind: .text, model: "test", configuration: BudgetConfiguration()))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupted ledger")
        }
    }
    func testPersistedReservationRemainsChargedAfterRestart() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("usage.json")
            let configuration = BudgetConfiguration()
            let first = BudgetController(url: url)
            let id = try first.reserve(0.05, kind: .audio, model: "test", configuration: configuration)
            let reloaded = BudgetController(url: url)
            XCTAssertEqual(reloaded.book.record(id: id)?.status, .uncertain)
            XCTAssertEqual(reloaded.book.spent(configuration: configuration), 0.05, accuracy: 1e-9)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testConverterProducesNonSilent24kMonoPCMFrom48kStereo() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        for channel in 0..<2 {
            for index in 0..<24_000 { buffer.floatChannelData![channel][index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000) * 0.25) }
        }
        let converter = try PCMConverter(input: format)
        var output = try converter.convert(buffer)
        output.append(try converter.finish())
        XCTAssertEqual(converter.output.sampleRate, 24_000)
        XCTAssertEqual(converter.output.channelCount, 1)
        XCTAssertEqual(output.count % 2, 0)
        XCTAssertEqual(Double(output.count) / 48_000, 0.5, accuracy: 0.01)
        let peak = output.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        XCTAssertGreaterThan(peak, 4000)
    }
}
