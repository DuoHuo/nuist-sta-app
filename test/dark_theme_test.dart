// 深色模式色板、WCAG 对比度与主题解析。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_snack_bar.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

/// WCAG 相对亮度。
double _relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// 两色对比度（WCAG，1..21）。
double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('底部提示布局', () {
    testWidgets('深色窄屏大字带键盘：文字与操作同排且可点击且对比度达标', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 220),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: Scaffold(
            bottomNavigationBar: const SizedBox(height: 64),
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  AppSnackBar(
                    content: const Text('登录已过期，请重新登录后继续同步'),
                    tone: AppSnackBarTone.warning,
                    persist: false,
                    action: SnackBarAction(
                      label: '重新登录',
                      onPressed: () => calls++,
                    ),
                  ),
                ),
                child: const Text('显示提示'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('显示提示'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final barContext = tester.element(find.byType(SnackBar));
      final theme = Theme.of(barContext).snackBarTheme;
      const palette = AppPalette.dark;
      expect(theme.backgroundColor, palette.surface);
      expect(
        _contrast(theme.contentTextStyle!.color!, palette.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(
          theme.actionTextColor!,
          Color.alphaBlend(theme.actionBackgroundColor!, palette.surface),
        ),
        greaterThanOrEqualTo(4.5),
      );
      await tester.tap(find.text('重新登录'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('色板与主题契约', () {
    test('深浅色板明暗方向、亮度层级与对比度均符合 WCAG 契约', () {
      final light = AppPalette.light;
      final dark = AppPalette.dark;

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);
      expect(
        _relativeLuminance(dark.pageBg),
        lessThan(_relativeLuminance(light.pageBg)),
      );
      expect(
        _relativeLuminance(dark.surface),
        lessThan(_relativeLuminance(light.surface)),
      );
      expect(
        _relativeLuminance(dark.titleText),
        greaterThan(_relativeLuminance(light.titleText)),
      );

      for (final palette in [light, dark]) {
        final reason = '${palette.brightness} 下文字对比度不足';
        expect(
          _contrast(palette.titleText, palette.surface),
          greaterThanOrEqualTo(4.5),
          reason: reason,
        );
        expect(
          _contrast(palette.titleText, palette.pageBg),
          greaterThanOrEqualTo(4.5),
          reason: reason,
        );
        expect(
          _contrast(palette.labelText, palette.surface),
          greaterThanOrEqualTo(3.0),
          reason: reason,
        );
      }

      expect(AppPalette.forBrightness(Brightness.light), light);
      expect(AppPalette.forBrightness(Brightness.dark), dark);
      final tweaked = light.copyWith(accent: const Color(0xFF123456));
      expect(tweaked.accent, const Color(0xFF123456));
      expect(tweaked.titleText, light.titleText);
      expect(light.lerp(dark, 0).pageBg, light.pageBg);
      expect(light.lerp(dark, 1).pageBg, dark.pageBg);
      expect(light.lerp(null, 0.5), light);
    });

    test('两套主题挂载对应色板扩展且保留品牌主色', () {
      final light = appLightTheme();
      final dark = appDarkTheme();

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.extension<AppPalette>(), AppPalette.light);
      expect(dark.extension<AppPalette>(), AppPalette.dark);
      expect(light.colorScheme.primary, AppColors.accent);
      expect(dark.colorScheme.primary, AppColorsDark.accent);
    });
  });

  group('取色入口', () {
    testWidgets('AppPalette.of 在深色主题下返回深色色板', (tester) async {
      late AppPalette captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Builder(
            builder: (context) {
              captured = AppPalette.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, AppPalette.dark);
    });

    testWidgets('没有挂扩展时退化成浅色而不抛异常', (tester) async {
      late AppPalette captured;
      await tester.pumpWidget(
        MaterialApp(
          // 故意用不带 extension 的裸主题。
          theme: ThemeData(useMaterial3: true),
          home: Builder(
            builder: (context) {
              captured = AppPalette.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, AppPalette.light);
      expect(tester.takeException(), isNull);
    });
  });

  _timetablePaletteTests();
}

void _timetablePaletteTests() {
  group('课表深色色板契约', () {
    test('深色课程与考试格对比度达标，非本周色不与任意配色板冲突', () {
      final softPairs = TimetableTheme.pairsOf(CoursePaletteScheme.soft);
      expect(softPairs, hasLength(16));
      for (var i = 0; i < softPairs.length; i++) {
        final d = TimetableTheme.coursePair(
          i,
          scheme: CoursePaletteScheme.soft,
          dark: true,
        );
        expect(
          _contrast(d.fg, d.bg),
          greaterThanOrEqualTo(7.0),
          reason: '色号 $i',
        );
      }

      for (final exam in [
        TimetableTheme.examDefault,
        const Color(0xFF00695C),
      ]) {
        expect(
          _contrast(
            TimetableTheme.examText,
            TimetableTheme.examCellBg(exam, dark: true),
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _relativeLuminance(TimetableTheme.examCellBg(exam, dark: true)),
          lessThan(_relativeLuminance(TimetableTheme.examCellBg(exam))),
        );
      }

      const sample = Color(0xFF3366CC);
      expect(
        _relativeLuminance(TimetableTheme.blendCellBg(sample, 50, dark: true)),
        lessThan(_relativeLuminance(TimetableTheme.blendCellBg(sample, 50))),
      );
      expect(TimetableTheme.blendCellBg(sample, 100, dark: true), sample);

      expect(
        _contrast(TimetableTheme.offWeekText, TimetableTheme.offWeekBg),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(
          TimetableColors.dark.offWeekText,
          TimetableColors.dark.offWeekBg,
        ),
        greaterThanOrEqualTo(4.5),
      );
      for (final scheme in CoursePaletteScheme.values) {
        final pairs = TimetableTheme.pairsOf(scheme);
        expect(pairs.length, 16);
        for (final p in pairs) {
          expect(p.bg, isNot(TimetableTheme.offWeekBg), reason: '$scheme');
          expect(p.fg, isNot(TimetableTheme.offWeekText), reason: '$scheme');
        }
      }
    });
  });
}
