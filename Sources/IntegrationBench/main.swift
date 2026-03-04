import AVFoundation
import FluidAudio
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import KaldiAlignerKit

// MARK: - Audio Loading

func loadAudioAsFloat(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        fatalError("Cannot create audio buffer")
    }
    try audioFile.read(into: buffer)

    guard let floatData = buffer.floatChannelData else {
        fatalError("Cannot read float channel data")
    }

    let sourceSR = Int(format.sampleRate)
    let channelCount = Int(format.channelCount)
    let sampleCount = Int(buffer.frameLength)

    // Mix to mono if stereo
    var monoSamples: [Float]
    if channelCount == 1 {
        monoSamples = Array(UnsafeBufferPointer(start: floatData[0], count: sampleCount))
    } else {
        monoSamples = [Float](repeating: 0, count: sampleCount)
        for ch in 0..<channelCount {
            let chData = floatData[ch]
            for i in 0..<sampleCount {
                monoSamples[i] += chData[i]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<sampleCount {
            monoSamples[i] *= scale
        }
    }

    // Resample to 16kHz if needed
    if sourceSR != 16000 {
        monoSamples = resampleLinear(monoSamples, from: sourceSR, to: 16000)
    }

    return (monoSamples, 16000)
}

func resampleLinear(_ samples: [Float], from sourceSR: Int, to targetSR: Int) -> [Float] {
    guard sourceSR != targetSR, !samples.isEmpty else { return samples }
    let ratio = Double(sourceSR) / Double(targetSR)
    let outputCount = Int(Double(samples.count) / ratio)
    var output = [Float](repeating: 0, count: outputCount)
    for i in 0..<outputCount {
        let srcIdx = Double(i) * ratio
        let idx0 = Int(srcIdx)
        let frac = Float(srcIdx - Double(idx0))
        let idx1 = min(idx0 + 1, samples.count - 1)
        output[i] = samples[idx0] * (1 - frac) + samples[idx1] * frac
    }
    return output
}

// MARK: - Timing Helper

struct StageTimer {
    var stages: [(name: String, duration: TimeInterval)] = []
    private var currentName: String?
    private var currentStart: Date?

    mutating func start(_ name: String) {
        if let prevName = currentName, let prevStart = currentStart {
            stages.append((prevName, Date().timeIntervalSince(prevStart)))
        }
        currentName = name
        currentStart = Date()
    }

    mutating func stop() {
        if let name = currentName, let start = currentStart {
            stages.append((name, Date().timeIntervalSince(start)))
        }
        currentName = nil
        currentStart = nil
    }

    func printReport(totalAudioDuration: TimeInterval) {
        let totalTime = stages.reduce(0.0) { $0 + $1.duration }
        print("\n=== TIMING REPORT ===")
        for (name, duration) in stages {
            let pct = totalTime > 0 ? (duration / totalTime) * 100 : 0
            print("  \(name): \(String(format: "%.2f", duration))s (\(String(format: "%.1f", pct))%)")
        }
        print("  ─────────────────────")
        print("  TOTAL: \(String(format: "%.2f", totalTime))s")
        print("  Audio duration: \(String(format: "%.1f", totalAudioDuration))s")
        let rtfx = totalTime > 0 ? totalAudioDuration / totalTime : 0
        print("  RTFx: \(String(format: "%.1f", rtfx))x realtime")
    }
}

// MARK: - Result Types

struct WordTiming: Codable {
    let word: String
    let startTime: Double
    let endTime: Double
    let segmentIndex: Int
}

struct SegmentResult: Codable {
    let index: Int
    let startTime: Double
    let endTime: Double
    let transcript: String
    let words: [WordTiming]
}

struct BenchmarkResult: Codable {
    let audioFile: String
    let audioDuration: Double
    let totalTime: Double
    let rtfx: Double
    let stages: [String: Double]
    let segmentCount: Int
    let wordCount: Int
    let segments: [SegmentResult]
}

// MARK: - Top-level Entry Point

do {
    try await run()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}

// MARK: - Main Pipeline

func run() async throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("Usage: integration-bench <audio-path> [--language <lang>] [--model-dir <kaldi-model-dir>] [--dict <dict-path>] [--output <json-path>]")
        print("")
        print("Pipeline: Audio → VAD (Silero) → ASR (Qwen3) → Forced Alignment (Kaldi) → JSON")
        exit(1)
    }

    let audioPath = args[1]
    var language = "Russian"
    var kaldiModelDir = "/Volumes/DATA/mfa_models/russian/russian_mfa/russian_mfa"
    var dictPath = NSString("~/Documents/MFA/pretrained_models/dictionary/russian_mfa.dict").expandingTildeInPath
    var outputPath: String?

    // Parse optional args
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--language":
            i += 1
            if i < args.count { language = args[i] }
        case "--model-dir":
            i += 1
            if i < args.count { kaldiModelDir = args[i] }
        case "--dict":
            i += 1
            if i < args.count { dictPath = args[i] }
        case "--output":
            i += 1
            if i < args.count { outputPath = args[i] }
        default:
            break
        }
        i += 1
    }

    print("╔══════════════════════════════════════════════╗")
    print("║  Integration Benchmark: VAD → ASR → Align   ║")
    print("╚══════════════════════════════════════════════╝")
    print("")
    print("Audio: \(audioPath)")
    print("Language: \(language)")
    print("Kaldi model: \(kaldiModelDir)")
    print("Dictionary: \(dictPath)")
    print("")

    var timer = StageTimer()

    // ── Stage 1: Load Audio ──
    timer.start("1_audio_load")
    let audioURL = URL(fileURLWithPath: audioPath)
    let (samples, sampleRate) = try loadAudioAsFloat(audioURL)
    let audioDuration = Double(samples.count) / Double(sampleRate)
    print("✓ Audio loaded: \(String(format: "%.1f", audioDuration))s, \(sampleRate)Hz, \(samples.count) samples")

    // ── Stage 2: VAD Segmentation (Silero via FluidAudio) ──
    timer.start("2_vad")
    let vadManager = try await VadManager()
    let vadConfig = VadSegmentationConfig(
        minSpeechDuration: 0.25,
        minSilenceDuration: 0.5,
        maxSpeechDuration: 30.0,
        speechPadding: 0.15
    )
    let vadSegments = try await vadManager.segmentSpeech(samples, config: vadConfig)
    print("✓ VAD: \(vadSegments.count) speech segments detected")
    for (idx, seg) in vadSegments.prefix(5).enumerated() {
        print("  [\(idx)] \(String(format: "%.2f", seg.startTime))s - \(String(format: "%.2f", seg.endTime))s (\(String(format: "%.1f", seg.duration))s)")
    }
    if vadSegments.count > 5 { print("  ... and \(vadSegments.count - 5) more") }

    // ── Stage 3: ASR Transcription (Qwen3-ASR via mlx-audio-swift) ──
    timer.start("3_asr_load")
    print("\nLoading Qwen3-ASR model...")
    let asrModel = try await Qwen3ASRModel.fromPretrained("mlx-community/Qwen3-ASR-0.6B-4bit")
    timer.start("3_asr_inference")

    var segmentTranscripts: [(index: Int, startTime: Double, endTime: Double, text: String)] = []

    for (idx, seg) in vadSegments.enumerated() {
        let startSample = seg.startSample(sampleRate: sampleRate)
        let endSample = min(seg.endSample(sampleRate: sampleRate), samples.count)
        guard endSample > startSample else { continue }

        let segSamples = Array(samples[startSample..<endSample])
        let mlxAudio = MLXArray(segSamples)

        let params = STTGenerateParameters(
            maxTokens: 4096,
            temperature: 0.0,
            language: language,
            chunkDuration: 1200.0,
            minChunkDuration: 1.0
        )
        let output = asrModel.generate(audio: mlxAudio, generationParameters: params)
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            segmentTranscripts.append((idx, seg.startTime, seg.endTime, text))
        }

        if (idx + 1) % 10 == 0 || idx == vadSegments.count - 1 {
            print("  ASR progress: \(idx + 1)/\(vadSegments.count) segments")
        }
    }
    print("✓ ASR: \(segmentTranscripts.count) segments transcribed")

    // ── Stage 4: Forced Alignment (Kaldi via KaldiAlignerKit) ──
    timer.start("4_align_load")
    print("\nLoading Kaldi alignment model...")
    let aligner = try KaldiAligner(modelDir: kaldiModelDir, dictPath: dictPath)
    timer.start("4_align_inference")

    var allSegmentResults: [SegmentResult] = []
    var totalWords = 0
    var alignFailCount = 0

    for (idx, seg) in segmentTranscripts.enumerated() {
        let startSample = Int(seg.startTime * Double(sampleRate))
        let endSample = min(Int(seg.endTime * Double(sampleRate)), samples.count)
        guard endSample > startSample else { continue }

        let segSamples = Array(samples[startSample..<endSample])

        do {
            let wordAlignments = try aligner.align(
                audio: segSamples,
                sampleRate: sampleRate,
                transcript: seg.text
            )

            let words = wordAlignments.map { wa in
                WordTiming(
                    word: wa.word,
                    startTime: Double(wa.startTime) + seg.startTime,
                    endTime: Double(wa.endTime) + seg.startTime,
                    segmentIndex: seg.index
                )
            }

            allSegmentResults.append(SegmentResult(
                index: seg.index,
                startTime: seg.startTime,
                endTime: seg.endTime,
                transcript: seg.text,
                words: words
            ))

            totalWords += words.count
        } catch {
            alignFailCount += 1
            // Still record the segment with empty words
            allSegmentResults.append(SegmentResult(
                index: seg.index,
                startTime: seg.startTime,
                endTime: seg.endTime,
                transcript: seg.text,
                words: []
            ))

            if alignFailCount <= 5 {
                print("  ⚠ Alignment failed for segment \(seg.index): \(error)")
            }
        }

        if (idx + 1) % 20 == 0 || idx == segmentTranscripts.count - 1 {
            print("  Align progress: \(idx + 1)/\(segmentTranscripts.count) segments, \(totalWords) words")
        }
    }
    timer.stop()

    print("✓ Alignment: \(totalWords) words across \(allSegmentResults.count) segments")
    if alignFailCount > 0 {
        print("  ⚠ \(alignFailCount) segments failed alignment")
    }

    // ── Results ──
    timer.printReport(totalAudioDuration: audioDuration)

    let stagesDict = Dictionary(uniqueKeysWithValues: timer.stages.map { ($0.name, $0.duration) })
    let totalTime = timer.stages.reduce(0.0) { $0 + $1.duration }

    let result = BenchmarkResult(
        audioFile: audioPath,
        audioDuration: audioDuration,
        totalTime: totalTime,
        rtfx: totalTime > 0 ? audioDuration / totalTime : 0,
        stages: stagesDict,
        segmentCount: allSegmentResults.count,
        wordCount: totalWords,
        segments: allSegmentResults
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(result)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
        fatalError("Failed to encode JSON")
    }

    if let outPath = outputPath {
        try jsonString.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("\nResults saved to: \(outPath)")
    } else {
        let defaultOutput = "/Volumes/DATA/alignment-benchmark/results/integration_pipeline_\(language.lowercased()).json"
        try jsonString.write(toFile: defaultOutput, atomically: true, encoding: .utf8)
        print("\nResults saved to: \(defaultOutput)")
    }

    // Print sample words from first few segments
    print("\n=== SAMPLE OUTPUT (first 3 segments) ===")
    for seg in allSegmentResults.prefix(3) {
        print("\n[\(seg.index)] \(String(format: "%.2f", seg.startTime))s - \(String(format: "%.2f", seg.endTime))s")
        print("  Text: \(seg.transcript.prefix(80))...")
        for w in seg.words.prefix(5) {
            print("  \(String(format: "%7.3f", w.startTime)) - \(String(format: "%7.3f", w.endTime))  \(w.word)")
        }
        if seg.words.count > 5 { print("  ... +\(seg.words.count - 5) more words") }
    }
}
