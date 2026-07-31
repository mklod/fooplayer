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
import 'dart:io';
import 'package:fooplayer_app/artwork/artwork_resolver.dart';
import 'package:fooplayer_app/artwork/artwork_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/artwork/artwork_picker.dart';
import 'package:fooplayer_app/artwork/picker_seams.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/library_roots_prefs.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/now_playing_bar.dart';
import 'package:fooplayer_app/ui/home_screen.dart';
import 'package:fooplayer_app/ui/layout_prefs.dart';
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
    // Deliberately a different artist AND album from the other two -- this
    // is the point of the multi-select tests below: a pick reaches this
    // track because it was SELECTED, never because it happens to share an
    // album tag with whatever was right-clicked.
    artworkFixtureTrack(
      contentId: 't3',
      title: 'Warm Memories',
      artist: 'Mr Suicide Sheep',
      album: 'Sheepy Mixes',
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
            store: PlaylistStore(library: library, device: 'test'),
            artwork: artwork,
          ),
          child: const Text('open sheet'),
        ),
      ),
    ),
  ),
);

/// The real desktop shell, as `main.dart` builds it. This is the link the
/// merge had to close: A3 shipped `TrackListView(artwork:)` but nothing
/// passed anything to it, so the menu item was unreachable in a real build.
Future<void> pumpHomeScreen(
  WidgetTester tester, {
  required LibraryModel library,
  ArtworkServices? artwork,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: HomeScreen(
      library: library,
      player: PlayerService(),
      layoutPrefs: LayoutPrefs(),
      libraryRootsPrefs: LibraryRootsPrefs(roots: [], writer: (_) {}),
      artworkServices: artwork,
    ),
  ),
);

