// "Play next" is for one track. A selection gets "Add to queue".
//
// Both items are the same operation -- put these in the queue -- differing
// only in where: directly after what is playing, or at the end. That
// distinction is real for a single track and vacuous for ten, because ten
// songs cannot all play next. On a multi-selection the menu was therefore
// showing two names for one action with nothing to choose between them.
//
// Last modified: 2026-07-29--1805

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    for (var i = 0; i < 6; i++)
      Track(
        contentId: 'id$i',
        relPath: 'song$i.mp3',
        dateAdded: DateTime.utc(2024, 6, 1).subtract(Duration(days: i)),
        title: 'Song $i',
        artist: 'Artist $i',
        album: 'Album',
        durationMs: 200000,
      ),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pump(WidgetTester tester, LibraryModel lib) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: TrackListView(
        library: lib,
        player: PlayerService(),
        playlistStore: PlaylistStore(library: lib, device: 'test'),
        onPlayTrack: (_, _) {},
        launchExplorer: (_) {},
      ),
    ),
  ),
);

/// Opens the row menu the way a mouse does.
Future<void> openMenuOn(WidgetTester tester, String title) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(title)),
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one track offers both, because both mean something', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    await openMenuOn(tester, 'Song 1');

    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
  });

  testWidgets('a selection of three offers ONLY "Add to queue"', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);
    lib.selectTrackClick(
      'id1',
      ctrl: false,
      shift: false,
      visibleOrder: lib.visibleTracks,
    );
    lib.selectTrackClick(
      'id2',
      ctrl: true,
      shift: false,
      visibleOrder: lib.visibleTracks,
    );
    lib.selectTrackClick(
      'id3',
      ctrl: true,
      shift: false,
      visibleOrder: lib.visibleTracks,
    );
    await tester.pump();

    await openMenuOn(tester, 'Song 2');

    expect(
      find.textContaining('Play next'),
      findsNothing,
      reason: 'three songs cannot all play next',
    );
    expect(find.text('Add to queue (3 tracks)'), findsOneWidget);
  });

  testWidgets(
    'right-clicking outside the selection collapses to that one row, so '
    '"Play next" comes back',
    (tester) async {
      final lib = fixtureLibrary();
      await pump(tester, lib);
      lib.selectTrackClick(
        'id1',
        ctrl: false,
        shift: false,
        visibleOrder: lib.visibleTracks,
      );
      lib.selectTrackClick(
        'id2',
        ctrl: true,
        shift: false,
        visibleOrder: lib.visibleTracks,
      );
      await tester.pump();

      // Song 4 is not in the selection: the menu retargets to it alone
      // (Explorer/foobar behavior), which makes it a single-track menu.
      await openMenuOn(tester, 'Song 4');

      expect(lib.selectedTrackIds, {'id4'});
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
    },
  );
}
