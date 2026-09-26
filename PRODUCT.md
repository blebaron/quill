# Quill product direction

Quill is Brian's **local meeting memory**: a deliberately captured, timestamped
source he can bring into his work when he needs it. It is not an automatic
meeting-ingestion or task-creation pipeline. The original audio remains
available to check what was said, especially when a recap or speaker label is
in doubt.

## How it is used

Brian starts and stops a recording, then selects a conversation for brAIn to
use when he needs a recap, follow-up, ongoing 1:1 context, interview evidence,
or a later check of an exact exchange. brAIn asks him to confirm or correct
speaker identities before attributing statements to people. It proposes work
for his review rather than treating a spoken commitment as an outstanding task.
Quill can transcribe sessions arriving in its configured recordings root;
that does **not** authorize brAIn to process them into work without a request.

## Ownership boundary

Ownership describes where a capability belongs, not what has shipped; import,
quality reporting, vocabulary corrections, and voice recognition are proposed
work.

- **Quill owns the source:** local capture and explicit import, original audio,
  timing, transcript and speaker artifacts, provenance, auditable vocabulary
  corrections, processing diagnostics, and safe reruns. It can suggest a name
  from a verified voice reference, but must preserve the session's cluster ID
  and make uncertainty visible. It cannot certify who spoke from processing
  diagnostics alone.
- **brAIn owns interpretation:** finding the requested conversation, using
  context to propose speaker mappings, interpreting decisions and commitments,
  checking other channels for already-completed work, and proposing Tasks or
  Thinking Notes for Brian to review. It must not silently turn an uncertain
  speaker suggestion into a person-attributed action.
- **Brian owns consequential decisions:** confirming identities, accepting
  follow-up, and deciding when ambiguous evidence is good enough to use.

Put facts at the earliest layer that can establish them; put judgments where
the necessary context and authority live. A request belongs in Quill when it
needs audio, embeddings, model behavior, or artifact history and is useful to
other transcript consumers. A request belongs in brAIn when it needs project,
person, or task state. Reframe requests that require Quill to guarantee an
identity it cannot verify, discard source evidence, or bypass human review.
Costly or low-priority is not the same as unreasonable.

## Papercut intake

When Brian asks brAIn to gather Quill-related papercuts, use observed friction
from the requested workflow, not an unsolicited scan of recordings. For each
distinct problem, give a short symptom, consequence, and example or workaround
if known; mark unknowns rather than inventing evidence. Sort it by the
ownership boundary above:

- **brAIn side:** finding the selected meeting, interpreting it, checking
  existing work, or asking Brian to confirm identity. Keep these out of
  Quill's issue database.
- **Quill side:** capture/import, source artifacts, ASR/diarization, vocabulary,
  provenance, processing health, or safe reruns. Check `bd list --all --json`
  and `bd show <id> --json` for an existing issue before proposing a new one.
- **Shared:** name the outcome and give each side its own responsibility;
  specify what signal or artifact Quill must provide and what brAIn must do
  with it. Do not file the same problem twice in Quill.

Show Brian the split and any matching Quill issue IDs first. **Gathering is not
authorization to create, claim, close, or reprioritize issues.** If he asks to
file the Quill-owned items, add concrete impact, a safe reproduction example,
and an observable acceptance criterion in Beads (`bd create ... --json`), or
add new evidence to the existing issue (`bd update <id> --append-notes ... --json`).
Preserve the original report without putting private meeting audio,
transcript excerpts, embeddings, or identifying details into an issue by
default. brAIn-side work stays with brAIn; Quill's Beads is not its backlog.

Make repeat handoffs **delta-first**. If every Quill-side observation already
maps to an issue and adds no new evidence or decision, say so briefly rather
than restating the backlog. For a new or changed observation, report its owner,
matching issue ID (if any), what happened and why it matters, and the smallest
safe example that could verify a fix. Distinguish an observed failure from a
suggested solution; say when frequency, impact, or reproduction is unknown.
For shared work, state what Quill needs to expose and what brAIn will do with
it. Only propose a priority change when new evidence or a product decision
justifies one. Do not inspect private recordings merely to complete an intake
report; ask Brian before using one as a test case.

For each mapped Quill problem reported in a handoff, include its stable
`quill-...` Beads ID. If brAIn keeps a related note or issue on its side,
retain that ID as the reference back to Quill; do not copy Quill's status into
a second tracker.

When Brian asks for progress, resolve the current status with
`bd show <id> --json` from this Quill checkout. Beads data is local to a
checkout unless separately synced, so an ID alone is not a public web link.

## Processing quality contract (target, not yet implemented)

Report **processing stages**, **output assessment**, and **rerun disposition**
separately. A command finishing does not mean its candidate passed review;
an upstream exception alone does not prove it failed.

- **Usable for review:** required artifacts are present and internally
  consistent; timing and speaker metadata are plausible. This does not
  verify speaker identity or authorize person-attributed follow-up.
- **Needs review:** words may be useful but attribution is uncertain, such as
  a suspected split, collapse, or cross-track mix. Flag the reason and, where
  possible, the affected passages. brAIn seeks confirmation before assigning
  a person an action from them.
- **Invalid:** required output is missing, broken, or internally inconsistent.
  Do not present it as a clean result.
- **Rerun disposition:** compare a candidate to the current result. If it is
  invalid or visibly loses content or speaker separation, keep the prior
  version as the default and retain the candidate for diagnosis. If quality
  cannot be established, preserve both for explicit review rather than
  silently replacing the default.

The classifications and preservation behavior are the goal for `quill-xdp`,
not a claim about today's CLI. Real sessions can later calibrate heuristics;
they are not needed to agree on the contract.

## How to prioritize

Prefer work that makes a selected recording safer and less costly to use:
first prevent misleading results and irreversible reruns, then reduce recurring
source corrections and identity-confirmation work, then improve access to the
source. Weigh observed frequency and consequence against effort and
uncertainty. Keep local processing, deliberate capture, source preservation,
and human review as constraints; always-on capture needs a separate privacy
and retention decision.

This document records product direction, **not feature status**. Decisions
and work are tracked in Beads: `quill-4jp` records the on-demand product goal;
`quill-xdp` tracks the processing quality contract. Use `bd ready` and
`bd show <id>` for current priorities and scope.
