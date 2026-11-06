// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DuckViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DuckViewer",
            path: "Sources/DuckViewer"
        ),
    ]
)
