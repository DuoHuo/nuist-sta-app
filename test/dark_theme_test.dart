// 深色模式：色板完整性、主题装配、以及页面在深色下真的取到深色色值。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/shell/profile/profile_list_tile.dart';
import 'package:nuist_sta_app/shell/profile/user_card.dart';

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
  group('色板', () {
    test('浅色与深色色板的每个字段都不同值（除刻意共用的 tabInactive）', () {
      final light = AppPalette.light;
      final dark = AppPalette.dark;

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);

      // 逐字段比对：漏配一个深色值就会在这里暴露。
      expect(dark.pageBg, isNot(light.pageBg));
      expect(dark.surface, isNot(light.surface));
      expect(dark.titleText, isNot(light.titleText));
      expect(dark.labelText, isNot(light.labelText));
      expect(dark.rowDivider, isNot(light.rowDivider));
      expect(dark.accent, isNot(light.accent));
      expect(dark.divider, isNot(light.divider));
      expect(dark.chevron, isNot(light.chevron));
      expect(dark.success, isNot(light.success));
      expect(dark.warning, isNot(light.warning));
      expect(dark.danger, isNot(light.danger));
    });

    test('深色色板的面色比浅色暗、文字比浅色亮', () {
      expect(
        _relativeLuminance(AppPalette.dark.pageBg),
        lessThan(_relativeLuminance(AppPalette.light.pageBg)),
      );
      expect(
        _relativeLuminance(AppPalette.dark.surface),
        lessThan(_relativeLuminance(AppPalette.light.surface)),
      );
      expect(
        _relativeLuminance(AppPalette.dark.titleText),
        greaterThan(_relativeLuminance(AppPalette.light.titleText)),
      );
    });

    test('主文字与面色的对比度不低于 WCAG AA 的 4.5', () {
      for (final palette in [AppPalette.light, AppPalette.dark]) {
        final reason = '${palette.brightness} 下主文字对比度不足';
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
      }
    });

    test('次级文字与面色的对比度不低于 3（大字/辅助文本档）', () {
      for (final palette in [AppPalette.light, AppPalette.dark]) {
        expect(
          _contrast(palette.labelText, palette.surface),
          greaterThanOrEqualTo(3.0),
          reason: '${palette.brightness} 下次级文字对比度不足',
        );
      }
    });

    test('forBrightness 与 copyWith / lerp 行为正确', () {
      expect(AppPalette.forBrightness(Brightness.light), AppPalette.light);
      expect(AppPalette.forBrightness(Brightness.dark), AppPalette.dark);

      final tweaked = AppPalette.light.copyWith(
        accent: const Color(0xFF123456),
      );
      expect(tweaked.accent, const Color(0xFF123456));
      // 没传的字段保持原值。
      expect(tweaked.titleText, AppPalette.light.titleText);

      // t=0 取自身、t=1 取对端。
      final at0 = AppPalette.light.lerp(AppPalette.dark, 0);
      final at1 = AppPalette.light.lerp(AppPalette.dark, 1);
      expect(at0.pageBg, AppPalette.light.pageBg);
      expect(at1.pageBg, AppPalette.dark.pageBg);
      // other 为 null 时原样返回，不抛。
      expect(AppPalette.light.lerp(null, 0.5), AppPalette.light);
    });
  });

  group('主题装配', () {
    test('两套主题都挂上了对应的色板扩展', () {
      final light = appLightTheme();
      final dark = appDarkTheme();

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.extension<AppPalette>(), AppPalette.light);
      expect(dark.extension<AppPalette>(), AppPalette.dark);
    });

    test('品牌色没有被 M3 seed 算法改掉', () {
      expect(appLightTheme().colorScheme.primary, AppColors.accent);
      expect(appDarkTheme().colorScheme.primary, AppColorsDark.accent);
    });

    test('页面底色、顶栏底色随主题切换', () {
      expect(appLightTheme().scaffoldBackgroundColor, AppPalette.light.pageBg);
      expect(appDarkTheme().scaffoldBackgroundColor, AppPalette.dark.pageBg);
      expect(
        appLightTheme().appBarTheme.backgroundColor,
        AppPalette.light.surface,
      );
      expect(
        appDarkTheme().appBarTheme.backgroundColor,
        AppPalette.dark.surface,
      );
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

  group('页面在深色下的实际取色', () {
    testWidgets('「我的」页入口行的文字与箭头取深色值', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(
            body: ProfileListTile(
              tile: const ProfileTile(icon: Icons.settings, label: '设置'),
              showDivider: true,
              onTap: () {},
            ),
          ),
        ),
      );

      final label = tester.widget<Text>(find.text('设置'));
      expect(label.style?.color, AppPalette.dark.titleText);

      final chevron = tester.widget<Icon>(find.byIcon(Icons.chevron_right));
      expect(chevron.color, AppPalette.dark.chevron);
      // 浅色下那个更淡的设计稿值不该出现在深色里。
      expect(chevron.color, isNot(AppColors.chevron));
    });

    testWidgets('门户状态卡在深色下用深色面色，强调色圆底上的图标仍为白', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(
            body: PortalStatusCard(
              bound: true,
              maskedStudentId: '2025****0001',
              revoked: false,
              onTap: () {},
            ),
          ),
        ),
      );

      final card = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(PortalStatusCard),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.color, AppPalette.dark.surface);

      // 白色图标压在 accent 实心圆上，底色不随主题变，应保持白色。
      final icon = tester.widget<Icon>(find.byIcon(Icons.verified_user));
      expect(icon.color, Colors.white);
    });
  });
}
