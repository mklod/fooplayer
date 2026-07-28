import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/ui/app_theme.dart';

void main() {
  test(
    'scaffold background and slider inactive track use the design tokens',
    () {
      final theme = buildAppTheme();
      expect(theme.scaffoldBackgroundColor, AppColors.windowBg);
      expect(theme.sliderTheme.inactiveTrackColor, AppColors.hairline);
    },
  );
}
