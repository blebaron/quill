# Feature ideas

Backlog of features being considered. Not commitments — just a place to
capture ideas before they're scoped or built. Move an item's status to
`in progress` when work starts, or delete it if it's abandoned.

Status values: `idea` / `in progress` / `done`

<!-- Example:
## Speaker naming pass
Status: idea

Rewrite `Speaker N` ids in `speakers.json` into real names, using the voice
embedding to match against a small set of known speakers.
-->

## More visible menu bar recording indicator
Status: done

Today the only always-visible signal that quill is recording is the feather
icon's tint (red vs. default) — the elapsed timer and "recording"/"idle" text
only show once you click open the dropdown (`MenuBarController.swift`). It's
too easy to glance at the bar and not register the state.

Two changes, both to `MenuBarController.update(recording:elapsed:)`:
- Show the elapsed timer as `button.title` next to the icon, not just in the
  dropdown's `stateLabel` — the `tick()` handler already computes this string
  every second for the menu, just also write it to the button.
- Swap the feather SVG for a filled/solid variant while recording (vs. the
  current outline stroke while idle), on top of the existing red tint — a
  shape change reads as "on" more strongly than color alone.

If this still isn't eye-catching enough in practice, next step is a custom
background pill (would need a custom-drawn `NSView` in place of the standard
`NSStatusItem.button`, since it only exposes `contentTintColor` — no built-in
way to paint a background chip).

## Recording state reminder notification
Status: done

Nothing currently interrupts you while a recording is running — `notifyUser`
(`Notify.swift`) only fires on start failure and transcript-ready/failed
events. Add a periodic notification (e.g. every 30/60 min) while a session is
active, e.g. "still recording · 47:12", so a long-forgotten session gets
surfaced instead of silently running until you happen to notice.

## Auto-split long recordings
Status: idea

A forgotten session can run for hours, producing one large, awkward-to-review
file. Consider auto-splitting into a new session folder at a time boundary
(e.g. hourly) so a long-running recording becomes several bounded,
transcribable chunks instead of one giant one. Distinct from the reminder
notification above — this is about bounding the damage of a long recording,
not about noticing it sooner.

## Configurable reminder interval from the menu
Status: idea

The reminder notification above is only tunable by hand-editing
`reminder_interval_minutes` in `~/.config/quill/config.json` (`Config.swift`)
and restarting the daemon. Add a way to change it from the menu itself — e.g.
a submenu on `toggleItem`'s neighbor with a few presets (15/30/60 min, Off) —
so it's discoverable and doesn't need a config file or restart. Open
question: does picking a value from the menu just override the in-memory
`reminderIntervalSeconds` for the current run (resets to config/default on
next launch), or should it write back to `config.json` so the choice sticks?
The latter is more useful but means `MenuBarController` needs a way to
persist config, which nothing does today.

## Surface transcription status on the menu bar itself
Status: idea

`TranscriptionCoordinator.Status` (idle/transcribing/failed) only reaches the
dropdown's `transcriptionLabel` via `MenuBarController.updateTranscription(_:)`
— invisible until you open the menu, the same blind spot the recording
indicator used to have. Add a lightweight cue on the button itself (e.g. a
small badge or secondary glyph next to the feather) so a stuck or failed
transcription doesn't go unnoticed. The tricky part: this has to coexist with
the recording-state icon, since a new session can be recording while the
previous one is still transcribing (`AppController` allows both at once) — a
corner badge layered on top of the feather is probably safer than swapping
the whole icon, which is already spoken for by recording state.

## Speaker naming pass (persistent voice identity)
Status: idea

`speakers.json` (written per session by `TranscriptionCoordinator`, see
CLAUDE.md) already carries a voice embedding per global speaker id —
deliberately built as input for exactly this. Build a small persistent store
(e.g. `~/.config/quill/known_speakers.json`) mapping a name to one or more
reference embeddings. During each session's diarization pass, compare every
speaker's embedding against the known store (cosine similarity above some
threshold) and use the matched name in `transcript.json`/`speakers.json`
instead of "Speaker N"; anything unmatched stays as Speaker N. Still needs a
way to actually populate the store in the first place — likely a small CLI
pass, e.g. `quill name-speaker <session> "Speaker 2" "Jane"`, that pulls the
embedding out of that session's `speakers.json` and adds/updates the named
entry.

