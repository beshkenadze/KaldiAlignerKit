// swift-tools-version: 6.0
import PackageDescription

let kaldiRoot = "/Volumes/DATA/kaldi"
let kaldiSrc = "\(kaldiRoot)/src"
let openfstRoot = "\(kaldiRoot)/tools/openfst"

let kaldiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(kaldiSrc)/decoder", "-lkaldi-decoder"]),
    .unsafeFlags(["-L\(kaldiSrc)/lat", "-lkaldi-lat"]),
    .unsafeFlags(["-L\(kaldiSrc)/hmm", "-lkaldi-hmm"]),
    .unsafeFlags(["-L\(kaldiSrc)/tree", "-lkaldi-tree"]),
    .unsafeFlags(["-L\(kaldiSrc)/gmm", "-lkaldi-gmm"]),
    .unsafeFlags(["-L\(kaldiSrc)/transform", "-lkaldi-transform"]),
    .unsafeFlags(["-L\(kaldiSrc)/feat", "-lkaldi-feat"]),
    .unsafeFlags(["-L\(kaldiSrc)/fstext", "-lkaldi-fstext"]),
    .unsafeFlags(["-L\(kaldiSrc)/lm", "-lkaldi-lm"]),
    .unsafeFlags(["-L\(kaldiSrc)/util", "-lkaldi-util"]),
    .unsafeFlags(["-L\(kaldiSrc)/matrix", "-lkaldi-matrix"]),
    .unsafeFlags(["-L\(kaldiSrc)/base", "-lkaldi-base"]),
    .unsafeFlags(["-L\(openfstRoot)/lib", "-lfst", "-lfstngram", "-lfstfar"]),
    .linkedFramework("Accelerate"),
    .unsafeFlags(["-lc++"])
]

let kaldiHeaderSettings: [CSetting] = [
    .unsafeFlags(["-I\(kaldiSrc)", "-I\(openfstRoot)/include"])
]

let package = Package(
    name: "KaldiAlignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KaldiAlignerKit", targets: ["KaldiAlignerKit"]),
        .executable(name: "swift-kaldi-bench", targets: ["SwiftKaldiBench"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "KaldiCore",
            path: "Sources/KaldiCore",
            sources: ["KaldiAligner.cpp"],
            publicHeadersPath: "include",
            cSettings: kaldiHeaderSettings,
            cxxSettings: [
                .unsafeFlags([
                    "-I\(kaldiSrc)",
                    "-I\(openfstRoot)/include",
                    "-std=c++17",
                    "-DOPENFST_VER=10804",
                    "-DKALDI_DOUBLEPRECISION=0",
                    "-DHAVE_EXECINFO_H=1",
                    "-DHAVE_CXXABI_H=1"
                ])
            ],
            linkerSettings: kaldiLinkerSettings
        ),
        .target(
            name: "KaldiAlignerKit",
            dependencies: ["KaldiCore"],
            linkerSettings: kaldiLinkerSettings
        ),
        .executableTarget(
            name: "SwiftKaldiBench",
            dependencies: ["KaldiAlignerKit"],
            path: "Sources/SwiftKaldiBench"
        ),
        .testTarget(
            name: "KaldiAlignerKitTests",
            dependencies: ["KaldiAlignerKit"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
