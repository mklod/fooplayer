// Artwork that belongs to a TRACK, not to whatever its tags say today.
//
// The bug this exists for, in full: twelve Mr Suicide Sheep mixes were
// retagged to share one album, "Sheepy Mixes". Artwork is filed under a key
// built from the artist and album strings, so every one of those tracks
// moved to the same key at once. Three separately-chosen covers collapsed
// into one shared cover plus two orphans -- the tracks kept pointing at a
// key nothing wrote any more.
//
// The fix is to pin a hand-picked cover to the content id as well, which is
// a hash of the audio and cannot be moved by editing tags.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/track.dart';

Uint8List _jpeg(int seed) {
  final b = Uint8List(64);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  for (var i = 3; i < b.length; i++) {
    b[i] = (seed * i) % 251;
  }
  return b;
}

void main() {
  late Directory tmp;
  late Directory root;
  late ArtworkStoreRegistry stores;
  late ArtworkResolver resolver;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pinart');
    root = await Directory('${tmp.path}/lib').create();
    stores = ArtworkStoreRegistry(appDataDir: tmp);
    resolver = ArtworkResolver(
      stores: stores,
      embeddedLoader: (_) async => null,
    );
    addTearDown(resolver.dispose);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Track track(String id, String title, {String album = ''}) => Track(
    contentId: id,
    relPath: '$title.mp3',
    rootPath: root.path,
    dateAdded: DateTime.utc(2024),
    title: title,
    artist: 'Mr Suicide Sheep',
    album: album,
  );

  test('three tracks sharing an album keep three different covers', () async {
    final warm = track('id-warm', 'Warm Memories', album: 'Sheepy Mixes');
    final dreams = track('id-dreams', 'Forgotten Dreams', album: 'Sheepy Mixes');
    final sleep = track('id-sleep', 'No Sleep', album: 'Sheepy Mixes');

    for (final (t, seed) in [(warm, 1), (dreams, 2), (sleep, 3)]) {
      await resolver.applyImage(
        ArtworkRequest.forTrack(t),
        _jpeg(seed),
        source: 'local',
        alsoPinToTrack: true,
      );
    }

    expect(await resolver.resolve(ArtworkRequest.forTrack(warm)), _jpeg(1));
    expect(await resolver.resolve(ArtworkRequest.forTrack(dreams)), _jpeg(2));
    expect(
      await resolver.resolve(ArtworkRequest.forTrack(sleep)),
      _jpeg(3),
      reason: 'the last pick must not have overwritten the other two',
    );
  });

  test('a pinned cover survives being retagged into another album', () async {
    final before = track('id-warm', 'Warm Memories');
    await resolver.applyImage(
      ArtworkRequest.forTrack(before),
      _jpeg(7),
      source: 'local',
      alsoPinToTrack: true,
    );

    // The user retags it, which moves the album key underneath it.
    final after = track('id-warm', 'Warm Memories', album: 'Sheepy Mixes');
    expect(
      ArtworkRequest.forTrack(after).albumKey,
      isNot(ArtworkRequest.forTrack(before).albumKey),
      reason: 'fixture: the retag must actually move the album key',
    );

    expect(
      await resolver.resolve(ArtworkRequest.forTrack(after)),
      _jpeg(7),
      reason: 'the cover follows the track, not its tags',
    );
  });

  test('album-mates without a pick still inherit the album cover', () async {
    // The other half: picking a cover on one track of a REAL album is
    // expected to dress the whole record, so the album key is still written.
    final one = track('id-1', 'Speak to Me', album: 'Dark Side');
    final two = track('id-2', 'Breathe', album: 'Dark Side');

    await resolver.applyImage(
      ArtworkRequest.forTrack(one),
      _jpeg(9),
      source: 'local',
      alsoPinToTrack: true,
    );

    expect(await resolver.resolve(ArtworkRequest.forTrack(two)), _jpeg(9));
  });

  test('removing artwork clears the pin too', () async {
    final t = track('id-x', 'A Mix', album: 'Sheepy Mixes');
    await resolver.applyImage(
      ArtworkRequest.forTrack(t),
      _jpeg(4),
      source: 'local',
      alsoPinToTrack: true,
    );
    expect(await resolver.resolve(ArtworkRequest.forTrack(t)), isNotNull);

    await resolver.removeImage(ArtworkRequest.forTrack(t));

    expect(
      await resolver.resolve(ArtworkRequest.forTrack(t)),
      isNull,
      reason: 'otherwise Remove clears the album cover and the pin stays',
    );
  });

  test('the pin key cannot collide with an album key', () async {
    // Content ids are hex; the marker is a control character the album-key
    // normalizer strips from every real artist and album string.
    expect(trackArtKey('abc123').startsWith('\x03'), isTrue);
    expect(
      artworkAlbumKey(artist: 'A', album: 'B').contains('\x03'),
      isFalse,
    );
  });
}
