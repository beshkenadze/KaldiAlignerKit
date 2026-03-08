import Darwin
import Foundation
@_implementationOnly import ZIPFoundation

/// Paths to a downloaded MFA model (acoustic model directory + pronunciation dictionary).
public struct MFAModelPaths: Sendable {
    public let modelDirURL: URL
    public let dictURL: URL

    public var modelDir: String {
        modelDirURL.path
    }

    public var dictPath: String {
        dictURL.path
    }

    public init(modelDirURL: URL, dictURL: URL) {
        self.modelDirURL = modelDirURL
        self.dictURL = dictURL
    }

    public init(modelDir: String, dictPath: String) {
        self.init(
            modelDirURL: URL(fileURLWithPath: modelDir, isDirectory: true),
            dictURL: URL(fileURLWithPath: dictPath)
        )
    }
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

struct DownloaderTestHooks {
    var downloadFile: @Sendable (URL, URL) async throws -> Void
    var extractArchive: @Sendable (URL, URL) async throws -> Void

    static let live = DownloaderTestHooks(
        downloadFile: { sourceURL, destinationURL in
            let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ModelDownloadError.downloadFailed("HTTP \(code) for \(sourceURL.absoluteString)")
            }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        },
        extractArchive: { sourceURL, destinationURL in
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.unzipItem(at: sourceURL, to: destinationURL)
        }
    )
}

private actor DownloaderHookStore {
    private var hooks = DownloaderTestHooks.live

    func withHooks<T: Sendable>(
        _ newHooks: DownloaderTestHooks,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let previous = hooks
        hooks = newHooks
        defer { hooks = previous }
        return try await operation()
    }

    func currentHooks() -> DownloaderTestHooks {
        hooks
    }
}

