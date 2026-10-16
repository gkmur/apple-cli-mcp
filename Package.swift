// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "apple-cli",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "AppleKit",
            dependencies: ["CZlib"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("EventKit")]
        ),
        .executableTarget(
            name: "apple-cli",
            dependencies: ["AppleKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist",
            ])]
        ),
    ]
)
