import KaldiCore

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
    ///   - modelDir: Path to extracted MFA model (contains final.mdl, tree, lda.mat, phones.txt)
    ///   - dictPath: Path to pronunciation dictionary (word\tphone1 phone2...)
    public init(modelDir: String, dictPath: String) throws {
        guard let h = kaldi_aligner_create(modelDir, dictPath) else {
            throw AlignerError.initFailed("kaldi_aligner_create returned nil")
        }
        if let err = kaldi_aligner_last_error(h) {
            let msg = String(cString: err)
            kaldi_aligner_destroy(h)
            throw AlignerError.initFailed(msg)
        }
        self.handle = h
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
            for i in 0..<Int(cResult.count) {
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
