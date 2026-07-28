import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/settings_dialog.dart';

/// Pumps a [SettingsDialog] wrapped in a small [StatefulWidget] harness that
/// owns the roots list itself and feeds add/remove callbacks back into
/// state -- mirroring how home_screen.dart's `ListenableBuilder` over
/// `LibraryRootsPrefs` keeps the dialog's `roots`/`rootsMissingManifest`
/// props live after each change, without needing `LibraryRootsPrefs` (or
/// its config-writing side effects) in this widget-level test.
class _Harness extends StatefulWidget {
  final List<String> initialRoots;
  final List<String> initialMissing;
  final List<String> initialFailed;
  final Future<String?> Function() pickDirectory;
  final void Function(String)? onAdd;
  final void Function(String)? onRemove;

  const _Harness({
    required this.initialRoots,
    this.initialMissing = const [],
    this.initialFailed = const [],
    required this.pickDirectory,
    this.onAdd,
    this.onRemove,
  });

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<String> roots = List.of(widget.initialRoots);
  late List<String> missing = List.of(widget.initialMissing);
  late List<String> failed = List.of(widget.initialFailed);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SettingsDialog(
          roots: roots,
          rootsMissingManifest: missing,
          rootsFailed: failed,
          pickDirectory: widget.pickDirectory,
          onAddRoot: (path) {
            widget.onAdd?.call(path);
            setState(() {
              roots = [...roots, path];
            });
          },
          onRemoveRoot: (path) {
            widget.onRemove?.call(path);
            setState(() {
              roots = roots.where((r) => r != path).toList();
              missing = missing.where((r) => r != path).toList();
              failed = failed.where((r) => r != path).toList();
            });
          },
        ),
      ),
    );
  }
}

void main() {
  testWidgets('lists configured roots by full path', (tester) async {
    await tester.pumpWidget(
      _Harness(
        initialRoots: [r'L:\music (original structure)', r'D:\more music'],
        pickDirectory: () async => null,
      ),
    );

    expect(find.text(r'L:\music (original structure)'), findsOneWidget);
    expect(find.text(r'D:\more music'), findsOneWidget);
  });

  testWidgets(
    'missing-manifest root shows the inline seed note; others do not',
    (tester) async {
      await tester.pumpWidget(
        _Harness(
          initialRoots: [r'L:\music', r'L:\new drop'],
          initialMissing: [r'L:\new drop'],
          pickDirectory: () async => null,
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('root-tile-L:\\new drop')),
          matching: find.text('no library manifest — seed with foolib'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('root-tile-L:\\music')),
          matching: find.text('no library manifest — seed with foolib'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'failed-manifest root shows the corrupt/reseed note; others do not',
    (tester) async {
      await tester.pumpWidget(
        _Harness(
          initialRoots: [r'L:\music', r'L:\corrupt drop'],
          initialFailed: [r'L:\corrupt drop'],
          pickDirectory: () async => null,
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('root-tile-L:\\corrupt drop')),
          matching: find.text(
            'library manifest is corrupt — reseed with foolib to repair',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('root-tile-L:\\music')),
          matching: find.text(
            'library manifest is corrupt — reseed with foolib to repair',
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Add folder... invokes the injected picker and the newly-picked path '
    'appears as a new root tile',
    (tester) async {
      var addedPath = '';
      await tester.pumpWidget(
        _Harness(
          initialRoots: [r'L:\music'],
          pickDirectory: () async => r'E:\picked folder',
          onAdd: (path) => addedPath = path,
        ),
      );

      expect(find.text(r'E:\picked folder'), findsNothing);
      await tester.tap(find.byKey(const Key('add-folder-button')));
      await tester.pumpAndSettle();

      expect(addedPath, r'E:\picked folder');
      expect(find.text(r'E:\picked folder'), findsOneWidget);
    },
  );

  testWidgets('a cancelled picker (returns null) adds nothing', (tester) async {
    var addCalled = false;
    await tester.pumpWidget(
      _Harness(
        initialRoots: [r'L:\music'],
        pickDirectory: () async => null,
        onAdd: (_) => addCalled = true,
      ),
    );

    await tester.tap(find.byKey(const Key('add-folder-button')));
    await tester.pumpAndSettle();

    expect(addCalled, isFalse);
    expect(find.byType(ListTile), findsOneWidget); // still just the one root
  });

  testWidgets('removing a root fires onRemoveRoot and the tile disappears', (
    tester,
  ) async {
    var removedPath = '';
    await tester.pumpWidget(
      _Harness(
        initialRoots: [r'L:\music', r'D:\more music'],
        pickDirectory: () async => null,
        onRemove: (path) => removedPath = path,
      ),
    );

    expect(find.text(r'D:\more music'), findsOneWidget);
    await tester.tap(find.byKey(const Key('remove-root-D:\\more music')));
    await tester.pumpAndSettle();

    expect(removedPath, r'D:\more music');
    expect(find.text(r'D:\more music'), findsNothing);
    expect(find.text(r'L:\music'), findsOneWidget); // untouched
  });

  testWidgets(
    'no roots configured shows the empty-state message instead of a list',
    (tester) async {
      await tester.pumpWidget(
        _Harness(initialRoots: const [], pickDirectory: () async => null),
      );

      expect(find.text('No library roots configured.'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    },
  );
}