## Diarization speaker count doesn't match actual attendees
Status: idea

On a known 2-person call (Brian + Troy Tomkinson, session `2026.07.30-1429`),
diarization produced 3 clusters — `me` plus two separate `Speaker N` labels —
instead of 2. Untangling which lines actually belonged to which real
attendee took multiple rounds of manual transcript review before Brian could
confirm identities. There's currently no way to give the pipeline a known
ground truth (e.g. "there were only 2 people on this call") to check or
correct the diarization output against.

## Transcript-level echo suppression (mic track picking up system audio)
Status: done

`mic_voice_processing` was meant to stop system audio bleeding into the "me"
track when recording without headphones, but enabling it can steal the mic
from other apps' own voice processing — a live Teams call lost its mic
entirely the moment a recording with this flag on started (2026-07-31,
Brian + Daniel). See `.issues/rca-001-voice-processing-silent-mic.md` and
`Config.swift`'s default-off comment; the setting is staying off. The safer
fix is to leave voice processing off entirely and suppress the echo after
the fact instead, using audio quill already records independently.

`TranscriptionCoordinator.transcribe(_:)` collects `raw` segments from both
tracks separately (mic → "me", system → "them") before merging them by
timestamp (`TranscriptionCoordinator.swift:217-230`). Right around that
merge, compare each mic-track segment against system-track segments that
overlap it in time; where the mic segment's text is a close fuzzy match to
the overlapping system segment's text, it's very likely acoustic echo of the
far end rather than something the local speaker actually said — drop it, or
flag it, instead of keeping it as a "me" line.

Open questions: what similarity metric/threshold to use (needs real echoey
sessions to tune against — normalized-text edit distance is the obvious
start, but the two tracks' ASR passes may transcribe the same audio
differently, so something looser may be needed); whether to drop the
segment outright or keep it with an `"echo": true` flag for review rather
than silently deleting text, in the same non-destructive spirit as "Auto-detect
forgotten-recording tail" below; and whether it needs to cross-check against
`Speaker N` identity once diarization is enabled, so it doesn't eat a real
"me" line that happens to echo back the same short phrase (e.g. agreeing
"yeah, yeah").

## Continuous recording with silence trimming
Status: idea

The "crazy idea" version of always-on: instead of a manual start/stop toggle,
record continuously and use FluidAudio's VAD (already vendored — see
CLAUDE.md's "External dependency" section; quill doesn't use it yet) to drop
silent/no-speech stretches, security-camera style, so you're not storing
hours of dead air. Builds on "Auto-split long recordings" above for bounding
individual file size. Bigger in scope than the other three here — it changes
the whole interaction model (the menu toggle becomes pause/resume, or goes
away entirely) and needs an explicit retention policy (a rolling window,
like a dashcam) since keeping everything forever isn't realistic for disk
space or privacy. Worth a deliberate go/no-go conversation before scoping
further — always-on mic + system-audio capture is a meaningfully different
privacy posture than today's manually-started sessions.

## Auto-detect forgotten-recording tail and trim transcript
Status: idea

Easy to forget to stop a recording after everyone's left — the session keeps
capturing you talking to yourself (or dead air) for several more minutes,
which then shows up in the transcript as a run of low-confidence, fragmented
`me`-only segments. `TranscriptionCoordinator` already computes a full
per-speaker timeline during diarization (see CLAUDE.md's transcription
pipeline section), so detecting this post-hoc is cheap: walk the mic track's
timeline backward from the end and find the last point where two or more
distinct speakers actually alternate. Mark everything after that point as a
likely tail — either drop it from `transcript.json`/`transcript.md` or write
a `likely_ended_at` timestamp into `meta.json` for confirmation before acting
on it. Deliberately non-destructive: this only changes what's rendered into
the transcript, never touches the source `.caf` files, so a wrong guess costs
nothing. Distinct from "Continuous recording with silence trimming" above —
that's a real-time VAD-driven capture redesign; this is a one-shot heuristic
over data the pipeline already produces.
