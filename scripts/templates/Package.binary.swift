// swift-tools-version: 6.0
import PackageDescription

// The release workflow renders concrete artifact coordinates into this manifest before tagging.
let artifactURL = "__ARTIFACT_URL__"
let artifactChecksum = "__ARTIFACT_CHECKSUM__"

let package = Package(
    name: "KaldiAlignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KaldiAlignerKit", targets: ["KaldiAlignerKit"])
    ],
    targets: [
        .binaryTarget(
            name: "KaldiAlignerKit",
            url: artifactURL,
            checksum: artifactChecksum
        )
    ]
)
