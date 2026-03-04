import XCTest
@testable import KaldiAlignerKit

final class KaldiAlignerKitTests: XCTestCase {
    func testAlignerInitFailsWithBadPath() {
        XCTAssertThrowsError(
            try KaldiAligner(modelDir: "/nonexistent", dictPath: "/nonexistent")
        ) { error in
            guard case AlignerError.initFailed(let msg) = error else {
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
}
