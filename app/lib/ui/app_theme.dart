import 'package:flutter/material.dart';

/// Central design tokens for the iTunes-style light theme.
///
/// Every color used anywhere in the UI must come from here (or from
/// `Theme.of(context)` component themes built with these tokens in
/// [buildAppTheme]) -- no widget should hardcode a `Color(...)` or reach for
/// a dark-theme-assuming `Colors.*` shade. Clean Apple/iTunes white-and-grey,
/// dense, no purple anywhere; the blue accent is used sparingly (selection,
/// the active slider track, the current-track title, links).
/// Corner radius shared by every dialog. See the dialogTheme below.
const double kDialogRadius = 8;

class AppColors {
  AppColors._();

  /// Main content background (track list, scaffold).
  static const windowBg = Color(0xFFFAFAFA);

  /// Sidebar and filter-panel background.
  static const panelBg = Color(0xFFF2F2F4);

  /// Now-playing bar background.
  static const barBg = Color(0xFFECECEE);

  /// Hairline dividers and the slider's inactive track.
  static const hairline = Color(0xFFD9D9DE);

  /// Primary text/icon color.
  static const ink = Color(0xFF1D1D1F);

  /// Secondary text (subtitles, dates, panel headers).
  static const inkSecondary = Color(0xFF6E6E73);

  /// The one splash of color: selection, active slider track, the
  /// currently-playing track's title, links. Used sparingly.
  static const accent = Color(0xFF0A84FF);

  /// Selected row/panel-entry fill -- paired with [ink] text, never
  /// white-on-blue.
  static const selectionFill = Color(0xFFDFEBFB);
}

/// Builds the app's single light theme from [AppColors].
///
/// Deliberately uses `ColorScheme.light(...)` with explicit token values --
/// never `ColorScheme.fromSeed`, which derives a tinted (purple-leaning)
/// Material 3 palette from a seed color and would reintroduce exactly the
/// look this theme exists to avoid.
/// [phone] scales the whole type ramp and densities up for a handheld
/// screen -- reported live: the desktop's iTunes-dense 13/11.5px ramp and
/// compact ListTiles, reused verbatim on the phone, read as "much too
/// small" everywhere (library rows, drawer, mini player). Desktop and
/// tablet (which uses the desktop panel layout) keep the dense ramp;
/// main.dart applies the phone variant through MaterialApp.builder so every
/// pushed route and dialog on a phone inherits it.
ThemeData buildAppTheme({bool phone = false}) {
  final double rowSize = phone ? 15 : 13;
  final double subSize = phone ? 13 : 11.5;
  final double labelSize = phone ? 12 : 11;
  const colorScheme = ColorScheme.light(
    brightness: Brightness.light,
    primary: AppColors.accent,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    onSecondary: Colors.white,
    error: Color(0xFFD70015),
    onError: Colors.white,
    surface: AppColors.windowBg,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.inkSecondary,
    surfaceContainerHighest: AppColors.panelBg,
    outline: AppColors.hairline,
    outlineVariant: AppColors.hairline,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    fontFamily: 'Segoe UI', // system default on Windows
  );

  final textTheme = base.textTheme.copyWith(
    // List rows (track titles, sidebar/filter entries): 13.
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontSize: rowSize,
      color: AppColors.ink,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: rowSize,
      color: AppColors.ink,
    ),
    // Subtitles (artist — album, dates): 11.5.
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: subSize,
      color: AppColors.inkSecondary,
    ),
    // Bar title / emphasized row title: 13 w600.
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: rowSize,
      fontWeight: FontWeight.w600,
      color: AppColors.ink,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: rowSize,
      fontWeight: FontWeight.w600,
      color: AppColors.ink,
    ),
    // Panel headers (Genre/Artist/Album): 11 w600 uppercase +0.4 tracking.
    // Widgets are responsible for upper-casing the label text itself; this
    // only fixes the type spec.
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: labelSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      color: AppColors.inkSecondary,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.windowBg,
    canvasColor: AppColors.windowBg,
    visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
    textTheme: textTheme,
    // Every dialog in the app gets the same corners. Material's default is
    // 28, at which a dialog reads as a phone sheet rather than a desktop
    // panel; the artwork picker had already been pulled back to 8 by hand
    // and everything else was still round, so they never matched.
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.windowBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
      ),
    ),
    dividerColor: AppColors.hairline,
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      dense: !phone,
      visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
      selectedTileColor: AppColors.selectionFill,
      selectedColor: AppColors.ink,
      iconColor: AppColors.inkSecondary,
      textColor: AppColors.ink,
      titleTextStyle: textTheme.bodyMedium,
      subtitleTextStyle: textTheme.bodySmall,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 2,
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.hairline,
      thumbColor: AppColors.accent,
      overlayColor: AppColors.accent.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 3),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      showValueIndicator: ShowValueIndicator.never,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.panelBg,
      hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.inkSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(AppColors.ink),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.ink.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return AppColors.ink.withValues(alpha: 0.06);
          }
          return null;
        }),
      ),
    ),
  );
}
