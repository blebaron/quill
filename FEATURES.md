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
Status: idea

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
