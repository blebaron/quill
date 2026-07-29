# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `speakers.json` | one entry per detected speaker — talk time + voice embedding (see Diarization) |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is a free first cut at diarization — `me` vs `them` with no
model. CAF on purpose: unlike m4a, it needs no finalization pass — if the
process dies mid-meeting, everything already written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Diarization

Built in, on-device, automatic — each track (`mic.caf` and `system.caf`) is
diarized separately via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
offline pipeline (pyannote-based segmentation + embedding + clustering), so
speakers are identified whether they're multiple people in the room on your
mic, multiple people on the other end of a call, or both. Models (a small
one-time download, well under Parakeet's 600MB) download on first use, same
as transcription; `quill doctor` reports whether they're cached.

Each ASR segment is relabeled from the track's flat `me`/`them` into
`Speaker 1`, `Speaker 2`, etc. — numbered in order of first appearance across
the whole conversation, not per track, so the numbering reads naturally
regardless of which track someone spoke on. `speakers.json` holds the data
behind those labels: each speaker's track, total talk time, and voice
embedding — meant as the input to a separate speaker-naming step (not
included here), which can match embeddings across sessions and rewrite the
`Speaker N` ids into real names in `transcript.json`/`transcript.md`.

If diarization fails or is disabled, quill falls back to the flat
`me`/`them` labels and no `speakers.json` is written — never a hard failure
for the rest of the transcript.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "diarization": { "enabled": true },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `diarization.enabled` — set `false` to skip per-speaker labeling (flat
  `me`/`them` instead of `Speaker N`) and the diarization model download
  entirely.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **FluidAudio offline diarizer** — on-device Core ML speaker diarization
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
