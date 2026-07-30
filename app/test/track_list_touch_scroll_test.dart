// Scrolling the library with a finger must not select a track.
//
// Reported on the tablet: "the scrolling through the library always selects a
// track". Selection fired on pointer DOWN -- correct for a mouse (Explorer
// and foobar2000 both do it, and it is what removed a 300ms double-tap-window
// stutter), but every flick to scroll begins with a pointer-down on whatever
// row is under the finger. So browsing constantly changed the selection, and
// with it the sidebar's cover preview.
//
// A finger now selects on LIFT, and only if it stayed within kTouchSlop --
// the same threshold the enclosing scrollable uses to decide it is being
// dragged, so "the list would have scrolled" and "that was not a tap" are the
// same question by construction. A mouse is untouched.
//
// Last modified: 2026-07-29--1710

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    for (var i = 0; i < 40; i++)
      Track(
        contentId: 'id$i',
        relPath: 'song$i.mp3',
        // Descending, so 'Song 0' is newest and sits at the top of the
        // default date-desc sort where the tests can reach it.
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
        onPlayTrack: (_, _) {},
        launchExplorer: (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('a finger flick that scrolls selects nothing', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);
    expect(lib.selectedTrackIds, isEmpty);

    final row = tester.getCenter(find.text('Song 0'));
    final touch = await tester.startGesture(row, kind: PointerDeviceKind.touch);
    // Well past kTouchSlop (18): this is a scroll by any measure.
    await touch.moveBy(const Offset(0, -120));
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();

    expect(
      lib.selectedTrackIds,
      isEmpty,
      reason: 'browsing the library is not choosing a track',
    );
  });

  testWidgets('a finger tap that stays put still selects, on lift', (
    tester,
  ) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    final row = tester.getCenter(find.text('Song 3'));
    final touch = await tester.startGesture(row, kind: PointerDeviceKind.touch);
    // Nothing yet -- a press alone is not a choice; it might become a scroll.
    await tester.pump();
    expect(lib.selectedTrackIds, isEmpty);

    await touch.up();
    await tester.pumpAndSettle();
    expect(lib.selectedTrackIds, {'id3'});
  });

  testWidgets('a small wobble inside the slop is still a tap', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    final row = tester.getCenter(find.text('Song 5'));
    final touch = await tester.startGesture(row, kind: PointerDeviceKind.touch);
    await touch.moveBy(const Offset(2, -3)); // a finger is never perfectly still
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();

    expect(lib.selectedTrackIds, {'id5'});
  });

  testWidgets('a MOUSE still selects on press, with no wait', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);

    final row = tester.getCenter(find.text('Song 7'));
    final mouse = await tester.startGesture(row, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(
      lib.selectedTrackIds,
      {'id7'},
      reason: 'press-to-select is what keeps the desktop feeling instant; '
          'waiting for the lift (or the double-click window) was the stutter',
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(lib.selectedTrackIds, {'id7'});
  });

  testWidgets('a mouse DRAG still selects, unlike a finger drag', (
    tester,
  ) async {
    // Not a scroll gesture on a desktop: the wheel scrolls there, so a
    // press-and-move with a button held has no competing meaning and the
    // press already counted.
    final lib = fixtureLibrary();
    await pump(tester, lib);

    final row = tester.getCenter(find.text('Song 9'));
    final mouse = await tester.startGesture(row, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(0, -120));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    expect(lib.selectedTrackIds, {'id9'});
  });

  testWidgets('scrolling really does move the list (the gesture is a scroll, '
      'not a swallowed no-op)', (tester) async {
    final lib = fixtureLibrary();
    await pump(tester, lib);
    // A row far enough down the list to still be on screen afterwards --
    // 'Song 0' scrolls clean off and gets unmounted, which would make this
    // assert unreadable rather than wrong.
    final before = tester.getCenter(find.text('Song 8')).dy;

    await tester.drag(
      find.text('Song 0'),
      const Offset(0, -120),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();

    // A 120px drag scrolls 100: the first kTouchSlop (20 in the vertical
    // drag recognizer) is spent deciding it IS a drag. Asserting on the
    // remainder rather than the whole 120 keeps this about "did it scroll".
    expect(
      tester.getCenter(find.text('Song 8')).dy,
      lessThan(before - 50),
      reason: 'the flick has to actually scroll -- a fix that just swallowed '
          'the gesture would also pass the no-selection assert',
    );
    expect(lib.selectedTrackIds, isEmpty);
  });
}
