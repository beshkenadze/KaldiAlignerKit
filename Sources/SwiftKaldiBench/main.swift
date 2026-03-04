import Foundation
import AVFoundation
import KaldiAlignerKit

struct BenchResult: Codable {
    let model: String
    let audio_file: String
    let language: String
    let inference_time_seconds: Double
    let model_load_time_seconds: Double
    let peak_memory_mb: Double
    let words: [WordResult]
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

    let targetRate: Double = 16000
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
        let readFrames: AVAudioFrameCount = 4096
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

func runBenchmark(
    lang: String,
    audioPath: String,
    transcript: String,
    modelDir: String,
    dictPath: String,
    outputPath: String
) {
    print("[\(lang)] Loading model from \(modelDir)...")
    let loadStart = CFAbsoluteTimeGetCurrent()
    let aligner: KaldiAligner
    do {
        aligner = try KaldiAligner(modelDir: modelDir, dictPath: dictPath)
    } catch {
        print("[\(lang)] ERROR: Failed to create aligner: \(error)")
        return
    }
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("[\(lang)] Model loaded in \(String(format: "%.3f", loadTime))s")

    print("[\(lang)] Loading audio from \(audioPath)...")
    let audio: [Float]
    do {
        audio = try loadAudioAsPCM16kHz(audioPath)
    } catch {
        print("[\(lang)] ERROR: Failed to load audio: \(error)")
        return
    }
    print("[\(lang)] Audio loaded: \(audio.count) samples (\(String(format: "%.1f", Double(audio.count)/16000))s)")

    print("[\(lang)] Aligning...")
    let inferStart = CFAbsoluteTimeGetCurrent()
    let alignments: [WordAlignment]
    do {
        alignments = try aligner.align(
            audio: audio,
            sampleRate: 16000,
            transcript: transcript
        )
    } catch {
        print("[\(lang)] ERROR: Alignment failed: \(error)")
        return
    }
    let inferTime = CFAbsoluteTimeGetCurrent() - inferStart
    print("[\(lang)] Alignment done in \(String(format: "%.3f", inferTime))s — \(alignments.count) words")

    for w in alignments {
        print("  \(String(format: "%7.3f", w.startTime)) - \(String(format: "%7.3f", w.endTime))  \(w.word)")
    }

    let result = BenchResult(
        model: "swift-kaldi-aligner",
        audio_file: audioPath,
        language: lang,
        inference_time_seconds: inferTime,
        model_load_time_seconds: loadTime,
        peak_memory_mb: 0,
        words: alignments.map { WordResult(
            word: $0.word, start: Double($0.startTime),
            end: Double($0.endTime), confidence: nil
        )}
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(result),
       let json = String(data: data, encoding: .utf8) {
        try? json.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("[\(lang)] Results written to \(outputPath)")
    }
}

// --- Main ---
let outputDir = "/Volumes/DATA/alignment-benchmark/results"

// EN
runBenchmark(
    lang: "en",
    audioPath: "\(NSHomeDirectory())/Downloads/Contracts Week 1 Module 1 Slides_30sec.mp3",
    transcript: "Well hello and welcome Welcome to U.S. Contract Law for the Bar My name is Mike Sims and I am genuinely excited to be your guide for this course Now I realize that you may have studied law in another country Well that's okay because this class is designed to meet you exactly where you are My mission My mission is very simple to give you a fundamental understanding of the law of contracts in the U.S. and to highlight",
    modelDir: "/Volumes/DATA/mfa_models/english/english_mfa",
    dictPath: "\(NSHomeDirectory())/Documents/MFA/pretrained_models/dictionary/english_mfa.dict",
    outputPath: "\(outputDir)/swift_kaldi_en.json"
)

// RU
runBenchmark(
    lang: "ru",
    audioPath: "\(NSHomeDirectory())/Downloads/Spoon Episodex/Episode 171/compare/episode171-original_trim10_10s.wav",
    transcript: "Новый год и Рождество о чём ещё можно говорить кроме как о Гарри Поттере И эта замечательная серия книг на мой взгляд является лучшим произведением",
    modelDir: "/Volumes/DATA/mfa_models/russian/russian_mfa/russian_mfa",
    dictPath: "\(NSHomeDirectory())/Documents/MFA/pretrained_models/dictionary/russian_mfa.dict",
    outputPath: "\(outputDir)/swift_kaldi_ru.json"
)
