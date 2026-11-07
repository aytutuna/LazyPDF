// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone and iPad, as in Lazy Print:
// - LazyPDFKit: the engine, the twin of windows/LazyPDF.Core. No AppKit, UIKit or SwiftUI; Foundation alone.
// - LazyPDFApp: what the Mac and the iPhone and iPad apps share below the views: documents, tabs, recovery, the viewer's
//   arithmetic, and the engine's platform hooks on Apple's frameworks (those files are wrapped in `#if canImport(...)`, so
//   the rest builds and tests on Linux and Windows too).
// - LazyPDFUI: the SwiftUI views the Mac and the iPhone and iPad share. Every file is wrapped in `#if canImport(SwiftUI)`.
// - LazyPDFMac: the Mac's views and system services. Every file is wrapped in `#if os(macOS)`.
// - LazyPDFIOS: the iPhone's and iPad's views and services. Every file is wrapped in `#if os(iOS)`.
// - LazyPDF: the Mac app.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "LazyPDF",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .executable(name: "LazyPDF", targets: ["LazyPDF"]),
        .library(name: "LazyPDFKit", targets: ["LazyPDFKit"]),
        .library(name: "LazyPDFMac", targets: ["LazyPDFMac"]),
        .library(name: "LazyPDFIOS", targets: ["LazyPDFIOS"]),
    ],
    targets: [
        .target(
            name: "LazyPDFKit",
            path: "Sources/LazyPDFKit"
        ),
        .target(
            name: "LazyPDFApp",
            dependencies: ["LazyPDFKit"],
            path: "Sources/LazyPDFApp"
        ),
        .target(
            name: "LazyPDFUI",
            dependencies: ["LazyPDFApp"],
            path: "Sources/LazyPDFUI"
        ),
        .target(
            name: "LazyPDFMac",
            dependencies: ["LazyPDFUI"],
            path: "Sources/LazyPDFMac"
        ),
        .target(
            name: "LazyPDFIOS",
            dependencies: ["LazyPDFUI"],
            path: "Sources/LazyPDFIOS"
        ),
        .executableTarget(
            name: "LazyPDF",
            dependencies: [
                .target(name: "LazyPDFMac", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/LazyPDF"
        ),
        .testTarget(
            name: "LazyPDFKitTests",
            dependencies: ["LazyPDFKit"],
            // Reads Tests/Fixtures by #filePath, the folder the Windows tests read too.
            path: "Tests/LazyPDFKitTests"
        ),
        .testTarget(
            name: "LazyPDFAppTests",
            dependencies: ["LazyPDFApp"],
            path: "Tests/LazyPDFAppTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
