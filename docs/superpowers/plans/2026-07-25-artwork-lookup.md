# Album Artwork Lookup (Plan 4) Implementation Plan

> Executed as an ultracode round (3 parallel worktrees → merge → integrity + adversarial review → fixer). Modeled on metaGen's artwork flow (`L:\PROJECTS\metaGen\backend\artwork.py`): providers → scored candidates → best guess auto-applied → user-replaceable from a picker grid.

**Goal:** every album shows art. Automatic best guess from keyless online providers when a file has no embedded art, and a picker (desktop + phone) to browse candidates and replace on demand — including a local file or pasted URL.

**Architecture:** app-side only (core engine and `.library.json` schema untouched). New `app/lib/artwork/`: keyless providers → normalized `ArtCandidate`s → deterministic scorer → best guess. Chosen/auto art is cached as files in the app data dir and recorded in a **sidecar** `.artwork.json` per library root (portable, travels with the folder, never touches the manifest schema). Display resolution chain is centralised so both platforms benefit.

**Tech Stack:** existing + `http` (Flutter first-party) for provider calls; `crypto` (already present) for cache keys. No API keys, no new heavyweight deps.

## Global Constraints

- Branch base: current `main` (desktop+phone unified). Worktrees per agent; Bash env every call: `export PATH="/c/dev/flutter/bin:/c/Users/mklod/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"`; tests from `app/`; `flutter analyze` clean; desktop tests stay green.
- **Providers (all keyless, no signup):** iTunes Search API (`https://itunes.apple.com/search?entity=album&term=...`, artwork 100→600px by URL rewrite), Deezer (`https://api.deezer.com/search/album?q=...`, `cover_xl`), Cover Art Archive via MusicBrainz (`https://musicbrainz.org/ws/2/release-group?query=...&fmt=json` → `https://coverartarchive.org/release-group/<mbid>/front-500`). MusicBrainz REQUIRES a descriptive `User-Agent` (`fooplayer/1.0 (https://github.com/mklod/fooplayer)`) and ≤1 req/sec — rate-limit it; the other two get modest concurrency. Every provider must degrade silently: network off / 404 / malformed JSON → empty candidate list, never an exception to the UI.
- **Scoring (deterministic, pure, unit-tested):** normalize both sides (lowercase, strip punctuation/diacritics, drop bracketed suffixes like `(Deluxe Edition)`, `[Explicit]`, `- EP`); score = artist similarity (0–50, token-set ratio) + album similarity (0–40) + provider prior (0–5: iTunes 5, Deezer 4, CAA 3) + resolution bonus (0–5). **Auto-apply only when top score ≥ 75 AND beats the runner-up by ≥ 10**; otherwise leave unset and let the picker decide (a wrong cover silently applied is worse than none).
- **Resolution chain for display** (single helper, used by desktop bar, phone mini-player, phone Now Playing, and any future grid): embedded tag art → user/auto choice recorded in the sidecar → `folder.jpg`/`cover.jpg`/`front.jpg` beside the audio file → placeholder. Never blocks the UI: async, cached in memory per album key, reuses the existing stale-request guard pattern from `AlbumArt`.
- **Album key:** `normalizedArtist|normalizedAlbum` (from the same normalizer the scorer uses) so all tracks of an album share one artwork entry. Tracks with an empty album fall back to `artist|title` (single-track key).
- **Sidecar `.artwork.json`** (one per library root, written atomically tmp→rename with a `.bak`, exactly like `saveManifest`): `{"schema":1,"art":{"<albumKey>":{"file":"<relative path under the root's .artwork/ dir>","source":"itunes|deezer|caa|local|url|embedded","pickedAt":"<ISO>","query":"<what was searched>"}}}`. Downloaded images are stored under `<root>/.artwork/<albumKey-hash>.jpg` so the whole thing travels with the music folder. If the root is read-only, fall back to the app data dir and note it in the entry (`"external": true`).
- **Never overwrite user music files.** Do not write `folder.jpg` into album directories in v1 (a later opt-in setting can). READ-ONLY on `L:\music` in tests and dev.
- **Concurrency/manners:** lookups run off the UI isolate; at most 3 concurrent provider fetches; a per-album in-flight guard prevents duplicate lookups; results (including negative results, with a timestamp) are cached so we don't re-query every launch. Manual "Search again" bypasses the negative cache.
- Tests use an injectable `HttpClient`/fetch function — **no test may hit the network**. Fixtures = captured JSON payloads.

