---
title: "Persistent speaker name catalog from voice embeddings"
date: 2026-08-05
beads_issue: quill-up5
requested_by: brAIn (AI-agent consumer of quill recordings)
affects: "speaker identification across sessions"
---

Original consumer request, retained as design context. The current scope and
status live in the single Beads issue `quill-up5` (`bd show quill-up5`).

## Context

quill already computes and persists a real voice embedding for every non-`me`
speaker in every session (`speakers.json`, `SpeakerInfo.embedding: [Float]`,
sourced from FluidAudio's diarization pipeline). Nothing currently matches
these embeddings against anything else. `Speaker 1`, `Speaker 2`, etc. are
not stable identities across sessions — quill's own agent-facing docs say so
directly (`RecordingsAgentsDoc.swift`), and flag a name-resolving pass as a
known future gap, not yet built.

brAIn (Brian's personal task/inbox system) consumes quill transcripts as an
input source and currently works around the gap by asking Brian to manually
confirm who's who in every session before processing it
(`rules/recordings.md`). That's the cost this feature would remove.

## Desired outcome

A speaker who has been identified once, in any past session, is
automatically recognized in every future session — without a human (or an
agent on their behalf) re-confirming identity every time.

Concretely:
- `transcript.md` / `transcript.json` / `speakers.json` show a real name
  (e.g. `Jeff Lewis`) instead of `Speaker 2` for any voice quill has already
  matched to a known name, for *every* session going forward — not just the
  one where the name was first supplied.
- A genuinely new voice still shows up as `Speaker N`, unresolved, exactly as
  today — this feature narrows the unresolved set over time, it doesn't
  eliminate it.
- The catalog is durable across quill upgrades unless the underlying
  embedding model changes, in which case quill should be explicit that old
  entries no longer apply (see Risks) rather than silently mismatching.

## How brAIn would like this to work

brAIn doesn't need to own or duplicate the matching logic — it's quill's
data and quill's model. What brAIn needs from quill:

1. **A way to label a voice, once.** Some interface — CLI is enough, e.g.
   `quill identify-speaker <session-dir> <speaker-label> "<name>"` — that
   takes an unresolved `Speaker N` in a given session and records its
   embedding under a real name in a persistent catalog. brAIn (or Brian
   directly) is the one supplying the name; quill owns storing and matching
   it.
2. **Automatic resolution on future sessions.** Once a name is in the
   catalog, any subsequent session whose diarization produces a
   sufficiently-similar embedding gets labeled with that name directly in
   `transcript.md`/`transcript.json`/`speakers.json`, with no per-session
   confirmation step required.
3. **A visible "confidence" signal for near-matches**, so a consuming agent
   (brAIn or otherwise) can tell "quill is confident this is Jeff Lewis" from
   "quill has a low-confidence guess, worth a human double-check" — even a
   coarse two-tier signal (resolved vs. tentative) is enough; brAIn's own
   `rules/recordings.md` can decide what to do with a tentative match (e.g.
   still ask Brian to confirm, but only for the *tentative* ones — the
   already-known speaker.

Once these three exist, brAIn's own confirmation step in
`rules/recordings.md` narrows from "confirm every unnamed speaker in this
session" to "confirm only speakers quill couldn't already resolve" — the
per-session cost drops toward zero as the catalog fills in.

## Ownership boundary (why this belongs in quill, not brAIn)

- The embedding format and matching math are tied to FluidAudio, which quill
  owns; a brAIn-side catalog would be duplicated logic that silently breaks
  if quill's diarization model changes.
- Solving it once in quill benefits every consumer of a quill transcript
  (brAIn, or any other future agent/human reading the recordings folder
  directly), not just brAIn.
- brAIn keeps owning the parts that are inherently its own: the moment it
  asks Brian to confirm an identity, and what it does with a tentative
  match. It does not need to own where the catalog lives or how similarity
  is computed.

## Open questions / risks

- **Model versioning:** if the FluidAudio embedding model changes, old
  catalog entries may no longer be comparable to new embeddings. The catalog
  should carry a model-version tag per entry so a mismatch is detected
  explicitly (fall back to unresolved) rather than silently matching wrong.
- **Bad input poisoning the catalog:** a mis-clustered session (see
  `.issues/rca-002-diarization-speaker-collapse.md` — busy single-mic
  recordings can collapse multiple real speakers into one `Speaker 1`) could
  get labeled with a name that's actually a blend of several people's voices
  if identified before the collapse is caught. Worth deciding whether
  `identify-speaker` should warn (or refuse) when the target speaker's
  talk-time share looks anomalously high for the session's likely headcount.
- **Where the catalog lives:** a local file (e.g. `speaker_catalog.json` next
  to quill's other config) is probably sufficient — no strong opinion from
  brAIn's side beyond "quill owns it."

## Relevant quill source (read while scoping this request)

- `Sources/quill/Transcription/TranscriptionCoordinator.swift` —
  `SpeakerInfo` struct and `writeSpeakers`, where `speakers.json` is written.
- `Sources/quill/Transcription/DiarizationEngine.swift` — where the
  embedding actually comes from (FluidAudio's `OfflineDiarizerManager`).
- `Sources/quill/RecordingsAgentsDoc.swift` — the schema doc handed to any
  agent reading a recordings folder; already flags this as a known future
  gap ("not built yet").
- `.issues/rca-002-diarization-speaker-collapse.md` — adjacent risk noted
  above.
