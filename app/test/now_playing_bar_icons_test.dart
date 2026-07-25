// Last modified: 2026-07-24--1735
//
// TODO #31: the now-playing bar's transport controls render Mike's
// metro-style PNG glyphs (assets/icons/, copied from his original
// foobar2000 JScript panel set) instead of Material icons. These tests pin
// down (a) which asset each button shows, (b) that the play/pause and
// shuffle glyphs flip with player state, and (c) that the white-on-
// transparent source PNGs get the AppColors.ink tint that makes them
// visible against the light barBg.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart';

List<Track> fixtureTracks() => [
      Track(
          contentId: 'a',
          relPath: 'a.mp3',
          rootPath: r'L:\Music',
          dateAdded: DateTime.utc(2026, 7, 1),
          title: 'Song A',
          artist: 'Artist A',
          album: 'Album A',
          genre: 'Rock'),
      Track(
          contentId: 'b',
          relPath: 'b.mp3',
          rootPath: r'L:\Music',
          dateAdded: DateTime.utc(2026, 7, 2),
          title: 'Song B',
          artist: 'Artist B',
          album: 'Album B',
          genre: 'Rock'),
    ];

/// Finds the [Image] rendering the given bundled asset.
Finder metroIcon(String asset) => find.byWidgetPredicate((w) =>
    w is Image &&
    w.image is AssetImage &&
    (w.image as AssetImage).assetName == asset);

/// Pumps a wide-surface bar (so the shuffle/volume group, hidden below the
/// 900px narrow threshold, is present) with a queue loaded.
Future<PlayerService> pumpBar(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final player = PlayerService();
  // Queue without touching media_kit natives; setVolume notifies without
  // constructing the lazy Player.
  player.queueController.setQueue(fixtureTracks(), 0);
  await player.setVolume(1.0);
  await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: NowPlayingBar(player: player))));
  await tester.pumpAndSettle();
  return player;
}

void main() {
  testWidgets('transport buttons render the metro PNG assets', (tester) async {
    await pumpBar(tester);

    expect(metroIcon(kIconPrevious), findsOneWidget);
    expect(metroIcon(kIconPlay), findsOneWidget); // not playing -> play glyph
    expect(metroIcon(kIconPause), findsNothing);
    expect(metroIcon(kIconNext), findsOneWidget);
    expect(metroIcon(kIconShuffleOff), findsOneWidget);
    expect(metroIcon(kIconShuffleOn), findsNothing);

    // No Material transport icons remain (volume stays Material by design).
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.pause), findsNothing);
    expect(find.byIcon(Icons.skip_next), findsNothing);
    expect(find.byIcon(Icons.skip_previous), findsNothing);
    expect(find.byIcon(Icons.shuffle), findsNothing);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    // Each glyph sits inside an IconButton (tap semantics/tooltips kept).
    for (final asset in [kIconPrevious, kIconPlay, kIconNext, kIconShuffleOff]) {
      expect(
        find.ancestor(
            of: metroIcon(asset), matching: find.byType(IconButton)),
        findsOneWidget,
        reason: '$asset should be wrapped in an IconButton',
      );
    }
  });

  testWidgets('play/pause glyph follows playing state', (tester) async {
    final player = await pumpBar(tester);

    expect(metroIcon(kIconPlay), findsOneWidget);
    expect(metroIcon(kIconPause), findsNothing);

    // playing is mirrored from the engine's stream in production; set it
    // directly and use setVolume as the no-native notifyListeners trigger.
    player.playing = true;
    await player.setVolume(1.0);
    await tester.pumpAndSettle();

    expect(metroIcon(kIconPlay), findsNothing);
    expect(metroIcon(kIconPause), findsOneWidget);
  });

  testWidgets('shuffle glyph flips shuffle1/shuffle2 with state',
      (tester) async {
    final player = await pumpBar(tester);

    expect(player.shuffle, isFalse);
    expect(metroIcon(kIconShuffleOff), findsOneWidget);
    expect(metroIcon(kIconShuffleOn), findsNothing);

    await tester.tap(find.byTooltip('Shuffle'));
    await tester.pumpAndSettle();

    expect(player.shuffle, isTrue);
    expect(metroIcon(kIconShuffleOff), findsNothing);
    expect(metroIcon(kIconShuffleOn), findsOneWidget);

    // Toggle back off.
    await tester.tap(find.byTooltip('Shuffle'));
    await tester.pumpAndSettle();
    expect(player.shuffle, isFalse);
    expect(metroIcon(kIconShuffleOff), findsOneWidget);
  });

  testWidgets('metro glyphs are tinted AppColors.ink (source PNGs are white)',
      (tester) async {
    await pumpBar(tester);

    for (final asset in [kIconPrevious, kIconPlay, kIconNext, kIconShuffleOff]) {
      final img = tester.widget<Image>(metroIcon(asset));
      expect(img.color, AppColors.ink,
          reason: '$asset must be tinted ink to be visible on barBg');
      expect(img.colorBlendMode, BlendMode.srcIn);
    }
  });
}
