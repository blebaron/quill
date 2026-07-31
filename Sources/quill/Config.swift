import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "diarization": { "enabled": true },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "reminder_interval_minutes": 30
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Whether tracks are diarized (split into per-speaker labels) during
    /// transcription. Default on; disabling falls back to flat "me"/"them"
    /// labels and skips the diarization model entirely.
    static func diarizationEnabled() -> Bool {
        diarization()?["enabled"] as? Bool ?? true
    }

    private static func diarization() -> [String: Any]? {
        load()?["diarization"] as? [String: Any]
    }

    /// Minutes between "still recording" reminder notifications while a
    /// session is active, or 0 to disable. Default 30 — long enough not to
    /// be noisy, short enough that a forgotten recording doesn't run all day
    /// unnoticed.
    static func reminderIntervalMinutes() -> Int {
        load()?["reminder_interval_minutes"] as? Int ?? 30
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Suppress transcript segments where the mic track just picked up
    /// acoustic echo of the system track played through speakers (no
    /// headphones) — compares mic segments against overlapping system-track
    /// text and drops close matches from transcript.md only, never
    /// transcript.json. Default on: it's a pure rendering filter over text
    /// already produced, never touches recorded audio.
    static func echoSuppressionEnabled() -> Bool {
        load()?["echo_suppression"] as? Bool ?? true
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
