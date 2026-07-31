// Standard Explorer/foobar multi-select in the desktop track list (see
// ui/track_list.dart's per-row onSelect and model/library_model.dart's
// selectTrackClick): plain click replaces the selection, Ctrl+click toggles
// a row in/out, Shift+click ranges from the anchor, Ctrl+Shift+click adds
// that range to the existing selection, Ctrl+A selects everything visible,
// and the row context menu's playlist actions act on the whole selection
// when the right-clicked row is part of it (Explorer-style: right-clicking
// an unselected row selects just it first). Double-click still plays and
// selects only the clicked row regardless of any wider selection.
//
// Model-level click-combination coverage (plain/ctrl/shift/ctrl+shift on a
// synthetic visible order, selectAll, selection-clearing cascade points)
// lives in library_model_selection_test.dart; this file exercises the same
// semantics end-to-end through real taps/key events plus the UI-only pieces
// (highlight rendering, focus wiring, context-menu labelling and batch
// store calls).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/playlist_store.dart';
import 'package:fooplayer_app/model/track.dart';
import 'package:fooplayer_app/player/player_service.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/track_list.dart';

/// Records batch calls (never the singular per-track ones) so tests can
/// assert a whole multi-select action writes the manifest exactly once.
class SpyPlaylistStore extends PlaylistStore {
  SpyPlaylistStore(LibraryModel library)
    : super(library: library, device: 'test');

  final created = <String>[];
  final addTracksCalls = <(String, List<String>)>[];
  final removeTracksCalls = <(String, List<String>)>[];

  @override
  Future<void> createPlaylist(String name) async => created.add(name.trim());

  @override
  Future<int> addTracks(String name, List<String> contentIds) async {
    addTracksCalls.add((name, List<String>.of(contentIds)));
    return contentIds.length;
  }

  @override
  Future<int> removeTracks(String name, List<String> contentIds) async {
    removeTracksCalls.add((name, List<String>.of(contentIds)));
    return contentIds.length;
  }
}

/// Five tracks, dateAdded ascending t1..t5 -- with the default library sort
/// (dateAdded descending) the visible top-to-bottom order is Song E, Song D,
/// Song C, Song B, Song A. Also carries a 'mix' playlist (all five tracks,
/// in id order) for the playlist-view multi-remove test.
LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    for (var i = 1; i <= 5; i++)
      Track(
        contentId: 't$i',
        relPath: 't$i.mp3',
        dateAdded: DateTime.utc(2024, 1, i),
        title:
            'Song ${String.fromCharCode(64 + i)}', // t1->Song A .. t5->Song E
      ),
  ];
  m.playlists = [
    const ManifestPlaylist(
      name: 'mix',
      trackIds: ['t1', 't2', 't3', 't4', 't5'],
    ),
  ];
  m.status = 'ready';
  return m;
}

Future<void> pumpTrackList(
  WidgetTester tester,
  LibraryModel lib,
  PlayerService player, {
  void Function(List<Track>, int)? onPlayTrack,
  void Function(Track)? launchExplorer,
  PlaylistStore? playlistStore,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: TrackListView(
        library: lib,
        player: player,
        onPlayTrack: onPlayTrack,
        launchExplorer: launchExplorer ?? (_) {},
        playlistStore: playlistStore,
      ),
    ),
  ),
);

/// A plain click, pumped past the double-tap disambiguation window so
/// onTap actually resolves (same technique as track_list_interaction_test).
Future<void> plainClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
}

/// Holds a modifier key down for the duration of a click -- mirrors
/// filter_panel_test.dart's ctrlClick, but (unlike FilterPanel's onTap,
/// which resolves the instant the tap completes) a track row's onTap is
/// deferred until [kDoubleTapTimeout] elapses, since the same InkWell also
/// registers onDoubleTap and Flutter's gesture arena needs that whole
/// window to rule out a second tap. The modifier must stay held through
/// that wait -- released right after the synthetic tap (before the pump
/// that lets onTap actually fire) would make [HardwareKeyboard.instance]
/// see it up by the time the row's onSelect callback runs, silently
/// degrading every Ctrl/Shift click into a plain one.
Future<void> _modifiedClick(
  WidgetTester tester,
  Finder finder,
  List<LogicalKeyboardKey> modifiers,
) async {
  for (final k in modifiers) {
    await tester.sendKeyDownEvent(k);
  }
  await tester.tap(finder);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
  for (final k in modifiers.reversed) {
    await tester.sendKeyUpEvent(k);
  }
}

Future<void> ctrlClick(WidgetTester tester, Finder finder) =>
    _modifiedClick(tester, finder, [LogicalKeyboardKey.controlLeft]);

