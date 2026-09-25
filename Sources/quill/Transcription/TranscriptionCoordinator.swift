import FluidAudio
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). When diarization is enabled,
/// each track is additionally diarized and its segments relabeled into a
/// single "Speaker N" id space (numbered by first appearance across both
/// tracks), with per-speaker talk time and voice embeddings written to
/// speakers.json — fodder for a later, separate speaker-naming pass. The
/// filesystem is the queue — `resumePending()` rescans at launch, so a crash
/// or quit mid-transcription just retries on next run. Failures append to
/// the session's transcribe.log and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var inFlight: URL?
    private var engine: TranscriptionEngine?
    private var diarizer: DiarizationEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort. Safe to call repeatedly — e.g. a periodic
    /// re-scan to pick up sessions dropped in externally (a mobile companion
    /// syncing via iCloud Drive, say) rather than created by this process —
    /// since it skips anything already queued or mid-transcription.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        Self.repackageFlatDrops(root: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) && dir != inFlight {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// Some drop-in sources (a mobile companion Shortcut, notably) can't
    /// create nested folders reliably, only flat files with a variable
    /// filename — so they land as `<name>__mic.m4a` / `<name>__meta.json`
    /// siblings directly in the recordings root instead of inside a
    /// `<name>/` folder. Group any such pairs and move them into a proper
    /// session folder (preserving each file's own name, since meta.json's
    /// `files` entries reference them by exact name) so the normal scan
    /// below treats them like any other session.
    private static func repackageFlatDrops(root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let metaSuffix = "__meta.json"
        for metaFile in entries where metaFile.lastPathComponent.hasSuffix(metaSuffix) {
            let name = String(metaFile.lastPathComponent.dropLast(metaSuffix.count))
            guard !name.isEmpty else { continue }

            let sessionDir = root.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: sessionDir.path) else { continue }

            let siblings = entries.filter {
                $0 != metaFile && $0.lastPathComponent.hasPrefix(name + "__")
            }
            guard !siblings.isEmpty else { continue }

            do {
                try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                for file in siblings {
                    try fm.moveItem(at: file, to: sessionDir.appendingPathComponent(file.lastPathComponent))
                }
                try fm.moveItem(at: metaFile, to: sessionDir.appendingPathComponent("meta.json"))
            } catch {
                FileHandle.standardError.write(Data("failed to repackage \(name): \(error)\n".utf8))
            }
        }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            inFlight = dir
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
            inFlight = nil
        }
        await releaseEngines()
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Re-run transcription + diarization for one session outside the normal
    /// queue, with an explicit speaker count for one or both tracks (keyed by
    /// "me"/"them") — the engine underneath the `quill rediarize` CLI, for
    /// when a human (or an agent reading the transcript) knows the headcount
    /// that FluidAudio's automatic detection got wrong. Always overwrites
    /// transcript.json/transcript.md/speakers.json for this session, and runs
    /// regardless of `diarization.enabled` in config — an explicit request
    /// like this overrides that default.
    func reprocess(_ dir: URL, speakerCountOverrides: [String: Int]) async throws {
        do {
            try await transcribe(dir, speakerCountOverrides: speakerCountOverrides, requireAllTracks: true)
        } catch {
            await releaseEngines()
            throw error
        }
        await releaseEngines()
    }

    /// Manual, on-demand full re-transcription of one session — the engine
    /// underneath `quill retranscribe`, for when a transcript is missing,
    /// empty, partial, or stale and needs to be regenerated without deleting
    /// files by hand. Shares reprocess/transcribe with `rediarize`; unlike
    /// rediarize it passes no speaker-count overrides, so diarization runs
    /// fully automatically (or not at all, per config) rather than being
    /// pinned to a known headcount.
    func retranscribe(_ dir: URL) async throws {
        log(dir, "manual retranscribe requested")
        do {
            try await reprocess(dir, speakerCountOverrides: [:])
            log(dir, "manual retranscribe succeeded")
        } catch {
            log(dir, "manual retranscribe failed: \(error)")
            throw error
        }
    }

    private func releaseEngines() async {
        await engine?.release()
        engine = nil
        await diarizer?.release()
        diarizer = nil
    }

    private func transcribe(
        _ dir: URL, speakerCountOverrides: [String: Int] = [:], requireAllTracks: Bool = false
    ) async throws {
        let meta = try SessionMeta.read(from: dir)
        if requireAllTracks { try meta.validateSourceAudio(in: dir) }
        let engine = try await preparedEngine()

        // Only need the shared, automatic diarizer for tracks that aren't
        // getting an explicit override below.
        let needsAutoDiarizer = meta.tracks.contains { speakerCountOverrides[$0.speaker] == nil }
        var diarizer: DiarizationEngine?
        if needsAutoDiarizer, Config.diarizationEnabled() {
            do {
                diarizer = try await preparedDiarizer()
            } catch {
                log(dir, "diarization unavailable: \(error)")
            }
        }

        // Per-track diarization results, keyed by the track's fallback label
        // ("me"/"them") — kept around after the loop to compute each global
        // speaker's talk time and embedding for speakers.json.
        var diarizations: [String: TrackDiarization] = [:]
        var raw: [RawSegment] = []

        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // ASR and diarization both read the same file independently —
            // run them concurrently rather than paying their cost serially.
            // A fresh local binding (rather than closing over `diarizer`
            // directly) keeps each loop iteration's async-let independent of
            // the others in the eyes of the region-isolation checker.
            let trackDiarizer = diarizer
            let overrideCount = speakerCountOverrides[track.speaker]
            async let segmentsTask = engine.transcribe(audio)
            async let diarizationTask: DiarizationResult? = Self.diarize(
                audio, overrideCount: overrideCount, fallback: trackDiarizer
            )

            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await segmentsTask
            } catch {
                if requireAllTracks {
                    _ = try? await diarizationTask
                    throw error
                }
                log(dir, "skipping \(track.file): \(error)")
                // Still await the diarization child task so its result (or
                // error) doesn't leak past this scope.
                _ = try? await diarizationTask
                continue
            }

            var trackDiarization: TrackDiarization?
            do {
                if let result = try await diarizationTask {
                    let diarization = TrackDiarization(
                        timeline: result.segments,
                        speakerDatabase: result.speakerDatabase ?? [:]
                    )
                    diarizations[track.speaker] = diarization
                    trackDiarization = diarization
                }
            } catch {
                log(dir, "diarization skipped for \(track.file): \(error)")
            }

            let offset = TimeInterval(track.offsetMs) / 1000
            for segment in segments {
                let localSpeakerId = trackDiarization.flatMap {
                    Self.speakerId(at: segment, in: $0.timeline)
                }
                raw.append(RawSegment(
                    trackLabel: track.speaker,
                    localSpeakerId: localSpeakerId,
                    start_ms: Int((segment.start + offset) * 1000),
                    end_ms: Int((segment.end + offset) * 1000),
                    text: segment.text
                ))
            }
        }
        raw.sort { $0.start_ms < $1.start_ms }
        let echoFlags = Config.echoSuppressionEnabled()
            ? Self.detectEcho(in: raw)
            : [Bool](repeating: false, count: raw.count)

        // Assign "Speaker N" in order of first appearance across the whole
        // chronological transcript, not per-track — so numbering reads
        // naturally regardless of which physical track someone spoke on.
        // Segments with no diarization match (disabled, failed, or no
        // overlapping cluster) keep the track's flat fallback label.
        var globalIds: [String: String] = [:]
        var nextSpeakerNumber = 1
        var merged: [Transcript.Segment] = []
        for (index, segment) in raw.enumerated() {
            let speaker: String
            if let localSpeakerId = segment.localSpeakerId {
                let key = "\(segment.trackLabel)::\(localSpeakerId)"
                if let assigned = globalIds[key] {
                    speaker = assigned
                } else {
                    let assigned = "Speaker \(nextSpeakerNumber)"
                    globalIds[key] = assigned
                    nextSpeakerNumber += 1
                    speaker = assigned
                }
            } else {
                speaker = segment.trackLabel
            }
            merged.append(Transcript.Segment(
                speaker: speaker, start_ms: segment.start_ms, end_ms: segment.end_ms,
                text: segment.text, echo: echoFlags[index] ? true : nil
            ))
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        let speakers = try speakerData(diarizations: diarizations, globalIds: globalIds)
        try transcript.write(to: dir, speakers: speakers)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private func preparedDiarizer() async throws -> DiarizationEngine {
        if let diarizer { return diarizer }
        let diarizer = DiarizationEngine()
        try await diarizer.prepare()
        self.diarizer = diarizer
        return diarizer
    }

    /// Diarizes one track, preferring an explicit speaker-count override
    /// (`quill rediarize`) over the shared automatic diarizer.
    private static func diarize(
        _ audio: URL, overrideCount: Int?, fallback: DiarizationEngine?
    ) async throws -> DiarizationResult? {
        if let overrideCount {
            return try await DiarizationEngine.diarizeWithKnownSpeakerCount(audio, count: overrideCount)
        }
        return try await fallback?.diarize(audio)
    }

    /// The diarization timeline for one track, kept around after ASR so
    /// speakers.json can report each speaker's total talk time (measured
    /// from the diarization timeline itself, not the coarser ASR segments)
    /// and voice embedding.
    private struct TrackDiarization {
        let timeline: [TimedSpeakerSegment]
        let speakerDatabase: [String: [Float]]
    }

    /// One ASR segment before final speaker-label resolution: still tagged
    /// with its track's fallback label and (if diarization ran) the
    /// track-local cluster id it fell into.
    private struct RawSegment {
        let trackLabel: String
        let localSpeakerId: String?
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    /// Segments further than this from any detected speech span are left
    /// unlabeled rather than snapped to the nearest speaker — matches the
    /// silence-gap threshold ParakeetEngine already uses to break segments
    /// (see ParakeetEngine.segments(from:)), so a gap long enough to end a
    /// sentence is also long enough to stop guessing who's talking.
    private static let maxSnapDistanceSeconds: Float = 1.0

    /// The diarization cluster (if any) whose span contains this ASR
    /// segment's midpoint, on the assumption that segment boundaries and
    /// diarization boundaries won't align exactly. Falls back to the
    /// nearest cluster by distance — but only within maxSnapDistanceSeconds,
    /// so a segment that lands in real silence (e.g. an ASR hallucination
    /// between two speakers' turns) isn't confidently misattributed to
    /// whichever speaker happens to be closer in time.
    private static func speakerId(
        at segment: TranscriptSegment, in timeline: [TimedSpeakerSegment]
    ) -> String? {
        guard !timeline.isEmpty else { return nil }
        let midpoint = Float((segment.start + segment.end) / 2)
        if let contained = timeline.first(where: {
            $0.startTimeSeconds <= midpoint && midpoint <= $0.endTimeSeconds
        }) {
            return contained.speakerId
        }
        func distance(_ span: TimedSpeakerSegment) -> Float {
            if midpoint < span.startTimeSeconds { return span.startTimeSeconds - midpoint }
            if midpoint > span.endTimeSeconds { return midpoint - span.endTimeSeconds }
            return 0
        }
        guard let nearest = timeline.min(by: { distance($0) < distance($1) }) else { return nil }
        return distance(nearest) <= maxSnapDistanceSeconds ? nearest.speakerId : nil
    }

    /// How far apart two tracks' segments can start/end and still be
    /// considered the same moment. The mic and system tracks are
    /// transcribed independently and won't split into matching segment
    /// boundaries, so this has to be generous — wider than
    /// maxSnapDistanceSeconds above, which only nudges a single segment to
    /// the nearest diarization cluster rather than aligning two whole
    /// independent transcripts.
    private static let echoWindowToleranceSeconds: Double = 1.5

    /// Fraction of a mic segment's words that must also appear in the
    /// overlapping system-track window for it to count as echo, not an
    /// exact-match requirement since the two tracks' ASR passes transcribe
    /// the same audio slightly differently. Below this, the segment likely
    /// has substantial content of its own (a real interruption or
    /// backchannel during someone else's speech) and is left alone even if
    /// it partly overlaps — see the trade-off note in detectEcho below.
    private static let echoContainmentThreshold: Double = 0.7

    /// True per raw segment (aligned by index) if it's very likely acoustic
    /// echo: the mic picking up system audio played through speakers,
    /// rather than something the local speaker actually said. Compares each
    /// mic-track ("me") segment's words against every system-track ("them")
    /// segment overlapping it in time (widened by
    /// echoWindowToleranceSeconds) and flags it when most of its words show
    /// up there too.
    ///
    /// Deliberately imprecise for very short common backchannel words
    /// ("yeah", "okay", "right") — a genuine independent utterance and true
    /// echo read identically as text, so a real short backchannel said at
    /// the same moment as its echo will sometimes get suppressed too.
    /// Accepted trade-off: the alternative, on an un-headphoned session, is
    /// near-total duplication of the transcript (see FEATURES.md).
    private static func detectEcho(in raw: [RawSegment]) -> [Bool] {
        let toleranceMs = Int(echoWindowToleranceSeconds * 1000)
        let themSegments = raw.filter { $0.trackLabel == "them" }
        guard !themSegments.isEmpty else { return [Bool](repeating: false, count: raw.count) }

        return raw.map { segment in
            guard segment.trackLabel == "me" else { return false }
            let windowStart = segment.start_ms - toleranceMs
            let windowEnd = segment.end_ms + toleranceMs
            let windowTokens = Set(themSegments
                .filter { $0.end_ms >= windowStart && $0.start_ms <= windowEnd }
                .flatMap { tokenize($0.text) })
            guard !windowTokens.isEmpty else { return false }

            let micTokens = tokenize(segment.text)
            guard !micTokens.isEmpty else { return false }
            let matched = micTokens.filter { windowTokens.contains($0) }.count
            return Double(matched) / Double(micTokens.count) >= echoContainmentThreshold
        }
    }

    /// Lowercased word tokens, punctuation stripped — enough normalization
    /// to compare two independent ASR passes over the same audio without
    /// pulling in a string-similarity dependency for what's just a rough
    /// containment check.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// speakers.json: one entry per global speaker id actually used in the
    /// transcript, ordered by "Speaker N". Sidecar to transcript.json rather
    /// than inline, so the canonical transcript stays small — a later
    /// speaker-naming pass reads this file's embeddings/talk time and
    /// rewrites the `id` strings here and in transcript.json/.md.
    private func speakerData(
        diarizations: [String: TrackDiarization],
        globalIds: [String: String]
    ) throws -> Data? {
        // No speaker data means the publisher removes an old sidecar as part
        // of the same update as the transcript, rather than leaving it stale.
        guard !globalIds.isEmpty else { return nil }
        let entries = globalIds.sorted {
            Self.speakerNumber($0.value) < Self.speakerNumber($1.value)
        }
        var infos: [SpeakerInfo] = []
        for (key, globalId) in entries {
            guard let separator = key.range(of: "::") else { continue }
            let trackLabel = String(key[key.startIndex..<separator.lowerBound])
            let localSpeakerId = String(key[separator.upperBound...])
            guard let diarization = diarizations[trackLabel] else { continue }
            let talkTimeMs = diarization.timeline
                .filter { $0.speakerId == localSpeakerId }
                .reduce(0.0) { $0 + Double($1.durationSeconds) * 1000 }
            infos.append(SpeakerInfo(
                id: globalId,
                track: trackLabel == "me" ? "mic" : "system",
                talk_time_ms: Int(talkTimeMs),
                embedding: diarization.speakerDatabase[localSpeakerId] ?? []
            ))
        }
        guard !infos.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(infos)
    }

    private static func speakerNumber(_ label: String) -> Int {
        Int(label.split(separator: " ").last.map(String.init) ?? "") ?? 0
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)
        case noTracks
        case missingAudio(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            case .noTracks: return "meta.json has no source audio tracks"
            case .missingAudio(let url): return "missing or empty source audio track: \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }

    /// Manual reruns must not replace a usable transcript with a partial one.
    /// The normal queue deliberately remains best-effort for damaged tracks.
    func validateSourceAudio(in dir: URL) throws {
        guard !tracks.isEmpty else { throw MetaError.noTracks }
        for track in tracks {
            let url = dir.appendingPathComponent(track.file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  (attributes?[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                throw MetaError.missingAudio(url)
            }
        }
    }
}

/// One entry in speakers.json. Property names are the JSON schema.
private struct SpeakerInfo: Codable {
    let id: String
    let track: String
    let talk_time_ms: Int
    let embedding: [Float]
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. If you change these fields, what they mean, or
/// what rendered(title:) below filters out of transcript.md, also update
/// RecordingsAgentsDoc.swift's `content` (and bump its `version`) — that's
/// the schema description handed to any other agent pointed at a recordings
/// folder, and it goes stale silently otherwise.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        /// Present (and true) only when detectEcho flagged this as likely
        /// acoustic echo of the system track. Kept in transcript.json even
        /// though rendered(title:) skips it, so nothing is destroyed — only
        /// the readable view is filtered.
        let echo: Bool?
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Prepare all generated artifacts before replacing any existing ones.
    func write(to dir: URL, speakers: Data?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try GeneratedArtifacts.publish(
            in: dir, transcriptJSON: encoder.encode(self),
            transcriptMarkdown: Data(rendered(title: dir.lastPathComponent).utf8),
            speakersJSON: speakers
        )
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments where seg.echo != true {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
