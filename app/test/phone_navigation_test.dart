// Phone navigation: into a song, and back out one level at a time.
//
// Two complaints, both about the same thing -- the shell had no notion of
// where you were.
//
// Tapping a song only started playback and left you looking at the list; the
// full-screen player existed but was reachable solely by noticing the strip
// at the bottom and tapping that.
//
// And the drawer switched views by setting state rather than pushing a
// route, so the system Back button found nothing to pop and closed the whole
// app -- from Albums, from Settings, from anywhere but the feed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/app_background.dart';
import 'package:fooplayer_app/ui/phone/now_playing_page.dart';
import 'package:fooplayer_app/ui/phone/phone_shell.dart';

LibraryModel _library() {
  final m = LibraryModel()
    ..allTracks = [
      Track(
        contentId: 'a',
        relPath: 'a.mp3',
        dateAdded: DateTime.utc(2026, 7, 1),
        title: 'Newest Song',
        artist: 'Muse',
        album: 'Absolution',
        durationMs: 200000,
      ),
    ]
    ..status = 'ready';
  return m;
}

Future<void> _pump(
  WidgetTester tester, {
  void Function(List<Track>, int)? onPlayTrack,
  bool openNowPlayingOnPlay = true,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: PhoneShell(
      library: _library(),
      player: PlayerService(),
      onPlayTrack: onPlayTrack ?? (_, _) {},
      onTrackLongPress: (_, _) {},
      openNowPlayingOnPlay: openNowPlayingOnPlay,
      viewBuilders: {
        for (final v in PhoneView.values)
          if (v != PhoneView.library)
            v: (_) => Center(child: Text('${v.name} body')),
      },
    ),
  ),
);

Future<void> _openDrawerTo(WidgetTester tester, PhoneView view) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('phone-drawer-${view.name}')));
  await tester.pumpAndSettle();
}

/// The system Back button / gesture.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  group('tapping a song', () {
    testWidgets('plays it AND goes full screen into it', (tester) async {
      final played = <int>[];
      await _pump(tester, onPlayTrack: (tracks, i) => played.add(i));

      await tester.tap(find.text('Newest Song'));
      await tester.pumpAndSettle();

      expect(played, [0], reason: 'still starts playback');
      expect(
        find.byType(NowPlayingPage),
        findsOneWidget,
        reason: 'going into the song is what tapping a song means',
      );
    });

    testWidgets('and back returns to the list, not out of the app', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.text('Newest Song'));
      await tester.pumpAndSettle();

      await _systemBack(tester);

      expect(find.byType(NowPlayingPage), findsNothing);
      expect(find.text('Newest Song'), findsOneWidget);
    });
  });

  group('back unwinds exactly one level', () {
    testWidgets('a drawer view returns to where it came from', (tester) async {
      await _pump(tester);
      await _openDrawerTo(tester, PhoneView.albums);
      expect(find.text('albums body'), findsOneWidget);

      await _systemBack(tester);

      expect(find.text('albums body'), findsNothing);
      expect(find.text('Newest Song'), findsOneWidget, reason: 'the feed');
    });

    testWidgets('three deep unwinds one at a time, in order', (tester) async {
      await _pump(tester);
      await _openDrawerTo(tester, PhoneView.albums);
      await _openDrawerTo(tester, PhoneView.artists);
      await _openDrawerTo(tester, PhoneView.settings);
      expect(find.text('settings body'), findsOneWidget);

      await _systemBack(tester);
      expect(find.text('artists body'), findsOneWidget);

      await _systemBack(tester);
      expect(find.text('albums body'), findsOneWidget);

      await _systemBack(tester);
      expect(find.text('Newest Song'), findsOneWidget);
    });

    testWidgets('re-selecting the current view does not stack a duplicate', (
      tester,
    ) async {
      await _pump(tester);
      await _openDrawerTo(tester, PhoneView.albums);
      await _openDrawerTo(tester, PhoneView.albums);

      await _systemBack(tester);

      expect(
        find.text('Newest Song'),
        findsOneWidget,
        reason: 'one tap in, one press back out',
      );
    });

    testWidgets('back closes the drawer before it changes anything', (
      tester,
    ) async {
      await _pump(tester);
      await _openDrawerTo(tester, PhoneView.albums);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      await _systemBack(tester);

      // The drawer is a route, so Back pops it and leaves the view alone.
      expect(find.text('albums body'), findsOneWidget);
    });
  });

  group('at the root', () {
    testWidgets('back backgrounds the app instead of closing it', (
      tester,
    ) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        appChannel,
        (call) async {
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appChannel,
          null,
        ),
      );

      await _pump(tester);
      await _systemBack(tester);

      expect(
        calls,
        ['moveToBackground'],
        reason: 'finishing the activity would cold-start the whole library',
      );
      expect(find.text('Newest Song'), findsOneWidget, reason: 'still there');
    });

    testWidgets('a platform without backgrounding does not crash', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        appChannel,
        (call) async => throw MissingPluginException(),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appChannel,
          null,
        ),
      );

      await _pump(tester);
      await _systemBack(tester);

      expect(find.text('Newest Song'), findsOneWidget);
    });
  });
}
