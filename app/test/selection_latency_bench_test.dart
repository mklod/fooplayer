// Measures where the click-to-highlight delay actually goes, at this
// library's real size (5443 tracks). Reported as a test so the numbers come
// from the same code the app runs, not a hand-rolled harness.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';

List<Track> _library(int n) {
  final rnd = Random(7);
  const artists = ['Echos', 'RÜFÜS', 'Various Artists', 'Akon', 'Zero 7'];
  const albums = ['Revival', 'Inhale / Exhale', '2007-08', 'Destiny', ''];
  return [
    for (var i = 0; i < n; i++)
      Track(
        contentId: 'id$i',
        relPath: 'sub${i % 40}/track$i.mp3',
        rootPath: r'L:\music (original structure)\monthly',
        dateAdded: DateTime.utc(2020).add(Duration(hours: i)),
        title: 'Track $i ${rnd.nextInt(999)}',
        artist: artists[i % artists.length],
        album: albums[i % albums.length],
        durationMs: 180000 + i,
      ),
  ];
}

void main() {
  test('visibleTracks cost at library scale', () {
    final model = LibraryModel()..allTracks = _library(5443);

    // Warm up (first call pays for lazy init inside sort/filter helpers).
    model.visibleTracks;

    final sw = Stopwatch()..start();
    const iterations = 20;
    for (var i = 0; i < iterations; i++) {
      model.visibleTracks;
    }
    sw.stop();
    final perCall = sw.elapsedMicroseconds / iterations / 1000.0;
    // ignore: avoid_print
    print(
      'visibleTracks: ${perCall.toStringAsFixed(1)} ms per call '
      '(${model.visibleTracks.length} tracks)',
    );

    // A selection triggers notifyListeners -> rebuild -> at least two
    // visibleTracks calls (the list itself and the sidebar's count).
    // ignore: avoid_print
    print(
      '=> a rebuild costs roughly ${(perCall * 2).toStringAsFixed(1)} ms '
      'in visibleTracks alone',
    );

    final swSel = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      model.selectTrackClick(
        'id$i',
        ctrl: false,
        shift: false,
        visibleOrder: model.visibleTracks,
      );
    }
    swSel.stop();
    // ignore: avoid_print
    print(
      'selectTrackClick + visibleOrder: '
      '${(swSel.elapsedMicroseconds / iterations / 1000.0).toStringAsFixed(1)} ms',
    );

    // The filter panes rebuild on the same notify, so their derived lists
    // are part of a selection's cost too.
    final swF = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      model.artists;
      model.albums;
      model.folderEntries;
    }
    swF.stop();
    // ignore: avoid_print
    print(
      'artists + albums + folderEntries: '
      '${(swF.elapsedMicroseconds / iterations / 1000.0).toStringAsFixed(1)} ms',
    );

    expect(model.visibleTracks, isNotEmpty);
  });

  test('search/filter typing cost (worst case: every keystroke refilters)', () {
    final model = LibraryModel()..allTracks = _library(5443);
    final sw = Stopwatch()..start();
    for (final term in ['e', 'ec', 'ech', 'echo', 'echos']) {
      model.search = term;
      model.visibleTracks;
    }
    sw.stop();
    // ignore: avoid_print
    print('5 keystrokes of search: ${sw.elapsedMilliseconds} ms total');
    expect(model.search, 'echos');
  });
}
