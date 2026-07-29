# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                     # debug build
swift build -c release          # release build — always use this for actually running/testing behavior
.build/release/quill doctor     # check mic/system-audio permissions, recordings folder, model cache
.build/release/quill run --out <dir>   # run the menu-bar daemon against a scratch recordings dir
```

There is no test target — this is a single executable SPM package (see
`Package.swift`). Verification is manual: build, run, record a session via
the menu bar, and inspect the resulting session folder (see below) or
`quill doctor`'s output.

Installing system-wide (`sudo cp .build/release/quill /usr/local/bin/quill`
or a symlink to the same path) requires `sudo`, so it isn't part of the
normal edit/build loop — only do it when the user asks to actually try the
built binary end-to-end.

## Architecture

Single-binary macOS menu-bar app (`NSStatusItem`, `.accessory` activation
policy — no dock icon, no windows). Entry point is `Quill.swift`
(`ArgumentParser` with `run`/`doctor`/`install` subcommands, `run` is
default). `AppController` (`@MainActor`, in `Quill.swift`) owns the menu bar,
the current `RecordingSession`, and the elapsed-time ticker — all recording
state transitions happen there.

### Recording

`RecordingSession` ([RecordingSession.swift](Sources/quill/RecordingSession.swift))
creates a timestamped folder under the recordings root and drives two
independent, concurrently-running recorders:

- `MicRecorder` ([Audio/MicRecorder.swift](Sources/quill/Audio/MicRecorder.swift)) — `AVAudioEngine` capture of the default input device.
- `SystemAudioRecorder` ([Audio/SystemAudioRecorder.swift](Sources/quill/Audio/SystemAudioRecorder.swift)) — a Core Audio process tap (`AudioHardwareCreateProcessTap`, macOS 14.2+) mixed through a private aggregate device. No virtual device, no kernel extension.

Both write streaming AAC into `.caf` (not `.m4a` — CAF needs no finalization
pass, so a crash mid-session loses nothing already written). Each recorder
tracks `firstBufferAt`, the wall-clock time of its first real buffer;
`RecordingSession.stop()` diffs the two against the earliest and writes the
gap as `start_offset_ms` in `meta.json` — this is what lets the transcription
pipeline align two tracks that didn't start on the same buffer onto one
clock.

**Mic voice processing is a load-bearing gotcha** (`Config.micVoiceProcessing()`,
default off): enabling Apple's echo canceller on the input node makes
`AVAudioEngine` switch to a duplex `VoiceProcessingIO` unit, not just an
input effect — it silently delivers zeroed buffers unless the output side of
the graph is also connected with an explicit mono format on both sides (see
`.issues/rca-001-voice-processing-silent-mic.md` for the full incident).
`MicRecorder.attach(voiceProcessing:)` builds that full duplex graph when
enabled, plus a first-second liveness check that tears down and restarts raw
capture if the route still comes back silent. Don't "simplify" this graph
without reading that RCA first.

### Transcription + diarization pipeline

`TranscriptionCoordinator` (actor, [Transcription/TranscriptionCoordinator.swift](Sources/quill/Transcription/TranscriptionCoordinator.swift))
is a serial queue of session folders. The filesystem *is* the queue —
`resumePending()` rescans the recordings root at launch and treats "has
`meta.json` but no `transcript.json`" as pending, so a crash or quit
mid-transcription just retries next run. Per-session flow in `transcribe(_:)`:

1. Read `meta.json` to find each track's file, fallback speaker label (`me`
   for mic, `them` for system), and start offset.
2. Transcribe each track independently via `TranscriptionEngine`
   ([Transcription/TranscriptionEngine.swift](Sources/quill/Transcription/TranscriptionEngine.swift))
   — currently `ParakeetEngine` (FluidAudio's Parakeet TDT Core ML port).
3. If `Config.diarizationEnabled()`, diarize each track independently via
   `DiarizationEngine` ([Transcription/DiarizationEngine.swift](Sources/quill/Transcription/DiarizationEngine.swift))
   — FluidAudio's offline pipeline (`OfflineDiarizerManager`). Each track's
   clusters are its own id space (FluidAudio's `"S1"`, `"S2"`, ... scoped to
   that one `process()` call) — segments are matched to a cluster by
   midpoint, then a **global** speaker id (`"Speaker 1"`, `"Speaker 2"`, ...)
   is assigned in chronological order of first appearance across *both*
   tracks, keyed by `(trackLabel, localSpeakerId)`. A track with diarization
   disabled/failed keeps its flat `me`/`them` label instead.
4. Segments from both tracks are offset-shifted, merged by timestamp, and
   written as `transcript.json` (canonical) + `transcript.md` (rendered).
   `speakers.json` is a sidecar with one entry per global speaker id actually
   used (track, total talk time from the diarization timeline, voice
   embedding) — deliberately kept out of `transcript.json` so the canonical
   transcript stays small; it's meant as input to a separate, not-yet-built
   speaker-naming pass that would rewrite the `Speaker N` ids into real names.

Both engines are prepared lazily (model weights load only once the queue has
real work) and released once the queue drains — see `preparedEngine()` /
`preparedDiarizer()` and the end of `drain()`. Failures are per-track and
non-fatal: one bad/missing file or a diarization failure logs to the
session's `transcribe.log` and falls back gracefully rather than losing the
other track's transcript.

`OfflineDiarizerManager` (FluidAudio) is a plain class, not `Sendable` — that
forces `@preconcurrency import FluidAudio` and a `nonisolated(unsafe)` stored
reference in `DiarizationEngine`; this is safe only because
`TranscriptionCoordinator` always awaits one call at a time. `AsrManager`
(used by `ParakeetEngine`) is an actor upstream and needs none of this.

### Other pieces

- `Config.swift` — optional `~/.config/quill/config.json`. Resolution order for the recordings root: `--out` CLI flag > config `recordings_dir` > `~/Recordings`.
- `Doctor.swift` — `DoctorReport.run()` is a flat array of independent `Check`s (mic/system-audio permission state, recordings folder writability, model cache presence for both the ASR and diarization model repos). Adding a new check is just adding another function to that array — nothing else enumerates them by index.
- `MenuBarController.swift` — the entire UI. Feather icon is an inlined SVG (no resource bundle, keeps this a true single-binary install).
- `Install.swift` — writes/removes a plain `~/Library/LaunchAgents` plist and bootstraps it via `launchctl`. Deliberately not `SMAppService.mainApp`, which requires a full `.app` bundle.
- `Notify.swift` — user notifications via `osascript display notification`, not `UserNotifications`, again to avoid needing an app bundle/entitlement.

### External dependency: FluidAudio

Both ASR (`ParakeetEngine`) and diarization (`DiarizationEngine`) sit on top
of [FluidAudio](https://github.com/FluidInference/FluidAudio), checked out
under `.build/checkouts/FluidAudio`. It's worth reading directly when
extending either engine — it also ships VAD, TTS, and streaming diarization
(`Diarizer` protocol) that quill doesn't currently use. Model downloads for
both engines land under `~/Library/Application Support/FluidAudio/Models/`
and are cached indefinitely; `quill doctor` reports presence, never triggers
a download itself (downloads happen lazily on first real transcription job).
