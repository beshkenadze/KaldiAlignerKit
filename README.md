# KaldiAlignerKit

Native Swift forced alignment using Kaldi C++ — word-level timestamps from audio + transcript.

Uses MFA (Montreal Forced Aligner) acoustic models and dictionaries. Zero Python runtime dependency.

## Requirements

- macOS 14+, Apple Silicon (arm64)
- Xcode 16.3+ (Swift 6.2, C++17)
- Kaldi + OpenFst static libraries (see [Build Kaldi](#build-kaldi))

## Installation

### 1. Build Kaldi

Clone and build Kaldi static libraries (~5 min on M-series Mac):

```bash
git clone --depth 1 https://github.com/kaldi-asr/kaldi.git
cd kaldi/tools
OPENFST_CONFIGURE="--enable-static --disable-shared --enable-far --enable-ngram-fsts --enable-lookahead-fsts --with-pic" \
  CXXFLAGS="-O3 -fPIC -arch arm64" \
  make -j$(sysctl -n hw.ncpu) openfst
cd ../src
./configure --static --static-fst --fst-root="$(cd ../tools/openfst && pwd)"
CXXFLAGS="-O3 -fPIC -arch arm64" make -j$(sysctl -n hw.ncpu) \
  base matrix util feat tree gmm hmm transform fstext decoder lat lm
```

After build, note the paths:
- **Kaldi src**: `<your-path>/kaldi/src`
- **OpenFst**: `<your-path>/kaldi/tools/openfst`

### 2. Add SPM Dependency

In your project's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/beshkenadze/KaldiAlignerKit.git", branch: "main"),
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

### 3. Configure Kaldi Paths

KaldiAlignerKit links against Kaldi/OpenFst static libraries. The `Package.swift` in this repo uses absolute paths — you need to update them to match your Kaldi build location.

In `KaldiAlignerKit/Package.swift`, change the root paths at the top:

```swift
let kaldiRoot = "/path/to/your/kaldi"       // ← your Kaldi clone
let kaldiSrc = "\(kaldiRoot)/src"
let openfstRoot = "\(kaldiRoot)/tools/openfst"
```

> **Note**: SPM requires absolute paths for linker flags. Relative paths will fail.

### 4. Build

```bash
swift build --target KaldiAlignerKit
```

## MFA Models

The aligner needs an MFA acoustic model and pronunciation dictionary.

### Automatic Download

KaldiAlignerKit can download MFA models automatically from [GitHub releases](https://github.com/MontrealCorpusTools/mfa-models/releases):

```swift
// Download model + dictionary, create aligner in one step
let aligner = try await KaldiAligner.withModel("english_mfa")

// Or download separately for more control
let paths = try await MFAModelDownloader.download("russian_mfa")
let aligner = try KaldiAligner(modelDir: paths.modelDir, dictPath: paths.dictPath)
```

Models are cached in `~/Library/Caches/KaldiAlignerKit/`. Subsequent calls skip the download.

### Manual Download via MFA CLI

```bash
pip install montreal-forced-aligner
mfa model download acoustic english_mfa
mfa model download dictionary english_mfa
mfa model download acoustic russian_mfa
mfa model download dictionary russian_mfa
```

Models are saved to `~/Documents/MFA/pretrained_models/`.

### Supported Languages

Any language with an MFA acoustic model and pronunciation dictionary. Tested:

| Language | Model | Dictionary | Dict Size |
|---|---|---|---|
| English | `english_mfa` | `english_mfa.dict` | 42K words |
| Russian | `russian_mfa` | `russian_mfa.dict` | 452K words |

Full list: [MFA pretrained models](https://mfa-models.readthedocs.io/en/latest/acoustic/index.html)

## Usage

### Quick Start

```swift
import KaldiAlignerKit

// Download model and create aligner
let aligner = try await KaldiAligner.withModel("english_mfa")

// Align audio + transcript → word timestamps
let words = try aligner.align(
    audio: pcmSamples,      // [Float], mono, 16kHz
    sampleRate: 16000,
    transcript: "hello world this is a test"
)

for word in words {
    print("\(word.word): \(word.startTime)–\(word.endTime)s")
}
// hello: 0.430–0.690s
// world: 0.690–1.050s
// this:  1.050–1.230s
// ...
```

### Manual Model Paths

```swift
let aligner = try KaldiAligner(
    modelDir: "/path/to/english_mfa",
    dictPath: "/path/to/english_mfa.dict"
)
```

### Audio Preparation

The aligner expects mono 16kHz PCM Float32 samples. Convert using AVFoundation:

```swift
import AVFoundation

func loadAudio(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let frameCount = AVAudioFrameCount(
        Double(file.length) * 16000 / file.processingFormat.sampleRate
    )
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!

    var error: NSError?
    converter.convert(to: buffer, error: &error) { _, status in
        let readBuf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 4096
        )!
        do {
            try file.read(into: readBuf, frameCount: 4096)
            status.pointee = readBuf.frameLength > 0 ? .haveData : .endOfStream
            return readBuf
        } catch {
            status.pointee = .endOfStream
            return nil
        }
    }

    let floatData = buffer.floatChannelData!
    return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
}
```

### Error Handling

```swift
do {
    let aligner = try KaldiAligner(modelDir: modelDir, dictPath: dictPath)
    let words = try aligner.align(audio: samples, sampleRate: 16000, transcript: text)
} catch AlignerError.initFailed(let message) {
    // Model files missing or invalid
    print("Init failed: \(message)")
} catch AlignerError.alignmentFailed(let message) {
    // Decoder failed (empty audio, incompatible transcript, etc.)
    print("Alignment failed: \(message)")
}
```

### Batch Processing (Long Audio)

For long audio, segment first (e.g., with VAD), then align each segment:

```swift
let aligner = try await KaldiAligner.withModel("english_mfa")

for segment in vadSegments {
    let segSamples = Array(allSamples[segment.startSample..<segment.endSample])

    let words = try aligner.align(
        audio: segSamples,
        sampleRate: 16000,
        transcript: segment.transcript
    )

    // Offset word times to absolute position
    for word in words {
        let absStart = Double(word.startTime) + segment.startTime
        let absEnd = Double(word.endTime) + segment.startTime
        print("\(word.word): \(absStart)–\(absEnd)s")
    }
}
```

> **Tip**: The `KaldiAligner` instance is reusable. Load once, call `align()` many times.

## API Reference

### `KaldiAligner`

```swift
public final class KaldiAligner {
    /// Load Kaldi acoustic model and pronunciation dictionary.
    public init(modelDir: String, dictPath: String) throws

    /// Download MFA model and create aligner in one step.
    public static func withModel(
        _ name: String,
        version: String? = nil,
        cacheDir: URL? = nil
    ) async throws -> KaldiAligner

    /// Perform forced alignment on audio with known transcript.
    public func align(audio: [Float], sampleRate: Int, transcript: String) throws -> [WordAlignment]
}
```

### `MFAModelDownloader`

```swift
public enum MFAModelDownloader {
    /// Download MFA acoustic model and dictionary.
    /// Caches in ~/Library/Caches/KaldiAlignerKit/.
    public static func download(
        _ name: String,             // e.g. "english_mfa", "russian_mfa"
        version: String? = nil,     // default: latest known
        cacheDir: URL? = nil
    ) async throws -> MFAModelPaths
}

public struct MFAModelPaths: Sendable {
    public let modelDir: String
    public let dictPath: String
}
```

### `WordAlignment`

```swift
public struct WordAlignment {
    public let word: String       // The aligned word
    public let startTime: Float   // Start time in seconds (relative to input audio)
    public let endTime: Float     // End time in seconds (relative to input audio)
}
```

### `AlignerError`

```swift
public enum AlignerError: Error {
    case initFailed(String)       // Model loading failed
    case alignmentFailed(String)  // Viterbi decoding failed
}
```

## Architecture

```
KaldiAlignerKit (Swift)
  └─ KaldiAligner class (opaque handle wrapper)
       └─ KaldiCore (C++ via extern "C")
            ├─ MFCC extraction (13 coefficients)
            ├─ CMVN normalization (mean-only)
            ├─ Splice frames (±3 context)
            ├─ LDA transform (91→40 dimensions)
            ├─ HCLG graph composition
            └─ Viterbi decoding → word intervals
```

The C++ layer (`KaldiAligner.cpp`) calls Kaldi libraries directly — same pipeline as MFA Python but without Python/kalpy overhead.

## Performance

Benchmarked on Apple M4 Max:

| | English (30s clip) | Russian (10s clip) |
|---|---|---|
| Model load | 0.23s | 1.28s |
| Alignment | 0.13s (79 words) | 0.11s (25 words) |

Kaldi alignment accuracy matches MFA Python API within ~100ms (within inherent forced alignment uncertainty).

## Project Structure

```
Sources/
├── KaldiCore/              # C++ Kaldi wrapper (extern "C" API)
│   ├── KaldiAligner.cpp    # MFCC → CMVN → LDA → HCLG → Viterbi
│   └── include/
│       └── KaldiAligner.hpp
├── KaldiAlignerKit/        # Swift public API
│   ├── KaldiAligner.swift  # KaldiAligner, WordAlignment, AlignerError
│   └── ModelDownloader.swift # MFA model download + cache
└── SwiftKaldiBench/        # Standalone Kaldi benchmark
Tests/
└── KaldiAlignerKitTests/
```

## Development

### Linting & Formatting

```bash
# Lint
swiftlint lint --strict

# Format
swiftformat .

# Check format without changing files
swiftformat . --lint
```

### CI

GitHub Actions runs on every push/PR to `main`:
- **SwiftLint** — code quality
- **SwiftFormat** — consistent style
- **Build & Test** — compiles Kaldi from source (cached), runs `swift test`

## License

MIT
