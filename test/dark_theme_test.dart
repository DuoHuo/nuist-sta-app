// 深色模式：色板完整性、主题装配、以及页面在深色下真的取到深色色值。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/shell/profile/profile_list_tile.dart';
import 'package:nuist_sta_app/shell/profile/user_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

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

  _timetableDarkTests();
}

// ---------------------------------------------------------------------------
// 课表深色（spec-next-1019 item 12）：构造数据，不读真实样例。

const _darkBase = Color(0xFF121316);
final _tt = TimetableController.instance;

Course _ttCourse(
  String id,
  String name, {
  String weeks = '11111111111111111111',
  int day = 1,
}) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: [
    CourseSlot(
      day: day,
      startNode: 1,
      endNode: 2,
      weeks: weeks,
      location: '测试楼 A101',
      teacher: '张老师',
    ),
  ],
);

void _ttLoad(List<Course> manual, {int cellOpacity = 100}) {
  _tt.debugSetSnapshot(
    TimetableSnapshot(
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: DateTime(2026, 8, 31),
        cellOpacity: cellOpacity,
        showNonCurrentWeek: true,
      ),
    ),
    viewingWeek: 7,
    manualCourses: manual,
  );
}

Future<void> _ttIo(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _pumpDark(
  WidgetTester tester,
  Widget home, {
  double width = 400,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appDarkTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    ),
  );
  await _ttIo(tester);
}

