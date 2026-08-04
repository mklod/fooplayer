// Last modified: 2026-08-04--0340
//
// Plan 2b / P2: phone MiniPlayer widget tests. The bar must be hidden with
// no current track, appear as a 64px bar (48px art + title/artist + metro
// play/pause) once a queue is set, flip its glyph with playing state,
// toggle playback via a spy-safe path (never touching media_kit natives),
// and push NowPlayingPage when the bar itself is tapped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart'
    show AlbumArt, kIconPlay, kIconPause;
import 'package:fooplayer_app/ui/phone/mini_player.dart';
import 'package:fooplayer_app/ui/phone/now_playing_page.dart';

List<Track> fixtureTracks() => [
  Track(
    contentId: 'a',
    relPath: 'a.mp3',
    rootPath: r'L:\Music',
    dateAdded: DateTime.utc(2026, 7, 1),
    title: 'Song A',
    artist: 'Artist A',
    album: 'Album A',
    genre: 'Rock',
  ),
  Track(
    contentId: 'b',
    relPath: 'b.mp3',
    rootPath: r'L:\Music',
    dateAdded: DateTime.utc(2026, 7, 2),
    title: 'Song B',
    artist: 'Artist B',
    album: 'Album B',
    genre: 'Rock',
  ),
];

/// Records transport calls instead of reaching PlayerService's real
/// implementations, whose next/previous would construct a media_kit
/// [Player] (natives unavailable under `flutter test`).
class SpyPlayer extends PlayerService {
  int toggleCalls = 0;

  @override
  Future<void> togglePlayPause() async {
    toggleCalls++;
  }
}

Finder metroIcon(String asset) => find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is AssetImage &&
      (w.image as AssetImage).assetName == asset,
);

/// Pumps a Scaffold with [MiniPlayer] in the bottom slot. Queue is loaded
/// without touching media_kit natives (setQueue via the queueController;
/// setVolume as the no-native notifyListeners trigger).
Future<PlayerService> pumpMini(
  WidgetTester tester, {
  bool withQueue = true,
  PlayerService? player,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final p = player ?? PlayerService();
  if (withQueue) {
    p.queueController.setQueue(fixtureTracks(), 0);
    await p.setVolume(1.0);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: MiniPlayer(player: p),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return p;
}

void main() {
  testWidgets('hidden entirely when no current track', (tester) async {
    await pumpMini(tester, withQueue: false);

    expect(find.byKey(const Key('mini-player-bar')), findsNothing);
    expect(metroIcon(kIconPlay), findsNothing);
    expect(find.text('Song A'), findsNothing);
  });

  testWidgets('appears once a queue is set: 76px bar, 56px art, title/artist', (
    tester,
  ) async {
    await pumpMini(tester);

    final bar = find.byKey(const Key('mini-player-bar'));
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).height, 76);

    final art = find.byType(AlbumArt);
    expect(art, findsOneWidget);
    expect(tester.getSize(art), const Size(56, 56));

    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    expect(metroIcon(kIconPlay), findsOneWidget); // not playing -> play glyph
    expect(metroIcon(kIconPause), findsNothing);
  });

  testWidgets('play/pause glyph follows playing state', (tester) async {
    final player = await pumpMini(tester);

    expect(metroIcon(kIconPlay), findsOneWidget);

    // playing is mirrored from the engine's stream in production; set it
    // directly and use setVolume as the no-native notifyListeners trigger.
    player.playing = true;
    await player.setVolume(1.0);
    await tester.pumpAndSettle();

    expect(metroIcon(kIconPlay), findsNothing);
    expect(metroIcon(kIconPause), findsOneWidget);
  });

  testWidgets('play/pause button calls togglePlayPause and does NOT navigate', (
    tester,
  ) async {
    final spy = SpyPlayer();
    await pumpMini(tester, player: spy);

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();

    expect(spy.toggleCalls, 1);
    // The button consumes its own tap: no NowPlayingPage pushed.
    expect(find.byType(NowPlayingPage), findsNothing);
  });

  testWidgets(
    'tapping the bar pushes NowPlayingPage; np-close pops back to the bar',
    (tester) async {
      await pumpMini(tester);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsOneWidget);
      // No AppBar on the reskinned page -- np-close is the dismiss
      // affordance instead of the framework BackButton.
      expect(find.byKey(const Key('np-close')), findsOneWidget);

      await tester.tap(find.byKey(const Key('np-close')));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsNothing);
      expect(find.byKey(const Key('mini-player-bar')), findsOneWidget);
    },
  );
}
