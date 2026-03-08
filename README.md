# KaldiAlignerKit

Native Swift forced alignment using Kaldi C++ with MFA acoustic models and dictionaries.

The consumer story is binary-first: released tags ship a prebuilt `KaldiAlignerKit.xcframework` via SwiftPM. The source tree remains for development and release engineering.

## Requirements

- macOS 14+
- Apple Silicon (`arm64`) in v1
- Xcode 16.3+

## Install From a Release Tag

Use a released semver tag instead of `main`:

```swift
dependencies: [
    .package(url: "https://github.com/beshkenadze/KaldiAlignerKit.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "KaldiAlignerKit", package: "KaldiAlignerKit"),
        ]
    ),
]
```

The consumer path does not require a local Kaldi/OpenFst toolchain. Those dependencies are baked into the release artifact produced by CI.

## Quick Start

```swift
import KaldiAlignerKit

let aligner = try await KaldiAligner.withModel("english_mfa")

let words = try aligner.align(
    audio: pcmSamples,
    sampleRate: 16_000,
    transcript: "hello world this is a test"
)
```

## Models

`KaldiAlignerKit` works with MFA acoustic models and pronunciation dictionaries.

- Automatic download: `try await KaldiAligner.withModel("english_mfa")`
- Manual download: `try await MFAModelDownloader.download("english_mfa")`
- Default cache: `~/Library/Caches/KaldiAlignerKit/`

Expected model layout:

- `tree`
- `lda.mat`
- `phones.txt`
- one of `final.alimdl` or `final.mdl`
- optional `meta.json`

## API Notes

Current public API remains source-compatible:

- `KaldiAligner`
- `WordAlignment`
- `MFAModelDownloader`
- `KaldiAligner.withModel(...)`

The aligner expects mono 16 kHz `Float32` PCM samples. Resample before calling `align(...)`.

## Development

The checked-in root manifest is reserved for binary consumption. Development and release scripts render a source manifest only for source builds.

### 1. Render the source manifest

```bash
./scripts/render-package-manifest.sh source
```

### 2. Build Kaldi/OpenFst into the repo-local vendor directory

```bash
./scripts/build-kaldi.sh
```

This produces a repo-local toolchain under `.build/vendor/kaldi`.

### 3. Build or test from source

```bash
KALDI_ROOT="$PWD/.build/vendor/kaldi" swift build --target KaldiAlignerKit
KALDI_ROOT="$PWD/.build/vendor/kaldi" swift test
```

## Internal Benchmark Tool

`swift-kaldi-bench` is a development-only executable. It no longer carries any machine-specific sample paths.

```bash
KALDI_ROOT="$PWD/.build/vendor/kaldi" swift run swift-kaldi-bench \
  --audio /path/to/audio.wav \
  --transcript "hello world" \
  --model-dir /path/to/model \
  --dict /path/to/model.dict \
  --output /path/to/result.json \
  --language en
```

## Release Workflow

The release pipeline is implemented in GitHub Actions and the scripts in `scripts/`.

Local dry run:

```bash
./scripts/render-package-manifest.sh source
./scripts/build-xcframework.sh 0.1.0
./scripts/run-binary-consumer-smoke.sh
```

That produces:

- `.build/artifacts/KaldiAlignerKit-0.1.0.xcframework.zip`
- `.build/artifacts/KaldiAlignerKit-0.1.0.checksum.txt`
- `.build/artifacts/KaldiAlignerKit-0.1.0.THIRD_PARTY_NOTICES.txt`

Publishing is handled by `.github/workflows/release.yml`. The workflow:

- builds the xcframework from a temp source package
- smoke-tests a clean SwiftPM client against the local XCFramework package
- computes the SwiftPM checksum
- renders the binary manifest
- tags the release
- uploads the release artifacts

## Repository Layout

- `Package.swift`: binary consumer manifest placeholder in development, concrete in release tags
- `scripts/templates/Package.source.swift`: source manifest template used by CI/release scripts
- `scripts/templates/Package.binary.swift`: rendered into release tags for consumer installs
- `scripts/templates/Package.binary.local.swift`: local-path binary manifest template for smoke tests
- `scripts/build-kaldi.sh`: builds repo-local Kaldi/OpenFst dependencies
- `scripts/build-xcframework.sh`: builds and packages the release artifact
- `scripts/run-binary-consumer-smoke.sh`: verifies a clean SwiftPM client can build against the local xcframework
- `scripts/render-package-manifest.sh`: switches between source and binary manifests
