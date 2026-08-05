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

    /// Diarize a track with an explicit, known speaker count instead of
    /// letting FluidAudio detect it automatically.
    ///
    /// FluidAudio's automatic speaker-count detection can badly under-count
    /// on a busy, single-mic recording (a whole room collapsed to one
    /// "Speaker 1"), and its `minSpeakers`/`maxSpeakers` hints don't reliably
    /// fix it — the safety net that's supposed to catch this compares against
    /// the pre-EM warm-start cluster count, not the number of speakers VBx's
    /// own EM step decides actually have meaningful support, so a mismatch
    /// between the two goes uncaught. Only an exact `numSpeakers` reliably
    /// forces a re-cluster. See `.issues/rca-002-diarization-speaker-collapse.md`
    /// for the full investigation.
    ///
    /// There's no way to know the right count ahead of time for a passive
    /// recording, so this isn't wired into the normal per-session pipeline —
    /// it's the engine underneath the manual `quill rediarize` CLI path,
    /// used once a human (or an agent reading the transcript) knows the
    /// headcount. Builds its own manager rather than reusing the shared,
    /// lazily-prepared instance above, since `OfflineDiarizerManager`'s
    /// config is fixed for its lifetime — an acceptable extra model load for
    /// this rare, manual path.
    static func diarizeWithKnownSpeakerCount(
        _ audio: URL, count: Int
    ) async throws -> DiarizationResult {
        let manager = OfflineDiarizerManager(config: .default.withSpeakers(exactly: count))
        try await manager.prepareModels()
        return try await manager.process(audio)
    }
}
