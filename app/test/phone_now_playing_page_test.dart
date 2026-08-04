// Last modified: 2026-08-04--1654
//
// Now Playing, Apple-Music-style layout: full-bleed, artwork-tinted, no
// AppBar (np-close chevron dismisses). Left-aligned title/artist/source-
// folder block with circular shuffle + overflow actions on its right, a
// fat thumbless seek bar with the times directly below it, exactly THREE
// transport controls (previous / play-pause / next), and a persistent
// bottom shortcut bar (np-nav-bar) that pops the page and switches the
// shell view via phoneShellNavRequest. Transport taps go through spy-safe
// paths (PlayerService.next/previous would construct a media_kit Player,
// whose natives are unavailable under `flutter test`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
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
import 'package:fooplayer_app/ui/phone/phone_shell.dart'
    show PhoneView, phoneShellNavRequest;

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
    album: '', // no album tag -- the third line is the folder, not the album
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
  LibraryModel? library,
  PlaylistStore? store,
  int startIndex = 0,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final p = player ?? PlayerService();
  // Queue without touching media_kit natives; setVolume notifies without
  // constructing the lazy Player.
  p.queueController.setQueue(fixtureTracks(), startIndex);
  await p.setVolume(1.0);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: NowPlayingPage(player: p, library: library, store: store),
    ),
  );
  await tester.pumpAndSettle();
  return p;
}

void main() {
  testWidgets('no AppBar / "Now Playing" title -- full-bleed page', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Now Playing'), findsNothing);
    expect(find.byKey(const Key('np-tint')), findsOneWidget);
  });

  testWidgets('np-close pops the route', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = PlayerService();
    player.queueController.setQueue(fixtureTracks(), 0);
    await player.setVolume(1.0);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(NowPlayingPage.route(player: player)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('np-close')));
    await tester.pumpAndSettle();

    expect(find.byType(NowPlayingPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets(
    'exactly three transport controls; shuffle and more are circle actions',
    (tester) async {
      await pumpPage(tester);

      final transport = find.byKey(const Key('np-transport'));
      expect(transport, findsOneWidget);
      expect(
        find.descendant(of: transport, matching: find.byType(IconButton)),
        findsNWidgets(3),
      );

      // Shuffle and overflow moved up to the title row, still present.
      expect(metroIcon(kIconShuffleOff), findsOneWidget);
      expect(metroIcon(kIconPrevious), findsOneWidget);
      expect(metroIcon(kIconPlay), findsOneWidget); // not playing
      expect(metroIcon(kIconPause), findsNothing);
      expect(metroIcon(kIconNext), findsOneWidget);
      expect(find.byKey(const Key('np-more')), findsOneWidget);

      // Nothing else on this screen.
      expect(find.byIcon(Icons.repeat), findsNothing);
      expect(find.byIcon(Icons.equalizer), findsNothing);
      expect(find.byIcon(Icons.volume_up), findsNothing);
      expect(find.byIcon(Icons.favorite), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byIcon(Icons.fast_forward), findsNothing);
      expect(find.byIcon(Icons.fast_rewind), findsNothing);
      expect(find.byType(Slider), findsOneWidget); // seek only
    },
  );

  testWidgets('renders track info: title, artist, source folder', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    // Third line is the file's immediate parent folder -- the fixture
    // lives directly in the root L:/Music, so its basename.
    expect(find.text('Music'), findsOneWidget);
  });

  testWidgets('seek bar has no thumb dot and a fat track', (tester) async {
    await pumpPage(tester);

    final theme = tester.widget<SliderTheme>(
      find
          .ancestor(
            of: find.byKey(const Key('np-seek')),
            matching: find.byType(SliderTheme),
          )
          .first,
    );
    expect(theme.data.thumbShape, SliderComponentShape.noThumb);
    expect(theme.data.trackHeight, 7);
  });

  testWidgets(
    'nav bar lists the five shortcuts and posts the view on tap',
    (tester) async {
      addTearDown(() => phoneShellNavRequest.value = null);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final player = PlayerService();
      player.queueController.setQueue(fixtureTracks(), 0);
      await player.setVolume(1.0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(NowPlayingPage.route(player: player)),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final bar = find.byKey(const Key('np-nav-bar'));
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.byType(IconButton)),
        findsNWidgets(5),
      );
      for (final v in const [
        PhoneView.library,
        PhoneView.queue,
        PhoneView.folders,
        PhoneView.artists,
        PhoneView.playlists,
      ]) {
        expect(find.byKey(Key('np-nav-${v.name}')), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('np-nav-artists')));
      await tester.pumpAndSettle();

      // Popped itself and posted the request for the shell to consume.
      expect(find.byType(NowPlayingPage), findsNothing);
      expect(phoneShellNavRequest.value, PhoneView.artists);
    },
  );

  testWidgets('art is sized min(width - 56, 400)', (tester) async {
    // Phone-narrow: 390 - 56 = 334.
    await pumpPage(tester);
    expect(tester.getSize(find.byType(AlbumArt)), const Size(334, 334));
  });

  testWidgets('art caps at 400 on wide surfaces', (tester) async {
    await pumpPage(tester, surface: const Size(800, 1000));
    expect(tester.getSize(find.byType(AlbumArt)), const Size(400, 400));
  });

  testWidgets('time labels show position/duration with tabular figures', (
    tester,
  ) async {
    final player = await pumpPage(tester);

    player.duration = const Duration(minutes: 3, seconds: 5);
    player.position = const Duration(seconds: 12);
    await player.setVolume(1.0);
    await tester.pumpAndSettle();

    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('3:05'), findsOneWidget);
    final style = tester.widget<Text>(find.text('3:05')).style;
    expect(style?.fontSize, 11);
    expect(style?.color, Colors.white70);
    expect(style?.fontFeatures, contains(const FontFeature.tabularFigures()));
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

  testWidgets('shuffle toggle flips the state glyph and calls toggleShuffle', (
    tester,
  ) async {
    final player = await pumpPage(tester);

    expect(player.shuffle, isFalse);
    await tester.tap(find.byKey(const Key('np-shuffle')));
    await tester.pumpAndSettle();

    expect(player.shuffle, isTrue);
    expect(metroIcon(kIconShuffleOff), findsNothing);
    expect(metroIcon(kIconShuffleOn), findsOneWidget);
  });

  testWidgets('np-more opens the existing track context sheet', (
    tester,
  ) async {
    final library = LibraryModel();
    final store = PlaylistStore(library: library, device: 'test');
    await pumpPage(tester, library: library, store: store);

    await tester.tap(find.byKey(const Key('np-more')));
    await tester.pumpAndSettle();

    // One of the sheet's known items -- proves the EXISTING sheet opened,
    // not some new bespoke menu.
    expect(find.byKey(const Key('sheet-view-details')), findsOneWidget);
    expect(find.byKey(const Key('sheet-add-to-playlist')), findsOneWidget);
  });

  testWidgets('np-more is a no-op without library/store wired', (
    tester,
  ) async {
    await pumpPage(tester); // no library/store

    await tester.tap(find.byKey(const Key('np-more')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sheet-view-details')), findsNothing);
  });
}
