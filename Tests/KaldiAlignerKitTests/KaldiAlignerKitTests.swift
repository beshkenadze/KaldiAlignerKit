import Foundation
@testable import KaldiAlignerKit
import XCTest

final class KaldiAlignerKitTests: XCTestCase {
    func testAlignerInitFailsWithBadPath() {
        XCTAssertThrowsError(
            try KaldiAligner(modelDir: "/nonexistent", dictPath: "/nonexistent")
        ) { error in
            guard case let AlignerError.initFailed(msg) = error else {
                XCTFail("Expected initFailed, got \(error)")
                return
            }
            XCTAssertFalse(msg.isEmpty)
        }
    }

    func testWordAlignmentStruct() {
        let alignment = WordAlignment(word: "test", startTime: 0.5, endTime: 1.2)
        XCTAssertEqual(alignment.word, "test")
        XCTAssertEqual(alignment.startTime, 0.5, accuracy: 0.001)
        XCTAssertEqual(alignment.endTime, 1.2, accuracy: 0.001)
    }

    func testModelArtifactsPrefersFinalAliModel() throws {
        try withTemporaryDirectory { tempDir in
            let modelDir = tempDir.appendingPathComponent("model")
            let dictURL = tempDir.appendingPathComponent("lexicon.dict")

            try createModelDirectory(
                at: modelDir,
                modelFiles: ["final.alimdl", "final.mdl"]
            )
            try "hello HH AH L OW\n".write(to: dictURL, atomically: true, encoding: .utf8)

            let resolvedURL = try ModelArtifacts.validateModelDirectory(at: modelDir)
            try ModelArtifacts.validateDictionary(at: dictURL)

            XCTAssertEqual(resolvedURL.lastPathComponent, "final.alimdl")
        }
    }

    func testModelArtifactsFallsBackToFinalModel() throws {
        try withTemporaryDirectory { tempDir in
            let modelDir = tempDir.appendingPathComponent("model")
            try createModelDirectory(at: modelDir, modelFiles: ["final.mdl"])

            let resolvedURL = try ModelArtifacts.validateModelDirectory(at: modelDir)

            XCTAssertEqual(resolvedURL.lastPathComponent, "final.mdl")
        }
    }

