// Last modified: 2026-07-25--2115
//
// Plan 4 / A2: wiring the resolver into the EXISTING art surfaces --
// desktop `AlbumArt` (now_playing_bar.dart), the phone mini-player and the
// phone Now Playing page.
//
// The point of these tests is that the wiring did not regress what those
// files document: the per-track stale-request guard, the "don't re-fetch on
// every position tick" caching, the stable-Uint8List / gapless behavior,
// and (new, so it must not leak) the resolver listener being detached on
// dispose. Also pins the embedded-only fallback: with no resolver supplied,
// AlbumArt still goes through `loader`, which is what the pre-Plan-4 tests
// rely on.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart';
import 'package:fooplayer_app/ui/phone/mini_player.dart';
import 'package:fooplayer_app/ui/phone/now_playing_page.dart';

/// A valid 1x1 transparent PNG -- real bytes so `Image.memory` never throws
/// if the framework does get around to decoding it inside a widget test.
const onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// Pure, in-memory [ArtworkResolver] stand-in: the real chain's disk I/O is
/// covered in `artwork_resolver_test.dart`; here we only care about how the
/// WIDGETS drive it, so `resolve` must settle on a microtask (no real file
/// futures, which a widget test's fake clock would never deliver).
class FakeResolver extends ArtworkResolver {
  FakeResolver()
      : super(stores: ArtworkStoreRegistry(appDataDir: Directory('.')));

  final List<ArtworkRequest> requests = [];
  List<int>? bytes;

  int get resolveCalls => requests.length;

  /// [ChangeNotifier.hasListeners] is protected -- exposed here (legally,
  /// from a subclass) so a test can prove `AlbumArt` detaches on dispose.
  bool get listenerAttached => hasListeners;

  @override
  Future<List<int>?> resolve(ArtworkRequest req) async {
    requests.add(req);
    return bytes;
  }
}

Track track({
  String id = 'a',
  String album = 'Album A',
  String title = 'Song A',
}) =>
    Track(
      contentId: id,
      relPath: '$title.mp3',
      rootPath: r'L:\Music',
      dateAdded: DateTime.utc(2026, 7, 1),
      title: title,
      artist: 'Artist A',
      album: album,
    );

