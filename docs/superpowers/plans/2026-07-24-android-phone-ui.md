# Android Phone UI (Plan 2b) Implementation Plan

> **For agentic workers:** executed as an ultracode workflow (integration task first, then parallel worktree round + merge + adversarial review + fix). Compact plan: Global Constraints are the spec.

**Goal:** fooplayer on Android looks and works like a phone app — Mike's directive verbatim: "mobile will not perfectly mirror desktop. there's no space for the panels that desktop has. rely on hamburger menu/panels" — while desktop keeps its panel layout from the same codebase.

**Architecture:** one adaptive switch (phone form factor → `PhoneShell`, else existing `HomeScreen`); phone UI is new widgets under `app/lib/ui/phone/` reusing the existing `LibraryModel`/`PlayerService`/`PlaylistStore` unchanged wherever possible. Playback stays in-app (no background-audio service in 2b — that's 2c with `audio_service`).

## Global Constraints

- Branch `android-app`, worktree `C:\dev\fooplayer-android`; keep `windows-app`/desktop behavior byte-identical (all 275 existing tests keep passing; adaptive switch must not disturb desktop widget tests).
- Bash env per call: `export PATH="/c/dev/flutter/bin:/c/Users/mklod/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"`; JAVA_HOME = Temurin 17 for gradle; tests from `app/`; analyze clean; `flutter build apk --debug` must succeed (gradle heaps stay trimmed).
- Form-factor switch: `bool usePhoneShell(BuildContext)` = `Platform.isAndroid || MediaQuery.shortestSide < 600` (tablet future-proofing) — lives in `app/lib/ui/adaptive.dart`; `main.dart` picks the shell. Desktop windows NEVER satisfy it (Platform.isWindows guard).
- Phone design tokens: same `AppColors` light theme.
- **PhoneShell** (`app/lib/ui/phone/phone_shell.dart`): Scaffold + AppBar (hamburger, title = current view name, search icon → `PhoneSearchPage`), Drawer, body = current view, `bottomNavigationBar`-slot = `MiniPlayer` (only when a track is loaded).
- **Drawer**: entries Library (feed), Folders, Artists, Albums, Playlists (with per-playlist children or a Playlists page), Settings (reuses existing `SettingsDialog` content as a page). Selecting navigates the body view; active entry highlighted `selectionFill`.
- **Feed (home)**: date-added-desc list; rows = title (13 ink), artist — album (11.5 inkSecondary), duration right; tap = play (phone idiom — NOT desktop's select-then-double-click), long-press = context sheet (Add to playlist / View details; no explorer on Android).
- **Folders view**: drill-down list reusing `folderEntries`/`drillIntoFolder`/`popFolderTo`; AppBar back pops one level; breadcrumb text under AppBar.
- **Artists / Albums views**: alphabetical lists from existing getters; tap → filtered track list page (album page sorts by trackNumber via existing logic).
- **Playlists view**: list + create (+) + swipe/long-press delete (confirm); tap → playlist tracks (playlist order).
- **MiniPlayer** (`phone/mini_player.dart`): 64px bar — art 48, title/artist, play/pause (metro icon), tap-anywhere → `NowPlayingPage`.
- **NowPlayingPage** (`phone/now_playing_page.dart`): large art (min(width−48, 360)), title/artist/album centered, seek slider + times, transport row with the metro icons (prev 32 / play-pause 48 / next 32), shuffle (state glyphs) + volume row.
- Storage scope for 2b: app-private library dir only (`platform_paths.dart` default; seeded via adb for testing). Real device/media-store access is Plan 3 territory — do NOT add permissions/SAF in 2b.
- Tests: widget tests for PhoneShell (drawer entries + navigation switches body + active highlight), feed (tap plays via injected onPlayTrack, rows show duration), folders view (drill + AppBar back pops), mini-player (appears when queue set, play/pause toggles, tap opens NowPlayingPage), now-playing (metro assets render, seek slider present), adaptive switch (desktop stays HomeScreen — pump with Platform overridden via injectable `isAndroidOverride` on usePhoneShell for testability).

## Tasks

### Task 0 (serial, before the parallel round): integrate main into android-app
In `C:\dev\fooplayer-android`: merge `main` (1dc9765+) into `android-app`. Real conflicts expected in `app/pubspec.yaml` (union of deps: media_kit_libs_android_audio + path_provider + file_selector + fooplayer_core path dep) and `app/lib/main.dart` (the android branch's platform_paths wiring predates config v2 / LayoutPrefs / rescan / lifecycle flush / PlaylistStore — RE-PORT platform_paths (`appDataDir()`/`defaultLibraryRoots()`) into the CURRENT main.dart structure rather than resurrecting old code; Windows behavior byte-identical, Android paths via path_provider). Keep `android/` platform files + gradle.properties heap trim. Contract: full `flutter test` green (275+), analyze clean, `flutter build apk --debug` succeeds AND `flutter build windows --release` still succeeds (desktop untouched proof). Commit.

### Parallel round (worktrees off the integrated android-app head)
- **P1 shell+feed+adaptive**: adaptive.dart + PhoneShell + Drawer + Feed view + Search page; main.dart switch. Owns main.dart.
- **P2 player surfaces**: MiniPlayer + NowPlayingPage (+ hooks: PhoneShell exposes a builder slot P1 defines — coordinate via the plan: P1 lands the slot contract in phone_shell.dart FIRST as a stub file both branches include identically... simpler: P2 creates mini_player.dart/now_playing_page.dart standalone with their tests; wiring line into PhoneShell happens in merge (documented one-liner) or P1 stubs it behind `Widget Function()?`).
- **P3 browse views**: Folders/Artists/Albums/Playlists pages + long-press sheet + playlist create/delete phone UI (reuses PlaylistStore).

### Merge → integrity review + adversarial review (severity enum: critical|important|minor ONLY) → single fixer.

### Verification (controller): install on pixel7 emulator, seed test lib, drive drawer/feed/now-playing via adb taps, screenshots; then rebuild desktop release and spot-check desktop unchanged.

## Out of scope (2b)
Background audio/notification controls (2c, audio_service); real media-store/SAF storage + phone library sync (Plan 3); tablet layouts.
