# fooplayer — WORKPLAN

*Forward-looking queue. State: [STATUS.md](STATUS.md) · History: [CHANGELOG.md](CHANGELOG.md). Last update: 2026-07-27.*

## ✅ Completed since the last plan revision

- Repo migration to `L:\PROJECTS\fooplayer`; old `foobar` dir deleted and verified clear.
- Android phone-native UI (Plan 2b) shipped and verified on the emulator; launcher icon + app label.
- Album artwork lookup (Plan 4) shipped on both platforms: auto-enrichment + picker, two adversarial-review passes' findings fixed.
- Emulator rebuilt at 16 GB and seeded with the real 444-file library.
- Live-use polish: metro glyph hairlines, blue shuffle, breadcrumb ↑ up-one-level, phone volume removal, uniform column typography.

## Next milestones

1. **Real-device pass** — install the APK on the Pixel 7 over USB, exercise the phone UI on real hardware (touch targets, scroll feel, playback, artwork on a real network). Needs Mike to plug the phone in.
2. **Plan 2c — background audio**: `audio_service` integration so playback survives screen-off with lock-screen/notification controls and proper audio-focus handling. This is the gap between "a music app on a phone" and "a music app you'd actually use on a phone".
3. **Plan 3 — phone library sync**: one-button LAN pull of new files + manifests from the NAS to the phone. Manifests make the diff trivial (content IDs already identify what's missing); the hard parts are Android storage scope (app-private vs. shared media) and transfer resilience.
4. **Artwork polish (optional)**: batch "fix all missing artwork" view, artist images/fanart types, opt-in `folder.jpg` writing beside albums.

## Decision gates (Mike only)

- **File-dates fix** for foobar2000/Explorer sorting — options in [docs/music-library-dates-issue.md](docs/music-library-dates-issue.md); NO filesystem-date action without an explicit go-ahead.

## Backlog (deferred minors, triaged non-blocking)

- "NN." dot-prefix track-number parse ("01. Gorilla Zoe")
- Fuzzy title matching for the 26 unmatched "alternative times" playlist lines
- Missing-file tracks not hidden from the feed (spec line-item; rescan's diff already knows)
- `visibleTracks` memoization (recomputes per player tick); gear-tap integration test; multi-format tagged-file fixtures (package-upgrade protection)
- Deeper duration probe for never-played null-duration tracks; duration re-check on retag
- Empty-roots config restart quirk; `.bad` backup clobber on repeat corruption; sub-400px bar widths
- Artwork: late CAA results discarded after the picker's budget expires; noise-word normalizer can fold distinct album titles together (accepted fuzzy-matching trade-off)
- Workflow-script hygiene: reviewer severity labels are enum-locked now; keep it that way (a non-enum label once slipped a finding past a filter)

## Process (as agreed with Mike)

- UI iteration: no pausing to ask — implement the reasonable interpretation, screenshot, iterate.
- Parallel work: ultracode rounds (isolated branch worktrees → merge agent → integrity + adversarial review → single fixer); trivial fixes done inline by the orchestrator instead of spawning agents.
- Review rigor stays. It has caught, among others: a UI-freezing parser stall, two wrong-data races (duration, artwork), a silently broken explorer launcher, a dead launch-rescan, a biased shuffle, a file-handle leak, and a zombie isolate that could clobber a playlist write.
