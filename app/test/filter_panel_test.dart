// FilterPanel's pinned selection header (see ui/filter_panel.dart): whenever
// a value is selected, that value plus a clear ("X") button must stay
// visible in a non-scrolling region above the value list -- regardless of
// how far the list itself has been scrolled -- and tapping the X clears the
// selection (onSelect(null)).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/app_theme.dart';
import 'package:fooplayer_app/ui/filter_panel.dart';

void main() {
  testWidgets(
      'selected value + clear button stay pinned and visible while the '
      'list scrolls, and tapping the clear button clears the selection',
      (tester) async {
    String? selected = 'Value 05';
    final values = List.generate(40, (i) => 'Value ${i.toString().padLeft(2, '0')}');

    await tester.pumpWidget(MaterialApp(
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
    ));

    // Pinned header shows the selection and its clear button immediately.
    expect(find.text('Value 05'), findsWidgets); // pinned header (+ maybe the list row too, still on-screen)
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

    expect(selected, isNull);
  });

  testWidgets('no pinned header/clear button when nothing is selected',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SizedBox(
          height: 260,
          child: FilterPanel(
            title: 'Artist',
            values: const ['Muse', 'Feed Me'],
            selected: null,
            onSelect: (_) {},
          ),
        ),
      ),
    ));

    expect(find.byKey(const Key('filter-clear')), findsNothing);
  });

  testWidgets('displayName maps the underlying value to display text in '
      'both the pinned header and the scrolling list', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SizedBox(
          height: 260,
          child: FilterPanel(
            title: 'Folder',
            values: const [r'L:\Music\RockFolder'],
            selected: r'L:\Music\RockFolder',
            onSelect: (_) {},
            displayName: (v) => v.split(r'\').last,
          ),
        ),
      ),
    ));

    expect(find.text('RockFolder'), findsWidgets);
    expect(find.text(r'L:\Music\RockFolder'), findsNothing);
  });
}
