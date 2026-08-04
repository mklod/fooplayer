// Last modified: 2026-08-04--0340
import 'package:flutter/material.dart';
import '../app_theme.dart';

/// One metro-style PNG glyph for the phone player surfaces.
///
/// Public sibling of the desktop bar's private `_MetroIcon` (see
/// `now_playing_bar.dart`). Duplicated (rather than making the desktop one
/// public) so the phone branch leaves desktop files byte-identical.
///
/// The source PNGs are baked INK-DARK (measured ~#1D1D1F, same as
/// [AppColors.ink]) glyphs on transparency -- NOT white, as this doc once
/// claimed; that error shipped the Now Playing transport as near-invisible
/// black-on-dark. Null [color] renders that baked-in dark, which is right
/// for light surfaces (the mini player); any dark surface MUST pass an
/// explicit white tint.
class MetroIcon extends StatelessWidget {
  final String asset;
  final double size;

  /// Optional runtime tint (srcIn repaint of every opaque pixel). Null (the
  /// default) applies no filter: the PNG's own baked-in ink-dark shows,
  /// which suits light backgrounds only -- see the class doc.
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
