// What the Art column promises: "you will see a cover on this row".
//
// The column used to tick for the track's own embedded art, or a sidecar
// entry under the ALBUM key. The DISPLAY chain is longer than that: it also
// takes a `folder/cover/front.jpg` sitting beside the file, and failing
// that, another track's embedded cover from the same album. So a row could
// draw a perfectly good picture with an empty tick, which is exactly how it
// was reported (2026-09-18, Kanye West - Late Registration: one skit has no
// picture of its own, borrows track 1's, and read as "no art" while showing
// one). "Emb" answers the other question -- is the picture IN the file --
// which is what other players and the loose-image cleanup care about.
//
// This index is the shared half of both jobs: it knows which albums have a
// cover to lend, which folders hold an image, and it hands the resolver the
// mate files to borrow from. Everything it answers synchronously is
// precomputed, because it is consulted once per visible row on every
// repaint.
//
// Last modified: 2026-09-18--1545

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../model/track.dart';
import 'album_key.dart';
import 'artwork_resolver.dart';
import 'artwork_store.dart';

/// Whether [dir] holds an image the resolver would display. Injected so
/// tests never need a directory listing of their own.
typedef FolderImageProbe = Future<bool> Function(Directory dir);

/// The default [FolderImageProbe]: ONE listing per directory, matched
/// case-insensitively against exactly the names the resolver reads. Nine
/// `exists()` probes per folder over SMB is the stall this avoids -- and
/// matching on the resolver's own constants is what keeps the tick and the
/// picture from ever disagreeing about what counts.
Future<bool> folderHoldsImage(Directory dir) async {
  try {
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path).toLowerCase();
      for (final base in artworkSiblingBaseNames) {
        for (final ext in artworkSiblingExtensions) {
          if (name == '$base$ext') return true;
        }
      }
    }
  } catch (_) {
    // Unreadable or vanished: same as no image.
  }
  return false;
}

/// Album-level artwork knowledge, derived from the loaded library.
class TrackArtIndex extends ChangeNotifier {
  /// The library, as a function so this never holds a stale list.
  final List<Track> Function() tracks;

  final FolderImageProbe folderProbe;

  /// How many directories are probed at once. Small on purpose: these
  /// listings go over SMB, behind whatever else the app is doing.
  final int probeConcurrency;

  TrackArtIndex({
    required this.tracks,
    FolderImageProbe? folderProbe,
    this.probeConcurrency = 4,
  }) : folderProbe = folderProbe ?? folderHoldsImage;

  /// Album key -> the tracks on it whose tags carry a picture.
  Map<String, List<Track>> _lenders = {};

  /// The track list [_lenders] was built from, by identity -- rebuilding is
  /// O(library) and a rebuild per repaint would be absurd.
  List<Track>? _lendersSource;

  /// Absolute directory -> holds a folder/cover/front image. Absent means
  /// "not probed yet", which reads as false until [refreshFolders] runs.
  final Map<String, bool> _folderImages = {};

  void _ensureLenders() {
    final current = tracks();
    if (identical(current, _lendersSource)) return;
    final next = <String, List<Track>>{};
    for (final t in current) {
      if (!t.hasEmbeddedArt) continue;
      (next[albumKeyForTrack(t)] ??= <Track>[]).add(t);
    }
    _lenders = next;
    _lendersSource = current;
  }

  /// True when [track] will actually draw a cover -- the same chain
  /// [ArtworkResolver] walks, minus the bytes.
  ///
  /// [store] is the sidecar store for the track's root; null (no store
  /// wired) just skips the recorded-choice links.
  bool showsArt(Track track, ArtworkStore? store) {
    final id = track.contentId;
    final trackKey = id.isEmpty ? null : trackArtKey(id);

    if (store != null && trackKey != null) {
      // A cover pinned to this one track. Checked first because it also
      // outranks the album's -- and because the old column looked only at
      // the album key, so an explicit pick read as "no art".
      if (store.entryFor(trackKey) != null) return true;
      // "Remove artwork" on this track means this track shows nothing, and
      // no amount of borrowing may undo it.
      if (store.isSuppressed(trackKey)) return false;
    }

    if (track.hasEmbeddedArt) return true;

    final albumKey = albumKeyForTrack(track);
    if (store != null && store.entryFor(albumKey) != null) return true;

    if (_folderImages[_dirOf(track)] == true) return true;

    _ensureLenders();
    final lenders = _lenders[albumKey];
    return lenders != null && lenders.any((t) => t.contentId != track.contentId);
  }

  /// Files the resolver may borrow a cover from for [req] -- album-mates
  /// whose tags are already known to carry one, so the borrow costs one
  /// tag read rather than a search.
  List<File> matesFor(ArtworkRequest req) {
    _ensureLenders();
    final lenders = _lenders[req.albumKey];
    if (lenders == null) return const [];
    final out = <File>[];
    for (final t in lenders) {
      final f = File(p.join(t.rootPath, t.relPath));
      if (f.path == req.file.path) continue;
      out.add(f);
      // Two is plenty: if neither of the album's known-arted files can be
      // read, a third is not going to save the row.
      if (out.length == 2) break;
    }
    return out;
  }

  String _dirOf(Track t) => p.dirname(p.join(t.rootPath, t.relPath));

  /// Probes every album directory not yet known, then notifies once.
  ///
  /// Deliberately not called per row: a listing per visible row, over SMB,
  /// on every repaint is precisely the kind of stall artwork resolution is
  /// built to avoid.
  Future<void> refreshFolders() async {
    final dirs = <String>{for (final t in tracks()) _dirOf(t)}
      ..removeWhere(_folderImages.containsKey);
    if (dirs.isEmpty) return;

    final pending = dirs.toList();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= pending.length) return;
        final dir = pending[i];
        _folderImages[dir] = await folderProbe(Directory(dir));
      }
    }

    await Future.wait([
      for (var i = 0; i < probeConcurrency; i++) worker(),
    ]);
    notifyListeners();
  }
}