private actor DownloadCoordinator {
    private var inFlightTasks: [String: Task<MFAModelPaths, Error>] = [:]

    func perform(
        key: String,
        operation: @escaping @Sendable () async throws -> MFAModelPaths
    ) async throws -> MFAModelPaths {
        if let task = inFlightTasks[key] {
            return try await task.value
        }

        let task = Task(operation: operation)
        inFlightTasks[key] = task
        defer { inFlightTasks[key] = nil }
        return try await task.value
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
    private static let hooks = DownloaderHookStore()
    private static let coordinator = DownloadCoordinator()

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
        let modelDir = cache.appendingPathComponent("acoustic/\(name)/v\(ver)/\(name)", isDirectory: true)
        let dictURL = cache.appendingPathComponent("dictionary/\(name)/v\(ver)/\(name).dict")
        let key = "\(name)-\(ver)-\(cache.path)"

        return try await coordinator.perform(key: key) {
            try await withModelLock(name: name, version: ver, cacheDir: cache) {
                if let ready = try cachedPathsIfReady(modelDir: modelDir, dictURL: dictURL) {
                    return ready
                }

                let activeHooks = await hooks.currentHooks()

                if try !isModelReady(at: modelDir) {
                    try await downloadModel(
                        name: name,
                        version: ver,
                        cacheDir: cache,
                        finalModelDir: modelDir,
                        hooks: activeHooks
                    )
                }

                if !isDictionaryReady(at: dictURL) {
                    try await downloadDictionary(
                        name: name,
                        version: ver,
                        cacheDir: cache,
                        finalDictURL: dictURL,
                        hooks: activeHooks
                    )
                }

                guard let ready = try cachedPathsIfReady(modelDir: modelDir, dictURL: dictURL) else {
                    throw ModelDownloadError.modelValidationFailed(
                        "Downloaded artifacts are not valid for \(name) v\(ver)"
                    )
                }

                return ready
            }
        }
    }

    static func withTestHooks<T: Sendable>(
        _ testHooks: DownloaderTestHooks,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await hooks.withHooks(testHooks, operation: operation)
    }

    // MARK: - Private

    private static func defaultCacheDir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("KaldiAlignerKit", isDirectory: true)
    }

    private static func cachedPathsIfReady(
        modelDir: URL,
        dictURL: URL
    ) throws -> MFAModelPaths? {
        guard try isModelReady(at: modelDir), isDictionaryReady(at: dictURL) else {
            return nil
        }
        return MFAModelPaths(modelDirURL: modelDir, dictURL: dictURL)
    }

    private static func isModelReady(at url: URL) throws -> Bool {
        do {
            _ = try ModelArtifacts.validateModelDirectory(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func isDictionaryReady(at url: URL) -> Bool {
        do {
            try ModelArtifacts.validateDictionary(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func downloadModel(
        name: String,
        version: String,
        cacheDir: URL,
        finalModelDir: URL,
        hooks: DownloaderTestHooks
    ) async throws {
        let acousticURL = try validatedURL(
            "\(baseURL)/acoustic-\(name)-v\(version)/\(name).zip"
        )
        let tempRoot = cacheDir.appendingPathComponent(
            "tmp/\(name)-\(version)-\(UUID().uuidString)",
            isDirectory: true
        )
        let archiveURL = tempRoot.appendingPathComponent("\(name).zip")
        let extractURL = tempRoot.appendingPathComponent("extract", isDirectory: true)

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        do {
            try await hooks.downloadFile(acousticURL, archiveURL)
            try await hooks.extractArchive(archiveURL, extractURL)

            let extractedModelDir = extractURL.appendingPathComponent(name, isDirectory: true)
            _ = try validatedModelURL(at: extractedModelDir)

            try FileManager.default.createDirectory(
                at: finalModelDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalModelDir.path) {
                try FileManager.default.removeItem(at: finalModelDir)
            }
            try FileManager.default.moveItem(at: extractedModelDir, to: finalModelDir)
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.extractionFailed(error.localizedDescription)
        }
    }

    private static func downloadDictionary(
        name: String,
        version: String,
        cacheDir: URL,
        finalDictURL: URL,
        hooks: DownloaderTestHooks
    ) async throws {
        let dictionaryURL = try validatedURL(
            "\(baseURL)/dictionary-\(name)-v\(version)/\(name).dict"
        )
        let tempRoot = cacheDir.appendingPathComponent(
            "tmp/\(name)-\(version)-dict-\(UUID().uuidString)",
            isDirectory: true
        )
        let tempDictURL = tempRoot.appendingPathComponent("\(name).dict")

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try await hooks.downloadFile(dictionaryURL, tempDictURL)
        do {
            try ModelArtifacts.validateDictionary(at: tempDictURL)
        } catch {
            throw ModelDownloadError.modelValidationFailed(String(describing: error))
        }

        try FileManager.default.createDirectory(
            at: finalDictURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: finalDictURL.path) {
            try FileManager.default.removeItem(at: finalDictURL)
        }
        try FileManager.default.moveItem(at: tempDictURL, to: finalDictURL)
    }

    private static func validatedModelURL(at url: URL) throws -> URL {
        do {
            return try ModelArtifacts.validateModelDirectory(at: url)
        } catch {
            throw ModelDownloadError.modelValidationFailed(String(describing: error))
        }
    }

    private static func validatedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw ModelDownloadError.downloadFailed("Invalid URL: \(string)")
        }
        return url
    }

    private static func withModelLock<T>(
        name: String,
        version: String,
        cacheDir: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let lockDir = cacheDir.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lockURL = lockDir.appendingPathComponent("\(name)-\(version).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw ModelDownloadError.downloadFailed("Unable to open lock file at \(lockURL.path)")
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw ModelDownloadError.downloadFailed("Unable to acquire lock for \(name) v\(version)")
        }
        defer { flock(fd, LOCK_UN) }

        return try await operation()
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
        return try KaldiAligner(modelDir: paths.modelDirURL, dictURL: paths.dictURL)
    }
}
