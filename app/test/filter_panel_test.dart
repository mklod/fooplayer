// FilterPanel's multi-select behavior (see ui/filter_panel.dart): a plain
// click replaces the whole selection with just the clicked value (clicking
// the only-selected value clears it); Ctrl+click toggles a value in/out of
// the existing selection so several can be selected at once; the pinned
// header above the scrolling list shows the single selected value, or "N
// selected" when more than one is picked, either way with a clear ("X")
// button that always empties the selection outright.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/filter_panel.dart';

/// Holds Ctrl down for the duration of [action] (e.g. a [WidgetTester.tap])
/// so [FilterPanel]'s `HardwareKeyboard.instance.isControlPressed` check
/// sees it held, then releases it -- mirrors a real Ctrl+click.
Future<void> ctrlClick(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await action();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  testWidgets('selected value + clear button stay pinned and visible while the '
      'list scrolls, and tapping the clear button clears the selection', (
    tester,
  ) async {
    Set<String> selected = {'Value 05'};
    final values = List.generate(
      40,
      (i) => 'Value ${i.toString().padLeft(2, '0')}',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          // Bounded height, small enough that the 41-row list (All + 40
          // values) cannot fit -- scrolling is required to reach the bottom.
          body: SizedBox(
            height: 260,
            child: StatefulBuilder(
              builder: (context, setState) => FilterPanel(
                title: 'Artist',
                values: values,
                selected: selected,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );

    // Pinned header shows the selection and its clear button immediately.
    expect(
      find.text('Value 05'),
      findsWidgets,
    ); // pinned header (+ maybe the list row too, still on-screen)
    expect(find.byKey(const Key('filter-clear')), findsOneWidget);

    // Scroll the value list well past where "Value 05" would have been.
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();

    // The list has scrolled the row away, but the pinned header (outside
    // the ListView) still shows the selected value and its clear button.
    expect(find.text('Value 05'), findsOneWidget);
    expect(find.byKey(const Key('filter-clear')), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-clear')));
    await tester.pump();

    expect(selected, isEmpty);
  });

  testWidgets('no pinned header/clear button when nothing is selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: FilterPanel(
              title: 'Artist',
              values: const ['Muse', 'Feed Me'],
              selected: const {},
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('filter-clear')), findsNothing);
  });

  testWidgets('displayName maps the underlying value to display text in '
      'both the pinned header and the scrolling list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: FilterPanel(
              title: 'Folder',
              values: const [r'L:\Music\RockFolder'],
              selected: const {r'L:\Music\RockFolder'},
              onSelect: (_) {},
              displayName: (v) => v.split(r'\').last,
            ),
          ),
        ),
      ),
    );

    expect(find.text('RockFolder'), findsWidgets);
    expect(find.text(r'L:\Music\RockFolder'), findsNothing);
  });

  testWidgets(
    'plain click replaces the selection with just the clicked value',
    (tester) async {
      Set<String> selected = {'Muse'};
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SizedBox(
              height: 260,
              child: StatefulBuilder(
                builder: (context, setState) => FilterPanel(
                  title: 'Artist',
                  values: const ['Muse', 'Feed Me'],
                  selected: selected,
                  onSelect: (v) => setState(() => selected = v),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Feed Me'));
      await tester.pump();

      expect(selected, {'Feed Me'}); // replaced, not accumulated
    },
  );

  testWidgets('plain click on the only-selected value clears the selection', (
    tester,
  ) async {
    Set<String> selected = {'Muse'};
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: StatefulBuilder(
              builder: (context, setState) => FilterPanel(
                title: 'Artist',
                values: const ['Muse', 'Feed Me'],
                selected: selected,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );

    // 'Muse' is currently both the sole pinned-header value and a list row
    // -- an unscoped text finder would be ambiguous, so target the list row
    // specifically via its ListTile.
    await tester.tap(find.widgetWithText(ListTile, 'Muse'));
    await tester.pump();

    expect(selected, isEmpty);
  });

  testWidgets(
    'Ctrl+click accumulates a second value instead of replacing the first',
    (tester) async {
      Set<String> selected = {'Muse'};
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SizedBox(
              height: 260,
              child: StatefulBuilder(
                builder: (context, setState) => FilterPanel(
                  title: 'Artist',
                  values: const ['Muse', 'Feed Me'],
                  selected: selected,
                  onSelect: (v) => setState(() => selected = v),
                ),
              ),
            ),
          ),
        ),
      );

      await ctrlClick(tester, () => tester.tap(find.text('Feed Me')));
      await tester.pump();

      expect(selected, {'Muse', 'Feed Me'}); // both selected, union
    },
  );

  testWidgets('Ctrl+click on an already-selected value removes just that one', (
    tester,
  ) async {
    Set<String> selected = {'Muse', 'Feed Me'};
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: StatefulBuilder(
              builder: (context, setState) => FilterPanel(
                title: 'Artist',
                values: const ['Muse', 'Feed Me'],
                selected: selected,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );

    await ctrlClick(tester, () => tester.tap(find.text('Muse')));
    await tester.pump();

    expect(selected, {'Feed Me'});
  });

  testWidgets('pinned header shows "N selected" with multiple selections, '
      'and its clear button empties the whole selection', (tester) async {
    Set<String> selected = {'Muse', 'Feed Me'};
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: StatefulBuilder(
              builder: (context, setState) => FilterPanel(
                title: 'Artist',
                values: const ['Muse', 'Feed Me'],
                selected: selected,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byKey(const Key('filter-clear')), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-clear')));
    await tester.pump();

    expect(selected, isEmpty);
  });

  testWidgets('clicking "All (N)" always clears the selection outright, '
      'even with multiple values selected and even under Ctrl', (tester) async {
    Set<String> selected = {'Muse', 'Feed Me'};
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: StatefulBuilder(
              builder: (context, setState) => FilterPanel(
                title: 'Artist',
                values: const ['Muse', 'Feed Me'],
                selected: selected,
                onSelect: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );

    await ctrlClick(tester, () => tester.tap(find.text('All (2)')));
    await tester.pump();

    expect(selected, isEmpty);
  });

  group(
    'drill-down mode (onDrill/headerText/onClearHeader -- the Folder pane)',
    () {
      testWidgets('plain click routes to onDrill instead of replacing the '
          'selection; Ctrl+click still toggles via onSelect', (tester) async {
        final drilled = <String>[];
        Set<String>? selectResult;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: SizedBox(
                height: 260,
                child: FilterPanel(
                  title: 'Folder',
                  values: const ['2007-08', '2007-09'],
                  selected: const {'2007-08'},
                  onSelect: (v) => selectResult = v,
                  onDrill: drilled.add,
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('2007-09'));
        await tester.pump();
        expect(drilled, ['2007-09']);
        expect(
          selectResult,
          isNull,
          reason: 'plain click must not touch onSelect',
        );

        // Even the sole-selected value drills on plain click (no
        // "click-to-deselect" in drill-down mode).
        await tester.tap(find.widgetWithText(ListTile, '2007-08'));
        await tester.pump();
        expect(drilled, ['2007-09', '2007-08']);
        expect(selectResult, isNull);

        await ctrlClick(tester, () => tester.tap(find.text('2007-09')));
        await tester.pump();
        expect(selectResult, {'2007-08', '2007-09'}); // toggle, no drill
        expect(drilled, hasLength(2));
      });

      testWidgets('headerText pins the breadcrumb + clear button even with an '
          'empty selection set, and the X calls onClearHeader', (tester) async {
        var cleared = 0;
        Set<String>? selectResult;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: SizedBox(
                height: 260,
                child: FilterPanel(
                  title: 'Folder',
                  values: const ['2007-08', '2007-09'],
                  selected:
                      const {}, // drilled in, but no Ctrl-selected siblings
                  onSelect: (v) => selectResult = v,
                  headerText: 'monthly / 2007-08',
                  onClearHeader: () => cleared++,
                ),
              ),
            ),
          ),
        );

        expect(find.text('monthly / 2007-08'), findsOneWidget);
        expect(find.byKey(const Key('filter-clear')), findsOneWidget);

        await tester.tap(find.byKey(const Key('filter-clear')));
        await tester.pump();
        expect(cleared, 1);
        expect(
          selectResult,
          isNull,
          reason: 'X must use onClearHeader, not onSelect',
        );
      });

      testWidgets('headerText overrides the derived "N selected" text, and '
          '"All (N)" still clears just the selection set via onSelect', (
        tester,
      ) async {
        var cleared = 0;
        Set<String>? selectResult;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: SizedBox(
                height: 260,
                child: FilterPanel(
                  title: 'Folder',
                  values: const ['2007-08', '2007-09'],
                  selected: const {'2007-08', '2007-09'},
                  onSelect: (v) => selectResult = v,
                  headerText: '2 selected',
                  onClearHeader: () => cleared++,
                ),
              ),
            ),
          ),
        );

        expect(find.text('2 selected'), findsOneWidget);

        await tester.tap(find.text('All (2)'));
        await tester.pump();
        expect(selectResult, isEmpty); // sibling set cleared...
        expect(cleared, 0); // ...but not the whole drill-down
      });
    },
  );

  testWidgets('multiple selected values are all highlighted in the list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: FilterPanel(
              title: 'Artist',
              values: const ['Muse', 'Feed Me', 'ZZ Top'],
              selected: const {'Muse', 'ZZ Top'},
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );

    ListTile tileFor(String label) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, label));

    expect(tileFor('Muse').selected, isTrue);
    expect(tileFor('ZZ Top').selected, isTrue);
    expect(tileFor('Feed Me').selected, isFalse);
  });
}
