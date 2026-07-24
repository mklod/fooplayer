# UI Rework + Multi-Root (Plan 2a.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Prerequisite: the enrichment-stall fix (Task 9 debug) must be merged into `windows-app` before Task 1 starts.

**Goal:** iTunes-style light theme, centered fully-readable now-playing bar, draggable frame dividers, multiple source folders, and in-app rescan (launch / Refresh / periodic) so new downloads appear automatically.

**Architecture:** All work on branch `windows-app` in worktree C:\dev\foobar-app. The app gains a path dependency on `fooplayer_core` (the tested Plan-1 engine) and takes over manifest updating from the CLI. UI work is centralized: all colors/type live in a new `app_theme.dart` — no widget hardcodes a color afterward.

**Tech Stack:** existing + `file_selector` (first-party folder picker), `fooplayer_core` via `path: ../../core`… (path dep from the worktree: `../core` relative to `app/` — the worktree checks out the whole repo, so `core/` is a sibling of `app/`).

## Global Constraints

- Worktree C:\dev\foobar-app; commit there; tests `flutter test` from app/; `flutter analyze` clean; full suite green per task. Never touch L:\music or L:\APPS beyond reads; NEVER any mtime/ctime writes (user hold).
- Bash PATH prefix: `export PATH="/c/dev/flutter/bin:/c/Users/mklod/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"`
- New deps allowed ONLY: `file_selector`, `fooplayer_core` (path). Everything else stays.
- **Design tokens (Task 1 creates `app/lib/ui/app_theme.dart`; every later color/type comes from it):**
  - `windowBg #FAFAFA`, `panelBg #F2F2F4`, `barBg #ECECEE`, `hairline #D9D9DE`
  - `ink #1D1D1F` (primary text), `inkSecondary #6E6E73`
  - `accent #0A84FF` (selection, active slider track, current-track title, links) — used sparingly; NO purple anywhere
  - `selectionFill #DFEBFB` (selected rows/panel entries, with `ink` text — not white-on-blue)
  - Type: system default (Segoe UI on Windows); sizes: list rows 13, subtitles 11.5, panel headers 11 w600 uppercase +0.4 letter-spacing, bar title 13 w600. Dense `visualDensity: compact` everywhere.
  - Light `ThemeData(useMaterial3: true, colorScheme: ColorScheme.light(...))` built from the tokens explicitly — never `ColorScheme.fromSeed` (it reintroduces tinted purples).
  - Sliders: 2px tracks, 6px thumb, active = accent, inactive = hairline; no value indicator.
- **Bar layout (Task 2):** height 72. `[transport: prev/play/next] [Expanded spacer] [LCD cluster, centered, maxWidth 720: art 56 + column(title; artist — album; thin seek row: pos — slider — total)] [Expanded spacer] [shuffle | volume 100]`. LCD text is Expanded within the cluster: ellipsis ONLY when the window is genuinely too small, never a fixed 220px crop. Bar background `barBg`, top hairline border.
- **Dividers (Task 3):** custom drag handles (no package): sidebar width (clamp 140–400, default 200), filter-row height (clamp 120–320, default 180). 6px hit area over each divider, `SystemMouseCursors.resizeColumn/resizeRow`, hairline visual. Sizes persist in config.json under `"ui": {"sidebarWidth": …, "filterHeight": …}` (write-behind, debounced 500ms).
- **Config schema v2 (Task 4):** `{"libraryRoots": ["L:\\music (original structure)"], "ui": {…}}`; old `libraryRoot` (singular) auto-migrates on load. Each root keeps its own `.library.json` + `.hash_cache.json` (CLI-compatible).
- **Multi-root model (Task 4):** `Track` gains `final String rootPath`; all path resolution = `p.join(rootPath, relPath)`; `PlayerService` drops `libraryRoot` (uses track.rootPath); LibraryModel merges roots (contentId dedupe, first root wins; playlists merged, name collisions suffixed " (2)"); settings dialog (gear at sidebar bottom): list roots, add via `getDirectoryPath()` (file_selector), remove; roots missing `.library.json` are listed with an inline "no library manifest — seed with foolib" note and skipped by load.
- **Rescan (Task 5):** uses `package:fooplayer_core` (`scanLibrary`, `diffAgainstManifest`, `applyDiff`, `saveManifest`, `loadManifest`) per root, inside `Isolate.run` (scan is sync-heavy). Triggers: app launch (after first feed render), a Refresh icon-button in the top search row, and a periodic `Timer` every 5 minutes. New tracks stamped `DateTime.now()` (their date_added going forward), appear in the feed sorted correctly; status line reports "scanning…/N new tracks added". Concurrency guard: never two rescans at once; rescan and tag-enrichment may interleave safely (enrichment reads, rescan writes manifest — serialize via a shared `_libraryBusy` flag).
- **Verification task (Task 6):** rebuild release, relaunch, screenshots of: light theme feed, centered bar playing, resized panes, settings dialog with 1 root, and a live-rescan demo (drop a copy of a small mp3 into a TEMP staging root — NOT the real library — added as a second root, watch it appear). Then remove the temp root.

