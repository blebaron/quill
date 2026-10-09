# Releasing Quill

Quill uses a **manual, source-only release**: reviewed source commit, annotated
tag and GitHub Release. Consumers build locally. Preparing files does not
authorize a commit, tag, push, publication or installation.

## 1. Prepare for review

- Agree the release version and scope with the maintainer.
- Update `Quill.releaseVersion` in `Sources/quill/Quill.swift` and
  `CFBundleShortVersionString` in `Sources/quill/Info.plist`; increment
  `CFBundleVersion`. Version tests check the source metadata agrees.
- Keep the tested dependency versions in both `Package.swift` and
  `Package.resolved`. Do not run an unreviewed dependency update during release.
- Update `CHANGELOG.md` and draft `docs/releases/v<version>.md`, including
  behavior changes, known limits, upgrade and rollback.
- Keep private recordings, transcripts, embeddings and calibration evidence
  outside the repository. Review `git status --short` for unrelated edits.
- Stop here for review. No release exists just because `--version` changed.

## 2. Validate the candidate

Use a separate checkout/copy, not a build directory backing someone's installed
binary. Run:

```sh
set -e
swift test
swift build -c release
swift test -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/quill" --version
"$BIN_DIR/quill" --help
"$BIN_DIR/quill" doctor
git diff --exit-code -- Package.resolved
```

- Check the version matches the intended tag and CLI invalid-request failures
  preserve prior artifacts. The automated tests use synthetic/fake-engine data,
  not private recordings. Record any separate CLI checks performed.
- Review doctor warnings. It checks cache availability but cannot certify
  system-audio permission; a zero exit is not a fresh-capture test.
- Before publication, explicitly approve and perform a short nonsensitive
  recording/transcription smoke test, or record the maintainer's explicit
  decision to accept the existing validation instead. Never record silently.
- Document the tested Mac/toolchain. Do not claim other architectures or
  macOS versions were tested without evidence.

For a real CLI failure-path check, use only a disposable synthetic fixture
outside the configured recordings root. After setting `BIN_DIR` above:

```sh
(
  set -e
  PROBE_DIR="$(mktemp -d)"
  trap 'rm -rf "$PROBE_DIR"' EXIT
  printf '%s\n' '{"files":{"mic":"synthetic.m4a"}}' > "$PROBE_DIR/meta.json"
  printf '%s\n' 'synthetic placeholder, never decoded' > "$PROBE_DIR/synthetic.m4a"
  for file in transcript.json transcript.md speakers.json; do
    printf 'prior %s\n' "$file" > "$PROBE_DIR/$file"
    cp "$PROBE_DIR/$file" "$PROBE_DIR/$file.before"
  done
  if "$BIN_DIR/quill" rediarize "$PROBE_DIR" --system-speakers 2 \
      > "$PROBE_DIR/run.log" 2>&1; then
    echo 'Unexpected success for missing system track' >&2
    exit 1
  fi
  grep -F 'missing audio track(s): system' "$PROBE_DIR/run.log"
  if grep -F 'done —' "$PROBE_DIR/run.log"; then exit 1; fi
  for file in transcript.json transcript.md speakers.json; do
    cmp "$PROBE_DIR/$file.before" "$PROBE_DIR/$file"
  done
)
```

The expected error check prevents an unrelated executable/permission failure
from being mistaken for a passing guard test. No recording or model inference
is needed for this preflight failure.

## 3. Commit only approved files

Get explicit commit approval. Remove the draft banner from approved release
notes, then stage the exact reviewed files. Never use `git add -A` to sweep in
unrelated edits. For v0.1.0 the intended set is:

```sh
(
set -e
if ! git diff --cached --quiet; then
  echo 'Index is not empty; resolve pre-existing staged changes with their owner first' >&2
  exit 1
fi
git add -- Package.swift Package.resolved README.md RELEASING.md CHANGELOG.md \
  docs/releases/v0.1.0.md Sources/quill/Quill.swift Sources/quill/Info.plist \
  Sources/quill/RecordingsAgentsDoc.swift \
  Sources/quill/Transcription/DiarizationEngine.swift \
  Sources/quill/Transcription/TranscriptionCoordinator.swift \
  Tests/quillTests/SpeakerLabelTests.swift \
  Tests/quillTests/FluidAudioUpgradeTests.swift \
  Tests/quillTests/RequestedCountSafetyTests.swift Tests/quillTests/VersionTests.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
git commit -m "release: Quill v0.1.0"
)
```

`AGENTS.md` is intentionally absent from that list: preserve the unrelated
pre-existing edit unless separately reviewed and approved. Check that the
commit contains only the agreed public release files.

## 4. Verify the exact commit before tagging

Create a fresh detached worktree/clone at the candidate commit and repeat the
validation above. This makes the release independent of unstaged local edits.
Keep its logs and commit SHA. If validation changes the dependency lockfile or
finds a regression, stop and review the change before proceeding.

Record that exact reviewed SHA as `APPROVED_COMMIT`. Do not substitute a later
HEAD. The version's approved notes must be committed at that SHA with their
draft banner removed. Publication reads those committed bytes, not a working
copy that may have changed since validation.

## 5. Tag and publish only after explicit approval

The publishing account for this repository is `blebaron`; the destination is
`https://github.com/blebaron/quill.git`, branch `master`, not the upstream fork.
Confirm `git remote get-url origin` first. Recheck the remote branch, tags and
releases. Stop if the version exists or the remote has conflicting changes;
do not force-push or move a published tag.

After explicit approval, from the release repository root:

```sh
(
  set +x
  set -e
  version=0.1.0
  tag="v$version"
  : "${APPROVED_COMMIT:?Set this to the exact SHA reviewed and validated in step 4}"
  commit="$(git rev-parse "$APPROVED_COMMIT^{commit}")"
  test "$commit" = "$(git rev-parse HEAD)"
  test "$(git remote get-url origin)" = 'https://github.com/blebaron/quill.git'
  NOTES_FILE="$(mktemp)"
  trap 'rm -f "$NOTES_FILE"' EXIT
  git show "$commit:docs/releases/$tag.md" > "$NOTES_FILE"
  if grep -F 'Draft for review' "$NOTES_FILE"; then
    echo 'Release notes are still a draft' >&2
    exit 1
  fi
  # Per-operation credentials; no global account switch. Do not enable shell tracing.
  GH_TOKEN="$(gh auth token --user blebaron)"
  test -n "$GH_TOKEN"
  export GH_TOKEN
  git tag -a "$tag" "$commit" -m "Quill $version"
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push origin "$commit:refs/heads/master"
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push origin "refs/tags/$tag"
  gh release create "$tag" --repo blebaron/quill --verify-tag \
    --title "Quill $version" --notes-file "$NOTES_FILE"
)
```

Verify the remote tag resolves to the tested commit and the GitHub Release is
published before announcing it. Failed commands are blockers, not completion;
read the remote state before retrying an interrupted publish. Do not attach
private evidence or an unreviewed binary. Publication does not install Quill
on anyone's Mac. Binary distribution, signing/notarization and automatic
updates need a separate decision.

## 6. User upgrade and rollback

Send users the release link and the version's migration/rollback notes. They
choose when to upgrade, after finishing recording and transcription. Software
rollback does not undo transcripts regenerated by the new version; only the
saved session artifacts restore those. GitHub is authoritative for publication
status; local Beads completion alone never means a release shipped.
