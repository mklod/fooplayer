// Last modified: 2026-07-24--1835
//
// Plan 2b / P2: NowPlayingPage widget tests. The full-screen phone player
// must render the metro transport assets (prev 32 / play-pause 48 / next
// 32), the shuffle state-glyph + volume row, a seek slider with 10.5px time
// labels, centered title/artist/album, and art sized min(width - 48, 360).
// Transport taps go through spy-safe paths (PlayerService.next/previous
// would construct a media_kit Player, whose natives are unavailable under
// `flutter test`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart'
    show
        AlbumArt,
        kIconPlay,
        kIconPause,
        kIconNext,
        kIconPrevious,
        kIconShuffleOff,
        kIconShuffleOn;
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

/// Records transport/seek calls instead of reaching PlayerService's real
/// implementations (next/previous construct a media_kit Player).
class SpyPlayer extends PlayerService {
  int toggleCalls = 0;
  int nextCalls = 0;
  int prevCalls = 0;
  final seeks = <Duration>[];

  @override
  Future<void> togglePlayPause() async {
    toggleCalls++;
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> previous() async {
    prevCalls++;
  }

  @override
  Future<void> seek(Duration d) async {
    seeks.add(d);
  }
}

Finder metroIcon(String asset) => find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is AssetImage &&
      (w.image as AssetImage).assetName == asset,
);

Future<PlayerService> pumpPage(
  WidgetTester tester, {
  PlayerService? player,
  Size surface = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final p = player ?? PlayerService();
  // Queue without touching media_kit natives; setVolume notifies without
  // constructing the lazy Player.
  p.queueController.setQueue(fixtureTracks(), 0);
  await p.setVolume(1.0);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: NowPlayingPage(player: p),
    ),
  );
  await tester.pumpAndSettle();
  return p;
}

void main() {
  testWidgets('renders metro transport assets, both sliders, and track info', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(metroIcon(kIconPrevious), findsOneWidget);
    expect(metroIcon(kIconPlay), findsOneWidget); // not playing -> play glyph
    expect(metroIcon(kIconPause), findsNothing);
    expect(metroIcon(kIconNext), findsOneWidget);
    expect(metroIcon(kIconShuffleOff), findsOneWidget);
    expect(metroIcon(kIconShuffleOn), findsNothing);

    // Transport sizes per spec: prev 32 / play-pause 48 / next 32.
    expect(tester.widget<Image>(metroIcon(kIconPrevious)).width, 32);
    expect(tester.widget<Image>(metroIcon(kIconPlay)).width, 48);
    expect(tester.widget<Image>(metroIcon(kIconNext)).width, 32);

    expect(find.byKey(const Key('np-seek')), findsOneWidget);
    expect(find.byKey(const Key('np-volume')), findsOneWidget);

    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    expect(find.text('Album A'), findsOneWidget);

    // No duration known yet -> both time labels read 0:00.
    expect(find.text('0:00'), findsNWidgets(2));

    // AppBar with a title (back button appears when the page is pushed --
    // covered by the mini-player navigation test).
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Now Playing'), findsOneWidget);
  });

  testWidgets('art is sized min(width - 48, 360)', (tester) async {
    // Phone-narrow: 390 - 48 = 342.
    await pumpPage(tester);
    expect(tester.getSize(find.byType(AlbumArt)), const Size(342, 342));
  });

  testWidgets('art caps at 360 on wide surfaces', (tester) async {
    await pumpPage(tester, surface: const Size(800, 1000));
    expect(tester.getSize(find.byType(AlbumArt)), const Size(360, 360));
  });

  testWidgets('time labels show position/duration at 10.5px', (tester) async {
    final player = await pumpPage(tester);

    // position/duration mirror engine streams in production; set directly
    // and use setVolume as the no-native notifyListeners trigger.
    player.duration = const Duration(minutes: 3, seconds: 5);
    player.position = const Duration(seconds: 12);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();

    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('3:05'), findsOneWidget);
    expect(tester.widget<Text>(find.text('3:05')).style?.fontSize, 10.5);
    expect(tester.widget<Text>(find.text('0:12')).style?.fontSize, 10.5);
  });

  testWidgets('play/pause glyph follows playing state', (tester) async {
    final player = await pumpPage(tester);

    expect(metroIcon(kIconPlay), findsOneWidget);

    player.playing = true;
    await player.setVolume(1.0);
    await tester.pumpAndSettle();

    expect(metroIcon(kIconPlay), findsNothing);
    expect(metroIcon(kIconPause), findsOneWidget);
  });

  testWidgets('transport buttons hit the player via spy-safe paths', (
    tester,
  ) async {
    final spy = SpyPlayer();
    await pumpPage(tester, player: spy);

    await tester.tap(find.byTooltip('Previous'));
    await tester.tap(find.byTooltip('Play'));
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();

    expect(spy.prevCalls, 1);
    expect(spy.toggleCalls, 1);
    expect(spy.nextCalls, 1);
  });

  testWidgets('seek slider drag issues a seek within the track duration', (
    tester,
  ) async {
    final spy = SpyPlayer();
    await pumpPage(tester, player: spy);
    spy.duration = const Duration(minutes: 4);
    await spy.setVolume(1.0);
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('np-seek')), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(spy.seeks, isNotEmpty);
    expect(spy.seeks.last, greaterThan(Duration.zero));
    expect(spy.seeks.last, lessThanOrEqualTo(const Duration(minutes: 4)));
  });

  testWidgets('shuffle toggle flips the state glyph', (tester) async {
    final player = await pumpPage(tester);

    expect(player.shuffle, isFalse);
    await tester.tap(find.byTooltip('Shuffle'));
    await tester.pumpAndSettle();

    expect(player.shuffle, isTrue);
    expect(metroIcon(kIconShuffleOff), findsNothing);
    expect(metroIcon(kIconShuffleOn), findsOneWidget);
  });

  testWidgets('volume slider drives PlayerService.setVolume', (tester) async {
    final player = await pumpPage(tester);
    expect(player.volume, 1.0);

    await tester.drag(
      find.byKey(const Key('np-volume')),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();

    expect(player.volume, lessThan(1.0));
  });
}