void main() {
  group('AlbumArt source selection', () {
    testWidgets('with a resolver+track it resolves, never touching loader',
        (tester) async {
      var loaderCalls = 0;
      final resolver = FakeResolver();
      final t = track();

      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: t.contentId,
          file: File('unused.mp3'),
          loader: (_) async {
            loaderCalls++;
            return null;
          },
          resolver: resolver,
          track: t,
        ),
      ));
      await tester.pump();

      expect(loaderCalls, 0);
      expect(resolver.resolveCalls, 1);
      expect(resolver.requests.single.albumKey, 'artist a|album a');
      expect(resolver.requests.single.rootPath, r'L:\Music');
    });

    testWidgets('with no resolver it still uses loader (pre-Plan-4 behavior)',
        (tester) async {
      var loaderCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: 'a',
          file: File('unused.mp3'),
          loader: (_) async {
            loaderCalls++;
            return null;
          },
        ),
      ));
      await tester.pump();
      expect(loaderCalls, 1);
    });

    testWidgets('renders the resolved bytes', (tester) async {
      final resolver = FakeResolver()..bytes = onePixelPng;
      final t = track();
      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: t.contentId,
          file: File('unused.mp3'),
          resolver: resolver,
          track: t,
        ),
      ));
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.gaplessPlayback, isTrue,
          reason: 'gapless keeps the old cover up while the next one loads');
      expect(find.byIcon(Icons.album), findsNothing);
    });
  });

  group('stale-request / caching guards survive the resolver wiring', () {
    testWidgets('parent rebuilds with the same contentId do not re-resolve',
        (tester) async {
      final resolver = FakeResolver();
      var t = track();
      late StateSetter setState;

      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (context, setter) {
          setState = setter;
          return AlbumArt(
            contentId: t.contentId,
            file: File('unused.mp3'),
            resolver: resolver,
            track: t,
          );
        }),
      ));
      await tester.pump();
      expect(resolver.resolveCalls, 1);

      // The now-playing bar rebuilds several times a second on position
      // ticks; none of those may re-request art.
      for (var i = 0; i < 3; i++) {
        setState(() {});
        await tester.pump();
      }
      expect(resolver.resolveCalls, 1);

      // A real track change requests exactly once more.
      setState(() {
        t = track(id: 'b', album: 'Album B', title: 'Song B');
      });
      await tester.pump();
      expect(resolver.resolveCalls, 2);
      expect(resolver.requests.last.albumKey, 'artist a|album b');
    });

    testWidgets('an unchanged result does not rebuild the image', (tester) async {
      final resolver = FakeResolver()..bytes = onePixelPng;
      final t = track();
      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: t.contentId,
          file: File('unused.mp3'),
          resolver: resolver,
          track: t,
        ),
      ));
      await tester.pump();
      final first = tester.widget<Image>(find.byType(Image)).image;

      // The resolver hands back the SAME instance on a cache hit; the
      // widget must not build a new ImageProvider (which would miss
      // Flutter's image cache and re-decode).
      resolver.invalidate(t.album.toLowerCase());
      await tester.pump();
      resolver.invalidate('artist a|album a');
      await tester.pump();
      await tester.pump();

      expect(identical(tester.widget<Image>(find.byType(Image)).image, first),
          isTrue);
    });
  });

  group('resolver notifications', () {
    testWidgets('an applied pick re-resolves the visible art', (tester) async {
      final resolver = FakeResolver();
      final t = track();
      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: t.contentId,
          file: File('unused.mp3'),
          resolver: resolver,
          track: t,
        ),
      ));
      await tester.pump();
      expect(resolver.resolveCalls, 1);
      expect(find.byIcon(Icons.album), findsOneWidget);

      resolver.bytes = onePixelPng;
      resolver.invalidate('artist a|album a');
      await tester.pump();
      await tester.pump();

      expect(resolver.resolveCalls, 2);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.album), findsNothing);
    });

    testWidgets('the listener is detached on dispose (no leak)', (tester) async {
      final resolver = FakeResolver();
      final t = track();
      await tester.pumpWidget(MaterialApp(
        home: AlbumArt(
          contentId: t.contentId,
          file: File('unused.mp3'),
          resolver: resolver,
          track: t,
        ),
      ));
      await tester.pump();
      expect(resolver.listenerAttached, isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      expect(resolver.listenerAttached, isFalse);
    });
  });

  group('surfaces forward the resolver', () {
    Future<PlayerService> pumpWithQueue(
      WidgetTester tester,
      Widget Function(PlayerService) build,
    ) async {
      final p = PlayerService();
      p.queueController.setQueue([track()], 0);
      await p.setVolume(1.0);
      await tester.pumpWidget(
        MaterialApp(theme: buildAppTheme(), home: build(p)),
      );
      await tester.pump();
      return p;
    }

    testWidgets('desktop NowPlayingBar', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resolver = FakeResolver();
      await pumpWithQueue(
        tester,
        (p) => Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox.shrink()),
              NowPlayingBar(player: p, artworkResolver: resolver),
            ],
          ),
        ),
      );

      final art = tester.widget<AlbumArt>(find.byType(AlbumArt));
      expect(identical(art.resolver, resolver), isTrue);
      expect(art.track?.contentId, 'a');
      expect(resolver.requests.single.albumKey, 'artist a|album a');
    });

    testWidgets('phone MiniPlayer', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resolver = FakeResolver();
      await pumpWithQueue(
        tester,
        (p) => Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar:
              MiniPlayer(player: p, artworkResolver: resolver),
        ),
      );

      final art = tester.widget<AlbumArt>(find.byType(AlbumArt));
      expect(identical(art.resolver, resolver), isTrue);
      expect(art.track?.contentId, 'a');
    });

    testWidgets('phone NowPlayingPage', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resolver = FakeResolver();
      await pumpWithQueue(
        tester,
        (p) => NowPlayingPage(player: p, artworkResolver: resolver),
      );

      final art = tester.widget<AlbumArt>(find.byType(AlbumArt));
      expect(identical(art.resolver, resolver), isTrue);
      expect(art.track?.contentId, 'a');
    });

    testWidgets('MiniPlayer hands the resolver on to the page it pushes',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resolver = FakeResolver();
      await pumpWithQueue(
        tester,
        (p) => Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar:
              MiniPlayer(player: p, artworkResolver: resolver),
        ),
      );

      await tester.tap(find.byKey(const Key('mini-player-bar')));
      await tester.pumpAndSettle();

      final page = tester.widget<NowPlayingPage>(find.byType(NowPlayingPage));
      expect(identical(page.artworkResolver, resolver), isTrue);
    });
  });
}
