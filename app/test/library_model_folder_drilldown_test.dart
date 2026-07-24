// The Folder pane's one-level-at-a-time drill-down navigation (see
// LibraryModel.folderPath/folderSiblings/folderEntries): a plain click
// selects a folder AND descends into it -- the pane's entries are replaced
// by that folder's immediate subdirectories -- while Ctrl+click toggles
// sibling folders at the current level without drilling (their tracks OR
// together). The pinned header shows a "monthly / 2007-08" breadcrumb (or
// "N selected"), and its X fully resets the pane back to the root list.
// Every folder-selection change cascades: downstream artist/album filter
// sets clear, and a stale trackNumber sort reverts.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';

const monthlyRoot = r'L:\Music\monthly';
const albumsRoot = r'L:\Music\albums';

Track tr(String id, String relPath,
        {String rootPath = monthlyRoot,
        String artist = '',
        String album = '',
        int? trackNumber}) =>
    Track(
      contentId: id,
      relPath: relPath,
      rootPath: rootPath,
      dateAdded: DateTime.utc(2024, 1, 1),
      title: id,
      artist: artist,
      album: album,
      trackNumber: trackNumber,
    );

void main() {
  late LibraryModel lib;

  setUp(() {
    lib = LibraryModel();
    lib.allTracks = [
      tr('a1', '2007-08/track1.mp3', artist: 'Muse', album: 'Origin', trackNumber: 1),
      tr('a2', '2007-08/track2.mp3', artist: 'Muse', album: 'Origin', trackNumber: 2),
      tr('b1', '2007-09/sub/track3.mp3', artist: 'Feed Me', album: 'Calamari'),
      tr('c1', '2007-11/track4.mp3', artist: 'ZZ Top', album: 'Fandango'),
      tr('loose', 'loose.mp3', artist: 'Aphex Twin', album: 'Drukqs'),
      tr('x1', 'Muse/Origin/song.mp3',
          rootPath: albumsRoot, artist: 'Muse', album: 'Origin'),
    ];
  });

  Set<String> visibleIds() =>
      lib.visibleTracks.map((t) => t.contentId).toSet();

  group('drill-down navigation', () {
    test('top level lists the roots; nothing selected -> no header, no filter', () {
      expect(lib.folderEntries, [albumsRoot, monthlyRoot]); // basename-sorted
      expect(lib.folderHeaderText, isNull);
      expect(visibleIds(), hasLength(6));
    });

    test('plain click on a root selects it AND replaces the pane entries '
        'with its subdirectories (no phantom entry for root-level tracks)', () {
      lib.drillIntoFolder(monthlyRoot);
      expect(lib.folderPath, [monthlyRoot]);
      expect(lib.folderEntries, ['2007-08', '2007-09', '2007-11']);
      expect(lib.folderHeaderText, 'monthly');
      expect(visibleIds(), {'a1', 'a2', 'b1', 'c1', 'loose'});
    });

    test('drilling a second level narrows the filter to that subfolder; a '
        'leaf folder lists no entries but still filters the tracks', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.drillIntoFolder('2007-08');
      expect(lib.folderPath, [monthlyRoot, '2007-08']);
      expect(lib.folderEntries, isEmpty); // files only, no subdirectories
      expect(lib.folderHeaderText, 'monthly / 2007-08');
      expect(visibleIds(), {'a1', 'a2'});
    });

    test('a deeper subfolder with children keeps drilling one level at a time', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.drillIntoFolder('2007-09');
      expect(lib.folderEntries, ['sub']);
      expect(visibleIds(), {'b1'});
      lib.drillIntoFolder('sub');
      expect(lib.folderHeaderText, 'monthly / 2007-09 / sub');
      expect(visibleIds(), {'b1'});
    });
  });

  group('Ctrl+click sibling selection', () {
    test('siblings at the drilled level OR together without changing the '
        'pane entries, header says "N selected"', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.setFolderSiblings({'2007-08', '2007-11'});
      expect(lib.folderEntries, ['2007-08', '2007-09', '2007-11']); // no drill
      expect(lib.folderHeaderText, '2 selected');
      expect(visibleIds(), {'a1', 'a2', 'c1'});
    });

    test('a single Ctrl-selected sibling shows the full breadcrumb and '
        'narrows to just that sibling', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.setFolderSiblings({'2007-08'});
      expect(lib.folderHeaderText, 'monthly / 2007-08');
      expect(visibleIds(), {'a1', 'a2'});
    });

    test('toggling the sibling set empty reverts the filter to the whole '
        'drilled folder', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.setFolderSiblings({'2007-08'});
      lib.setFolderSiblings({});
      expect(lib.folderHeaderText, 'monthly');
      expect(visibleIds(), {'a1', 'a2', 'b1', 'c1', 'loose'});
    });

    test('at the top level, Ctrl-selected roots OR together (whole-root '
        'scopes) and a single one shows its basename in the header', () {
      lib.setFolderSiblings({monthlyRoot});
      expect(lib.folderPath, isEmpty); // still at the root list
      expect(lib.folderHeaderText, 'monthly');
      expect(visibleIds(), {'a1', 'a2', 'b1', 'c1', 'loose'});
      lib.setFolderSiblings({monthlyRoot, albumsRoot});
      expect(lib.folderHeaderText, '2 selected');
      expect(visibleIds(), hasLength(6));
    });

    test('plain click after Ctrl-selecting siblings drops them and drills '
        'into just the clicked folder', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.setFolderSiblings({'2007-08', '2007-09'});
      lib.drillIntoFolder('2007-11');
      expect(lib.folderPath, [monthlyRoot, '2007-11']);
      expect(lib.folderSiblings, isEmpty);
      expect(visibleIds(), {'c1'});
    });
  });

  group('clear (the pinned X)', () {
    test('fully resets to the top-level root list from any depth', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.drillIntoFolder('2007-09');
      lib.setFolderSiblings({'sub'});
      lib.clearFolderSelection();
      expect(lib.folderPath, isEmpty);
      expect(lib.folderSiblings, isEmpty);
      expect(lib.folderHeaderText, isNull);
      expect(lib.folderEntries, [albumsRoot, monthlyRoot]);
      expect(visibleIds(), hasLength(6));
    });
  });

  group('cascade into artist/album', () {
    test('artist and album lists rescope to the drilled folder', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.drillIntoFolder('2007-08');
      expect(lib.artists, ['Muse']);
      expect(lib.albums, ['Origin']);
    });

    test('every folder-selection change clears downstream artist/album '
        'filter sets', () {
      lib.setArtists({'Muse'});
      lib.setAlbums({'Origin'});
      lib.drillIntoFolder(monthlyRoot);
      expect(lib.artistFilters, isEmpty);
      expect(lib.albumFilters, isEmpty);

      lib.setArtists({'Muse'});
      lib.setFolderSiblings({'2007-08'});
      expect(lib.artistFilters, isEmpty);

      lib.setArtists({'Muse'});
      lib.clearFolderSelection();
      expect(lib.artistFilters, isEmpty);
    });

    test('folder changes revert a stale trackNumber sort (indirect album '
        'clear), for drill, sibling-toggle and clear alike', () {
      for (final change in [
        () => lib.drillIntoFolder(monthlyRoot),
        () => lib.setFolderSiblings({'2007-08'}),
        () => lib.clearFolderSelection(),
      ]) {
        lib.setAlbums({'Origin'}); // single album -> trackNumber ascending
        expect(lib.sortColumn, SortColumn.trackNumber);
        change();
        expect(lib.sortColumn, SortColumn.dateAdded);
        expect(lib.sortAscending, isFalse);
      }
    });
  });

  group('interaction with the rest of the model', () {
    test('setPlaylist clears the whole folder selection', () {
      lib.playlists = const [ManifestPlaylist(name: 'mix', trackIds: ['a1'])];
      lib.drillIntoFolder(monthlyRoot);
      lib.setFolderSiblings({'2007-08'});
      lib.setPlaylist('mix');
      expect(lib.folderPath, isEmpty);
      expect(lib.folderSiblings, isEmpty);
    });

    test('search scopes the drilled pane entries like it scopes the root '
        'list', () {
      lib.drillIntoFolder(monthlyRoot);
      lib.setSearch('b1'); // only b1 (2007-09/sub/track3.mp3) title-matches
      expect(lib.folderEntries, ['2007-09']);
    });
  });
}
