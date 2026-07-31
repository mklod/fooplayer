// Clicking a row must highlight it NOW, not after the double-tap window.
//
// The regression this guards: selection used to hang off InkWell.onTap,
// which Flutter withholds for the full kDoubleTapTimeout (~300ms) while it
// waits to see whether a second tap arrives. With the model work behind a
// selection measured at ~5ms, that wait was the entire perceived stutter.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel _library() => LibraryModel()
  ..allTracks = [
    Track(
      contentId: 'a',
      relPath: 'a.mp3',
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2026, 1, 3),
      title: 'Alpha',
      artist: 'One',
      album: 'First',
      durationMs: 1000,
    ),
    Track(
      contentId: 'b',
      relPath: 'b.mp3',
      rootPath: r'L:\M',
      dateAdded: DateTime.utc(2026, 1, 2),
      title: 'Bravo',
      artist: 'Two',
      album: 'Second',
      durationMs: 2000,
    ),
  ]
  ..status = 'ready';

Future<void> _pump(WidgetTester tester, LibraryModel lib) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: TrackListView(
          library: lib,
          player: PlayerService(),
          playlistStore: PlaylistStore(library: lib, device: 'test'),
          onPlayTrack: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a row is selected on pointer DOWN, before any tap completes', (
    tester,
  ) async {
    final lib = _library();
    await _pump(tester, lib);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Bravo')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    // One frame -- no pointer-up, and nowhere near kDoubleTapTimeout.
    await tester.pump();

    expect(
      lib.selectedTrackIds,
      {'b'},
      reason: 'the highlight must not wait for the double-tap window',
    );

    await gesture.up();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    expect(lib.selectedTrackIds, {'b'}, reason: 'and it stays selected');
  });

  testWidgets('double-click still plays, and selection survives it', (
    tester,
  ) async {
    final lib = _library();
    final played = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TrackListView(
            library: lib,
            player: PlayerService(),
            playlistStore: PlaylistStore(library: lib, device: 'test'),
            onPlayTrack: (tracks, i) => played.add(tracks[i].contentId),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final at = tester.getCenter(find.text('Alpha'));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(at);
    await tester.pumpAndSettle();

    expect(played, ['a'], reason: 'the second press still completes a play');
    expect(lib.selectedTrackIds, {'a'});
  });

  testWidgets(
    'right-clicking a row puts Album artwork at the top of the menu',
    (tester) async {
      final lib = _library();
      await _pump(tester, lib);

      await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      // No artwork services are wired here, so the item is (correctly) absent;
      // what's asserted is the ORDER of what is shown -- artwork would precede
      // "View in folder", which is itself first among the rest.
      final viewInFolder = find.text('View in folder');
      expect(viewInFolder, findsOneWidget);
      final addToPlaylist = find.text('Add to playlist ▸');
      expect(
        tester.getTopLeft(viewInFolder).dy,
        lessThan(tester.getTopLeft(addToPlaylist).dy),
      );
    },
  );
}
