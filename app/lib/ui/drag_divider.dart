import 'package:flutter/material.dart';
import 'app_theme.dart';

/// A thin, mouse-draggable vertical divider used to resize a horizontally
/// adjacent panel (e.g. the sidebar).
///
/// Reports each incremental horizontal pan delta via [onDragDelta]; this
/// widget holds no size state itself -- the caller (typically backed by a
/// [ChangeNotifier] like `LayoutPrefs`) owns the actual width and decides
/// how to clamp/apply the delta.
///
/// The hit target is [hitWidth] (6px) wide -- much easier to grab than the
/// 1px hairline it paints centered within that width -- and the cursor
/// becomes [SystemMouseCursors.resizeColumn] while hovering.
class VerticalDragDivider extends StatelessWidget {
  static const double hitWidth = 6;

  final ValueChanged<double> onDragDelta;

  const VerticalDragDivider({super.key, required this.onDragDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onDragDelta(details.delta.dx),
        child: SizedBox(
          width: hitWidth,
          child: Center(
            child: Container(width: 1, color: AppColors.hairline),
          ),
        ),
      ),
    );
  }
}

/// A thin, mouse-draggable horizontal divider used to resize a vertically
/// adjacent panel (e.g. the filter row).
///
/// Mirrors [VerticalDragDivider] on the other axis: reports each
/// incremental vertical pan delta via [onDragDelta], hit target is
/// [hitHeight] (6px) tall, cursor is [SystemMouseCursors.resizeRow].
class HorizontalDragDivider extends StatelessWidget {
  static const double hitHeight = 6;

  final ValueChanged<double> onDragDelta;

  const HorizontalDragDivider({super.key, required this.onDragDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onDragDelta(details.delta.dy),
        child: SizedBox(
          height: hitHeight,
          child: Center(
            child: Container(height: 1, color: AppColors.hairline),
          ),
        ),
      ),
    );
  }
}
