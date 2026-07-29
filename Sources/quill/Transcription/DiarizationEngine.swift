import FluidAudio
import Foundation

// FluidAudio doesn't mark this Sendable, but its own internal comment says
// why it's safe: the CoreML models are read-only after `prepareModels()`
// returns. quill's usage is even narrower — DiarizationEngine is the sole
// owner of any given instance, and TranscriptionCoordinator only ever awaits
// one prepare/diarize/release call at a time — so asserting Sendable here
// lets `manager` stay a normal, actor-protected stored property below
// instead of opting out of actor isolation with `nonisolated(unsafe)`.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

/// Local speaker diarization for a single audio track, via FluidAudio's
/// offline pipeline (pyannote-based segmentation + embedding + clustering).
/// Prepared lazily and released once the transcription queue drains, same
/// lifecycle as ParakeetEngine.
actor DiarizationEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared

        var description: String {
            "diarization engine used before prepare()"
        }
    }

    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        self.manager = manager
    }

    /// Diarize a complete audio file, returning per-speaker segments and
    /// embeddings. `speakerId` in the result (FluidAudio's "S1", "S2", ...)
    /// is only unique within this call — the caller must disambiguate
    /// across separate tracks.
    func diarize(_ audio: URL) async throws -> DiarizationResult {
        guard let manager else { throw EngineError.notPrepared }
        return try await manager.process(audio)
    }

    /// FluidAudio's offline manager has no explicit cleanup/reset — dropping
    /// the reference releases the CoreML models.
    func release() async {
        manager = nil
    }
}
