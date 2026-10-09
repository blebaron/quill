import Foundation
import XCTest
import FluidAudio
@testable import quill

final class RequestedCountSafetyTests: XCTestCase {
    private struct FakeASR: TranscriptionEngine {
        let name = "synthetic"
        let model = "no-audio-no-model"
        func prepare() async throws {}
        func release() async {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 1, text: "first synthetic turn"),
             TranscriptSegment(start: 1, end: 2, text: "second synthetic turn")]
        }
    }

    private enum SyntheticFailure: Error { case diarization }
    private let artifacts = ["transcript.json", "transcript.md", "speakers.json"]

    private func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-count-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["files": ["mic": "synthetic.m4a"]])
            .write(to: dir.appendingPathComponent("meta.json"))
        // Never decoded: the injected engines provide all observations.
        try Data("synthetic placeholder".utf8).write(to: dir.appendingPathComponent("synthetic.m4a"))
        for name in artifacts {
            try Data("original \(name)".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func timeline(_ count: Int, zeroLengthSecond: Bool = false) -> DiarizationResult {
        DiarizationResult(segments: (0..<count).map { index in
            TimedSpeakerSegment(
                speakerId: "S\(index + 1)", embedding: [], startTimeSeconds: Float(index),
                endTimeSeconds: zeroLengthSecond && index == 1 ? Float(index) : Float(index + 1),
                qualityScore: 1
            )
        })
    }

    private func assertOriginals(_ dir: URL) throws {
        for name in artifacts {
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), Data("original \(name)".utf8))
        }
        let logURL = dir.appendingPathComponent("transcribe.log")
        let log = FileManager.default.fileExists(atPath: logURL.path)
            ? try String(contentsOf: logURL, encoding: .utf8) : ""
        XCTAssertFalse(log.contains("done —"))
    }

    func testMismatchThrowsAndPreservesAllArtifacts() async throws {
        let dir = try session()
        let result = timeline(1)
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in result })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
            XCTFail("mismatch must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requested 2"))
            XCTAssertTrue(error.localizedDescription.contains("observed 1"))
        }
        try assertOriginals(dir)
    }

    func testDiarizationFailurePropagatesAndPreservesAllArtifacts() async throws {
        let dir = try session()
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
            throw SyntheticFailure.diarization
        })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
            XCTFail("diarization failure must propagate")
        } catch {
            XCTAssertTrue(error is SyntheticFailure)
        }
        try assertOriginals(dir)
    }

    func testMissingResultThrowsAndPreservesAllArtifacts() async throws {
        let dir = try session()
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in nil })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
            XCTFail("missing diarization must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("observed 0"))
        }
        try assertOriginals(dir)
    }

    func testZeroLengthSpeakerDoesNotSatisfyRequestedCount() async throws {
        let dir = try session()
        let result = timeline(2, zeroLengthSecond: true)
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in result })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
            XCTFail("zero-length speaker must not count")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("observed 1"))
        }
        try assertOriginals(dir)
    }

    func testMatchingCountPublishesNormally() async throws {
        let dir = try session()
        let result = timeline(2)
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in result })
        try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
        let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(Set(segments.compactMap { $0["speaker"] as? String }).count, 2)
    }

    func testAutomaticDiarizationFailureRetainsExistingFallbackBehavior() async throws {
        let dir = try session()
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
            throw SyntheticFailure.diarization
        })
        try await coordinator.reprocess(dir, speakerCountOverrides: [:])
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("diarization skipped"))
        XCTAssertTrue(log.contains("done —"))
    }

    func testAbsentSystemOnlyOverrideIsRejectedBeforeInference() async throws {
        let dir = try session()
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
            XCTFail("absent track must be rejected before inference")
            return nil
        })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["them": 2])
            XCTFail("absent system override must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing audio track(s): system"))
        }
        try assertOriginals(dir)
    }

    func testPresentMicAndAbsentSystemOverridesAreRejected() async throws {
        let dir = try session()
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
            XCTFail("all overrides must be checked before inference")
            return nil
        })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2, "them": 2])
            XCTFail("absent system override must not be ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing audio track(s): system"))
        }
        try assertOriginals(dir)
    }

    func testAbsentMicOverrideOnSystemOnlySessionIsRejected() async throws {
        let dir = try session()
        try JSONSerialization.data(withJSONObject: ["files": ["system": "synthetic.m4a"]])
            .write(to: dir.appendingPathComponent("meta.json"))
        let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
            XCTFail("absent track must be rejected before inference")
            return nil
        })
        do {
            try await coordinator.reprocess(dir, speakerCountOverrides: ["me": 2])
            XCTFail("absent mic override must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing audio track(s): mic"))
        }
        try assertOriginals(dir)
    }

    func testNonpositiveCountIsRejectedBeforeInference() async throws {
        for count in [0, -1] {
            let dir = try session()
            let coordinator = TranscriptionCoordinator(engine: FakeASR(), diarization: { _, _ in
                XCTFail("invalid count must be rejected before inference")
                return nil
            })
            do {
                try await coordinator.reprocess(dir, speakerCountOverrides: ["me": count])
                XCTFail("nonpositive count must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("must be positive"))
            }
            try assertOriginals(dir)
        }
    }
}
