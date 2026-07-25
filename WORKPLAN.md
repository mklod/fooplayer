# fooplayer — WORKPLAN

*Forward-looking queue. State: [STATUS.md](STATUS.md) · History: [CHANGELOG.md](CHANGELOG.md). Last update: 2026-07-24.*

## ✅ Completed 2026-07-24 night (post-reboot)

- Emulator verified under WHPX (15s boots, app runs, AEHD gone for good).
- Held UI batch #27–31 shipped via ultracode round 2 (see CHANGELOG): track numbers in folder-opened albums, clickable breadcrumb, playlist CRUD + deselection, metro transport buttons — plus the adversarial zombie-rescan fix.

## Next milestones (order per Mike: desktop polish → mobile)

3. **Repo migration** to `L:\PROJECTS\fooplayer` (fresh clone from GitHub, re-point worktrees, retire old dir).
4. **Android rebase + phone-native UI plan (Plan 2b proper)**: rebase `android-app` onto `main`; design per Mike's directive — *no desktop panels on mobile*: date feed home, hamburger/drawer for folders/artists/albums/playlists, persistent mini-player. Test on emulator + real Pixel 7 (USB).
5. **Plan 3 — LAN pull / phone sync**: one-button pull of new files + manifests from the NAS share to the phone (design sketch exists in the original spec; manifests make the diff trivial).

## Decision gates (Mike only)

- **File-dates fix** for foobar2000/Explorer sorting — options documented in [music-library-dates-issue.md](docs/music-library-dates-issue.md); NO filesystem-date action without his explicit go-ahead.

## Backlog (deferred minors, triaged non-blocking)

- "NN." dot-prefix track-number parse ("01. Gorilla Zoe") 
- Fuzzy title matching for the 26 unmatched "alternative times" playlist lines
- Missing-file tracks not hidden from the feed (spec line-item; add flag/filter using rescan's diff)
- `visibleTracks` memoization (recomputes per player tick); gear-tap integration test; multi-format tagged-file fixtures (package-upgrade protection)
- Deeper duration probe for never-played null-duration tracks; duration re-check on retag
- Empty-roots config restart quirk; `.bad` backup clobber on repeat corruption; sub-400px bar widths
- Workflow-script hygiene: normalize reviewer severity labels (high/medium leaked past a critical|important filter once)

## Process (as agreed with Mike)

- UI iteration: no pausing to ask — implement the reasonable interpretation, screenshot, iterate.
- Parallel work: ultracode workflow rounds with isolated branch worktrees + merge agent + adversarial review; trivial fixes done inline by the orchestrator.
- Full review rigor stays (it has caught: a UI-freezing parser stall, a wrong-duration race, a broken explorer launcher, a dead launch-rescan, a biased shuffle, a file-handle leak).
