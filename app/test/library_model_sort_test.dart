import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/manifest_io.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(
  String id, {
  required String title,
  String artist = '',
  String album = '',
  int? durationMs,
  required DateTime dateAdded,
}) =>
    Track(
      contentId: id,
      relPath: '$id.mp3',
      dateAdded: dateAdded,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
    );

void main() {
  late LibraryModel lib;

  setUp(() {
    lib = LibraryModel();
    // Deliberately mixed casing (title/artist/album) so case-insensitive
    // comparison is actually exercised, and one null duration (track 'c')
    // to exercise "nulls sort last" in both directions.
    lib.allTracks = [
      tr('a', title: 'banana', artist: 'muse', album: 'Zeta', durationMs: 200000, dateAdded: DateTime.utc(2024, 1, 2)),
      tr('b', title: 'Apple', artist: 'Feed Me', album: 'alpha', durationMs: 100000, dateAdded: DateTime.utc(2024, 1, 4)),
      tr('c', title: 'cherry', artist: 'ZZ Top', album: 'Middle', dateAdded: DateTime.utc(2024, 1, 1)),
      tr('d', title: 'Date Fruit', artist: 'apple corp', album: 'beta', durationMs: 50000, dateAdded: DateTime.utc(2024, 1, 3)),
    ];
  });

  List<String> ids() => lib.visibleTracks.map((t) => t.contentId).toList();

  group('default sort', () {
    test('dateAdded descending (newest first), matching pre-Task-6 behavior', () {
      expect(lib.sortColumn, SortColumn.dateAdded);
      expect(lib.sortAscending, isFalse);
      expect(ids(), ['b', 'd', 'a', 'c']);
    });
  });

  group('setSort direction rules', () {
    test('switching to a new non-date column starts ascending', () {
      lib.setSort(SortColumn.title);
      expect(lib.sortColumn, SortColumn.title);
      expect(lib.sortAscending, isTrue);
    });

    test('switching (back) to dateAdded always starts descending', () {
      lib.setSort(SortColumn.title);
      lib.setSort(SortColumn.dateAdded);
      expect(lib.sortColumn, SortColumn.dateAdded);
      expect(lib.sortAscending, isFalse);
    });

    test('clicking the already-active column toggles direction', () {
      lib.setSort(SortColumn.title);
      expect(lib.sortAscending, isTrue);
      lib.setSort(SortColumn.title);
      expect(lib.sortAscending, isFalse);
      lib.setSort(SortColumn.title);
      expect(lib.sortAscending, isTrue);
    });

    test('notifies listeners on every call, including toggles', () {
      var notifications = 0;
      lib.addListener(() => notifications++);
      lib.setSort(SortColumn.title);
      lib.setSort(SortColumn.title);
      expect(notifications, 2);
    });
  });

  group('title column', () {
    test('ascending is case-insensitive', () {
      lib.setSort(SortColumn.title);
      expect(ids(), ['b', 'a', 'c', 'd']); // Apple, banana, cherry, Date Fruit
    });

    test('descending reverses it', () {
      lib.setSort(SortColumn.title);
      lib.setSort(SortColumn.title);
      expect(ids(), ['d', 'c', 'a', 'b']);
    });
  });

  group('artist column', () {
    test('ascending is case-insensitive', () {
      lib.setSort(SortColumn.artist);
      expect(ids(), ['d', 'b', 'a', 'c']); // apple corp, Feed Me, muse, ZZ Top
    });

    test('descending reverses it', () {
      lib.setSort(SortColumn.artist);
      lib.setSort(SortColumn.artist);
      expect(ids(), ['c', 'a', 'b', 'd']);
    });
  });

  group('album column', () {
    test('ascending is case-insensitive', () {
      lib.setSort(SortColumn.album);
      expect(ids(), ['b', 'd', 'c', 'a']); // alpha, beta, Middle, Zeta
    });

    test('descending reverses it', () {
      lib.setSort(SortColumn.album);
      lib.setSort(SortColumn.album);
      expect(ids(), ['a', 'c', 'd', 'b']);
    });
  });

  group('duration column: null durations always sort last', () {
    test('ascending: known durations low-to-high, then the null one', () {
      lib.setSort(SortColumn.duration);
      expect(ids(), ['d', 'b', 'a', 'c']); // 50000, 100000, 200000, null
    });

    test('descending: known durations high-to-low, null STILL last (not first)', () {
      lib.setSort(SortColumn.duration);
      lib.setSort(SortColumn.duration);
      expect(ids(), ['a', 'b', 'd', 'c']); // 200000, 100000, 50000, null
    });
  });

  group('dateAdded column explicit toggle', () {
    test('toggling once from the default flips to ascending (oldest first)', () {
      lib.setSort(SortColumn.dateAdded);
      expect(lib.sortAscending, isTrue);
      expect(ids(), ['c', 'a', 'd', 'b']);
    });
  });

  group('playlist mode', () {
    test('playlist order is preserved regardless of sortColumn/sortAscending', () {
      lib.playlists = [
        const ManifestPlaylist(name: 'mix', trackIds: ['c', 'a', 'd', 'b']),
      ];
      lib.setPlaylist('mix');
      lib.setSort(SortColumn.title); // would reorder the library feed
      expect(ids(), ['c', 'a', 'd', 'b']); // but not the playlist
      lib.setSort(SortColumn.title); // toggle direction too
      expect(ids(), ['c', 'a', 'd', 'b']);
    });
  });
}
