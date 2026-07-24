import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart';

/// A titled, multi-select filter list (Folder/Artist/Album in
/// `home_screen.dart`'s filter row): a scrolling `All (N)` + [values] list,
/// plus -- whenever [selected] is non-empty -- a PINNED header region above
/// the list showing the current selection (one value, or "N selected") with
/// a clear ("X") button.
///
/// The pinned region sits outside the scrolling `ListView` (a sibling in the
/// outer `Column`, not a list item), so it stays visible and clickable no
/// matter how far the list below is scrolled -- previously the only way to
/// clear a selection while scrolled past it was to scroll back up to find
/// the highlighted row (or the `All` entry) again.
///
/// Selection model (standard foobar2000 multi-select): a plain click
/// replaces the whole selection with just the clicked value -- unless it's
/// already the sole selected value, in which case it clears the selection
/// (same "click the only-selected value to deselect" behavior as before);
/// Ctrl+click toggles the clicked value in/out of the existing selection
/// instead of replacing it, so several values can be selected at once
/// (their tracks OR together within this panel). Clicking `All (N)` always
/// clears the selection outright, regardless of modifier keys.
///
/// Drill-down mode (the Folder pane -- see `LibraryModel.folderEntries`):
/// providing [onDrill] reroutes plain clicks to it (the owner replaces
/// [values] with the clicked folder's children -- navigation, not
/// replace-the-selection), while Ctrl+click keeps its toggle-into-
/// [selected] behavior. [headerText] pins the owner-computed breadcrumb
/// ("monthly / 2007-08") even while [selected] itself is empty, and
/// [onClearHeader] lets the pinned ✕ reset the whole drill-down rather
/// than just emptying [selected].
class FilterPanel extends StatelessWidget {
  final String title;
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelect;

  /// When non-null, a plain (un-modified) click on a value is a *drill-in*
  /// -- routed here instead of the default replace-selection [onSelect]
  /// call. Ctrl+click is unaffected (still toggles via [onSelect]), as is
  /// `All (N)` (still `onSelect({})`).
  final ValueChanged<String>? onDrill;

  /// When non-null, the pinned header region shows regardless of whether
  /// [selected] is empty, with this as its text -- overriding the default
  /// single-value / "N selected" derivation. Lets the Folder pane show its
  /// drill-down breadcrumb, whose text spans levels this panel can't
  /// derive from [selected] alone.
  final String? headerText;

  /// What the pinned header's ✕ does -- defaults to `onSelect({})` (clear
  /// the selection set, the two remaining panels' behavior). The Folder
  /// pane passes its full reset here (back to the root list), which is
  /// deliberately NOT what its `All (N)` row does (that stays
  /// `onSelect({})`: "all entries at the current level").
  final VoidCallback? onClearHeader;

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
    this.onDrill,
    this.headerText,
    this.onClearHeader,
  });

  String _label(String value) => displayName == null ? value : displayName!(value);

  /// Handles a click on value [v] -- see the class doc's "Selection model"
  /// paragraph for the plain-click-vs-Ctrl+click contract this implements.
  /// [HardwareKeyboard.instance] reflects real-time modifier-key state (kept
  /// current independently of pointer events by Flutter's key event
  /// dispatch), so checking it here at click time correctly detects Ctrl
  /// held during the click regardless of exactly when the key went down.
  void _handleTap(String v) {
    if (HardwareKeyboard.instance.isControlPressed) {
      final next = Set<String>.of(selected);
      if (!next.remove(v)) next.add(v);
      onSelect(next);
      return;
    }
    if (onDrill != null) {
      onDrill!(v); // drill-down mode: plain click always navigates in
      return;
    }
    if (selected.length == 1 && selected.contains(v)) {
      onSelect(const {});
    } else {
      onSelect({v});
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = headerText != null || selected.isNotEmpty;
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
        if (hasSelection)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    headerText ??
                        (selected.length == 1
                            ? _label(selected.first)
                            : '${selected.length} selected'),
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
                  onTap: onClearHeader ?? () => onSelect(const {}),
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
                selected: selected.isEmpty,
                onTap: () => onSelect(const {}),
              ),
              for (final v in values)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(_label(v), maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: selected.contains(v),
                  onTap: () => _handleTap(v),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
