// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DuckViewer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "DuckViewer",
            dependencies: ["SwiftTerm"],
            path: "Sources/DuckViewer"
        ),
    ]
)
