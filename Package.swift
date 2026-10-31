// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranslateBar",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "TranslateBar", targets: ["TranslateBar"])],
    targets: [
        .target(name: "TranslateCore"),
        .executableTarget(name: "TranslateBar", dependencies: ["TranslateCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("CoreAudio"),
            .linkedFramework("AVFoundation"), .linkedFramework("ApplicationServices"),
            .linkedFramework("Security"), .linkedFramework("ServiceManagement"),
            .linkedFramework("ScreenCaptureKit")
        ]),
        .testTarget(name: "TranslateCoreTests", dependencies: ["TranslateCore"]),
        .testTarget(name: "TranslateBarTests", dependencies: ["TranslateBar", "TranslateCore"])
    ],
    swiftLanguageModes: [.v5]
)