Future<void> shiftClick(WidgetTester tester, Finder finder) =>
    _modifiedClick(tester, finder, [LogicalKeyboardKey.shiftLeft]);

Future<void> ctrlShiftClick(WidgetTester tester, Finder finder) =>
    _modifiedClick(tester, finder, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ]);

/// Same double-click simulation as track_list_interaction_test.dart.
Future<void> doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
}

Color? _rowFillColor(WidgetTester tester, String title) {
  final container = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.text(title),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  group('click/Ctrl/Shift selection semantics', () {
    testWidgets('plain click selects only that row', (tester) async {
      final lib = fixtureLibrary();
      await pumpTrackList(tester, lib, PlayerService());

      await plainClick(tester, find.text('Song D'));
      expect(lib.selectedTrackIds, {'t4'});

      await plainClick(tester, find.text('Song B'));
      expect(lib.selectedTrackIds, {'t2'});
    });

    testWidgets('ctrl+click toggles a row into/out of the selection without '
        'clearing the rest', (tester) async {
      final lib = fixtureLibrary();
      await pumpTrackList(tester, lib, PlayerService());

      await plainClick(tester, find.text('Song D'));
      await ctrlClick(tester, find.text('Song B'));
      expect(lib.selectedTrackIds, {'t4', 't2'});
      expect(_rowFillColor(tester, 'Song D'), AppColors.selectionFill);
      expect(_rowFillColor(tester, 'Song B'), AppColors.selectionFill);
      expect(_rowFillColor(tester, 'Song C'), isNot(AppColors.selectionFill));

      await ctrlClick(tester, find.text('Song D'));
      expect(lib.selectedTrackIds, {'t2'});
    });

    testWidgets(
      'shift+click selects the contiguous visible range from the anchor, '
      'replacing the selection',
      (tester) async {
        final lib = fixtureLibrary();
        await pumpTrackList(tester, lib, PlayerService());

        await plainClick(tester, find.text('Song D')); // anchor t4
        await shiftClick(tester, find.text('Song B'));
        expect(lib.selectedTrackIds, {'t4', 't3', 't2'});

        expect(_rowFillColor(tester, 'Song D'), AppColors.selectionFill);
        expect(_rowFillColor(tester, 'Song C'), AppColors.selectionFill);
        expect(_rowFillColor(tester, 'Song B'), AppColors.selectionFill);
        expect(_rowFillColor(tester, 'Song A'), isNot(AppColors.selectionFill));
        expect(_rowFillColor(tester, 'Song E'), isNot(AppColors.selectionFill));
      },
    );

    testWidgets(
      'ctrl+shift+click adds the anchor range to the existing selection '
      'instead of replacing it',
      (tester) async {
        final lib = fixtureLibrary();
        await pumpTrackList(tester, lib, PlayerService());

        await plainClick(tester, find.text('Song E')); // anchor t5
        await ctrlClick(tester, find.text('Song A')); // {t5,t1}, anchor t1
        await ctrlShiftClick(tester, find.text('Song C')); // + range t1..t3

        expect(lib.selectedTrackIds, {'t5', 't1', 't2', 't3'});
      },
    );

    testWidgets(
      'double-click plays and selects only the clicked row, collapsing '
      'any wider selection',
      (tester) async {
        final lib = fixtureLibrary();
        final player = PlayerService();
        final playedTracks = <Track>[];
        var playedIndex = -1;
        await pumpTrackList(
          tester,
          lib,
          player,
          onPlayTrack: (tracks, index) {
            playedTracks
              ..clear()
              ..addAll(tracks);
            playedIndex = index;
          },
        );

        await plainClick(tester, find.text('Song E'));
        await ctrlClick(tester, find.text('Song C'));
        expect(lib.selectedTrackIds, {'t5', 't3'});

        await doubleTap(tester, find.text('Song A'));

        expect(lib.selectedTrackIds, {'t1'});
        expect(playedTracks[playedIndex].contentId, 't1');
      },
    );
  });

  group('selection persistence and clearing', () {
    testWidgets('selection survives an unrelated rebuild', (tester) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      await pumpTrackList(tester, lib, player);

      await plainClick(tester, find.text('Song D'));
      await ctrlClick(tester, find.text('Song B'));
      expect(lib.selectedTrackIds, {'t4', 't2'});

      // Trigger a rebuild that has nothing to do with selection -- setVolume
      // notifies without ever constructing the real (native-backed) Player,
      // same technique as track_list_header_test.dart.
      await player.setVolume(0.5);
      await tester.pump();

      expect(lib.selectedTrackIds, {'t4', 't2'});
      expect(_rowFillColor(tester, 'Song D'), AppColors.selectionFill);
      expect(_rowFillColor(tester, 'Song B'), AppColors.selectionFill);
    });

    testWidgets('selection clears when the search filter changes', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      final player = PlayerService();
      await pumpTrackList(tester, lib, player);

      await plainClick(tester, find.text('Song D'));
      await ctrlClick(tester, find.text('Song B'));
      expect(lib.selectedTrackIds, {'t4', 't2'});

      lib.setSearch('Song');
      await tester.pump();

      expect(lib.selectedTrackIds, isEmpty);
      expect(_rowFillColor(tester, 'Song D'), isNot(AppColors.selectionFill));
    });
  });

  group('Ctrl+A', () {
    testWidgets('selects every visible track once the list has focus', (
      tester,
    ) async {
      final lib = fixtureLibrary();
      await pumpTrackList(tester, lib, PlayerService());

      // A click grabs focus for the list (see TrackListView's Listener) the
      // same way a real user would before pressing Ctrl+A.
      await plainClick(tester, find.text('Song D'));
      expect(lib.selectedTrackIds, {'t4'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(lib.selectedTrackIds, {'t1', 't2', 't3', 't4', 't5'});
    });
  });

  group('right-click context menu acts on the selection', () {
    testWidgets(
      'right-click on a row that is part of a 3-track selection adds all '
      '3 to the chosen playlist in one write',
      (tester) async {
        final lib = fixtureLibrary();
        final spy = SpyPlaylistStore(lib);
        await pumpTrackList(tester, lib, PlayerService(), playlistStore: spy);

        await plainClick(tester, find.text('Song E'));
        await ctrlClick(tester, find.text('Song C'));
        await ctrlClick(tester, find.text('Song A'));
        expect(lib.selectedTrackIds, {'t5', 't3', 't1'});

        await tester.tap(find.text('Song C'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(
          lib.selectedTrackIds,
          {'t5', 't3', 't1'},
          reason:
              'right-click on an already-selected row must not change '
              'the selection',
        );
        // Selection is 3 -- the single-target items are labelled unambiguous.
        expect(find.text('View in folder (this track)'), findsOneWidget);

        await tester.tap(find.text('Add to playlist ▸'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New playlist...'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('playlist-name-field')),
          'trio',
        );
        await tester.tap(find.byKey(const Key('playlist-name-create')));
        await tester.pumpAndSettle();

        expect(spy.created, ['trio']);
        expect(
          spy.addTracksCalls.length,
          1,
          reason: 'one manifest write for the whole batch, not one per track',
        );
        expect(spy.addTracksCalls.single.$1, 'trio');
        expect(spy.addTracksCalls.single.$2.toSet(), {'t5', 't3', 't1'});
        expect(find.text('Added 3 tracks to "trio"'), findsOneWidget);
      },
    );

    testWidgets('right-click on a row NOT in the current selection replaces the '
        'selection with just that row before acting', (tester) async {
      final lib = fixtureLibrary();
      final spy = SpyPlaylistStore(lib);
      final launched = <Track>[];
      await pumpTrackList(
        tester,
        lib,
        PlayerService(),
        playlistStore: spy,
        launchExplorer: (t) => launched.add(t),
      );

      await plainClick(tester, find.text('Song E'));
      await ctrlClick(tester, find.text('Song C'));
      expect(lib.selectedTrackIds, {'t5', 't3'});

      await tester.tap(find.text('Song A'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        lib.selectedTrackIds,
        {'t1'},
        reason:
            'Explorer-style: right-click on an unselected row selects '
            'just it first',
      );
      // Single-track selection now -- no "(this track)" disambiguation needed.
      expect(find.text('View in folder'), findsOneWidget);
      expect(find.text('View in folder (this track)'), findsNothing);

      await tester.tap(find.text('View in folder'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1));
      expect(launched.single.contentId, 't1');
    });

    testWidgets(
      'playlist view: "Remove from playlist" on a multi-selection removes '
      'all of them in one write',
      (tester) async {
        final lib = fixtureLibrary();
        lib.setPlaylist('mix'); // enter playlist view before selecting anything
        final spy = SpyPlaylistStore(lib);
        await pumpTrackList(tester, lib, PlayerService(), playlistStore: spy);

        await plainClick(tester, find.text('Song A'));
        await ctrlClick(tester, find.text('Song E'));
        expect(lib.selectedTrackIds, {'t1', 't5'});

        await tester.tap(find.text('Song A'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Remove from playlist'), findsOneWidget);

        await tester.tap(find.text('Remove from playlist'));
        await tester.pumpAndSettle();

        expect(spy.removeTracksCalls.length, 1);
        expect(spy.removeTracksCalls.single.$1, 'mix');
        expect(spy.removeTracksCalls.single.$2.toSet(), {'t1', 't5'});
        expect(find.text('Removed 2 tracks from the playlist'), findsOneWidget);
      },
    );
  });
}
