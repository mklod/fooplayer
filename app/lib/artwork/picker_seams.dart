// Last modified: 2026-07-25--2214
//
// Plan 4 (Album Artwork Lookup) task A3 -- the *seams* the picker UI is
// built on.
//
// A3 ships in parallel with A1 (providers + scoring) and A2 (store +
// resolution chain), so nothing in this file imports either of them.
// Everything the picker needs from the outside world is a plain typedef or
// a tiny value type declared here; the merge agent wires the real
// implementations in by constructing one [ArtworkServices] and passing it
// to the two entry points (desktop track context menu, phone long-press
// sheet). See the "MERGE" notes on each member for the intended mapping.
//
// Hard rules this file honours (plan Global Constraints):
//   * No network here or anywhere in A3 -- image bytes only ever arrive
//     through the injected [ArtworkThumbLoadFn], whose default returns
//     null. Tests therefore cannot hit the network even by accident.
//   * Nothing writes into album directories. A3 never touches the
//     filesystem at all except through [ArtworkFilePickFn] (a *read* of the
//     user's chosen path) -- persistence is entirely A2's job, reached via
//     [ArtworkApplyFn] / [ArtworkRemoveFn].
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as file_selector;

import '../model/track.dart';
import 'album_key.dart';

export 'album_key.dart' show ArtworkQuery, artworkAlbumKey, normalizeArtworkText;

/// Sidecar `source` ids, per the plan's `.artwork.json` schema
/// (`"itunes|deezer|caa|local|url|embedded"`). Deliberately plain strings
/// rather than an enum so A1/A2 can hand candidates straight through
/// without a shared enum declaration having to exist first.
class ArtworkSource {
  ArtworkSource._();

  static const itunes = 'itunes';
  static const deezer = 'deezer';
  static const coverArtArchive = 'caa';

  /// A file the user picked off disk.
  static const local = 'local';

  /// An image URL the user pasted.
  static const url = 'url';

  /// Art embedded in the audio file's tags.
  static const embedded = 'embedded';
}

/// Human-readable label for a sidecar [ArtworkSource] id, used for the
/// grid's source label. Unknown ids render as-is so a provider added later
/// (A1 or beyond) still shows something sensible instead of "Unknown".
String artworkSourceLabel(String source) {
  switch (source) {
    case ArtworkSource.itunes:
      return 'iTunes';
    case ArtworkSource.deezer:
      return 'Deezer';
    case ArtworkSource.coverArtArchive:
      return 'Cover Art Archive';
    case ArtworkSource.local:
      return 'Local file';
    case ArtworkSource.url:
      return 'URL';
    case ArtworkSource.embedded:
      return 'Embedded';
    default:
      return source;
  }
}

// [ArtworkQuery] -- what the picker searches for -- is the shared type from
// album_key.dart (re-exported below), the same one the background pass uses.

/// One row of the candidate grid.
///
/// Field names match the plan's `ArtCandidate {url, thumbUrl, source,
/// title, artist, year, width}` exactly, so MERGE is a one-line adapter
/// from A1's type:
/// ```dart
/// PickerCandidate(
///   url: c.url, thumbUrl: c.thumbUrl, source: c.source,
///   title: c.title, artist: c.artist, year: c.year, width: c.width);
/// ```
/// (A separate name is used only so both declarations can coexist until
/// that adapter lands -- the picker never needs A1's scoring fields.)
class PickerCandidate {
  /// Full-resolution image URL -- what gets stored/downloaded when picked.
  final String url;

  /// Smaller preview URL; falls back to [url] when absent.
  final String? thumbUrl;

  /// Sidecar source id -- see [ArtworkSource].
  final String source;

  final String title;
  final String artist;
  final int? year;

  /// Pixel width of [url]'s image when the provider reports it; drives the
  /// grid's resolution label.
  final int? width;

