// Which columns the library list shows, how wide they are, and the order
// they sit in.
//
// One ordered list drives the header AND the rows (see [buildColumnRow]),
// because the two drifting apart is how a resizable table gets subtly
// misaligned: the header says one width, the cells lay out another, and
// the columns lean further out of true the wider the window gets.
//
// Sizes mean one of two things, per column:
//   - a FLEX weight, for the text columns (Title/Artist/Album/Path) that
//     should share whatever space the window has;
//   - a PIXEL width, for the narrow fixed ones (Time/Date/Art/Emb) whose
//     content is a fixed shape and gains nothing from being stretched.
// Dragging the divider after a column adjusts that column's own number,
// so a flexible column takes its space from its flexible neighbours and a
// fixed one takes it from all of them.
//
// Last modified: 2026-09-18--1700

import 'package:flutter/widgets.dart';

/// A column in the library (non-playlist) track list, in display order.
enum TrackColumn {
  title('Title', flex: 3, hideable: false),
  artist('Artist', flex: 2),
  album('Album', flex: 2),
  time('Time', width: 44, alignEnd: true),
  date('Date', width: 82),
  art('Art', width: 34),
  emb('Emb', width: 34),
  // Last on purpose: a full path is the widest thing in the row and the
  // least often read, so it goes where it cannot push the columns you
  // actually scan off to the side.
  path('Path', flex: 3);

  const TrackColumn(
    this.label, {
    this.flex,
    this.width,
    this.hideable = true,
    this.alignEnd = false,
  }) : assert(
         (flex == null) != (width == null),
         'a column is either flexible or fixed, never both',
       );

  /// What the header and the right-click menu call it.
  final String label;

  /// Default flex weight, for a column that shares the leftover space.
  final int? flex;

  /// Default pixel width, for a column that does not.
  final double? width;

  /// Whether the header menu offers to hide it. Title is not hideable: a
  /// row with no title is not a row.
  final bool hideable;

  final bool alignEnd;

  bool get isFlexible => flex != null;

  /// The size this column has before the user drags anything: a flex
  /// weight or a pixel width, per [isFlexible].
  double get defaultSize => isFlexible ? flex!.toDouble() : width!;

  /// The stored id, so a renamed label never invalidates a saved choice.
  String get id => name;

  static TrackColumn? byId(String id) {
    for (final c in TrackColumn.values) {
      if (c.id == id) return c;
    }
    return null; // an id from a newer build: ignored, not fatal
  }

  static List<TrackColumn> get hideableColumns =>
      [for (final c in values) if (c.hideable) c];
}

/// Smallest a column may be dragged to. Below this a header label is a
/// couple of ellipsised characters and the column stops meaning anything.
const double kMinColumnWidth = 28;
const double kMinColumnFlex = 0.4;

/// Space between two columns -- and, in the header, the width of the
/// grab area that resizes the one on its left.
const double kColumnGap = 8;

/// What the user has done to the columns: hidden some, resized others.
@immutable
class TrackColumnLayout {
  final Set<TrackColumn> hidden;

  /// Size overrides by column; absent means [TrackColumn.defaultSize].
  final Map<TrackColumn, double> sizes;

  const TrackColumnLayout({this.hidden = const {}, this.sizes = const {}});

  bool shows(TrackColumn c) => !hidden.contains(c);

  List<TrackColumn> get visible => [
    for (final c in TrackColumn.values)
      if (shows(c)) c,
  ];

  double sizeOf(TrackColumn c) => sizes[c] ?? c.defaultSize;
}

/// Lays [columns] out as Row children, with [gap] between them.
///
/// The single place the header and the rows agree on geometry. [cell]
/// builds the content; [gapAfter] lets the header put a drag handle in
/// the gap where a row just leaves blank space of the same width.
List<Widget> buildColumnRow({
  required TrackColumnLayout layout,
  required Widget Function(TrackColumn column) cell,
  Widget Function(TrackColumn column)? gapAfter,
}) {
  final columns = layout.visible;
  final out = <Widget>[];
  for (var i = 0; i < columns.length; i++) {
    final c = columns[i];
    final size = layout.sizeOf(c);
    out.add(
      c.isFlexible
          // Flex is an int, and a dragged weight is fractional -- scaled
          // so a 0.01 difference still moves the column.
          ? Expanded(flex: (size * 100).round().clamp(1, 1 << 30), child: cell(c))
          : SizedBox(width: size, child: cell(c)),
    );
    if (i != columns.length - 1) {
      out.add(gapAfter?.call(c) ?? const SizedBox(width: kColumnGap));
    }
  }
  return out;
}
