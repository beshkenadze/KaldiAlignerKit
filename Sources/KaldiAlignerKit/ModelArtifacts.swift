import Foundation

enum ModelArtifactError: Error, CustomStringConvertible {
    case missingDirectory(URL)
    case missingFile(URL)
    case invalidDictionary(URL)
    case missingModelBinary(URL)

    var description: String {
        switch self {
        case let .missingDirectory(url):
            "Model directory does not exist: \(url.path)"
        case let .missingFile(url):
            "Required model artifact is missing: \(url.path)"
        case let .invalidDictionary(url):
            "Dictionary file does not exist: \(url.path)"
        case let .missingModelBinary(url):
            "Model directory is missing final.alimdl or final.mdl: \(url.path)"
        }
    }
}

enum ModelArtifacts {
    private static let requiredFiles = ["tree", "lda.mat", "phones.txt"]
    private static let modelFilePriority = ["final.alimdl", "final.mdl"]

    static func validateModelDirectory(at url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ModelArtifactError.missingDirectory(url)
        }

        for fileName in requiredFiles {
            let fileURL = url.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ModelArtifactError.missingFile(fileURL)
            }
        }

        for fileName in modelFilePriority {
            let modelURL = url.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: modelURL.path) {
                return modelURL
            }
        }

        throw ModelArtifactError.missingModelBinary(url)
    }

    static func validateDictionary(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ModelArtifactError.invalidDictionary(url)
        }
    }
}
