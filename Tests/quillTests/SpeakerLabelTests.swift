import Foundation
import XCTest
@testable import quill

final class SpeakerLabelTests: XCTestCase {
    func testUnmatchedMicTurnDoesNotClaimRecorderOrCreateCluster() {
        var labels = TranscriptionCoordinator.SpeakerLabels()
        let brian = labels.assign(trackLabel: "me", localSpeakerId: "S1")
        let unresolved = labels.assign(trackLabel: "me", localSpeakerId: nil)
        let chad = labels.assign(trackLabel: "me", localSpeakerId: "S2")

        XCTAssertEqual(brian.speaker, "Speaker 1")
        XCTAssertEqual(brian.track, "mic")
        XCTAssertEqual(unresolved.speaker, "Unassigned speaker")
        XCTAssertEqual(unresolved.track, "mic")
        XCTAssertEqual(chad.speaker, "Speaker 2")
        XCTAssertEqual(labels.assign(trackLabel: "me", localSpeakerId: "S1").speaker, "Speaker 1")
        XCTAssertEqual(labels.globalIds.count, 2)
    }

    func testEachTrackHasSeparateClusterIDsAndUnassignedProvenance() {
        var labels = TranscriptionCoordinator.SpeakerLabels()
        XCTAssertEqual(labels.assign(trackLabel: "them", localSpeakerId: "S1").speaker, "Speaker 1")
        XCTAssertEqual(labels.assign(trackLabel: "me", localSpeakerId: "S1").speaker, "Speaker 2")
        let mic = labels.assign(trackLabel: "me", localSpeakerId: nil)
        let system = labels.assign(trackLabel: "them", localSpeakerId: nil)
        XCTAssertEqual(mic.speaker, "Unassigned speaker")
        XCTAssertEqual(system.speaker, "Unassigned speaker")
        XCTAssertEqual(mic.track, "mic")
        XCTAssertEqual(system.track, "system")
        XCTAssertEqual(labels.globalIds.count, 2)
    }

    func testGeneratedArtifactsPreserveWordsTimingAndNeutralProvenance() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-speaker-label-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var labels = TranscriptionCoordinator.SpeakerLabels()
        let turns: [(String, String?, Int, String)] = [
            ("me", "S1", 39442, "first voice"),
            ("me", nil, 51522, "unresolved voice"),
            ("me", "S2", 54082, "second voice"),
            ("them", nil, 60000, "unresolved remote voice"),
        ]
        let segments = turns.map { track, cluster, start, text in
            let assignment = labels.assign(trackLabel: track, localSpeakerId: cluster)
            return Transcript.Segment(
                speaker: assignment.speaker, track: assignment.track,
                start_ms: start, end_ms: start + 1000, text: text, echo: nil
            )
        }
        let transcript = Transcript(
            engine: "test", model: "test", created_at: "2026-09-26T00:00:00Z", segments: segments
        )
        let sidecar = try JSONSerialization.data(withJSONObject: [
            ["id": "Speaker 1", "track": "mic"], ["id": "Speaker 2", "track": "mic"]
        ])
        try transcript.write(to: dir, speakers: sidecar)

        let decoded = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        )
        XCTAssertEqual(decoded.segments.map(\.speaker), [
            "Speaker 1", "Unassigned speaker", "Speaker 2", "Unassigned speaker"
        ])
        XCTAssertEqual(decoded.segments.map(\.track), ["mic", "mic", "mic", "system"])
        XCTAssertEqual(decoded.segments.map(\.start_ms), turns.map { $0.2 })
        XCTAssertEqual(decoded.segments.map(\.text), turns.map { $0.3 })
        let markdown = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Unassigned speaker (mic):** unresolved voice"))
        XCTAssertTrue(markdown.contains("Unassigned speaker (system):** unresolved remote voice"))
        XCTAssertFalse(markdown.contains(" me:"))
        XCTAssertFalse(markdown.contains(" them:"))
        let sidecarIDs = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("speakers.json"))
        ) as? [[String: String]]
        XCTAssertEqual(sidecarIDs?.map { $0["id"] }, ["Speaker 1", "Speaker 2"])
    }

    func testGeneratedGuideExplainsTrackIsNotIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-guide-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        RecordingsAgentsDoc.ensureUpToDate(root: root)
        let guide = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(guide.contains("quill:agents-doc-version: 5"))
        XCTAssertTrue(guide.contains("not a verified identity"))
        XCTAssertTrue(guide.contains("Unassigned speaker"))
        XCTAssertFalse(guide.contains("`me` — the person running quill"))
    }
}
