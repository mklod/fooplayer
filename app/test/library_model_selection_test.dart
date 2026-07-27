// Track-list multi-select semantics (see model/library_model.dart's
// selectTrackClick/selectTrack/selectAll): standard Explorer/foobar click
// behavior --
//   - plain click: selects only the clicked row, replacing the selection.
//   - Ctrl+click: toggles the row in/out of the existing selection, moving
//     the range anchor to it.
//   - Shift+click: replaces the selection with the contiguous range from the
//     anchor to the clicked row in the currently visible order.
//   - Ctrl+Shift+click: adds that range to the existing selection instead of
//     replacing it.
// Plus the selection-clearing cascade: a selection made against one visible
// set must not linger once search/artist/album/playlist/folder filters
// change it materially.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';

/// Five tracks, dateAdded ascending t1..t5 -- with the default sort
/// (dateAdded descending) [LibraryModel.visibleTracks] orders them
/// t5,t4,t3,t2,t1. Tests always read the order back via `m.visibleTracks`
/// rather than hard-coding it, so they stay correct even if the default
/// sort ever changes.
LibraryModel fixtureLibrary() {
  final m = LibraryModel();
  m.allTracks = [
    for (var i = 1; i <= 5; i++)
      Track(
        contentId: 't$i',
        relPath: 't$i.mp3',
        dateAdded: DateTime.utc(2024, 1, i),
        title: 'Track $i',
      ),
  ];
  m.status = 'ready';
  return m;
}

