// Which columns the library list shows, how wide they are, and the order
// they sit in.
//
// One ordered list drives the header AND the rows (see [buildColumnRow]),
// because the two drifting apart is how a resizable table gets subtly
// misaligned: the header says one width, the cells lay out another, and
// the columns lean further out of true the wider the window gets.
//
// **Every column is a fixed pixel width**, and dragging one changes that
// column alone. The first cut had the text columns share the leftover
// space as flex weights, which meant dragging Artist quietly resized
// Title and Path as well -- rejected on sight, and rightly: a column
// divider should move one edge, not redistribute the table.
//
// The columns therefore do not fill the window: leftover space sits
// empty to the right, and that slack is what a drag grows into. A drag
// is capped at it, so the columns can never add up to more than the
// window -- widen one past the edge and you shrink another first, which
// is the price of "one drag moves one edge".
//
// The one time widths change on their own is a window too narrow for
// them (dragged wide, then the window pulled in): everything scales down
// to fit rather than overflowing off the edge.
//
// Last modified: 2026-09-18--1930

import 'package:flutter/widgets.dart';

/// A column in the library (non-playlist) track list, in display order.
///
/// Everything is right-aligned except Time, and Time, Date and Path
/// start at [kMinColumnWidth] -- both asked for directly (2026-09-19).
/// A column too narrow for its value shows an ellipsis; double-clicking
/// its divider fits it in one gesture.
enum TrackColumn {
  title('Title', width: 230, hideable: false, alignEnd: true),
  artist('Artist', width: 150, alignEnd: true),
  album('Album', width: 150, alignEnd: true),
  time('Time', width: kMinColumnWidth),
  date('Date', width: kMinColumnWidth, alignEnd: true),
  // The two tick columns: at-a-glance state, not data to read, and
  // nothing about them gets better with more room -- so they are fixed
  // and not draggable.
  art('Art', width: 34, resizable: false, alignEnd: true),
  emb('Emb', width: 34, resizable: false, alignEnd: true),
  // Last on purpose: the widest thing in the row and the least often
  // read, so it goes where it cannot push the columns you actually scan
  // off to the side.
  path('Path', width: kMinColumnWidth, alignEnd: true);

  const TrackColumn(
    this.label, {
    required this.width,
    this.hideable = true,
    this.resizable = true,
    this.alignEnd = false,
  });

  /// What the header and its menu call it.
  final String label;

  /// Default width in pixels, before the user drags anything.
  final double width;

  /// Whether the header menu offers to hide it. Title is not hideable: a
  /// row with no title is not a row.
  final bool hideable;

  /// Whether its right edge is a grab handle.
  final bool resizable;

  final bool alignEnd;

  /// The stored id, so a renamed label never invalidates a saved choice.
  String get id => name;

  static TrackColumn? byId(String id) {
    for (final c in TrackColumn.values) {
      if (c.id == id) return c;
    }
    return null; // an id from a newer build: ignored, not fatal
  }

  static List<TrackColumn> get hideableColumns => [
    for (final c in values)
      if (c.hideable) c,
  ];
}

/// Smallest a column may be dragged to. Below this a header label is a
/// couple of ellipsised characters and the column stops meaning anything.
const double kMinColumnWidth = 28;

/// Space between two columns -- and, in the header, the width of the
/// grab area that resizes the one on its left.
///
/// 14, not the 8 it started at: a divider you have to hit is a target,
/// and 8px between two clickable header labels was too fine to find
/// (reported -- Album's edge in particular, where the label is short
/// and the column wide, so the obvious place to aim was still inside
/// the cell and sorted instead).
const double kColumnGap = 14;

/// The hairline drawn down the middle of that gap: what makes the grab
/// target visible at all. Soft on purpose -- it marks a boundary, it is
/// not a table border.
const double kColumnDividerWidth = 1;

/// What the user has done to the columns: hidden some, resized others.
@immutable
class TrackColumnLayout {
  final Set<TrackColumn> hidden;

  /// Width overrides by column; absent means [TrackColumn.width].
  final Map<TrackColumn, double> sizes;

  const TrackColumnLayout({this.hidden = const {}, this.sizes = const {}});

  bool shows(TrackColumn c) => !hidden.contains(c);

  List<TrackColumn> get visible => [
    for (final c in TrackColumn.values)
      if (shows(c)) c,
  ];

  /// [c]'s width: what the user dragged it to, or its default.
  ///
  /// A stored value below [kMinColumnWidth] is treated as absent, not
  /// obeyed. +33 stored flex WEIGHTS in this same field -- numbers like
  /// 1.64 -- and +34 changed them to mean pixels, so the first launch
  /// after that upgrade rendered Title and Artist 1.6px wide: present,
  /// checked in the menu, and invisible. Reported live.
  double widthOf(TrackColumn c) {
    final stored = sizes[c];
    return (stored == null || stored < kMinColumnWidth) ? c.width : stored;
  }

  /// Total the visible columns want, gaps included -- one gap after
  /// EVERY column, the last one included, because the header puts its
  /// grab handle there and the rows leave the same space blank.
  double get totalWidth {
    final cols = visible;
    if (cols.isEmpty) return 0;
    var total = cols.length * kColumnGap;
    for (final c in cols) {
      total += widthOf(c);
    }
    return total;
  }

  /// The widths to lay out in [available] pixels.
  ///
  /// The stored widths, which is the point -- dragging one column must
  /// not move the others. Scaled down proportionally ONLY when they no
  /// longer fit, so a window pulled in narrow clips nothing.
  Map<TrackColumn, double> widthsFor(double available) {
    final cols = visible;
    final wanted = totalWidth;
    final gaps = cols.length * kColumnGap;
    final scale = (wanted > available && wanted > gaps && available > gaps)
        ? (available - gaps) / (wanted - gaps)
        : 1.0;
    return {for (final c in cols) c: widthOf(c) * scale};
  }

  /// The most [column] may be dragged to: its own width plus whatever
  /// slack is left over at the right. Capping here is what stops a drag
  /// from pushing the table wider than the window.
  double maxWidthFor(TrackColumn column, double available) {
    // [totalWidth] counts a stretching last column at its own width,
    // not at the space it is currently filling -- so the slack here is
    // exactly what that column would give back.
    final slack = available - totalWidth;
    final max = widthOf(column) + (slack > 0 ? slack : 0);
    return max < kMinColumnWidth ? kMinColumnWidth : max;
  }
}

/// Lays the visible columns out as Row children at [widths], with
/// [kColumnGap] between them.
///
/// The single place the header and the rows agree on geometry. [cell]
/// builds the content; [gapAfter] lets the header put a drag handle in
/// the gap where a row just leaves blank space of the same width.
List<Widget> buildColumnRow({
  required TrackColumnLayout layout,
  required Map<TrackColumn, double> widths,
  required Widget Function(TrackColumn column) cell,
  Widget Function(TrackColumn column)? gapAfter,
}) {
  final columns = layout.visible;
  final out = <Widget>[];
  for (var i = 0; i < columns.length; i++) {
    final c = columns[i];
    out.add(SizedBox(width: widths[c] ?? c.width, child: cell(c)));
    // A gap after EVERY column, the last one included: that is where
    // the header hangs its grab handle, and without it the rightmost
    // column would be the one thing on the table that cannot be
    // resized -- with Path last and stretching, the column most worth
    // pinning to a width. The rows leave the same space blank so the
    // two stay aligned.
    out.add(gapAfter?.call(c) ?? const SizedBox(width: kColumnGap));
  }
  return out;
}
