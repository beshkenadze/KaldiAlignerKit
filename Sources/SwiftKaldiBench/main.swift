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
        fatalError("Cannot create target audio format")
    }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        fatalError("Cannot create audio converter")
    }

    let frameCount = AVAudioFrameCount(
        Double(file.length) * targetRate / file.processingFormat.sampleRate
    )
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        fatalError("Cannot create output buffer")
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
        fatalError("No float channel data")
    }
    let count = Int(outputBuffer.frameLength)
    return Array(UnsafeBufferPointer(start: floatData[0], count: count))
}

struct BenchConfig {
    let lang: String
    let audioPath: String
    let transcript: String
    let modelDir: String
    let dictPath: String
    let outputPath: String
}

func runBenchmark(_ config: BenchConfig) {
    print("[\(config.lang)] Loading model from \(config.modelDir)...")
    let loadStart = CFAbsoluteTimeGetCurrent()
    let aligner: KaldiAligner
    do {
        aligner = try KaldiAligner(modelDir: config.modelDir, dictPath: config.dictPath)
    } catch {
        print("[\(config.lang)] ERROR: Failed to create aligner: \(error)")
        return
    }
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("[\(config.lang)] Model loaded in \(String(format: "%.3f", loadTime))s")

    print("[\(config.lang)] Loading audio from \(config.audioPath)...")
    let audio: [Float]
    do {
        audio = try loadAudioAsPCM16kHz(config.audioPath)
    } catch {
        print("[\(config.lang)] ERROR: Failed to load audio: \(error)")
        return
    }
    let duration = String(format: "%.1f", Double(audio.count) / 16_000)
    print("[\(config.lang)] Audio loaded: \(audio.count) samples (\(duration)s)")

    print("[\(config.lang)] Aligning...")
    let inferStart = CFAbsoluteTimeGetCurrent()
    let alignments: [WordAlignment]
    do {
        alignments = try aligner.align(
            audio: audio,
            sampleRate: 16_000,
            transcript: config.transcript
        )
    } catch {
        print("[\(config.lang)] ERROR: Alignment failed: \(error)")
        return
    }
    let inferTime = CFAbsoluteTimeGetCurrent() - inferStart
    let elapsed = String(format: "%.3f", inferTime)
    print("[\(config.lang)] Alignment done in \(elapsed)s — \(alignments.count) words")

    for w in alignments {
        print("  \(String(format: "%7.3f", w.startTime)) - \(String(format: "%7.3f", w.endTime))  \(w.word)")
    }

    let result = BenchResult(
        model: "swift-kaldi-aligner",
        audioFile: config.audioPath,
        language: config.lang,
        inferenceTimeSeconds: inferTime,
        modelLoadTimeSeconds: loadTime,
        peakMemoryMb: 0,
        words: alignments.map {
            WordResult(word: $0.word, start: Double($0.startTime), end: Double($0.endTime), confidence: nil)
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(result),
          let json = String(data: data, encoding: .utf8) else { return }
    try? json.write(toFile: config.outputPath, atomically: true, encoding: .utf8)
    print("[\(config.lang)] Results written to \(config.outputPath)")
}

// MARK: - Main

let outputDir = "/Volumes/DATA/alignment-benchmark/results"

// EN
// swiftlint:disable line_length
runBenchmark(BenchConfig(
    lang: "en",
    audioPath: "\(NSHomeDirectory())/Downloads/Contracts Week 1 Module 1 Slides_30sec.mp3",
    transcript: "Well hello and welcome Welcome to U.S. Contract Law for the Bar My name is Mike Sims and I am genuinely excited to be your guide for this course Now I realize that you may have studied law in another country Well that's okay because this class is designed to meet you exactly where you are My mission My mission is very simple to give you a fundamental understanding of the law of contracts in the U.S. and to highlight",
    modelDir: "/Volumes/DATA/mfa_models/english/english_mfa",
    dictPath: "\(NSHomeDirectory())/Documents/MFA/pretrained_models/dictionary/english_mfa.dict",
    outputPath: "\(outputDir)/swift_kaldi_en.json"
))

// RU
runBenchmark(BenchConfig(
    lang: "ru",
    audioPath: "\(NSHomeDirectory())/Downloads/Spoon Episodex/Episode 171/compare/episode171-original_trim10_10s.wav",
    transcript: "Новый год и Рождество о чём ещё можно говорить кроме как о Гарри Поттере И эта замечательная серия книг на мой взгляд является лучшим произведением",
    modelDir: "/Volumes/DATA/mfa_models/russian/russian_mfa/russian_mfa",
    dictPath: "\(NSHomeDirectory())/Documents/MFA/pretrained_models/dictionary/russian_mfa.dict",
    outputPath: "\(outputDir)/swift_kaldi_ru.json"
))
// swiftlint:enable line_length
