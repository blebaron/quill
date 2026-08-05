---
title: "Multi-speaker mic recordings collapse into a single Speaker"
date: 2026-08-05
status: mitigated
affects: "speaker diarization on busy, single-mic recordings"
---

## Context

`f3fc3a2` added per-track diarization (`DiarizationEngine`, wrapping
FluidAudio's `OfflineDiarizerManager`) specifically so a mic track with
several people in the room — not just mic-vs-system 2-party calls — would get
split into distinct `Speaker N` ids. Session `2026.08.05-1104` was a ~51-minute
in-person meeting with 7 people, recorded entirely on `mic.caf` (`system.caf`
was near-silent, correctly skipped: "diarization skipped for system.caf:
noSpeechDetected"). The whole mic track diarized as a single `Speaker 1`.

## Problem statement

`speakers.json` had exactly one entry for the session — 47.5 of 51 minutes of
talk time on one `Speaker 1` id. The 7-person conversation was clearly visible
in the transcript text (multiple named people, back-and-forth turns), so this
wasn't a case of a genuinely single-speaker recording.

## RCA

Reproduced directly against FluidAudio's own `fluidaudiocli process --mode
offline` on the session's `mic.caf`:

| Run | Result |
|---|---|
| default (auto) | 1 cluster |
| `--min-speakers 2` | 1 cluster — no change |
| `--threshold 0.4` / `0.3` (tighter clustering) | 1 cluster — no change |
| `--num-speakers 7` (exact) | **7 clusters**, matching the room |

Instrumenting `OfflineDiarizerManager.process` (temporarily, in the vendored
checkout under `.build/checkouts/FluidAudio`) showed why the threshold and
`minSpeakers` runs did nothing:

```
hasConstraints=true rawMin=2 resolved=(min:2, max:1789)
initialClusters.uniqueCount=55
refineWithConstraints detectedCount=55 min=2 max=1789 needsAdjustment=false
```

The pipeline is AHC (threshold-based warm start) → VBx (EM refinement) →
optional KMeans re-cluster if the speaker count is out of bounds:

1. AHC actually found **55** initial voice clusters from the mic track's 1789
   training embeddings — the clustering threshold was never the problem.
2. VBx takes those 55 as an EM warm start and, via its own mixture-weight
   (`pi`) pruning, decided at convergence that only 1 of the 55 had
   meaningful support — the other 54 got pruned toward zero weight. That's
   the actual collapse to "Speaker 1" (`OfflineDiarizerManager.swift`, the
   `pi.enumerated().filter { $0.element > epsilon }` step that builds
   centroids).
3. `VBxOutput.numClusters` is set to the **warm-start** count (55), not the
   number of speakers that survived EM pruning. So
   `SpeakerCountConstraints.needsAdjustment(detectedCount:)` compares
   `minSpeakers` against 55 — which is essentially always satisfied — and
   never fires the KMeans re-cluster meant to catch exactly this failure.
   The real, pruned-down count is invisible to that check.
4. `--num-speakers 7` (exact) worked only because an exact target makes
   `needsAdjustment` compare 55 against 7 — any mismatch forces the KMeans
   override, bypassing VBx's pruning outcome entirely. It's not that 7 is
   detected correctly; any exact count would force the same override.

Net: this is an upstream gap in FluidAudio's offline pipeline (the
speaker-count safety net checks the pre-EM cluster count instead of the
post-EM active count), not something tunable from quill's side via
`clusteringThreshold`/`minSpeakers`. Not filing upstream (see decision below)
— documented here instead so the failure mode and workaround are known.

## Mitigation

There's no way to know the right speaker count ahead of time for a passive
background recording, so this can't be fixed automatically in the normal
per-session pipeline. Instead: a manual, on-demand path.

- `DiarizationEngine.diarizeWithKnownSpeakerCount(_:count:)` builds a
  dedicated `OfflineDiarizerManager` with `.default.withSpeakers(exactly:)`,
  bypassing the broken automatic detection entirely.
- `TranscriptionCoordinator.reprocess(_:speakerCountOverrides:)` re-runs ASR +
  diarization + merge for one session, with an explicit count for one or both
  tracks (`"me"`/`"them"`), overwriting transcript.json/.md and
  speakers.json. Runs regardless of `diarization.enabled` — an explicit
  request overrides that default.
- `quill rediarize <session-dir> --mic-speakers N [--system-speakers N]` is
  the CLI entry point — for a human, or an agent that's read the transcript
  and can tell from context that "everyone became one Speaker" is wrong and
  knows (or can ask) the actual headcount. Documented in
  `RecordingsAgentsDoc.swift` (agents-doc version 3) so an agent pointed at a
  recordings folder knows this exists and when to suggest it.

## Relevant files

- `Sources/quill/Transcription/DiarizationEngine.swift` —
  `diarizeWithKnownSpeakerCount`.
- `Sources/quill/Transcription/TranscriptionCoordinator.swift` — `reprocess`,
  the `speakerCountOverrides` threading through `transcribe`.
- `Sources/quill/Quill.swift` — `Rediarize` CLI subcommand.
- `Sources/quill/RecordingsAgentsDoc.swift` — documents the failure mode and
  the fix for agents reading a transcript.
- `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift`
  and `.../Clustering/VBxClustering.swift` — upstream code where the
  mismatch lives (`numClusters` vs. post-pruning active count).
