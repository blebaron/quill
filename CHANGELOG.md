# Changelog

Version sections describe source changes. Publication status and dates live on
[GitHub Releases](https://github.com/blebaron/quill/releases).

## 0.1.0

### Changed

- Pin FluidAudio to 0.17.7. The offline diarizer now checks active/assigned
  clusters rather than the initial cluster count when applying speaker-count
  constraints. Automatic clustering and speaker partitions can change.
- Explicit-count reruns reject missing tracks, nonpositive counts, diarization
  failures, absent results and mismatched returned timeline counts before
  replacing existing transcript/speaker artifacts.
- Generated recording guidance explains count targets, identity uncertainty
  and rerun risks. It refers to the recording owner rather than a specific user.

### Added

- `quill --version` and matching embedded version metadata.
- Synthetic clustering, artifact-preservation, invalid-request, guide and
  version regressions.
- Source-release checklist and upgrade/rollback documentation.

### Limits

- A count match does not establish identities, clean voice separation or the
  final number of transcript labels.
- Successful reruns still replace generated artifacts and rerun ASR. Back up
  the session first; words, timestamps and labels may change.
- Full processing-health results and uncertain-candidate review are not yet
  implemented. E5RT warnings are not resolved by this release.
