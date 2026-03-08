// swift-tools-version: 6.0
import PackageDescription

let artifactPath = "__ARTIFACT_PATH__"

let package = Package(
    name: "KaldiAlignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KaldiAlignerKit", targets: ["KaldiAlignerKit"])
    ],
    targets: [
        .binaryTarget(
            name: "KaldiAlignerKit",
            path: artifactPath
        )
    ]
)
