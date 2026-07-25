// Last modified: 2026-07-24--1835
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
  const MetroIcon(this.asset, {super.key, this.size = 26});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      color: AppColors.ink,
      colorBlendMode: BlendMode.srcIn,
      filterQuality: FilterQuality.medium,
    );
  }
}
