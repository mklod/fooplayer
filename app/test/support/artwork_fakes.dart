// Last modified: 2026-07-25--2214
//
// Shared fakes for the Plan 4 task A3 (artwork picker) widget tests.
//
// The picker takes every service through [ArtworkServices], so these three
// fakes are the whole test double surface: a recording store, a canned
// search, and an inert thumbnail loader. Nothing here opens a socket, a
// file dialog or a file -- which is what makes the plan's "no network in
// tests" rule structurally true rather than aspirational.
import 'dart:async';
import 'dart:typed_data';

import 'package:fooplayer_app/artwork/picker_seams.dart';
import 'package:fooplayer_app/model/track.dart';

/// Records every store call the picker makes, so a test can assert on the
/// album key AND on what was stored under it.
class FakeArtworkStore {
  final List<Track> appliedTracks = [];
  final List<String> appliedKeys = [];
  final List<ArtworkChoice> appliedChoices = [];
  final List<String> removedKeys = [];

  /// When set, [apply] throws it -- for the "store failure keeps the picker
  /// open" path.
  Object? applyError;

  /// MERGE: the store seams carry the [Track] as well as the album key --
  /// artwork is stored per LIBRARY ROOT, and the key alone can't say which
  /// root a choice belongs to. The fakes ignore the track; the assertions
  /// below still pin the key.
  Future<void> apply(Track track, String albumKey, ArtworkChoice choice) async {
    if (applyError != null) throw applyError!;
    appliedTracks.add(track);
    appliedKeys.add(albumKey);
    appliedChoices.add(choice);
  }

  Future<void> remove(Track track, String albumKey) async =>
      removedKeys.add(albumKey);
}

/// Fake [ArtworkSearchFn]: serves canned result batches in order (the last
/// batch repeats), recording the query and the forceRefresh flag of every
/// call so "Search again" can be checked for cache bypass.
class FakeArtworkSearch {
  final List<List<PickerCandidate>> batches;
  final List<ArtworkQuery> queries = [];
  final List<bool> forceFlags = [];

  /// When non-null, the search parks on this completer instead of
  /// returning -- lets a test observe the loading state.
  Completer<List<PickerCandidate>>? gate;

  FakeArtworkSearch(this.batches);

  int get calls => queries.length;

  Future<List<PickerCandidate>> call(
    Track track,
    ArtworkQuery query, {
    bool forceRefresh = false,
  }) {
    queries.add(query);
    forceFlags.add(forceRefresh);
    final g = gate;
    if (g != null) return g.future;
    final i = queries.length - 1;
    return Future.value(batches[i < batches.length ? i : batches.length - 1]);
  }
}

const itunesCandidate = PickerCandidate(
  url: 'https://example.test/itunes-600.jpg',
  thumbUrl: 'https://example.test/itunes-100.jpg',
  source: ArtworkSource.itunes,
  title: 'Absolution',
  artist: 'Muse',
  year: 2003,
  width: 600,
);

const deezerCandidate = PickerCandidate(
  url: 'https://example.test/deezer-xl.jpg',
  source: ArtworkSource.deezer,
  title: 'Absolution',
  artist: 'Muse',
  width: 1000,
);

const caaCandidate = PickerCandidate(
  url: 'https://example.test/caa-front-500.jpg',
  source: ArtworkSource.coverArtArchive,
  title: 'Absolution',
  artist: 'Muse',
);

Track artworkFixtureTrack({
  String contentId = 't1',
  String title = 'Time Is Running Out',
  String artist = 'Muse',
  String album = 'Absolution',
}) => Track(
  contentId: contentId,
  relPath: 'Muse/Absolution/01.mp3',
  rootPath: r'C:\Music',
  dateAdded: DateTime.utc(2024, 1, 1),
  title: title,
  artist: artist,
  album: album,
);

/// Assembles an [ArtworkServices] whose defaults are all inert: no file
/// dialog (returns null), no thumbnail bytes, no current selection.
ArtworkServices fakeArtworkServices({
  required FakeArtworkSearch search,
  required FakeArtworkStore store,
  ArtworkFilePickFn? pickFile,
  ArtworkThumbLoadFn? loadThumb,
  ArtworkCurrentFn? currentSelectionId,
}) => ArtworkServices(
  search: search.call,
  apply: store.apply,
  remove: store.remove,
  pickFile: pickFile ?? () async => null,
  loadThumb: loadThumb ?? noArtworkThumbnails,
  currentSelectionId: currentSelectionId ?? (_, _) => null,
);

/// Smallest valid PNG (1x1, transparent) -- enough for `Image.memory` to
/// decode without any asset or network access.
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