  const PickerCandidate({
    required this.url,
    required this.source,
    this.thumbUrl,
    this.title = '',
    this.artist = '',
    this.year,
    this.width,
  });

  /// Stable identity of the image this candidate points at -- compared
  /// against [ArtworkServices.currentSelectionId] to mark the current
  /// choice in the grid.
  String get id => url;

  /// URL to render in the grid tile (preview if the provider gave one).
  String get previewUrl =>
      (thumbUrl != null && thumbUrl!.isNotEmpty) ? thumbUrl! : url;

  /// `600 × 600` when the width is known, otherwise empty (the tile then
  /// shows only the source label rather than a fake "?" resolution).
  String get resolutionLabel {
    final w = width;
    if (w == null || w <= 0) return '';
    return '$w × $w';
  }
}

/// What the picker hands to the store when the user commits a choice.
///
/// Exactly one of [url] / [localPath] is set. A2 turns this into the
/// plan's sidecar entry (`{file, source, pickedAt, query}`) -- downloading
/// [url] or copying [localPath] into `<root>/.artwork/`; A3 deliberately
/// does neither.
class ArtworkChoice {
  /// Sidecar source id -- see [ArtworkSource].
  final String source;

  /// Remote image URL (provider candidate or a pasted URL).
  final String? url;

  /// Absolute path of a file the user picked off disk.
  final String? localPath;

  /// Pixel width when known, so A2 can record/prefer resolution.
  final int? width;

  /// The search term this choice came from, for the sidecar `query` field.
  /// Empty for choose-file / paste-URL (nothing was searched).
  final String query;

  const ArtworkChoice({
    required this.source,
    this.url,
    this.localPath,
    this.width,
    this.query = '',
  });

  ArtworkChoice.fromCandidate(PickerCandidate c, {this.query = ''})
    : source = c.source,
      url = c.url,
      localPath = null,
      width = c.width;

  /// Matches [PickerCandidate.id] / [ArtworkServices.currentSelectionId].
  String get id => localPath ?? url ?? '';

  @override
  String toString() => 'ArtworkChoice($source, $id)';
}

/// Runs a candidate search.
///
/// [forceRefresh] is the picker's **"Search again"**: per the plan it must
/// bypass the negative-result cache and re-query the providers.
///
/// MERGE: wire to A1's `searchAll` composed with A2's cache, e.g.
/// `(q, {forceRefresh = false}) => artworkService.search(ArtQuery(...),
/// bypassCache: forceRefresh).then(toPickerCandidates)`.
/// Must never throw -- providers degrade to `[]` (plan Global
/// Constraints); the picker surfaces a thrown error as an inline message
/// rather than crashing, but that path should stay unreachable.
typedef ArtworkSearchFn =
    Future<List<PickerCandidate>> Function(
      Track track,
      ArtworkQuery query, {
      bool forceRefresh,
    });

/// Persists [choice] as the artwork for [albumKey].
/// Wired to A2's `ArtworkResolver.applyImage` (sidecar write + cache
/// invalidation, so every visible surface refreshes immediately).
typedef ArtworkApplyFn =
    Future<void> Function(Track track, String albumKey, ArtworkChoice choice);

/// Clears any stored artwork for [albumKey] ("Remove artwork").
/// Wired to A2's `ArtworkResolver.removeImage`. Idempotent: removing an
/// album that has no entry is a no-op, not an error.
typedef ArtworkRemoveFn = Future<void> Function(Track track, String albumKey);

/// Opens the OS "choose an image" dialog; returns an absolute path, or
/// null when the user cancelled. Injected so widget tests never open a
/// real native dialog (impossible under `flutter test`).
typedef ArtworkFilePickFn = Future<String?> Function();

/// Loads preview bytes for a candidate URL, or null when unavailable.
/// This is the ONLY way pixels enter the picker.
/// MERGE: A2's injectable downloader (cached).
typedef ArtworkThumbLoadFn = Future<Uint8List?> Function(String url);

