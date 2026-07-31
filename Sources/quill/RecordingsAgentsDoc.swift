import Foundation

/// Writes/refreshes `AGENTS.md` in the recordings root — a plain-English
/// orientation doc for another AI agent pointed at this directory (or at one
/// session folder inside it), so it knows how to read `transcript.md`/
/// `transcript.json` without re-deriving the schema from scratch.
///
/// Content is versioned via the leading HTML comment rather than diffed
/// against disk: bump `version` whenever `content` changes so a stale copy
/// left over from an older quill build gets overwritten on next launch,
/// while a byte-identical file (or a user's own edits, once they've bumped
/// past the current version some other way) is left alone.
///
/// Keep this in sync with `TranscriptionCoordinator.swift`'s `Transcript`/
/// `Transcript.Segment` schema and `rendered(title:)` — this doc is the only
/// place that schema is explained to whoever/whatever reads a recordings
/// folder next, so a change on one side that doesn't land here goes
/// unnoticed rather than causing an error.
enum RecordingsAgentsDoc {
    static let filename = "AGENTS.md"

    static func ensureUpToDate(root: URL) {
        let url = root.appendingPathComponent(filename)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
            installedVersion(of: existing) == version
        {
            return
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func installedVersion(of text: String) -> Int? {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1).first else { return nil }
        guard firstLine.hasPrefix(versionPrefix), firstLine.hasSuffix(versionSuffix) else { return nil }
        let digits = firstLine.dropFirst(versionPrefix.count).dropLast(versionSuffix.count)
        return Int(digits.trimmingCharacters(in: .whitespaces))
    }

    private static let version = 2
    private static let versionPrefix = "<!-- quill:agents-doc-version:"
    private static let versionSuffix = "-->"

    private static let content = """
        \(versionPrefix) \(version) \(versionSuffix)
        # Recordings directory — agent notes

        This directory holds sessions recorded by `quill`, a menu-bar meeting
        recorder. Each subdirectory is one session, named by start time
        (`YYYY.MM.DD-HHMM`, e.g. `2026.07.30-1101`). You've likely been pointed at
        either this whole directory or one specific session folder.

        You almost never need the audio (`mic.caf` / `system.caf`). For
        understanding what was discussed, use these two files per session:

        ## `transcript.md` — read this first

        Human-readable, chronological. Each line is:

        ```
        **[MM:SS] <speaker>:** <text>
        ```

        Timestamps are relative to session start. `<speaker>` is one of:

        - `me` — the person running quill (mic wearer)
        - `them` — used only if diarization was off/failed for a track; a flat
          fallback label, not a real distinct speaker
        - `Speaker 1`, `Speaker 2`, ... — other people, numbered in order of first
          appearance. These are **not stable identities across sessions** — `Speaker
          1` in one folder has no relation to `Speaker 1` in another. There's no
          name attached anywhere yet (a future pass may add real names via
          `speakers.json`'s voice embeddings — not built yet, so don't expect names).

        Segments can be short and choppy (ASR breaks on pauses, not necessarily on
        sentence boundaries) — read several consecutive lines from the same speaker
        as one thought, not each line in isolation.

        **Tail caution:** it's easy to forget to stop a recording. If the last few
        minutes of a transcript degrade into short, fragmented, single-speaker (`me`
        only) lines with no back-and-forth, that's very likely dead time after the
        actual meeting ended, not meaningful content — treat it as noise unless
        context says otherwise.

        **Missing lines are intentional.** Recording without headphones means the mic
        also picks up whatever the speakers are playing, so far-end speech would
        otherwise show up twice — once from the system track, again a moment later
        as apparent mic speech. quill detects these and omits them here; see
        `transcript.json`'s `echo` field below if you need the raw, undeduplicated
        version.

        ## `transcript.json` — same content, structured

        ```json
        {
          "created_at": "...",
          "engine": "parakeet",
          "model": "parakeet-tdt-0.6b-v2-coreml",
          "segments": [
            {"start_ms": 310, "end_ms": 1910, "speaker": "me", "text": "..."},
            {"start_ms": 2130, "end_ms": 2400, "speaker": "Speaker 1", "text": "...", "echo": true}
          ]
        }
        ```

        Use this over the `.md` if you need to do timestamp math or filter/aggregate
        programmatically — one segment per object, same speaker labels as above.
        Unlike `transcript.md`, this includes every segment: `echo: true` marks ones
        quill judged to be acoustic echo of the other track rather than real local
        speech (see above). Skip those too unless you specifically need the raw
        view — the key is only present at all when true, so absence means "not
        flagged as echo," not "confirmed real."

        ## Other files, only if you need them

        - `meta.json` — session start/end time (ISO 8601, UTC) and total duration.
          Useful for "when did this happen" / "how long was it" questions.
        - `speakers.json` — one entry per non-`me` speaker with total talk time and a
          voice embedding (float vector). Only useful if you're comparing speaker
          identity/participation across the *same* session; the embedding isn't
          currently matched against anything else.
        - `transcribe.log` — pipeline log for that session. Only check this if
          `transcript.json`/`.md` are missing or look wrong — it'll say what failed
          (e.g. "diarization skipped for system.caf: noSpeechDetected", which is
          normal for in-person meetings, not an error).

        ## If `transcript.json` is missing

        The session is still queued or mid-transcription (or the daemon crashed
        before finishing) — quill retries automatically on next launch. Don't try to
        read `mic.caf`/`system.caf` directly; just wait or check `transcribe.log`.
        """
}
