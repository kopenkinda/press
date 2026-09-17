// swift-tools-version: 6.2
import PackageDescription

// The app keeps its existing signed bundle build. SwiftPM builds the same
// implementation for tests without launching windows or installing the app.
let package = Package(
    name: "Press",
    platforms: [.macOS("27.0")],
    targets: [
        .target(
            name: "PressCore",
            path: ".",
            exclude: ["Artwork", "scripts", "Tests", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
                      "Resources/Info.plist", "Sources/Press/PressApp.swift", "Sources/Press/ContentView.swift",
                      "Sources/Press/ArchiveViewController.swift"],
            sources: ["Sources/Press"],
            resources: [.copy("Resources/ArchiveFormats.json")]
        ),
        .testTarget(name: "PressTests", dependencies: ["PressCore"], path: "Tests",
                    exclude: ["make-fixtures.py", "Fixtures"])
    ]
)