/// The id ([PickerCandidate.id] / [ArtworkChoice.id]) currently stored for
/// [albumKey], or null when the album has no chosen artwork -- drives the
/// "current selection marked" affordance.
/// MERGE: A2's sidecar lookup.
typedef ArtworkCurrentFn = String? Function(Track track, String albumKey);

/// Maps a track to the album key all its artwork is filed under.
/// Defaults to [albumKeyForTrack], which is the shared normalizer-backed
/// key -- picker, scorer and store agree byte-for-byte.
typedef AlbumKeyFn = String Function(Track track);

/// The shared normalizer (album_key.dart) -- the picker deliberately does
/// NOT own one. A second implementation would let the picker file a cover
/// under a slightly different key than the background best-guess pass
/// records (diacritics, `- EP` tails, `&` vs `and`), which is exactly what
/// the plan forbids.
String normalizeArtworkKeyPart(String s) => normalizeArtworkText(s);

/// The plan's album key: `normalizedArtist|normalizedAlbum`, falling back
/// to `normalizedArtist|normalizedTitle` for a track with no album so
/// singles still get their own entry instead of all sharing `artist|`.
///
/// Delegates to [artworkAlbumKey] so the picker, the scorer and the store
/// agree byte-for-byte -- including [artworkAlbumKey]'s fully-untagged
/// fallback (rootPath/relPath), which MUST be passed exactly like A2's
/// `ArtworkRequest.forTrack` passes them for the same track: this is what
/// [ArtworkServices.currentSelectionId] looks the picker's "current
/// selection" up under, so a mismatch here would make it look up the wrong
/// key and never find what the resolver actually stored.
String albumKeyForTrack(Track track) => artworkAlbumKey(
  artist: track.artist,
  album: track.album,
  title: track.title,
  rootPath: track.rootPath,
  relPath: track.relPath,
);

/// The query a track's picker opens with: artist + album, falling back to
/// the title when the track has no album tag (same fallback shape as
/// [albumKeyForTrack]).
ArtworkQuery artworkQueryForTrack(Track track) => ArtworkQuery(
  artist: track.artist,
  album: track.album.isEmpty ? track.title : track.album,
);

/// Production file picker: `file_selector`'s native image dialog. Never
/// reached in tests (they inject a fake), matching the pattern
/// `settings_dialog.dart`'s [defaultPickDirectory] already established.
Future<String?> defaultPickArtworkFile() async {
  const images = file_selector.XTypeGroup(
    label: 'Images',
    extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
  );
  final file = await file_selector.openFile(acceptedTypeGroups: [images]);
  return file?.path;
}

/// Default [ArtworkThumbLoadFn]: no bytes. Keeps A3 network-free until
/// MERGE points it at A2's downloader; tiles render their placeholder.
Future<Uint8List?> noArtworkThumbnails(String url) async => null;

String? _noCurrentArtwork(Track track, String albumKey) => null;

/// Everything the picker (and the two entry points that open it) needs,
/// bundled so wiring is a single constructor call at MERGE time instead of
/// six parameters threaded through the widget tree.
///
/// [search], [apply] and [remove] are required because there is no sane
/// default for them; the rest default to inert/production values.
class ArtworkServices {
  final ArtworkSearchFn search;
  final ArtworkApplyFn apply;
  final ArtworkRemoveFn remove;
  final ArtworkFilePickFn pickFile;
  final ArtworkThumbLoadFn loadThumb;
  final ArtworkCurrentFn currentSelectionId;
  final AlbumKeyFn albumKey;

  const ArtworkServices({
    required this.search,
    required this.apply,
    required this.remove,
    this.pickFile = defaultPickArtworkFile,
    this.loadThumb = noArtworkThumbnails,
    this.currentSelectionId = _noCurrentArtwork,
    this.albumKey = albumKeyForTrack,
  });
}
