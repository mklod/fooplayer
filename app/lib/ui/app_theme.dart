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

/// One complete set of the app's design tokens. Two exist -- [_lightPalette]
/// (the original iTunes white/grey) and [_darkPalette] -- and
/// [setAppBrightness] copies the active one into [AppColors]' mutable
/// statics. See [AppColors]' doc for why mutation rather than Theme lookups.
class _AppPalette {
  final Color windowBg, panelBg, barBg, hairline;
  final Color ink, inkSecondary, accent, selectionFill;
  const _AppPalette({
    required this.windowBg,
    required this.panelBg,
    required this.barBg,
    required this.hairline,
    required this.ink,
    required this.inkSecondary,
    required this.accent,
    required this.selectionFill,
  });
}

const _lightPalette = _AppPalette(
  windowBg: Color(0xFFFAFAFA),
  panelBg: Color(0xFFF2F2F4),
  barBg: Color(0xFFECECEE),
  hairline: Color(0xFFD9D9DE),
  ink: Color(0xFF1D1D1F),
  inkSecondary: Color(0xFF6E6E73),
  accent: Color(0xFF0A84FF),
  selectionFill: Color(0xFFDFEBFB),
);

/// The same iTunes restraint, inverted: near-black surfaces stepped the
/// same way the light theme steps its greys, light ink, the SAME blue
/// accent, and a deep-blue selection fill that keeps light ink readable.
const _darkPalette = _AppPalette(
  windowBg: Color(0xFF1C1C1E),
  panelBg: Color(0xFF232326),
  barBg: Color(0xFF2A2A2D),
  hairline: Color(0xFF3A3A3E),
  ink: Color(0xFFF2F2F4),
  inkSecondary: Color(0xFF98989E),
  accent: Color(0xFF0A84FF),
  selectionFill: Color(0xFF16344F),
);

/// The active design tokens.
///
/// MUTABLE statics (not consts, not Theme lookups) as the dark-mode
/// mechanism: every widget file already references `AppColors.x` directly,
/// so swapping the values in place -- [setAppBrightness], called by the app
/// root before (re)building the tree -- re-skins everything without
/// threading a palette through dozens of constructors. The cost, paid
/// deliberately: these can no longer appear inside `const` expressions, and
/// a brightness change must rebuild the whole tree (which a theme change
/// forces anyway).
class AppColors {
  AppColors._();

  /// Main content background (track list, scaffold).
  static Color windowBg = _lightPalette.windowBg;

  /// Sidebar and filter-panel background.
  static Color panelBg = _lightPalette.panelBg;

  /// Now-playing bar background.
  static Color barBg = _lightPalette.barBg;

  /// Hairline dividers and the slider's inactive track.
  static Color hairline = _lightPalette.hairline;

  /// Primary text/icon color.
  static Color ink = _lightPalette.ink;

  /// Secondary text (subtitles, dates, panel headers).
  static Color inkSecondary = _lightPalette.inkSecondary;

  /// The one splash of color: selection, active slider track, the
  /// currently-playing track's title, links. Used sparingly.
  static Color accent = _lightPalette.accent;

  /// Selected row/panel-entry fill -- paired with [ink] text, never
  /// white-on-blue.
  static Color selectionFill = _lightPalette.selectionFill;

  /// Which palette is live -- for the few spots that branch on it
  /// (system status-bar icon brightness, mostly).
  static bool isDark = false;
}

/// Copies the palette for [brightness] into [AppColors]. Call BEFORE
/// building/rebuilding the widget tree (main.dart's App root does, keyed on
/// the platform brightness on Android; desktop stays light).
void setAppBrightness(Brightness brightness) {
  final p = brightness == Brightness.dark ? _darkPalette : _lightPalette;
  AppColors.windowBg = p.windowBg;
  AppColors.panelBg = p.panelBg;
  AppColors.barBg = p.barBg;
  AppColors.hairline = p.hairline;
  AppColors.ink = p.ink;
  AppColors.inkSecondary = p.inkSecondary;
  AppColors.accent = p.accent;
  AppColors.selectionFill = p.selectionFill;
  AppColors.isDark = brightness == Brightness.dark;
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
  final colorScheme = AppColors.isDark
      ? ColorScheme.dark(
          primary: AppColors.accent,
          onPrimary: Colors.white,
          secondary: AppColors.accent,
          onSecondary: Colors.white,
          // iOS's dark-mode system red -- the light theme's D70015 is too
          // dim against near-black surfaces.
          error: const Color(0xFFFF453A),
          onError: Colors.white,
          surface: AppColors.windowBg,
          onSurface: AppColors.ink,
          onSurfaceVariant: AppColors.inkSecondary,
          surfaceContainerHighest: AppColors.panelBg,
          outline: AppColors.hairline,
          outlineVariant: AppColors.hairline,
        )
      : ColorScheme.light(
          brightness: Brightness.light,
          primary: AppColors.accent,
          onPrimary: Colors.white,
          secondary: AppColors.accent,
          onSecondary: Colors.white,
          error: const Color(0xFFD70015),
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
    dividerTheme: DividerThemeData(
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
        borderSide: BorderSide(color: AppColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.accent, width: 1.5),
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
