import Foundation

/// Paths to a downloaded MFA model (acoustic model directory + pronunciation dictionary).
public struct MFAModelPaths: Sendable {
    public let modelDir: String
    public let dictPath: String
}

/// Errors during model download or extraction.
public enum ModelDownloadError: Error, CustomStringConvertible {
    case downloadFailed(String)
    case extractionFailed(String)
    case modelValidationFailed(String)

    public var description: String {
        switch self {
        case let .downloadFailed(msg): "Download failed: \(msg)"
        case let .extractionFailed(msg): "Extraction failed: \(msg)"
        case let .modelValidationFailed(msg): "Model validation failed: \(msg)"
        }
    }
}

/// Downloads MFA acoustic models and dictionaries from GitHub releases.
///
/// Models are cached in `~/Library/Caches/KaldiAlignerKit/` by default.
/// Re-downloading is skipped if the model already exists in cache.
///
/// Usage:
/// ```swift
/// let paths = try await MFAModelDownloader.download("english_mfa")
/// let aligner = try KaldiAligner(modelDir: paths.modelDir, dictPath: paths.dictPath)
/// ```
public enum MFAModelDownloader {
    /// Known model versions (latest tested).
    /// Override with the `version` parameter if needed.
    private static let knownVersions: [String: String] = [
        "english_mfa": "3.1.0",
        "russian_mfa": "3.1.0"
    ]

    private static let baseURL = "https://github.com/MontrealCorpusTools/mfa-models/releases/download"

    private static let requiredFiles = ["tree", "lda.mat", "phones.txt"]
    private static let modelFiles = ["final.alimdl", "final.mdl"]

    /// Download an MFA acoustic model and dictionary.
    ///
    /// - Parameters:
    ///   - name: Model name, e.g. `"english_mfa"`, `"russian_mfa"`
    ///   - version: Model version. Uses known latest if nil.
    ///   - cacheDir: Cache directory. Default: `~/Library/Caches/KaldiAlignerKit/`
    /// - Returns: Paths to the extracted model directory and dictionary file.
    public static func download(
        _ name: String,
        version: String? = nil,
        cacheDir: URL? = nil
    ) async throws -> MFAModelPaths {
        let ver = version ?? knownVersions[name] ?? "3.1.0"
        let cache = cacheDir ?? defaultCacheDir()
        let modelDir = cache.appendingPathComponent("acoustic/\(name)/v\(ver)/\(name)")
        let dictPath = cache.appendingPathComponent("dictionary/\(name)/v\(ver)/\(name).dict")

        let modelReady = validateModelDir(modelDir.path)
        let dictReady = FileManager.default.fileExists(atPath: dictPath.path)

        if modelReady, dictReady {
            return MFAModelPaths(modelDir: modelDir.path, dictPath: dictPath.path)
        }

        if !modelReady {
            let acousticURL = "\(baseURL)/acoustic-\(name)-v\(ver)/\(name).zip"
            let extractDir = modelDir.deletingLastPathComponent()
            try createDir(extractDir)
            try await downloadAndExtractZip(from: acousticURL, to: extractDir)

            guard validateModelDir(modelDir.path) else {
                throw ModelDownloadError.modelValidationFailed(
                    "Extracted model missing required files at \(modelDir.path)"
                )
            }
        }

        if !dictReady {
            let dictURL = "\(baseURL)/dictionary-\(name)-v\(ver)/\(name).dict"
            let dictDir = dictPath.deletingLastPathComponent()
            try createDir(dictDir)
            try await downloadFile(from: dictURL, to: dictPath)
        }

        return MFAModelPaths(modelDir: modelDir.path, dictPath: dictPath.path)
    }

    // MARK: - Private

    private static func defaultCacheDir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("KaldiAlignerKit")
    }

    private static func createDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func validateModelDir(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }

        let hasModelFile = modelFiles.contains { fm.fileExists(atPath: "\(path)/\($0)") }
        guard hasModelFile else { return false }

        return requiredFiles.allSatisfy { fm.fileExists(atPath: "\(path)/\($0)") }
    }

    private static func downloadFile(from urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw ModelDownloadError.downloadFailed("Invalid URL: \(urlString)")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelDownloadError.downloadFailed("HTTP \(code) for \(urlString)")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private static func downloadAndExtractZip(from urlString: String, to extractDir: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw ModelDownloadError.downloadFailed("Invalid URL: \(urlString)")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelDownloadError.downloadFailed("HTTP \(code) for \(urlString)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", tempURL.path, extractDir.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ModelDownloadError.extractionFailed("ditto exit \(process.terminationStatus): \(stderr)")
        }
    }
}

// MARK: - Convenience on KaldiAligner

public extension KaldiAligner {
    /// Download an MFA model and create an aligner in one step.
    ///
    /// ```swift
    /// let aligner = try await KaldiAligner.withModel("english_mfa")
    /// let words = try aligner.align(audio: samples, sampleRate: 16000, transcript: "hello world")
    /// ```
    static func withModel(
        _ name: String,
        version: String? = nil,
        cacheDir: URL? = nil
    ) async throws -> KaldiAligner {
        let paths = try await MFAModelDownloader.download(name, version: version, cacheDir: cacheDir)
        return try KaldiAligner(modelDir: paths.modelDir, dictPath: paths.dictPath)
    }
}
