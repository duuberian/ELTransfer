// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ELTransfer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ELTransfer",
            path: "Sources/ELTransfer"
        )
    ]
)
