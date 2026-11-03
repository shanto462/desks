// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Desks",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Desks", targets: ["Desks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        // Window tracking, layout model, parking, persistence. No UI.
        .target(name: "DesksCore", path: "Sources/DesksCore"),
        // Menu bar app: bar, overlay, menu, settings, hotkeys.
        .executableTarget(
            name: "Desks",
            dependencies: [
                "DesksCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Desks"
        ),
    ]
)