void _timetableDarkTests() {
  group('课表深色（item 12）', () {
    late Directory tmp;
    final origClock = TimetableController.clock;
    final origBinding = TimetableController.bindingCheck;
    final origFetch = TimetableController.fetchSnapshot;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_dark');
      TimetableStore.debugDirectory = tmp;
      _tt.debugReset();
      TimetableController.bindingCheck = () async => false;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline (test)');
      TimetableController.clock = () => DateTime(2026, 10, 12, 9);
    });
    tearDown(() {
      TimetableController.clock = origClock;
      TimetableController.bindingCheck = origBinding;
      TimetableController.fetchSnapshot = origFetch;
      TimetableStore.debugDirectory = null;
      _tt.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('DK01 非本周 / 页面 / 卡片直接用上游 TimetableColors.dark', () {
      final d = TimetableColors.dark;
      expect(d.offWeekBg, const Color(0xFF22242A));
      expect(d.offWeekBorder, const Color(0xFF3A3D45));
      expect(d.offWeekText, const Color(0xFF9CA3AF));
      expect(d.pageBg, _darkBase);
    });

    test('DK02 色板 A 16 色：深色格 = 深字色往 #121316 混 45%，字 = 浅底色，对比度 ≥ 4.5', () {
      final pairs = TimetableTheme.pairsOf(CoursePaletteScheme.soft);
      expect(pairs, hasLength(16));
      for (var i = 0; i < pairs.length; i++) {
        final p = pairs[i];
        final d = TimetableTheme.coursePair(
          i,
          scheme: CoursePaletteScheme.soft,
          dark: true,
        );
        expect(d.bg, Color.lerp(p.fg, _darkBase, 0.45));
        expect(d.fg, p.bg);
        expect(
          _contrast(d.fg, d.bg),
          greaterThanOrEqualTo(4.5),
          reason: '色号 $i',
        );
        // 浅色不变。
        final l = TimetableTheme.coursePair(
          i,
          scheme: CoursePaletteScheme.soft,
        );
        expect(
          l.bg,
          TimetableTheme.courseColor(i, scheme: CoursePaletteScheme.soft),
        );
        expect(
          l.fg,
          TimetableTheme.courseTextColor(i, scheme: CoursePaletteScheme.soft),
        );
      }
    });

    test('DK03 不透明度：深色往 #121316 混，浅色不变', () {
      const c = Color(0xFF3366CC);
      expect(
        TimetableTheme.blendCellBg(c, 50, dark: true),
        Color.lerp(_darkBase, c, 0.5),
      );
      expect(
        TimetableTheme.blendCellBg(c, 50),
        Color.lerp(TimetableTheme.pageBg, c, 0.5),
      );
      expect(TimetableTheme.blendCellBg(c, 100, dark: true), c);
    });

    test('DK04 考试格：深色往 #121316 混 25%（含自定义色），浅色原样', () {
      for (final exam in [
        TimetableTheme.examDefault,
        const Color(0xFF00695C),
      ]) {
        expect(
          TimetableTheme.examCellBg(exam, dark: true),
          Color.lerp(exam, _darkBase, 0.25),
        );
        expect(TimetableTheme.examCellBg(exam), exam);
        expect(
          _contrast(
            TimetableTheme.examText,
            TimetableTheme.examCellBg(exam, dark: true),
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    testWidgets('DK05 周视图深色：课程格深底浅字（按不透明度往 #121316 混）、非本周格用 offWeek 深色值', (
      tester,
    ) async {
      final on = _ttCourse('a', '测试课甲');
      final off = _ttCourse('b', '测试课乙', day: 2, weeks: '00000000100000000000');
      _ttLoad([on, off], cellOpacity: 70);
      await _pumpDark(
        tester,
        Scaffold(body: WeekGrid(week: 7, controller: _tt)),
      );
      expect(tester.takeException(), isNull);
      final pair = TimetableTheme.coursePair(
        courseColorIndex(_tt, on),
        scheme: coursePaletteSchemeFor(_tt),
        dark: true,
      );
      Color? cellBg(String name) =>
          (tester
                      .widget<Ink>(
                        find.descendant(
                          of: find.widgetWithText(CourseCell, name),
                          matching: find.byType(Ink),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;
      expect(
        cellBg('测试课甲'),
        TimetableTheme.blendCellBg(pair.bg, 70, dark: true),
      );
      final texts = tester.widgetList<Text>(
        find.descendant(
          of: find.widgetWithText(CourseCell, '测试课甲'),
          matching: find.byType(Text),
        ),
      );
      expect(texts.any((t) => t.style?.color == pair.fg), isTrue);
      expect(cellBg('测试课乙'), TimetableColors.dark.offWeekBg);
    });

    testWidgets('DK06 考试格深色：考试色往 #121316 混 25%、白字', (tester) async {
      _ttLoad([_ttCourse('a', '测试课甲')]);
      await tester.runAsync(
        () => _tt.addScheduleEvent(
          ScheduleEvent(
            id: '',
            kind: ScheduleKind.exam,
            source: ScheduleSource.manual,
            title: '测试考试',
            date: DateTime(2026, 10, 13),
            start: const TimeOfDayMinutes(10, 10),
            end: const TimeOfDayMinutes(11, 50),
            location: '测试楼 A101',
          ),
        ),
      );
      await _pumpDark(
        tester,
        Scaffold(body: WeekGrid(week: 7, controller: _tt)),
      );
      final id = _tt.scheduleEvents.first.id;
      final ink = tester.widget<Ink>(
        find.descendant(
          of: find.byKey(Key('schedule_cell_$id')),
          matching: find.byType(Ink),
        ),
      );
      expect(
        (ink.decoration! as BoxDecoration).color,
        TimetableTheme.examCellBg(Color(_tt.settings.examColor), dark: true),
      );
    });

    testWidgets('DK07 课表页 / 详情面板深色：页面底、面色取深色，不溢出', (tester) async {
      _ttLoad([_ttCourse('a', '测试课甲')]);
      await _pumpDark(tester, const TimetablePage());
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        TimetableColors.dark.pageBg,
      );
      await tester.tap(find.widgetWithText(CourseCell, '测试课甲'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('测试楼 A101'), findsWidgets);
      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .any(
              (d) =>
                  d.decoration is BoxDecoration &&
                  (d.decoration as BoxDecoration).color ==
                      TimetableColors.dark.surface,
            ),
        isTrue,
      );
    });

    testWidgets('DK08 设置页深色：页面底取深色、分组面色取深色，不溢出', (tester) async {
      _ttLoad([_ttCourse('a', '测试课甲')]);
      await _pumpDark(
        tester,
        TimetableSettingsPage(controller: _tt, onOpenAccount: () async {}),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        TimetableColors.dark.pageBg,
      );
      expect(
        find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).style?.color)
            .contains(TimetableTheme.titleText),
        isFalse,
      );
    });

    testWidgets('DK09 首页卡片深色（上课中、320dp、textScaler 1.3）：面色深色、不溢出', (
      tester,
    ) async {
      _ttLoad([_ttCourse('a', '测试课甲')]);
      final now = DateTime(2026, 10, 12, 9);
      await _pumpDark(
        tester,
        Scaffold(
          body: SingleChildScrollView(child: TimetableHomeCard(now: () => now)),
        ),
        width: 320,
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
      final card = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(TimetableHomeCard),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.color, TimetableColors.dark.surface);
      expect(find.byKey(const Key('home_course_remaining')), findsOneWidget);
    });
  });
}
