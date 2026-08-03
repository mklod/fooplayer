// Last modified: 2026-08-02--2327
import 'package:flutter/material.dart';
import '../app_theme.dart';

/// One metro-style PNG glyph for the phone player surfaces, tinted to be
/// visible on light backgrounds.
///
/// Public sibling of the desktop bar's private `_MetroIcon` (see
/// `now_playing_bar.dart`): the source PNGs are WHITE glyphs on transparency,
/// so the srcIn [ColorFilter] repaints every opaque pixel [AppColors.ink].
/// Duplicated (rather than making the desktop one public) so the phone
/// branch leaves desktop files byte-identical.
class MetroIcon extends StatelessWidget {
  final String asset;
  final double size;

  /// Optional runtime tint (Now Playing reskin: shuffle needs the app's
  /// blue accent when active, and a dimmer white when off). Null (the
  /// default) is byte-identical to the original widget -- no filter is
  /// applied and every existing call site keeps rendering the PNG's own
  /// baked-in white exactly as before.
  final Color? color;

  const MetroIcon(this.asset, {super.key, this.size = 26, this.color});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      color: color,
      // Only pay for the srcIn saveLayer (and its documented SwiftShader
      // hairline risk on emulators) when a caller actually asked for a
      // tint; every untinted glyph keeps the baked-in-PNG fast path.
      colorBlendMode: color == null ? null : BlendMode.srcIn,
      filterQuality: FilterQuality.medium,
    );
  }
}
