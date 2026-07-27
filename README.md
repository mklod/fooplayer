# fooplayer

Custom music player (Windows desktop + Android) built around portable per-folder `.library.json` manifests that store **date downloaded as permanent data** — immune to tag editors. Album artwork is looked up automatically and stored beside the music. Replaces foobar2000.

## Project docs

| Doc | What it is |
|---|---|
| [docs/STATUS.md](STATUS.md) | **Current state** — read this first |
| [docs/CHANGELOG.md](CHANGELOG.md) | Dated history of what shipped |
| [docs/WORKPLAN.md](WORKPLAN.md) | Forward queue, gates, backlog |
| [docs/superpowers/specs/2026-07-23-music-player-design.md](docs/superpowers/specs/2026-07-23-music-player-design.md) | Approved design spec |
| [docs/superpowers/plans/](docs/superpowers/plans/) | Workplans: Plan 1 (core engine), 2a (Windows app), 2a.2 (UI rework + multi-root) |
| [docs/music-library-dates-issue.md](docs/music-library-dates-issue.md) | The file-dates problem + options (decision pending) |

## Layout

- `core/` — pure-Dart engine (`fooplayer_core`): content-ID hashing, manifest, scanner, seed migration, `foolib` CLI
- `app/` — Flutter app (Windows + Android). Built from local worktrees (`C:\dev\foobar-app` → branch `windows-app`, `C:\dev\fooplayer-android` → branch `android-app`) because this repo lives on an SMB share that can't host Flutter's symlinks
- Engineering scratch (task briefs/reports/ledger): `.superpowers/` (git-ignored)

## Quick commands

- Rescan/stamp library from CLI: `cd core && dart run fooplayer_core:foolib status|update|seed --root <music folder>`
- App tests: `cd C:\dev\foobar-app\app && flutter test`
- Desktop exe: `C:\dev\foobar-app\app\build\windows\x64\runner\Release\fooplayer_app.exe`

GitHub: https://github.com/mklod/fooplayer
