// Pure-function layer of the Folder pane's drill-down navigation (see
// model/filtering.dart): subfolderNames derives the immediate subdirectory
// entries one level below a drilled folder from track relPaths (tracks
// sitting directly at that level contribute no phantom entries), and
// applyFilters' `folders` parameter restricts tracks to the union of the
// selected FolderScopes with segment-safe prefix matching.
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/filtering.dart';
import 'package:fooplayer_app/model/track.dart';

Track tr(String id, String relPath, {String rootPath = r'L:\Music\monthly'}) =>
    Track(
      contentId: id,
      relPath: relPath,
      rootPath: rootPath,
      dateAdded: DateTime.utc(2024, 1, 1),
      title: id,
    );

void main() {
  final monthly = [
    tr('a1', '2007-08/track1.mp3'),
    tr('a2', '2007-08/track2.mp3'),
    tr('b1', '2007-09/sub/track3.mp3'),
    tr('c1', '2007-11/track4.mp3'),
    tr('loose', 'loose.mp3'), // directly at root level -- no directory
  ];
  final other = tr('x1', 'Muse/Origin/song.mp3', rootPath: r'L:\Music\albums');
  final all = [...monthly, other];

  group('subfolderNames', () {
    test('derives immediate subdirectories at the root level; a track '
        'directly at that level yields no phantom entry', () {
      expect(subfolderNames(all, rootPath: r'L:\Music\monthly'), [
        '2007-08',
        '2007-09',
        '2007-11',
      ]); // sorted; no 'loose.mp3' entry
    });

    test('only tracks of the given root contribute', () {
      expect(subfolderNames(all, rootPath: r'L:\Music\albums'), ['Muse']);
    });

    test('nested prefix lists the next level down only', () {
      expect(
        subfolderNames(all, rootPath: r'L:\Music\monthly', prefix: '2007-09'),
        ['sub'],
      );
      // 2007-08 holds files directly -- a leaf: no entries at all.
      expect(
        subfolderNames(all, rootPath: r'L:\Music\monthly', prefix: '2007-08'),
        isEmpty,
      );
    });

    test('prefix matching is segment-safe: "2007-08" does not swallow a '
        'sibling named "2007-081"', () {
      final withTrap = [...monthly, tr('trap', '2007-081/trap.mp3')];
      expect(subfolderNames(withTrap, rootPath: r'L:\Music\monthly'), [
        '2007-08',
        '2007-081',
        '2007-09',
        '2007-11',
      ]);
      expect(
        subfolderNames(
          withTrap,
          rootPath: r'L:\Music\monthly',
          prefix: '2007-08',
        ),
        isEmpty,
        reason: '2007-081/trap.mp3 must not leak into 2007-08',
      );
    });

    test('names dedupe case-insensitively, first casing seen wins', () {
      final mixed = [tr('m1', 'Mixes/one.mp3'), tr('m2', 'mixes/two.mp3')];
      expect(subfolderNames(mixed, rootPath: r'L:\Music\monthly'), ['Mixes']);
    });
  });

  group('applyFilters folders parameter', () {
    test('empty list means no folder restriction', () {
      expect(applyFilters(all, folders: const []).length, all.length);
    });

    test('a root-only scope (empty sub) matches every track of that root, '
        'and only that root', () {
      final got = applyFilters(
        all,
        folders: [(root: r'L:\Music\albums', sub: '')],
      );
      expect(got.map((t) => t.contentId), ['x1']);
    });

    test('a sub scope matches tracks at or below the sub prefix, '
        'segment-safely', () {
      final withTrap = [...all, tr('trap', '2007-081/trap.mp3')];
      final got = applyFilters(
        withTrap,
        folders: [(root: r'L:\Music\monthly', sub: '2007-08')],
      );
      expect(got.map((t) => t.contentId).toSet(), {'a1', 'a2'}); // not 'trap'
    });

    test('multiple scopes (Ctrl-selected siblings) OR together', () {
      final got = applyFilters(
        all,
        folders: [
          (root: r'L:\Music\monthly', sub: '2007-08'),
          (root: r'L:\Music\monthly', sub: '2007-11'),
        ],
      );
      expect(got.map((t) => t.contentId).toSet(), {'a1', 'a2', 'c1'});
    });

    test('scope root comparison is exact (no cross-root leakage), and a '
        'nested sub matches deeper descendants too', () {
      expect(
        applyFilters(all, folders: [(root: r'L:\Music\MONTHLY', sub: '')]),
        isEmpty,
        reason: 'root paths compare exactly, like the rootPath filter',
      );
      final deep = applyFilters(
        all,
        folders: [(root: r'L:\Music\monthly', sub: '2007-09')],
      );
      expect(deep.single.contentId, 'b1'); // 2007-09/sub/track3.mp3 matches
    });

    test('folders AND with the other criteria (search)', () {
      final got = applyFilters(
        all,
        folders: [(root: r'L:\Music\monthly', sub: '2007-08')],
        search: 'a2',
      );
      expect(got.single.contentId, 'a2');
    });
  });
}
