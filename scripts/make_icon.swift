import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = destination.deletingLastPathComponent().appendingPathComponent("TranslateBar.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let inset = CGFloat(pixels) * 0.05
        let rect = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        NSColor(calibratedRed: 0.05, green: 0.49, blue: 0.46, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.21, yRadius: CGFloat(pixels) * 0.21).fill()
        let symbol = NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [.white]))!
        symbol.draw(in: NSRect(x: CGFloat(pixels) * 0.20, y: CGFloat(pixels) * 0.19, width: CGFloat(pixels) * 0.60, height: CGFloat(pixels) * 0.62))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); process.arguments = ["-c", "icns", directory.path, "-o", destination.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: directory)
