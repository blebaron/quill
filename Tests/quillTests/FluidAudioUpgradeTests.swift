import XCTest
@testable import FluidAudio

/// Synthetic arithmetic only. No models, audio, or named speaker identities.
final class FluidAudioUpgradeTests: XCTestCase {
    private func directions() -> [[Double]] {
        (0..<7).map { axis in
            (0..<7).map { $0 == axis ? 1.0 : 0.0 }
        } + [[1, 0, 0, 0, 0, 0, 0]]
    }

    private func output(survivors: Int) -> VBxOutput {
        let gamma = (0..<8).map { row in
            (0..<7).map { $0 == row % survivors ? 1.0 : 0.0 }
        }
        return VBxOutput(
            gamma: gamma,
            pi: (0..<7).map { $0 < survivors ? 1.0 / Double(survivors) : 1e-12 },
            hardClusters: [], centroids: [], numClusters: 7, elbos: []
        )
    }

    func testWarmStartSevenSurvivingThreeExactSevenActivatesRecovery() {
        let constraints = SpeakerCountConstraints.resolve(
            numEmbeddings: 8, numSpeakers: 7, minSpeakers: nil, maxSpeakers: nil
        )
        let adjusted = VBxClustering.applyConstraints(
            to: output(survivors: 3), trainingEmbeddings: directions(), constraints: constraints
        )
        XCTAssertTrue(adjusted.wasAdjusted)
        XCTAssertEqual(adjusted.originalClusterCount, 3)
        XCTAssertEqual(adjusted.centroids.count, 7)
        XCTAssertEqual(Set(adjusted.hardClusters.flatMap { $0 }).count, 7)
    }

    func testWarmStartSevenSurvivingSevenNeedsNoRecovery() {
        let constraints = SpeakerCountConstraints.resolve(
            numEmbeddings: 8, numSpeakers: 7, minSpeakers: nil, maxSpeakers: nil
        )
        let adjusted = VBxClustering.applyConstraints(
            to: output(survivors: 7), trainingEmbeddings: directions(), constraints: constraints
        )
        XCTAssertFalse(adjusted.wasAdjusted)
        XCTAssertEqual(adjusted.assignedClusterCount, 7)
    }

    func testRangeFiveToEightSurvivingThreeTargetsFive() {
        let constraints = SpeakerCountConstraints.resolve(
            numEmbeddings: 8, numSpeakers: nil, minSpeakers: 5, maxSpeakers: 8
        )
        let adjusted = VBxClustering.applyConstraints(
            to: output(survivors: 3), trainingEmbeddings: directions(), constraints: constraints
        )
        XCTAssertTrue(adjusted.wasAdjusted)
        XCTAssertEqual(adjusted.numClusters, 5)
        XCTAssertEqual(adjusted.centroids.count, 5)
    }

    func testNoConstraintsLeavesCollapsedOutputUnchanged() {
        let adjusted = VBxClustering.applyConstraints(
            to: output(survivors: 3), trainingEmbeddings: directions(), constraints: nil
        )
        XCTAssertFalse(adjusted.wasAdjusted)
        XCTAssertEqual(adjusted.activeClusterCount, 3)
    }

    func testDuplicateVectorsDemonstrateCentroidCountIsNotOccupancy() {
        let embeddings = Array(repeating: [1.0, 0.0], count: 8)
        let result = KMeansClustering.clusterWithCentroidsNInit(
            embeddings: embeddings, numClusters: 7, maxIterations: 100, nInit: 10, baseSeed: 0
        )
        XCTAssertEqual(result.centroids.count, 7)
        XCTAssertEqual(Set(result.clusters).count, 1)
    }

    func testManagerReassignmentCanCollapseSevenTrainingLabels() {
        let embeddings = Array(repeating: [1.0, 0.0], count: 7)
        let initial = KMeansClustering.clusterWithCentroidsNInit(
            embeddings: embeddings, numClusters: 7, maxIterations: 100, nInit: 10, baseSeed: 0
        )
        XCTAssertEqual(Set(initial.clusters).count, 7)
        let adjusted = VBxOutput(
            gamma: [], pi: [], hardClusters: [initial.clusters],
            centroids: initial.centroids, numClusters: 7, elbos: [], wasAdjusted: true
        )
        let final = OfflineDiarizerManager().clusterAssignments(
            vbxOutput: adjusted, trainingEmbeddings: embeddings,
            embeddingFeatures: embeddings, initialClusters: initial.clusters,
            chunkIndices: Array(0..<7)
        )
        XCTAssertEqual(final.centroids.count, 7)
        XCTAssertEqual(Set(final.assignments).count, 1)
    }
}