    func testModelArtifactsReportsMissingRequiredFile() throws {
        try withTemporaryDirectory { tempDir in
            let modelDir = tempDir.appendingPathComponent("model")
            try createModelDirectory(
                at: modelDir,
                modelFiles: ["final.alimdl"],
                requiredFiles: ["tree", "lda.mat"]
            )

            XCTAssertThrowsError(try ModelArtifacts.validateModelDirectory(at: modelDir)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("phones.txt"))
                XCTAssertTrue(message.contains(modelDir.path))
            }
        }
    }

    func testURLInitializerMatchesStringInitializerForValidationErrors() throws {
        try withTemporaryDirectory { tempDir in
            let modelDir = tempDir.appendingPathComponent("model")
            let dictURL = tempDir.appendingPathComponent("lexicon.dict")
            try createModelDirectory(
                at: modelDir,
                modelFiles: ["final.alimdl"],
                requiredFiles: ["tree", "phones.txt"]
            )
            try "hello HH AH L OW\n".write(to: dictURL, atomically: true, encoding: .utf8)

            let stringMessage = alignerInitFailureMessage {
                try KaldiAligner(modelDir: modelDir.path, dictPath: dictURL.path)
            }
            let urlMessage = alignerInitFailureMessage {
                try KaldiAligner(modelDir: modelDir, dictURL: dictURL)
            }

            XCTAssertEqual(stringMessage, urlMessage)
            XCTAssertTrue(urlMessage.contains("lda.mat"))
        }
    }

    func testDownloaderReturnsURLAliasesForValidatedCache() async throws {
        try await withTemporaryDirectory { tempDir in
            let modelDir = tempDir.appendingPathComponent("acoustic/english_mfa/vtest/english_mfa")
            let dictURL = tempDir.appendingPathComponent("dictionary/english_mfa/vtest/english_mfa.dict")
            try createModelDirectory(at: modelDir, modelFiles: ["final.alimdl"])
            try FileManager.default.createDirectory(
                at: dictURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "hello HH AH L OW\n".write(to: dictURL, atomically: true, encoding: .utf8)

            let hooks = DownloaderTestHooks(
                downloadFile: { _, _ in XCTFail("downloadFile should not be called when cache is valid") },
                extractArchive: { _, _ in XCTFail("extractArchive should not be called when cache is valid") }
            )

            let paths = try await MFAModelDownloader.withTestHooks(hooks) {
                try await MFAModelDownloader.download("english_mfa", version: "test", cacheDir: tempDir)
            }

            XCTAssertEqual(paths.modelDirURL.path, modelDir.path)
            XCTAssertEqual(paths.dictURL.path, dictURL.path)
            XCTAssertEqual(paths.modelDir, modelDir.path)
            XCTAssertEqual(paths.dictPath, dictURL.path)
        }
    }

    func testDownloaderCleansUpTemporaryArtifactsAfterExtractionFailure() async throws {
        try await withTemporaryDirectory { tempDir in
            let expectedParent = tempDir.appendingPathComponent("acoustic/english_mfa/vtest")
            let hooks = DownloaderTestHooks(
                downloadFile: { _, destination in
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("dict".utf8).write(to: destination)
                },
                extractArchive: { _, destination in
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try Data("partial".utf8).write(to: destination.appendingPathComponent("phones.txt"))
                    throw ModelDownloadError.extractionFailed("boom")
                }
            )

            do {
                _ = try await MFAModelDownloader.withTestHooks(hooks) {
                    try await MFAModelDownloader.download("english_mfa", version: "test", cacheDir: tempDir)
                }
                XCTFail("Expected download to fail")
            } catch let ModelDownloadError.extractionFailed(message) {
                XCTAssertEqual(message, "boom")
            }

            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: expectedParent.appendingPathComponent("english_mfa").path
                )
            )

            let remainingChildren = try? FileManager.default.contentsOfDirectory(
                at: expectedParent,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(remainingChildren?.count ?? 0, 0)
        }
    }

    func testDownloaderSerializesConcurrentDownloadsForSameModel() async throws {
        try await withTemporaryDirectory { tempDir in
            let counter = DownloadCounter()
            let hooks = DownloaderTestHooks(
                downloadFile: { _, destination in
                    if destination.pathExtension == "dict" {
                        await counter.recordDictionaryDownload()
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("dict".utf8).write(to: destination)
                },
                extractArchive: { _, destination in
                    await counter.recordModelExtraction()
                    try createModelDirectoryFixture(
                        at: destination.appendingPathComponent("english_mfa"),
                        modelFiles: ["final.alimdl"]
                    )
                }
            )

            let results = try await MFAModelDownloader.withTestHooks(hooks) {
                async let first = MFAModelDownloader.download("english_mfa", version: "test", cacheDir: tempDir)
                async let second = MFAModelDownloader.download("english_mfa", version: "test", cacheDir: tempDir)
                return try await [first, second]
            }

            XCTAssertEqual(results[0].modelDir, results[1].modelDir)
            XCTAssertEqual(results[0].dictPath, results[1].dictPath)
            let modelExtractionCount = await counter.modelExtractionCount()
            let dictionaryDownloadCount = await counter.dictionaryDownloadCount()
            XCTAssertEqual(modelExtractionCount, 1)
            XCTAssertEqual(dictionaryDownloadCount, 1)
        }
    }

    private func alignerInitFailureMessage(_ build: () throws -> KaldiAligner) -> String {
        do {
            _ = try build()
            XCTFail("Expected aligner initialization to fail")
            return ""
        } catch let AlignerError.initFailed(message) {
            return message
        } catch {
            XCTFail("Expected initFailed, got \(error)")
            return ""
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try body(tempDir)
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await body(tempDir)
    }

    private func createModelDirectory(
        at url: URL,
        modelFiles: [String],
        requiredFiles: [String] = ["tree", "lda.mat", "phones.txt"]
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for requiredFile in requiredFiles {
            try Data("stub".utf8).write(to: url.appendingPathComponent(requiredFile))
        }
        for modelFile in modelFiles {
            try Data("stub".utf8).write(to: url.appendingPathComponent(modelFile))
        }
    }
}

private actor DownloadCounter {
    private var modelExtractionCountValue = 0
    private var dictionaryDownloadCountValue = 0

    func recordModelExtraction() {
        modelExtractionCountValue += 1
    }

    func recordDictionaryDownload() {
        dictionaryDownloadCountValue += 1
    }

    func modelExtractionCount() -> Int {
        modelExtractionCountValue
    }

    func dictionaryDownloadCount() -> Int {
        dictionaryDownloadCountValue
    }
}

private func createModelDirectoryFixture(
    at url: URL,
    modelFiles: [String],
    requiredFiles: [String] = ["tree", "lda.mat", "phones.txt"]
) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    for requiredFile in requiredFiles {
        try Data("stub".utf8).write(to: url.appendingPathComponent(requiredFile))
    }
    for modelFile in modelFiles {
        try Data("stub".utf8).write(to: url.appendingPathComponent(modelFile))
    }
}
