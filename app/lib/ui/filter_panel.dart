import 'package:flutter/material.dart';
import 'app_theme.dart';

/// A titled, single-select filter list (Folder/Artist/Album in
/// `home_screen.dart`'s filter row): a scrolling `All (N)` + [values] list,
/// plus -- whenever [selected] is non-null -- a PINNED header region above
/// the list showing the current selection with a clear ("X") button.
///
/// The pinned region sits outside the scrolling `ListView` (a sibling in the
/// outer `Column`, not a list item), so it stays visible and clickable no
/// matter how far the list below is scrolled -- previously the only way to
/// clear a selection while scrolled past it was to scroll back up to find
/// the highlighted row (or the `All` entry) again.
class FilterPanel extends StatelessWidget {
  final String title;
  final List<String> values;
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// Renders [values] entries (and the pinned selected value) for display --
  /// defaults to the value itself. Selection/comparison (`selected`,
  /// [onSelect]) always operates on the raw value, never the display text,
  /// so callers whose "value" isn't already human-readable (e.g. the Folder
  /// panel keys entries by root path but displays just the folder's
  /// basename) can separate the two without the model needing to translate
  /// display text back into a value.
  final String Function(String value)? displayName;

  const FilterPanel({
    super.key,
    required this.title,
    required this.values,
    required this.selected,
    required this.onSelect,
    this.displayName,
  });

  String _label(String value) => displayName == null ? value : displayName!(value);

  @override
  Widget build(BuildContext context) {
    final selectedValue = selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        if (selectedValue != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _label(selectedValue),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                InkWell(
                  key: const Key('filter-clear'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(null),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 15, color: AppColors.inkSecondary),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('All (${values.length})'),
                selected: selected == null,
                onTap: () => onSelect(null),
              ),
              for (final v in values)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(_label(v), maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: v == selected,
                  onTap: () => onSelect(v == selected ? null : v),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
