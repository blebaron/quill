import Foundation
import XCTest
@testable import quill

final class RetranscribeTests: XCTestCase {
    private func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-retranscribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeMeta(_ files: [String: String], in dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["files": files])
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    func testManualRetryRejectsMissingTrackAndPreservesTranscript() async throws {
        let dir = try session()
        try writeMeta(["mic": "mic.caf", "system": "system.caf"], in: dir)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.caf"))
        try Data("old transcript".utf8).write(to: dir.appendingPathComponent("transcript.json"))

        do {
            try await TranscriptionCoordinator().retranscribe(dir)
            XCTFail("missing system audio must fail before preparing the model")
        } catch {
            XCTAssertTrue(String(describing: error).contains("system.caf"))
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8), "old transcript")
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("manual retranscribe requested"))
        XCTAssertTrue(log.contains("manual retranscribe failed"))
    }

    func testManualRetryRejectsEmptyTrackListAndEmptyAudio() throws {
        let dir = try session()
        try writeMeta([:], in: dir)
        XCTAssertThrowsError(try SessionMeta.read(from: dir).validateSourceAudio(in: dir))

        try writeMeta(["mic": "mic.caf"], in: dir)
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        XCTAssertThrowsError(try SessionMeta.read(from: dir).validateSourceAudio(in: dir))
    }

    func testPublishingReplacesOutputsAndRemovesStaleSpeakerSidecar() throws {
        let dir = try session()
        try Data("source audio".utf8).write(to: dir.appendingPathComponent("mic.caf"))
        try Data("metadata".utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data("stale".utf8).write(to: dir.appendingPathComponent("speakers.json"))
        try GeneratedArtifacts.publish(
            in: dir, transcriptJSON: Data("new json".utf8),
            transcriptMarkdown: Data("new md".utf8), speakersJSON: nil
        )
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8), "new json")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8), "new md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("speakers.json").path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("mic.caf"), encoding: .utf8), "source audio")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8), "metadata")

        try GeneratedArtifacts.publish(
            in: dir, transcriptJSON: Data("newer json".utf8),
            transcriptMarkdown: Data("newer md".utf8), speakersJSON: Data("new speakers".utf8)
        )
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("speakers.json"), encoding: .utf8), "new speakers")
    }

    func testPublishingFailureRestoresPriorTranscript() throws {
        let dir = try session()
        try Data("old json".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        try Data("old md".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        // Fail the second promotion after JSON was replaced, then verify
        // rollback restores the old JSON without changing markdown.
        XCTAssertThrowsError(try GeneratedArtifacts.publish(
            in: dir, transcriptJSON: Data("new json".utf8),
            transcriptMarkdown: Data("new md".utf8), speakersJSON: nil,
            promote: { source, destination in
                if destination.lastPathComponent == "transcript.md" {
                    throw NSError(domain: "quill.test", code: 1)
                }
                try GeneratedArtifacts.atomicRename(source, to: destination)
            }
        ))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8), "old json")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8), "old md")
    }

    func testPublishingWillNotDeleteNonFileAtArtifactPath() throws {
        let dir = try session()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("speakers.json"), withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try GeneratedArtifacts.publish(
            in: dir, transcriptJSON: Data("new json".utf8),
            transcriptMarkdown: Data("new md".utf8), speakersJSON: nil
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(try dir.appendingPathComponent("speakers.json").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
}
