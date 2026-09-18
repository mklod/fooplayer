// The Art column must mean what it looks like: "you will see a cover on
// this row".
//
// It used to tick only for the track's own embedded art or a sidecar entry
// under the ALBUM key, while the display also uses a folder image and,
// failing that, another track's cover from the same album. So a row could
// draw a perfectly good cover with an empty tick -- reported live
// 2026-09-18 on "Kanye West - Late Registration", where one skit carries no
// picture and borrows track 1's.
//
// Last modified: 2026-09-18--1540
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/artwork/album_key.dart';
import 'package:fooplayer_app/artwork/track_art_index.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory root;
  late Directory appData;
  late Directory albumDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('track_art_index');
    root = Directory(p.join(tmp.path, 'root'))..createSync(recursive: true);
    appData = Directory(p.join(tmp.path, 'appdata'))
      ..createSync(recursive: true);
    albumDir = Directory(p.join(root.path, 'Kanye West - Late Registration'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Track track(
    String name, {
    bool embedded = false,
    String album = 'Late Registration',
    String id = '',
  }) {
    final rel = p.join('Kanye West - Late Registration', name);
    File(p.join(root.path, rel)).writeAsBytesSync([0]);
    return Track(
      contentId: id.isEmpty ? name : id,
      relPath: rel,
      rootPath: root.path,
      dateAdded: DateTime.utc(2007, 9, 1),
      title: name,
      artist: 'Kanye West',
      album: album,
      genre: '',
      hasEmbeddedArt: embedded,
    );
  }

  Future<ArtworkStore> store() async {
    final s = ArtworkStoreRegistry(appDataDir: appData).forRoot(root.path);
    await s.ensureLoaded();
    return s;
  }

  test('a track with its own embedded art shows art', () async {
    final t = track('01 - Wake Up.mp3', embedded: true);
    final index = TrackArtIndex(tracks: () => [t]);
    expect(index.showsArt(t, await store()), isTrue);
  });

  test('a bare track shows art when an album-mate has some', () async {
    final mate = track('01 - Wake Up.mp3', embedded: true);
    final skit = track('15 - Skit 3.mp3');
    final index = TrackArtIndex(tracks: () => [mate, skit]);
    expect(
      index.showsArt(skit, await store()),
      isTrue,
      reason: 'this is the row that drew a cover with an empty tick',
    );
  });

  test('a bare track on an album where nothing has art shows none', () async {
    final a = track('01 - One.mp3');
    final b = track('02 - Two.mp3');
    final index = TrackArtIndex(tracks: () => [a, b]);
    expect(index.showsArt(a, await store()), isFalse);
  });

  test('a different album does not lend its cover', () async {
    final other = track('01 - Other.mp3', embedded: true, album: 'Graduation');
    final skit = track('15 - Skit 3.mp3');
    final index = TrackArtIndex(tracks: () => [other, skit]);
    expect(index.showsArt(skit, await store()), isFalse);
  });

  test('a recorded album cover counts', () async {
    final t = track('01 - One.mp3');
    final s = await store();
    await s.putImage(albumKeyForTrack(t), _png, source: 'itunes');
    final index = TrackArtIndex(tracks: () => [t]);
    expect(index.showsArt(t, s), isTrue);
  });

  test('a cover pinned to THIS track counts (the old check missed it)',
      () async {
    final t = track('01 - One.mp3', id: 'pinned-id');
    final s = await store();
    await s.putImage(trackArtKey('pinned-id'), _png, source: 'url');
    final index = TrackArtIndex(tracks: () => [t]);
    expect(index.showsArt(t, s), isTrue);
  });

  test('artwork explicitly REMOVED from a track shows none, even with a '
      'mate that has art', () async {
    final mate = track('01 - Wake Up.mp3', embedded: true);
    final skit = track('15 - Skit 3.mp3', id: 'skit-id');
    final s = await store();
    await s.remove(trackArtKey('skit-id'));
    final index = TrackArtIndex(tracks: () => [mate, skit]);
    expect(index.showsArt(skit, s), isFalse);
  });

  test('a folder image counts, once the folders have been probed', () async {
    final t = track('01 - One.mp3');
    File(p.join(albumDir.path, 'Folder.jpg')).writeAsBytesSync([1, 2, 3]);
    final index = TrackArtIndex(tracks: () => [t]);
    final s = await store();

    // Not probed yet: the index must not block a repaint guessing.
    expect(index.showsArt(t, s), isFalse);

    var notified = 0;
    index.addListener(() => notified++);
    await index.refreshFolders();

    expect(index.showsArt(t, s), isTrue);
    expect(notified, greaterThan(0), reason: 'the column must repaint');
  });

  test('matesFor offers only album-mates that actually carry art', () async {
    final mate = track('01 - Wake Up.mp3', embedded: true);
    final bare = track('02 - Bare.mp3');
    final skit = track('15 - Skit 3.mp3');
    final index = TrackArtIndex(tracks: () => [mate, bare, skit]);

    final mates = index.matesFor(ArtworkRequest.forTrack(skit));
    expect(mates.map((f) => p.basename(f.path)), ['01 - Wake Up.mp3']);

    // ...and never the track itself.
    expect(
      index.matesFor(ArtworkRequest.forTrack(mate)),
      isEmpty,
    );
  });
}

final _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];
