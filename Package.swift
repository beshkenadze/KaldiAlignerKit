// swift-tools-version: 6.0
import PackageDescription

// The release workflow renders concrete artifact coordinates into this manifest before tagging.
let artifactURL = "https://github.com/beshkenadze/KaldiAlignerKit/releases/download/v0.1.0/KaldiAlignerKit-0.1.0.xcframework.zip"
let artifactChecksum = "1cbaabee3221240a782f25083df582bb515e036d9ec9cf06ea18a6fbd5291ac6"

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