## Tasks (parallel round)

### A1 — providers + scoring (`app/lib/artwork/`)
`art_candidate.dart` (`ArtCandidate {url, thumbUrl, source, title, artist, year, width}`), `providers.dart` (three provider functions behind one `Future<List<ArtCandidate>> searchAll(ArtQuery q, {fetch})`, MusicBrainz rate-limited + UA header, per-provider error isolation), `scoring.dart` (normalizer + scorer + `bestGuess(candidates)` implementing the ≥75/≥10 rule). Tests: normalizer cases (deluxe/explicit/diacritics/punctuation), scorer ranking with real captured payload fixtures, auto-apply threshold honored (a near-tie returns null), every provider failure mode returns `[]` not a throw.

### A2 — storage, resolution chain, wiring
`artwork_store.dart` (sidecar load/save atomic+bak, `.artwork/` image cache, read-only-root fallback to app data dir, negative-result cache with timestamp), `artwork_resolver.dart` (the display chain + album key + in-memory cache + in-flight dedupe + injectable downloader), and wire it so existing `AlbumArt` (desktop bar) and the phone mini-player/Now Playing use the resolver instead of embedded-art-only (keep their loader seams and stale-request guards intact — do not regress the flicker/leak fixes those files document). Background best-guess pass: after enrichment settles, queue lookups for albums with no art (throttled, cancellable, never blocking; status line unchanged). Tests: sidecar round-trip + atomicity + `.bak`, read-only fallback, resolution chain precedence order, dedupe of concurrent same-album requests, negative cache honored and bypassed by manual search.

### A3 — picker UI (desktop + phone)
Desktop: track/album right-click → **“Album artwork…”** → dialog with a candidate grid (thumbnails, source + resolution labels, current selection marked), plus **“Choose file…”** (`file_selector`), **“Paste URL…”**, **“Search again”** (re-query, bypassing negative cache) and **“Remove artwork”**. Phone: long-press sheet gains **“Album artwork”** → full-screen picker with the same options (file picker + URL entry). Both share one `ArtworkPicker` widget driven by injected search/store services (tests inject fakes; no network, no real file dialogs). Applying a choice updates the sidecar and the resolver's cache so every visible surface refreshes immediately. Tests: grid renders candidates, selecting one calls store with the right album key, choose-file/URL paths, remove clears, phone sheet entry opens the picker.

### Merge → integrity + adversarial review (severity enum `critical|important|minor` only) → single fixer.
Adversarial focus: sidecar write races vs. rescan/playlist manifest writes (different file, but same root — verify no interference), unbounded provider retries or hammering MusicBrainz, cache-key collisions across roots, resolver leaks (listeners/futures) on rapid track changes, art files ballooning the library folder, and any path where a lookup can block or freeze the UI.

## Verification (controller)
Desktop: launch, confirm albums that lacked art now show it, open the picker, replace a cover, confirm it persists across restart and that `.artwork.json` + `.artwork/` appear in the root. Phone: same via emulator (long-press → Album artwork), screenshot.

## Out of scope (v1)
Writing `folder.jpg` into album dirs (opt-in later); artist/fanart/logo types (metaGen-style multi-type); LLM-assisted disambiguation for ambiguous matches (possible v2 — would need an API key and an explicit opt-in); batch "fix all artwork" UI beyond the automatic background pass.