void main() {
  group('MERGE: HomeScreen forwards the artwork services', () {
    testWidgets('no services -> the shell offers no "Album artwork..." item', (
      tester,
    ) async {
      await pumpHomeScreen(tester, library: fixtureLibrary());
      await tester.tap(
        find.text('Time Is Running Out'),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('View in folder'), findsOneWidget);
      expect(find.text('Album artwork...'), findsNothing);
    });

    testWidgets('services reach the track list, so the picker is reachable '
        'from the real shell', (tester) async {
      final search = FakeArtworkSearch([
        [itunesCandidate],
      ]);
      await pumpHomeScreen(
        tester,
        library: fixtureLibrary(),
        artwork: fakeArtworkServices(search: search, store: FakeArtworkStore()),
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
      expect(search.calls, 1);
    });
  });

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

  group(
    'desktop: multi-select -- "adding art to one track adds art to that '
    'one track; select several and it applies to the selection" '
    '(2026-07-29)',
    () {
      // A plain click, pumped past the double-tap disambiguation window so
      // onTap actually resolves -- same technique
      // track_list_multiselect_test.dart uses.
      Future<void> plainClick(WidgetTester tester, Finder finder) async {
        await tester.tap(finder);
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      }

      // Ctrl must stay held through that same wait -- released before the
      // pump that lets onTap fire would make HardwareKeyboard see it up by
      // the time the row's onSelect callback runs, silently degrading this
      // into a plain click (same gotcha track_list_multiselect_test.dart
      // documents on its own ctrlClick).
      Future<void> ctrlClick(WidgetTester tester, Finder finder) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(finder);
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }

      testWidgets(
        'the menu item names the count for a multi-selection',
        (tester) async {
          await pumpTrackList(
            tester,
            library: fixtureLibrary(),
            artwork: fakeArtworkServices(
              search: FakeArtworkSearch(const [[]]),
              store: FakeArtworkStore(),
            ),
          );

          await plainClick(tester, find.text('Time Is Running Out'));
          await ctrlClick(tester, find.text('Hysteria'));
          await ctrlClick(tester, find.text('Warm Memories'));

          await tester.tap(
            find.text('Warm Memories'),
            buttons: kSecondaryButton,
          );
          await tester.pumpAndSettle();

          expect(find.text('Album artwork... (3 tracks)'), findsOneWidget);
          expect(find.text('Album artwork...'), findsNothing);
        },
      );

      testWidgets(
        'picking a candidate applies it to every selected track -- even '
        'though they share NO album tag, and even the one right-clicked '
        'is not the first one selected',
        (tester) async {
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

          await plainClick(tester, find.text('Time Is Running Out'));
          await ctrlClick(tester, find.text('Hysteria'));
          await ctrlClick(tester, find.text('Warm Memories'));
          expect(library.selectedTrackIds, {'t1', 't2', 't3'});

          // Right-click the MIDDLE of the selection, not the first row --
          // the search is anchored on whichever row was clicked, but the
          // pick still has to land on all three.
          await tester.tap(find.text('Hysteria'), buttons: kSecondaryButton);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Album artwork... (3 tracks)'));
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('artwork-picker-selection-count')),
            findsOneWidget,
          );
          expect(find.text('Applies to 3 selected tracks'), findsOneWidget);

          await tester.tap(find.byKey(const Key('artwork-candidate-0')));
          await tester.pumpAndSettle();

          expect(
            store.appliedTracks.map((t) => t.contentId).toSet(),
            {'t1', 't2', 't3'},
            reason: 'every selected track got its own write, not one '
                'shared write the others silently inherited',
          );
          expect(
            store.appliedChoices.every((c) => c.url == itunesCandidate.url),
            isTrue,
            reason: 'the same picked image for all three',
          );
          expect(find.byKey(const Key('artwork-picker-dialog')), findsNothing);
        },
      );

      testWidgets(
        'Remove artwork on a multi-selection removes it from every '
        'selected track',
        (tester) async {
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

          await plainClick(tester, find.text('Time Is Running Out'));
          await ctrlClick(tester, find.text('Hysteria'));
          await ctrlClick(tester, find.text('Warm Memories'));

          await tester.tap(
            find.text('Time Is Running Out'),
            buttons: kSecondaryButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Album artwork... (3 tracks)'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('artwork-remove')));
          await tester.pumpAndSettle();

          expect(
            store.removedTracks.map((t) => t.contentId).toSet(),
            {'t1', 't2', 't3'},
          );
        },
      );

      testWidgets(
        'a single-track selection is unaffected: the menu says "Album '
        'artwork..." with no count, and only that one track is written to',
        (tester) async {
          final search = FakeArtworkSearch([
            [itunesCandidate],
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

          expect(
            find.byKey(const Key('artwork-picker-selection-count')),
            findsNothing,
          );

          await tester.tap(find.byKey(const Key('artwork-candidate-0')));
          await tester.pumpAndSettle();

          expect(store.appliedTracks, hasLength(1));
          expect(store.appliedTracks.single.contentId, 't1');
        },
      );
    },
  );

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

  group('desktop: the now-playing hero cover', () {
    testWidgets('tapping the cover opens the picker for the playing track', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final search = FakeArtworkSearch([[]]);
      final player = PlayerService();
      player.queueController.setQueue(fixtureLibrary().allTracks, 0);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: NowPlayingBar(
              player: player,
              artwork: fakeArtworkServices(
                search: search,
                store: FakeArtworkStore(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('now-playing-art-tap')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('artwork-picker-dialog')), findsOneWidget);
      expect(search.calls, 1, reason: 'the picker searched for THIS track');
    });

    testWidgets('with no artwork services the cover is inert', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final player = PlayerService();
      player.queueController.setQueue(fixtureLibrary().allTracks, 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: NowPlayingBar(player: player)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('now-playing-art-tap')), findsNothing);
    });
  });

  group('the picker hero', () {
    testWidgets('shows the cover currently in force, so you can see what you '
        'are replacing', (tester) async {
      // A resolver that hands back a real (1x1) PNG, so Image.memory decodes.
      final resolver = _HeroResolver(onePixelPng);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ArtworkPicker(
              track: artworkFixtureTrack(),
              albumKey: 'muse|absolution',
              albumLabel: 'Muse — Absolution',
              query: const ArtworkQuery(artist: 'Muse', album: 'Absolution'),
              services: fakeArtworkServices(
                search: FakeArtworkSearch([[]]),
                store: FakeArtworkStore(),
              ),
              resolver: resolver,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('artwork-picker-hero')), findsOneWidget);
    });

    testWidgets('without a resolver there is simply no hero', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ArtworkPicker(
              track: artworkFixtureTrack(),
              albumKey: 'muse|absolution',
              albumLabel: 'Muse — Absolution',
              query: const ArtworkQuery(artist: 'Muse', album: 'Absolution'),
              services: fakeArtworkServices(
                search: FakeArtworkSearch([[]]),
                store: FakeArtworkStore(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('artwork-picker-hero')), findsNothing);
      expect(find.byKey(const Key('artwork-picker-title')), findsOneWidget);
    });
  });
}

/// Minimal [ArtworkResolver] that always resolves to the same bytes.
class _HeroResolver extends ArtworkResolver {
  final Uint8List _bytes;
  _HeroResolver(this._bytes)
    : super(stores: ArtworkStoreRegistry(appDataDir: Directory.systemTemp));

  @override
  Future<List<int>?> resolve(ArtworkRequest req) async => _bytes;
}
