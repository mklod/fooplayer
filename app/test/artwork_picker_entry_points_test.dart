// Plan 4 (Album Artwork Lookup) task A3 -- the two entry points that open
// the shared picker:
//
//   * desktop: the track row's right-click menu item "Album artwork..."
//     -> [showArtworkPickerDialog];
//   * phone:   the long-press sheet item "Album artwork"
//     -> [ArtworkPickerPage] pushed full screen.
//
// Both are gated on injected [ArtworkServices]: null (the default) hides
// the entry entirely, so a build without A1/A2 wired never offers a dead
// affordance. Everything below runs on fakes -- no network, no native file
// dialog, no disk (see test/support/artwork_fakes.dart).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/picker_seams.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/phone/track_context_sheet.dart';
import 'package:fooplayer_app/ui/track_list.dart';

import 'support/artwork_fakes.dart';

LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    artworkFixtureTrack(),
    artworkFixtureTrack(
      contentId: 't2',
      title: 'Hysteria',
      artist: 'Muse',
      album: 'Absolution (Deluxe Edition)',
    ),
  ];
  m.status = 'ready';
  return m;
}

/// Desktop host: the real [TrackListView] with playback stubbed out (the
/// media_kit Player must never be constructed in a widget test).
Future<void> pumpTrackList(
  WidgetTester tester, {
  required LibraryModel library,
  ArtworkServices? artwork,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: TrackListView(
        library: library,
        player: PlayerService(),
        onPlayTrack: (_, _) {},
        launchExplorer: (_) {},
        artwork: artwork,
      ),
    ),
  ),
);

/// Phone host: a button that opens the real long-press sheet for [track],
/// exactly as `main.dart` / the phone views close over it.
Future<void> pumpSheetHost(
  WidgetTester tester, {
  required LibraryModel library,
  required Track track,
  ArtworkServices? artwork,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showTrackContextSheet(
            context,
            track: track,
            library: library,
            store: PlaylistStore(library: library),
            artwork: artwork,
          ),
          child: const Text('open sheet'),
        ),
      ),
    ),
  ),
);

