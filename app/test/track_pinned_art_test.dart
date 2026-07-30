// Artwork that belongs to a TRACK, not to whatever its tags say today.
//
// The bug this exists for, in full: twelve Mr Suicide Sheep mixes were
// retagged to share one album, "Sheepy Mixes". Artwork is filed under a key
// built from the artist and album strings, so every one of those tracks
// moved to the same key at once. Three separately-chosen covers collapsed
// into one shared cover plus two orphans -- the tracks kept pointing at a
// key nothing wrote any more.
//
// The fix has two halves. A hand-picked cover is pinned to the content id --
// a hash of the audio, which no tag edit can move -- and it is pinned ONLY
// there. An earlier version wrote the album key too, so picking a cover for
// "Forgotten Dreams" silently replaced it on "Colourful Emotions" and
// "Peaceful Solitude", which is the bug reported again on 2026-07-29. The app
// cannot tell a real album from a label used as a shortcut for a YouTube
// playlist, so it does not guess: the picker means this track, the automatic
// pass means the album it searched for.
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
        scope: ArtworkApplyScope.track,
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
      scope: ArtworkApplyScope.track,
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

  test('a hand pick does NOT touch album-mates', () async {
    // The reported bug, as an assertion. Changing the cover on one track must
    // change exactly one track, whether or not the album is a real album --
    // nothing in the tags can tell the app which it is, and silently
    // rewriting a cover the user chose for another track is the worse error.
    final one = track('id-1', 'Colourful Emotions', album: 'Sheepy Mixes');
    final two = track('id-2', 'Peaceful Solitude', album: 'Sheepy Mixes');

    await resolver.applyImage(
      ArtworkRequest.forTrack(one),
      _jpeg(9),
      source: 'local',
      scope: ArtworkApplyScope.track,
    );

    expect(await resolver.resolve(ArtworkRequest.forTrack(one)), _jpeg(9));
    expect(
      await resolver.resolve(ArtworkRequest.forTrack(two)),
      isNull,
      reason: 'the sibling had no cover and was not given one',
    );
  });

  test('a hand pick does not overwrite a cover a sibling already had', () async {
    final mine = track('id-mine', 'Forgotten Dreams', album: 'Sheepy Mixes');
    final theirs = track('id-theirs', 'Warm Memories', album: 'Sheepy Mixes');

    await resolver.applyImage(
      ArtworkRequest.forTrack(theirs),
      _jpeg(11),
      source: 'local',
      scope: ArtworkApplyScope.track,
    );
    await resolver.applyImage(
      ArtworkRequest.forTrack(mine),
      _jpeg(12),
      source: 'local',
      scope: ArtworkApplyScope.track,
    );

    expect(await resolver.resolve(ArtworkRequest.forTrack(theirs)), _jpeg(11));
    expect(await resolver.resolve(ArtworkRequest.forTrack(mine)), _jpeg(12));
  });

  test('the automatic pass still fills a whole album at once', () async {
    // The album scope is what the background best-guess pass uses, because
    // that IS the scope it searched at. Unpinned tracks inherit from it.
    final one = track('id-a', 'Speak to Me', album: 'Dark Side');
    final two = track('id-b', 'Breathe', album: 'Dark Side');

    await resolver.applyImage(
      ArtworkRequest.forTrack(one),
      _jpeg(21),
      source: 'itunes',
      scope: ArtworkApplyScope.album,
    );

    expect(await resolver.resolve(ArtworkRequest.forTrack(two)), _jpeg(21));
  });

  test('a pin beats the album cover the automatic pass wrote', () async {
    final pinned = track('id-p', 'Best of 2025', album: 'Sheepy Mixes');
    final other = track('id-o', 'Best of 2023', album: 'Sheepy Mixes');

    await resolver.applyImage(
      ArtworkRequest.forTrack(other),
      _jpeg(31),
      source: 'itunes',
      scope: ArtworkApplyScope.album,
    );
    await resolver.applyImage(
      ArtworkRequest.forTrack(pinned),
      _jpeg(32),
      source: 'local',
      scope: ArtworkApplyScope.track,
    );

    expect(await resolver.resolve(ArtworkRequest.forTrack(pinned)), _jpeg(32));
    expect(
      await resolver.resolve(ArtworkRequest.forTrack(other)),
      _jpeg(31),
      reason: 'pinning one track leaves the album cover alone',
    );
  });

  test('removing artwork on one track leaves its album-mates alone', () async {
    // The same bug in reverse: Remove used to suppress the album key too, so
    // clearing one mix stripped the cover from every track sharing the label.
    final gone = track('id-g', 'Colourful Emotions', album: 'Sheepy Mixes');
    final kept = track('id-k', 'Peaceful Solitude', album: 'Sheepy Mixes');

    await resolver.applyImage(
      ArtworkRequest.forTrack(gone),
      _jpeg(41),
      source: 'itunes',
      scope: ArtworkApplyScope.album,
    );
    expect(await resolver.resolve(ArtworkRequest.forTrack(kept)), _jpeg(41));

    await resolver.removeImage(ArtworkRequest.forTrack(gone));

    expect(
      await resolver.resolve(ArtworkRequest.forTrack(gone)),
      isNull,
      reason: 'the track it was removed from shows nothing',
    );
    expect(
      await resolver.resolve(ArtworkRequest.forTrack(kept)),
      _jpeg(41),
      reason: 'and the album cover is still there for everyone else',
    );
  });

  test('removing artwork clears the pin too', () async {
    final t = track('id-x', 'A Mix', album: 'Sheepy Mixes');
    await resolver.applyImage(
      ArtworkRequest.forTrack(t),
      _jpeg(4),
      source: 'local',
      scope: ArtworkApplyScope.track,
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