void main() {
  group('LibraryModel.selectTrackClick', () {
    test('plain click selects only the clicked row, replacing any existing selection', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks;
      m.selectTrackClick('t4', ctrl: false, shift: false, visibleOrder: order);
      expect(m.selectedTrackIds, {'t4'});

      m.selectTrackClick('t2', ctrl: false, shift: false, visibleOrder: order);
      expect(m.selectedTrackIds, {'t2'},
          reason: 'plain click replaces, does not add');
    });

    test('ctrl+click toggles a row in/out of the selection and moves the anchor', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks;
      m.selectTrackClick('t4', ctrl: false, shift: false, visibleOrder: order);
      m.selectTrackClick('t2', ctrl: true, shift: false, visibleOrder: order);
      expect(m.selectedTrackIds, {'t4', 't2'});

      // Ctrl+click an already-selected row removes just that one.
      m.selectTrackClick('t4', ctrl: true, shift: false, visibleOrder: order);
      expect(m.selectedTrackIds, {'t2'});
    });

    test(
        'shift+click selects the contiguous range from the anchor to the '
        'clicked row in visible order, replacing the selection; the anchor '
        'itself does not move', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks; // t5,t4,t3,t2,t1
      m.selectTrackClick('t4', ctrl: false, shift: false, visibleOrder: order); // anchor=t4
      m.selectTrackClick('t2', ctrl: false, shift: true, visibleOrder: order);
      expect(m.selectedTrackIds, {'t4', 't3', 't2'});

      // Anchor unchanged: a further shift+click re-ranges from t4, not t2.
      m.selectTrackClick('t5', ctrl: false, shift: true, visibleOrder: order);
      expect(m.selectedTrackIds, {'t5', 't4'});
    });

    test('shift+click range works when the anchor sits after the clicked row too', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks;
      m.selectTrackClick('t2', ctrl: false, shift: false, visibleOrder: order); // anchor=t2
      m.selectTrackClick('t5', ctrl: false, shift: true, visibleOrder: order);
      expect(m.selectedTrackIds, {'t5', 't4', 't3', 't2'});
    });

    test(
        'ctrl+shift+click adds the anchor->clicked range to the existing '
        'selection instead of replacing it (Explorer "extend" behavior)', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks; // t5,t4,t3,t2,t1
      m.selectTrackClick('t1', ctrl: false, shift: false, visibleOrder: order); // anchor=t1, {t1}
      m.selectTrackClick('t5', ctrl: true, shift: false, visibleOrder: order); // anchor=t5, {t1,t5}
      m.selectTrackClick('t3', ctrl: true, shift: true, visibleOrder: order); // + range t5->t3
      expect(m.selectedTrackIds, {'t1', 't5', 't4', 't3'});
    });

    test('shift+click with no prior anchor falls back to a plain click', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks;
      m.selectTrackClick('t3', ctrl: false, shift: true, visibleOrder: order);
      expect(m.selectedTrackIds, {'t3'});
    });

    test('notifyListeners fires on a selection click', () {
      final m = fixtureLibrary();
      var notifications = 0;
      m.addListener(() => notifications++);
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      expect(notifications, 1);
    });
  });

  group('LibraryModel.selectTrack (single-select, used by double-click)', () {
    test('selects exactly one row, discarding a wider selection, and resets the anchor', () {
      final m = fixtureLibrary();
      final order = m.visibleTracks;
      m.selectTrackClick('t1', ctrl: false, shift: false, visibleOrder: order);
      m.selectTrackClick('t5', ctrl: true, shift: false, visibleOrder: order); // {t1,t5}

      m.selectTrack('t3');
      expect(m.selectedTrackIds, {'t3'});

      // Anchor reset to t3: a subsequent shift+click ranges from there.
      m.selectTrackClick('t1', ctrl: false, shift: true, visibleOrder: order);
      expect(m.selectedTrackIds, {'t3', 't2', 't1'});
    });

    test('selectTrack(null) clears the selection entirely', () {
      final m = fixtureLibrary();
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      m.selectTrack(null);
      expect(m.selectedTrackIds, isEmpty);
    });
  });

  group('LibraryModel.selectAll (Ctrl+A)', () {
    test('selects every currently visible track', () {
      final m = fixtureLibrary();
      m.selectAll();
      expect(m.selectedTrackIds, {'t1', 't2', 't3', 't4', 't5'});
    });

    test('is a no-op on an empty visible list', () {
      final m = LibraryModel();
      m.status = 'ready';
      m.selectAll();
      expect(m.selectedTrackIds, isEmpty);
    });
  });

  group('selection clears on the existing filter/search/playlist/folder cascade points', () {
    test('setSearch clears the selection', () {
      final m = fixtureLibrary();
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      expect(m.selectedTrackIds, isNotEmpty);

      m.setSearch('Track 1');
      expect(m.selectedTrackIds, isEmpty);
    });

    test('setArtists clears the selection', () {
      final m = fixtureLibrary();
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      m.setArtists({'anything'});
      expect(m.selectedTrackIds, isEmpty);
    });

    test('setAlbums clears the selection', () {
      final m = fixtureLibrary();
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      m.setAlbums({'anything'});
      expect(m.selectedTrackIds, isEmpty);
    });

    test('setPlaylist clears the selection', () {
      final m = fixtureLibrary();
      m.playlists = [const ManifestPlaylist(name: 'mix', trackIds: ['t1'])];
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      m.setPlaylist('mix');
      expect(m.selectedTrackIds, isEmpty);
    });

    test('drillIntoFolder (Folder-pane navigation) clears the selection', () {
      final m = LibraryModel();
      m.allTracks = [
        for (var i = 1; i <= 2; i++)
          Track(
            contentId: 't$i',
            relPath: 't$i.mp3',
            rootPath: 'root$i',
            dateAdded: DateTime.utc(2024, 1, i),
            title: 'Track $i',
          ),
      ];
      m.status = 'ready';
      m.selectTrackClick('t1',
          ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      expect(m.selectedTrackIds, isNotEmpty);

      m.drillIntoFolder('root1');
      expect(m.selectedTrackIds, isEmpty);
    });

    test('setSort does NOT clear the selection -- the same rows stay visible, just reordered', () {
      final m = fixtureLibrary();
      m.selectTrackClick('t1', ctrl: false, shift: false, visibleOrder: m.visibleTracks);
      m.selectTrackClick('t3', ctrl: true, shift: false, visibleOrder: m.visibleTracks);
      expect(m.selectedTrackIds, {'t1', 't3'});

      m.setSort(SortColumn.title);
      expect(m.selectedTrackIds, {'t1', 't3'});
    });
  });
}