void main() {
  group('desktop: track context menu', () {
    testWidgets('no artwork services -> no "Album artwork..." item', (
      tester,
    ) async {
      await pumpTrackList(tester, library: fixtureLibrary());

      await tester.tap(
        find.text('Time Is Running Out'),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('View in folder'), findsOneWidget); // menu is open
      expect(find.text('Album artwork...'), findsNothing);
    });

    testWidgets('with services the item appears and opens the picker dialog', (
      tester,
    ) async {
      final search = FakeArtworkSearch([
        [itunesCandidate, deezerCandidate],
      ]);
      final store = FakeArtworkStore();
      await pumpTrackList(
        tester,
        library: fixtureLibrary(),
        artwork: fakeArtworkServices(search: search, store: store),
      );

      await tester.tap(
        find.text('Time Is Running Out'),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Album artwork...'), findsOneWidget);

      await tester.tap(find.text('Album artwork...'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('artwork-picker-dialog')), findsOneWidget);
      expect(find.byKey(const Key('artwork-picker')), findsOneWidget);
      // The dialog opened on THIS track's album, and searched for it.
      expect(find.byKey(const Key('artwork-picker-title')), findsOneWidget);
      expect(find.text('Muse — Absolution'), findsOneWidget);
      expect(search.queries.single.artist, 'Muse');
      expect(search.queries.single.album, 'Absolution');
    });

    testWidgets('picking a candidate from the dialog stores it under the '
        "track's album key and closes", (tester) async {
      final search = FakeArtworkSearch([
        [itunesCandidate],
      ]);
      final store = FakeArtworkStore();
      final library = fixtureLibrary();
      await pumpTrackList(
        tester,
        library: library,
        artwork: fakeArtworkServices(search: search, store: store),
      );

      // Second row: album tagged "Absolution (Deluxe Edition)" -- the key
      // must be the normalized album, shared with the plain-edition track.
      await tester.tap(find.text('Hysteria'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Album artwork...'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('artwork-candidate-0')));
      await tester.pumpAndSettle();

      expect(store.appliedKeys, ['muse|absolution']);
      expect(store.appliedChoices.single.url, itunesCandidate.url);
      expect(find.byKey(const Key('artwork-picker-dialog')), findsNothing);
    });

    testWidgets('Remove artwork from the dialog clears the album key', (
      tester,
    ) async {
      final search = FakeArtworkSearch([
        [itunesCandidate],
      ]);
      final store = FakeArtworkStore();
      await pumpTrackList(
        tester,
        library: fixtureLibrary(),
        artwork: fakeArtworkServices(
          search: search,
          store: store,
          currentSelectionId: (_, _) => itunesCandidate.url,
        ),
      );

      await tester.tap(
        find.text('Time Is Running Out'),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Album artwork...'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('artwork-remove')));
      await tester.pumpAndSettle();

      expect(store.removedKeys, ['muse|absolution']);
      expect(store.appliedKeys, isEmpty);
      expect(find.byKey(const Key('artwork-picker-dialog')), findsNothing);
    });
  });

  group('phone: long-press sheet', () {
    testWidgets('no artwork services -> no "Album artwork" sheet item', (
      tester,
    ) async {
      final library = fixtureLibrary();
      await pumpSheetHost(
        tester,
        library: library,
        track: artworkFixtureTrack(),
      );
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sheet-view-details')), findsOneWidget);
      expect(find.byKey(const Key('sheet-album-artwork')), findsNothing);
    });

    testWidgets('with services the sheet item opens the full-screen picker', (
      tester,
    ) async {
      final search = FakeArtworkSearch([
        [itunesCandidate, deezerCandidate],
      ]);
      final store = FakeArtworkStore();
      final library = fixtureLibrary();
      await pumpSheetHost(
        tester,
        library: library,
        track: artworkFixtureTrack(),
        artwork: fakeArtworkServices(search: search, store: store),
      );

      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-album-artwork')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sheet-album-artwork')));
      await tester.pumpAndSettle();

      // Full-screen page (not a dialog), hosting the same shared picker.
      expect(find.byKey(const Key('artwork-picker-page')), findsOneWidget);
      expect(find.byKey(const Key('artwork-picker-dialog')), findsNothing);
      expect(find.byKey(const Key('artwork-picker')), findsOneWidget);
      expect(find.text('Album artwork'), findsOneWidget); // app bar title
      expect(find.byKey(const Key('artwork-candidate-0')), findsOneWidget);
      expect(find.byKey(const Key('artwork-candidate-1')), findsOneWidget);
    });

    testWidgets('picking on the phone stores under the album key and pops '
        'back', (tester) async {
      final search = FakeArtworkSearch([
        [itunesCandidate],
      ]);
      final store = FakeArtworkStore();
      final library = fixtureLibrary();
      await pumpSheetHost(
        tester,
        library: library,
        track: artworkFixtureTrack(
          title: 'Hysteria',
          album: 'Absolution [Explicit]',
        ),
        artwork: fakeArtworkServices(search: search, store: store),
      );

      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-album-artwork')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('artwork-candidate-0')));
      await tester.pumpAndSettle();

      expect(store.appliedKeys, ['muse|absolution']);
      expect(find.byKey(const Key('artwork-picker-page')), findsNothing);
      expect(find.text('open sheet'), findsOneWidget); // back on the host
    });

    testWidgets('the phone picker offers the same manual paths as desktop', (
      tester,
    ) async {
      final search = FakeArtworkSearch([<PickerCandidate>[]]);
      final store = FakeArtworkStore();
      await pumpSheetHost(
        tester,
        library: fixtureLibrary(),
        track: artworkFixtureTrack(),
        artwork: fakeArtworkServices(
          search: search,
          store: store,
          pickFile: () async => r'D:\covers\phone.jpg',
        ),
      );

      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-album-artwork')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('artwork-picker-empty')), findsOneWidget);
      expect(find.byKey(const Key('artwork-paste-url')), findsOneWidget);
      expect(find.byKey(const Key('artwork-search-again')), findsOneWidget);
      expect(find.byKey(const Key('artwork-remove')), findsOneWidget);

      await tester.tap(find.byKey(const Key('artwork-choose-file')));
      await tester.pumpAndSettle();

      expect(store.appliedChoices.single.source, ArtworkSource.local);
      expect(store.appliedChoices.single.localPath, r'D:\covers\phone.jpg');
      expect(find.byKey(const Key('artwork-picker-page')), findsNothing);
    });
  });
}
