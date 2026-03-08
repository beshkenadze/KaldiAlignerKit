import Foundation
@_implementationOnly import KaldiCore

public struct WordAlignment {
    public let word: String
    public let startTime: Float
    public let endTime: Float
}

public enum AlignerError: Error {
    case initFailed(String)
    case alignmentFailed(String)
}

public final class KaldiAligner {
    private let handle: KaldiAlignerRef

    /// Create aligner from extracted MFA model directory and dictionary file.
    /// - Parameters:
    ///   - modelDir: Path to extracted MFA model (contains tree, lda.mat, phones.txt, and final.alimdl or final.mdl)
    ///   - dictPath: Path to pronunciation dictionary (word\tphone1 phone2...)
    public convenience init(modelDir: String, dictPath: String) throws {
        try self.init(
            modelDir: URL(fileURLWithPath: modelDir, isDirectory: true),
            dictURL: URL(fileURLWithPath: dictPath)
        )
    }

    public init(modelDir: URL, dictURL: URL) throws {
        let modelBinaryURL: URL
        do {
            modelBinaryURL = try ModelArtifacts.validateModelDirectory(at: modelDir)
            try ModelArtifacts.validateDictionary(at: dictURL)
        } catch {
            throw AlignerError.initFailed(String(describing: error))
        }

        guard let h = kaldi_aligner_create(modelDir.path, modelBinaryURL.path, dictURL.path) else {
            throw AlignerError.initFailed("kaldi_aligner_create returned nil")
        }
        if let err = kaldi_aligner_last_error(h) {
            let msg = String(cString: err)
            kaldi_aligner_destroy(h)
            throw AlignerError.initFailed(msg)
        }
        handle = h
    }

    deinit {
        kaldi_aligner_destroy(handle)
    }

    /// Perform forced alignment.
    /// - Parameters:
    ///   - audio: Raw PCM float samples (mono, 16kHz recommended)
    ///   - sampleRate: Sample rate in Hz
    ///   - transcript: Space-separated words to align
    /// - Returns: Array of word alignments with time boundaries
    public func align(
        audio: [Float],
        sampleRate: Int,
        transcript: String
    ) throws -> [WordAlignment] {
        let cResult = audio.withUnsafeBufferPointer { buffer in
            kaldi_aligner_align(
                handle,
                buffer.baseAddress,
                Int32(buffer.count),
                Int32(sampleRate),
                transcript
            )
        }

        defer { kaldi_aligner_free_result(cResult) }

        if let errPtr = cResult.error {
            throw AlignerError.alignmentFailed(String(cString: errPtr))
        }

        var result: [WordAlignment] = []
        if let intervals = cResult.intervals {
            for i in 0 ..< Int(cResult.count) {
                let item = intervals[i]
                if let wordPtr = item.word {
                    result.append(WordAlignment(
                        word: String(cString: wordPtr),
                        startTime: item.start_time,
                        endTime: item.end_time
                    ))
                }
            }
        }
        return result
    }
}
