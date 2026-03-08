import AVFoundation
import Foundation
import KaldiAlignerKit

struct BenchResult: Codable {
    let model: String
    let audioFile: String
    let language: String
    let inferenceTimeSeconds: Double
    let modelLoadTimeSeconds: Double
    let peakMemoryMb: Double
    let words: [WordResult]

    enum CodingKeys: String, CodingKey {
        case model, language, words
        case audioFile = "audio_file"
        case inferenceTimeSeconds = "inference_time_seconds"
        case modelLoadTimeSeconds = "model_load_time_seconds"
        case peakMemoryMb = "peak_memory_mb"
    }
}

struct WordResult: Codable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double?
}

enum BenchError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case audioConversion(String)

    var description: String {
        switch self {
        case let .invalidArguments(message), let .audioConversion(message):
            message
        }
    }
}

struct BenchConfig {
    let audioPath: String
    let transcript: String
    let modelDir: String
    let dictPath: String
    let outputPath: String
    let language: String

    static func parse(arguments: [String]) throws -> BenchConfig {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw BenchError.invalidArguments("Unexpected argument: \(key)")
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BenchError.invalidArguments("Missing value for \(key)")
            }
            values[key] = arguments[valueIndex]
            index += 2
        }

        guard let audioPath = values["--audio"],
              let transcript = values["--transcript"],
              let modelDir = values["--model-dir"],
              let dictPath = values["--dict"],
              let outputPath = values["--output"]
        else {
            throw BenchError.invalidArguments("Missing required arguments.")
        }

        return BenchConfig(
            audioPath: audioPath,
            transcript: transcript,
            modelDir: modelDir,
            dictPath: dictPath,
            outputPath: outputPath,
            language: values["--language"] ?? "unknown"
        )
    }

    static let usage = """
    Usage:
      swift run swift-kaldi-bench \
        --audio /path/to/audio.wav \
        --transcript "hello world" \
        --model-dir /path/to/model \
        --dict /path/to/model.dict \
        --output /path/to/result.json \
        [--language en]
    """
}

func loadAudioAsPCM16kHz(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)

    let targetRate: Double = 16_000
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetRate,
        channels: 1,
        interleaved: false
    ) else {
        throw BenchError.audioConversion("Cannot create target audio format")
    }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        throw BenchError.audioConversion("Cannot create audio converter")
    }

    let frameCount = AVAudioFrameCount(
        Double(file.length) * targetRate / file.processingFormat.sampleRate
    )
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw BenchError.audioConversion("Cannot create output buffer")
    }

    var convError: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        let readFrames: AVAudioFrameCount = 4_096
        guard let readBuf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: readFrames
        ) else {
            outStatus.pointee = .noDataNow
            return nil
        }
        do {
            try file.read(into: readBuf, frameCount: readFrames)
            outStatus.pointee = readBuf.frameLength > 0 ? .haveData : .endOfStream
            return readBuf
        } catch {
            outStatus.pointee = .endOfStream
            return nil
        }
    }

    converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
    if let err = convError {
        throw err
    }

    guard let floatData = outputBuffer.floatChannelData else {
        throw BenchError.audioConversion("No float channel data")
    }
    let count = Int(outputBuffer.frameLength)
    return Array(UnsafeBufferPointer(start: floatData[0], count: count))
}

@discardableResult
func runBenchmark(_ config: BenchConfig) throws -> BenchResult {
    print("[\(config.language)] Loading model from \(config.modelDir)...")
    let loadStart = CFAbsoluteTimeGetCurrent()
    let aligner = try KaldiAligner(modelDir: config.modelDir, dictPath: config.dictPath)
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("[\(config.language)] Model loaded in \(String(format: "%.3f", loadTime))s")

    print("[\(config.language)] Loading audio from \(config.audioPath)...")
    let audio = try loadAudioAsPCM16kHz(config.audioPath)
    let duration = String(format: "%.1f", Double(audio.count) / 16_000)
    print("[\(config.language)] Audio loaded: \(audio.count) samples (\(duration)s)")

    print("[\(config.language)] Aligning...")
    let inferStart = CFAbsoluteTimeGetCurrent()
    let alignments = try aligner.align(
        audio: audio,
        sampleRate: 16_000,
        transcript: config.transcript
    )
    let inferTime = CFAbsoluteTimeGetCurrent() - inferStart
    let elapsed = String(format: "%.3f", inferTime)
    print("[\(config.language)] Alignment done in \(elapsed)s — \(alignments.count) words")

    for word in alignments {
        print(
            "  \(String(format: "%7.3f", word.startTime)) - " +
                "\(String(format: "%7.3f", word.endTime))  \(word.word)"
        )
    }

    let result = BenchResult(
        model: "swift-kaldi-aligner",
        audioFile: config.audioPath,
        language: config.language,
        inferenceTimeSeconds: inferTime,
        modelLoadTimeSeconds: loadTime,
        peakMemoryMb: 0,
        words: alignments.map {
            WordResult(
                word: $0.word,
                start: Double($0.startTime),
                end: Double($0.endTime),
                confidence: nil
            )
        }
    )

    let outputURL = URL(fileURLWithPath: config.outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    try data.write(to: outputURL, options: .atomic)
    print("[\(config.language)] Results written to \(config.outputPath)")

    return result
}

do {
    let config = try BenchConfig.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    _ = try runBenchmark(config)
} catch {
    fputs("\(error)\n", stderr)
    if case BenchError.invalidArguments = error {
        fputs("\n\(BenchConfig.usage)\n", stderr)
    }
    exit(EXIT_FAILURE)
}
