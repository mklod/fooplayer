// Dark mode's mechanism: setAppBrightness swaps AppColors' mutable statics
// in place (see AppColors' doc for why mutation over Theme lookups), and
// buildAppTheme rebuilt afterwards reflects the active palette. Every test
// here restores light mode -- the statics are process-global and the rest
// of the suite assumes the light defaults.
//
// Last modified: 2026-08-05--0031
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

void main() {
  tearDown(() => setAppBrightness(Brightness.light));

  test('setAppBrightness(dark) swaps every token and flags isDark', () {
    final lightInk = AppColors.ink;
    final lightBg = AppColors.windowBg;

    setAppBrightness(Brightness.dark);
    expect(AppColors.isDark, isTrue);
    expect(AppColors.ink, isNot(lightInk));
    expect(AppColors.windowBg, isNot(lightBg));
    // Ink must be LIGHT on the dark background.
    expect(AppColors.ink.computeLuminance(),
        greaterThan(AppColors.windowBg.computeLuminance()));
    // The accent survives unchanged -- the one splash of color is shared.
    expect(AppColors.accent, const Color(0xFF0A84FF));

    setAppBrightness(Brightness.light);
    expect(AppColors.isDark, isFalse);
    expect(AppColors.ink, lightInk);
    expect(AppColors.windowBg, lightBg);
  });

  test('buildAppTheme built after the switch reflects the palette', () {
    setAppBrightness(Brightness.dark);
    final dark = buildAppTheme();
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, AppColors.windowBg);
    expect(dark.textTheme.bodyMedium?.color, AppColors.ink);

    setAppBrightness(Brightness.light);
    final light = buildAppTheme();
    expect(light.colorScheme.brightness, Brightness.light);
    expect(
      light.scaffoldBackgroundColor.computeLuminance(),
      greaterThan(dark.scaffoldBackgroundColor.computeLuminance()),
    );
  });

  test('resolveDarkPreference: explicit wins everywhere, system is '
      'Android-only', () {
    expect(resolveDarkPreference('dark', Brightness.light, isAndroid: false),
        isTrue);
    expect(resolveDarkPreference('light', Brightness.dark, isAndroid: true),
        isFalse);
    expect(resolveDarkPreference('system', Brightness.dark, isAndroid: true),
        isTrue);
    expect(resolveDarkPreference('system', Brightness.light, isAndroid: true),
        isFalse);
    // Desktop 'system' never goes dark -- its OS integration isn't wired.
    expect(resolveDarkPreference('system', Brightness.dark, isAndroid: false),
        isFalse);
  });

  testWidgets('the settings picker writes themePreference', (tester) async {
    addTearDown(() => themePreference.value = 'system');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: ThemePreferencePicker()),
      ),
    );
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(themePreference.value, 'dark');
    await tester.tap(find.text('System'));
    await tester.pump();
    expect(themePreference.value, 'system');
  });
}