## Task list (implementer model guidance: Task 1,3 sonnet; 2 sonnet; 4,5 sonnet; 6 controller)

### Task 1: app_theme.dart + apply light theme
Files: create `app/lib/ui/app_theme.dart` (exports `ThemeData buildAppTheme()` + an `AppColors` class with the exact token hex values above); modify `app/lib/main.dart` (`theme: buildAppTheme()`); sweep `home_screen.dart`, `track_list.dart`, `filter_panel.dart`, `now_playing_bar.dart` replacing any hardcoded/dark-theme color with theme/token lookups. Tests: existing widget tests keep passing (update the `ThemeData.dark` pump wrappers to `buildAppTheme()`); add one test asserting the theme's scaffold background == `AppColors.windowBg` and slider theme inactive == hairline. Commit: "feat: iTunes-style light theme via central app_theme tokens".

### Task 2: now-playing bar redesign
Files: rewrite layout of `app/lib/ui/now_playing_bar.dart` per the Bar layout constraint (keep `AlbumArt` widget + its loader seam and gapless/stable-bytes behavior intact; art 56px). Seek slider moves INTO the LCD under the text; times flank it at 10.5px `inkSecondary`. Update/extend the existing bar widget tests: transport icons present; title text findable; and a wide-surface test (1400px) asserting the LCD cluster's center x ≈ window center ±40 (use `tester.getCenter`). Commit: "feat: centered iTunes-style now-playing bar with full track info".

### Task 3: draggable dividers + persisted layout
Files: create `app/lib/ui/drag_divider.dart` (`HorizontalDragDivider`/`VerticalDragDivider` widgets: GestureDetector pan + MouseRegion cursor + 6px hit target painting a `hairline` line); modify `home_screen.dart` to make sidebar width and filter-row height stateful (values from a new `LayoutPrefs` ChangeNotifier created in main.dart from config.json, saved debounced). Tests: widget test drags the sidebar divider by +80 and asserts the sidebar's new width; unit test for LayoutPrefs clamp + debounce (fake async). Commit: "feat: draggable sidebar/filter dividers with persisted sizes".

### Task 4: multi-root config, model, settings
Files: modify `app/pubspec.yaml` (add `file_selector`, `fooplayer_core` path dep); `app/lib/model/track.dart` (+rootPath); `manifest_io.dart` (loadManifestFile gains a `rootPath` argument it stamps into tracks); `library_model.dart` (multi-root load/merge per constraint); `player/player_service.dart` (resolve via track.rootPath; constructor loses libraryRoot); `metadata/meta_cache.dart` (fillMetadata/readTagsBatch use track.rootPath); `main.dart` (config v2 + migration); new `app/lib/ui/settings_dialog.dart` (roots list per constraint, gear ListTile pinned at sidebar bottom). Tests: config migration unit test; two-root merge test (dedupe by contentId first-root-wins, playlist name collision suffix); settings dialog widget test (add via injected fake picker, remove, missing-manifest note). Commit: "feat: multiple library roots with settings UI and config v2".

### Task 5: in-app rescan
Files: modify `library_model.dart` (add `Future<void> rescan()` per the Rescan constraint + `_libraryBusy` guard + status strings "scanning <root>…" / "added N new tracks"); `main.dart` (post-first-feed rescan + 5-min Timer); `home_screen.dart` (Refresh IconButton beside search, disabled while busy). The scan/diff/stamp/save calls run in `Isolate.run` returning the updated manifest data + new-track list; merge on main isolate. Tests: unit test with a temp root — seed a mini manifest via `fooplayer_core`'s saveManifest, add one junk-bytes mp3 file, run `rescan()`, assert the new track appears in allTracks with a fresh dateAdded and the manifest file on disk gained it. Commit: "feat: automatic library rescan on launch, refresh, and 5-minute timer".

### Task 6 (controller): rebuild, relaunch, screenshot set, ledger, then whole-branch final review.

## Out of scope
Android (separate 2b-lite pass right after: platform-aware config paths via path_provider, android platform add, media_kit android libs, emulator smoke test). Any filesystem date/mtime work (user hold). Theming beyond the fixed light theme.
