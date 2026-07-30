// A single library root IS the top of the Folder pane.
//
// Reported on the tablet: opening Folders showed one row, "Music", which you
// had to tap before you could see anything at all. A list of one is not a
// choice -- it is a tap tax on every visit. With one root the pane now opens
// inside it, showing its subfolders and its loose tracks straight away.
//
// With several roots (the desktop's five) the root list is a real choice and
// nothing here changes.
//
// Last modified: 2026-07-29--1520

import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/library_model.dart';
import 'package:fooplayer_app/model/track.dart';

Track t(String id, String rel, String root, {String album = 'A'}) => Track(
  contentId: id,
  relPath: rel,
  rootPath: root,
  dateAdded: DateTime.utc(2024),
  title: id,
  artist: 'Artist',
  album: album,
);

LibraryModel single() => LibraryModel()
  ..allTracks = [
    t('a', 'monthly/2024-01/one.mp3', '/Music'),
    t('b', 'loose tracks/two.mp3', '/Music'),
    t('c', 'at the top.mp3', '/Music'),
  ];

void main() {
  test('one root: the pane opens inside it, not on a list of one', () {
    final lib = single();
    expect(lib.folderTopPath, ['/Music']);
    expect(lib.folderPath, ['/Music'], reason: 'no tap needed to get here');
    expect(lib.folderAtTop, isTrue, reason: 'so no back affordance');
    expect(lib.folderEntries, ['loose tracks', 'monthly']);
  });

  test('several roots: the root list is still the top level', () {
    final lib = LibraryModel()
      ..allTracks = [
        t('a', 'x.mp3', '/Music'),
        t('b', 'y.mp3', '/Other'),
      ];
    expect(lib.folderTopPath, isEmpty);
    expect(lib.folderPath, isEmpty);
    expect(lib.folderAtTop, isTrue);
    expect(lib.folderEntries, ['/Music', '/Other']);
  });

  test('one root: popping cannot climb above it', () {
    final lib = single()..drillIntoFolder('monthly');
    expect(lib.folderPath, ['/Music', 'monthly']);

    lib.popFolderTo(0); // what a leading "All" breadcrumb would ask for
    expect(lib.folderPath, ['/Music'], reason: 'clamped to the real top');
    expect(lib.folderAtTop, isTrue);
  });

  test('one root: clearing returns to the root, not to nothing', () {
    final lib = single()..drillIntoFolder('monthly');
    lib.clearFolderSelection();
    expect(lib.folderPath, ['/Music']);
    expect(lib.folderEntries, ['loose tracks', 'monthly']);
  });

  test(
    'sitting at the top is not a folder selection, so a one-album library '
    'does not render as though its album folder had been picked',
    () {
      final lib = LibraryModel()
        ..allTracks = [
          t('a', 'one.mp3', '/Music', album: 'Only Album'),
          t('b', 'two.mp3', '/Music', album: 'Only Album'),
        ];
      expect(lib.folderPath, ['/Music']);
      expect(
        lib.folderSelectionIsSingleAlbum,
        isFalse,
        reason: 'the implicit root position is not something the user chose',
      );
    },
  );

  test('a second root appearing gives back a level to climb to', () {
    final lib = single();
    expect(lib.folderPath, ['/Music']);

    lib.allTracks = [...lib.allTracks, t('d', 'z.mp3', '/Other')];
    expect(lib.folderTopPath, isEmpty, reason: 'the root list means something now');
    // The view stays where the user left it rather than being yanked up,
    // but there is now somewhere above it to go.
    expect(lib.folderPath, ['/Music']);
    expect(lib.folderAtTop, isFalse);
    lib.popFolderTo(0);
    expect(lib.folderPath, isEmpty);
    expect(lib.folderEntries, ['/Music', '/Other']);
  });

  test('the root a drilled-in path belongs to going away resets the pane', () {
    final lib = LibraryModel()
      ..allTracks = [
        t('a', 'x.mp3', '/Music'),
        t('b', 'sub/y.mp3', '/Other'),
      ];
    lib.drillIntoFolder('/Other');
    lib.drillIntoFolder('sub');
    expect(lib.folderPath, ['/Other', 'sub']);

    // /Other is removed from the library roots.
    lib.allTracks = [t('a', 'x.mp3', '/Music')];
    expect(
      lib.folderPath,
      ['/Music'],
      reason: 'never left pointing at a folder the library no longer has',
    );
    expect(lib.folderSiblings, isEmpty);
  });

  test('search cannot make a back affordance appear', () {
    final lib = single();
    lib.search = 'nothing matches this';
    expect(
      lib.folderTopPath,
      ['/Music'],
      reason: 'derived from the library, not the filtered view',
    );
    expect(lib.folderAtTop, isTrue);
  });

  group('one root: its own name is never a breadcrumb segment', () {
    // Reported: the Folder filter panel showed "Music" as a header before
    // ever getting to a real folder -- a place nothing is ever NOT under,
    // so naming it added a step without adding a choice. Unlike the panel's
    // TITLE ("FOLDER"), which stays; this is the pinned breadcrumb showing
    // where inside the root you are.
    test('at the root, nothing drilled: no segment at all', () {
      final lib = single();
      expect(lib.folderPath, ['/Music']);
      expect(lib.folderBreadcrumbs, isEmpty);
    });

    test('one level in: just the folder name, not "Music / monthly"', () {
      final lib = single()..drillIntoFolder('monthly');
      expect(lib.folderBreadcrumbs, ['monthly']);
    });

    test('two levels in: still no root name at the front', () {
      final lib = single()
        ..drillIntoFolder('monthly')
        ..drillIntoFolder('2024-01');
      expect(lib.folderBreadcrumbs, ['monthly', '2024-01']);
    });

    test('several roots: a root IS a real choice, so its name stays', () {
      final lib = LibraryModel()
        ..allTracks = [t('a', 'x.mp3', '/Music'), t('b', 'y.mp3', '/Other')]
        ..drillIntoFolder('/Music');
      expect(lib.folderBreadcrumbs, ['Music']);
    });
  });

  group('one root: a breadcrumb tap still lands on the segment it named', () {
    // The offset math has to independently track the same root-name
    // omission folderBreadcrumbs applies, or a tap lands one level off from
    // what it visibly named -- this pins that agreement directly, rather
    // than trusting the two to happen to stay in sync.
    test('tapping the only segment, one level in, keeps the root', () {
      final lib = single()..drillIntoFolder('monthly');
      expect(lib.folderBreadcrumbs, ['monthly']);
      lib.popFolderTo(lib.breadcrumbPopDepth(0));
      expect(lib.folderPath, ['/Music', 'monthly']);
    });

    test('tapping the first of two segments keeps root + that segment', () {
      final lib = single()
        ..drillIntoFolder('monthly')
        ..drillIntoFolder('2024-01');
      expect(lib.folderBreadcrumbs, ['monthly', '2024-01']);
      lib.popFolderTo(lib.breadcrumbPopDepth(0));
      expect(lib.folderPath, ['/Music', 'monthly']);
    });

    test('several roots: uiIndex 0 is the UI-prepended "All"', () {
      final lib = LibraryModel()
        ..allTracks = [t('a', 'x.mp3', '/Music'), t('b', 'y.mp3', '/Other')]
        ..drillIntoFolder('/Music')
        ..drillIntoFolder('sub');
      // headerSegments = ['All', ...folderBreadcrumbs] here -- 'All' is
      // uiIndex 0, folderBreadcrumbs[0] ('Music') is uiIndex 1.
      expect(lib.folderBreadcrumbs, ['Music', 'sub']);
      lib.popFolderTo(lib.breadcrumbPopDepth(0));
      expect(lib.folderPath, isEmpty, reason: '"All" resets to the root list');
      lib.drillIntoFolder('/Music');
      lib.drillIntoFolder('sub');
      lib.popFolderTo(lib.breadcrumbPopDepth(1));
      expect(lib.folderPath, ['/Music']);
    });
  });
}
