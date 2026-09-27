// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ELTransfer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "ELTransfer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ELTransfer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
