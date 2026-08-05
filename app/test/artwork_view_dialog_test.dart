// Right-click full-res artwork viewer (ui/artwork_view_dialog.dart) and its
// entry point: right-clicking the sidebar's corner art preview
// (home_screen.dart's _SelectedArtPreview). The dialog is read-only -- the
// LEFT click keeps opening the picker; this covers that the right click
// resolves through the same ArtworkResolver chain, shows the pixels with a
// WxH caption, and silently declines when there is no artwork to show.
//
// Last modified: 2026-08-04--1712
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/artwork_view_dialog.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';

/// A canonical 1x1 transparent PNG -- small, valid, decodes to 1x1.
const List<int> kTinyPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

class FakeResolver extends ArtworkResolver {
  FakeResolver()
    : super(stores: ArtworkStoreRegistry(appDataDir: Directory('.')));

  List<int>? bytes;

  @override
  Future<List<int>?> resolve(ArtworkRequest req) async => bytes;
}

Track fixtureTrack() => Track(
  contentId: 'a',
  relPath: 'a.mp3',
  rootPath: r'L:\Music',
  dateAdded: DateTime.utc(2026, 7, 1),
  title: 'Song A',
  artist: 'Artist A',
  album: 'Album A',
);

/// Lets the dialog's real-async work (resolver, image decode) actually run
/// under the widget test's otherwise-fake clock.
Future<void> settleRealAsync(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the artwork with a WxH caption; Close dismisses', (
    tester,
  ) async {
    final resolver = FakeResolver()..bytes = kTinyPng;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    final open = showFullResArtworkDialog(
      ctx,
      track: fixtureTrack(),
      resolver: resolver,
    );
    await settleRealAsync(tester);

    expect(find.byKey(const Key('artwork-view-dialog')), findsOneWidget);
    expect(find.text('Album A — 1×1 px'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('artwork-view-dialog')), findsNothing);
    await open; // resolves once the dialog is dismissed
  });

  testWidgets('no artwork -> no dialog, no error', (tester) async {
    final resolver = FakeResolver(); // bytes stays null
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    await tester.runAsync(
      () => showFullResArtworkDialog(
        ctx,
        track: fixtureTrack(),
        resolver: resolver,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('artwork-view-dialog')), findsNothing);
  });

  testWidgets(
    'right-clicking the sidebar corner preview opens the viewer',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final lib = LibraryModel();
      lib.allTracks = [fixtureTrack()];
      lib.status = 'ready';
      lib.selectTrack('a'); // selection + nothing playing -> preview shows

      final resolver = FakeResolver()..bytes = kTinyPng;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: HomeScreen(
            library: lib,
            player: PlayerService(),
            layoutPrefs: LayoutPrefs(),
            libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
            playlistStore: PlaylistStore(library: lib, device: 'test'),
            artworkResolver: resolver,
          ),
        ),
      );
      await settleRealAsync(tester);

      final preview = find.byKey(const Key('sidebar-art-preview-tap'));
      expect(preview, findsOneWidget);

      await tester.tap(preview, buttons: kSecondaryButton);
      await settleRealAsync(tester);

      expect(find.byKey(const Key('artwork-view-dialog')), findsOneWidget);
      expect(find.text('Album A — 1×1 px'), findsOneWidget);
    },
  );
}
