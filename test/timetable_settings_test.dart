// 设置页 v0.4 卡片版、格子接设置、B/C 配色（spec §13.3–§13.7；用例 23 章 ST、CA16）。
// 全部为构造数据。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Color _hex(String h) => Color(int.parse('FF$h', radix: 16));

/// 找一个哈希色号为 [hash] 且大于 [after] 的「测试课…」课名（构造用，确定性）。
String _nameWithHash(int hash, {String after = ''}) {
  for (var i = 0; i < 100000; i++) {
    final n = '测试课$i';
    if (courseColorIndexForName(n) == hash && n.compareTo(after) > 0) return n;
  }
  throw StateError('no name');
}

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int? colorIndex,
}) => Course(
  id: id,
  name: name,
  colorIndex: colorIndex,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: '1' * 16,
      location: '测试楼A101',
      teacher: '教师A',
    ),
  ],
);

/// [dir] 下所有文件的 路径 → (内容, 修改时间)，用来断言「打开页面不回写」。
Map<String, (String, DateTime)> _filesIn(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>())
    f.path: (f.readAsStringSync(), f.lastModifiedSync()),
};

void main() {
  late Directory tmp;

  void load({TimetableSettings? settings, List<Course> manual = const []}) {
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings:
            settings ?? TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
      ),
      viewingWeek: 7,
      manualCourses: manual,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_settings_v2');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    load();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpPage(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: body));
    await tester.pump();
  }

  bool switchValue(WidgetTester tester, String key) => tester
      .widget<Switch>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Switch),
        ),
      )
      .value;

  bool chipSelected(WidgetTester tester, String groupKey, String label) =>
      tester
          .widget<ChoiceChip>(
            find.descendant(
              of: find.byKey(Key(groupKey)),
              matching: find.byKey(ValueKey('seg_$label')),
            ),
          )
          .selected;

  group('设置页', () {
    testWidgets('ST01 默认值', (tester) async {
      await pumpPage(
        tester,
        TimetableSettingsPage(controller: _c, showReminderCard: true),
      );
      expect(switchValue(tester, 'tt_settings_show_location'), isTrue);
      expect(switchValue(tester, 'tt_settings_show_teacher'), isFalse);
      expect(chipSelected(tester, 'tt_settings_font_scale', '标准'), isTrue);
      expect(chipSelected(tester, 'tt_settings_week_start', '周一'), isTrue);
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tt_settings_opacity_value')))
            .data,
        '100%',
      );
      // A/B/C 入口已隐藏（ST19）；默认方案仍为 A（存储）。
      expect(find.text('A 柔和'), findsNothing);
      expect(_c.settings.paletteScheme, 'A');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(switchValue(tester, 'tt_settings_reminder'), isFalse);
      expect(find.text('15 分钟'), findsOneWidget);
      expect(switchValue(tester, 'tt_settings_show_tomorrow'), isTrue);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('tt_settings_period_height_value')),
            )
            .data,
        '64',
      );
      // 提醒关着时「提前时间」整行置灰不可点。
      await tester.tap(
        find.byKey(const Key('tt_settings_reminder_lead')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_settings_lead_5')), findsNothing);
    });

    testWidgets('ST02 四张卡片、顺序、组内行；不出现未选的设置项', (tester) async {
      await pumpPage(
        tester,
        TimetableSettingsPage(controller: _c, showReminderCard: true),
      );
      // 六张卡片一屏放不下：拉高视口，让懒加载列表全部建出来。
      tester.view.physicalSize = const Size(1080, 6000);
      await tester.pump();
      final titles = ['显示', '外观', '提醒', '首页', '考试', '其他'];
      final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i] > ys[i - 1], isTrue, reason: titles[i]);
      }
      Finder inGroup(String g, String text) => find.descendant(
        of: find.byKey(Key('tt_settings_group_$g')),
        matching: find.text(text),
      );
      // §13.16 新名。
      for (final t in ['地点', '老师', '一周起始']) {
        expect(inGroup('display', t), findsOneWidget, reason: t);
      }
      // 「周日」仅剩「一周起始」选项；周六/非本周已迁入外观页。
      expect(inGroup('display', '周日'), findsOneWidget);
      expect(inGroup('display', '周六'), findsNothing);
      expect(inGroup('display', '非本周课程'), findsNothing);
      for (final t in ['配色与预览', '字号', '格子高度']) {
        expect(inGroup('appearance', t), findsOneWidget, reason: t);
      }
      for (final t in ['上课提醒', '提前时间', '放假期间也会提醒']) {
        expect(inGroup('reminder', t), findsOneWidget, reason: t);
      }
      expect(inGroup('home', '显示明天的课'), findsOneWidget);
      expect(inGroup('exam', '显示考试'), findsOneWidget);
      expect(inGroup('other', '教务账号'), findsOneWidget);
      expect(inGroup('other', '恢复教务课程'), findsOneWidget);
      for (final t in ['深色模式', '网格线', '背景', '圆角', '开学', '当前周']) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      // 行高 52、卡片圆角 12。
      expect(
        tester
            .getSize(find.byKey(const Key('tt_settings_show_location')))
            .height,
        52,
      );
      final card = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const Key('tt_settings_group_display')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.borderRadius, BorderRadius.circular(12));
      expect(card.color, Colors.white);
      // 小字 12sp。
      final hint = tester.widget<Text>(find.text('放假期间也会提醒'));
      expect(hint.style!.fontSize, 12);
    });

    testWidgets('ST02b 本版默认隐藏提醒：只有 显示→外观→首页 三张卡片，间距正常', (tester) async {
      expect(kShowReminderSettings, isFalse);
      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      expect(find.textContaining('提醒'), findsNothing);
      expect(find.text('放假期间也会提醒'), findsNothing);
      expect(find.text('提前时间'), findsNothing);
      for (final m in TimetableSettings.reminderLeadOptions) {
        expect(find.text('$m 分钟'), findsNothing, reason: '$m');
        expect(find.byKey(Key('tt_settings_lead_$m')), findsNothing);
      }
      expect(find.textContaining('分钟'), findsNothing);
      for (final k in [
        'tt_settings_group_reminder',
        'tt_settings_reminder',
        'tt_settings_reminder_hint',
        'tt_settings_reminder_lead',
      ]) {
        expect(find.byKey(Key(k)), findsNothing, reason: k);
      }
      final groups = [
        for (final g in ['display', 'appearance', 'home'])
          find.byKey(Key('tt_settings_group_$g')),
      ];
      for (final g in groups) {
        expect(g, findsOneWidget);
      }
      final titles = ['显示', '外观', '首页'];
      final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i] > ys[i - 1], isTrue, reason: titles[i]);
      }
      // 卡片紧挨着排（间距由每组自带的上边距给出），外观与首页之间没有空位。
      for (var i = 1; i < groups.length; i++) {
        expect(
          tester.getTopLeft(groups[i]).dy,
          tester.getBottomLeft(groups[i - 1]).dy,
          reason: titles[i],
        );
      }
      final gap1 =
          tester.getTopLeft(find.text('外观')).dy -
          tester.getBottomLeft(groups[0]).dy;
      final gap2 =
          tester.getTopLeft(find.text('首页')).dy -
          tester.getBottomLeft(groups[1]).dy;
      expect(gap2, gap1);
    });

    testWidgets('ST02c 存储里 reminderEnabled=true：默认页仍无提醒 UI，打开不回写', (
      tester,
    ) async {
      final stored = TimetableSettings(
        termStartDate: DateTime(2026, 8, 31),
        reminderEnabled: true,
        reminderLeadMinutes: 30,
      );
      await tester.runAsync(() => TimetableStore.saveSettings(stored));
      final read = (await tester.runAsync(TimetableStore.readSettings))!;
      expect(read.reminderEnabled, isTrue);
      load(settings: read);
      final before = _filesIn(tmp);
      expect(before, isNotEmpty);

      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      await settleIo(tester);
      expect(find.textContaining('提醒'), findsNothing);
      expect(find.text('放假期间也会提醒'), findsNothing);
      expect(find.textContaining('分钟'), findsNothing);
      expect(find.byKey(const Key('tt_settings_group_reminder')), findsNothing);
      expect(find.byKey(const Key('tt_settings_reminder')), findsNothing);
      expect(_c.settings.reminderEnabled, isTrue);
      expect(_c.settings.reminderLeadMinutes, 30);
      expect(_filesIn(tmp), before);
    });

    testWidgets('连点多个设置：每次读当前值合并，互不覆盖并持久化', (tester) async {
      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      await tester.tap(find.byKey(const Key('tt_settings_show_location')));
      await tester.tap(find.byKey(const Key('tt_settings_show_teacher')));
      await tester.tap(find.byKey(const Key('seg_大')));
      await tester.tap(find.byKey(const Key('seg_周日')));
      await tester.tap(find.byKey(const Key('tt_settings_show_tomorrow')));
      await settleIo(tester);
      final s = _c.settings;
      expect(s.showLocation, isFalse);
      expect(s.showTeacher, isTrue);
      expect(s.fontScale, CellFontScale.large);
      expect(s.weekStartsOnMonday, isFalse);
      expect(s.showTomorrowOnHome, isFalse);
      final stored = (await tester.runAsync(TimetableStore.readSettings))!;
      expect(stored.showLocation, isFalse);
      expect(stored.showTeacher, isTrue);
      expect(stored.fontScale, CellFontScale.large);
      expect(stored.weekStartsOnMonday, isFalse);
      expect(stored.showTomorrowOnHome, isFalse);
    });

    testWidgets('ST12 不透明度滑块 30–100、步长 10', (tester) async {
      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('tt_settings_opacity')),
      );
      expect((slider.min, slider.max, slider.divisions), (30.0, 100.0, 7));
      await tester.drag(
        find.byKey(const Key('tt_settings_opacity')),
        const Offset(-2000, 0),
      );
      // updateSettings 先 merge/save 再 notifyListeners，等标签刷新后再断言。
      String? opacityLabel() => tester
          .widget<Text>(find.byKey(const Key('tt_settings_opacity_value')))
          .data;
      for (var i = 0; i < 40 && opacityLabel() != '30%'; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_c.settings.cellOpacity, 30);
      expect(opacityLabel(), '30%');
    });

    testWidgets('ST12b 存储不透明度 55：读出保留 55，滑块/标签显示 55%，打开不回写', (tester) async {
      await tester.runAsync(
        () => TimetableStore.saveSettings(
          TimetableSettings(
            termStartDate: DateTime(2026, 8, 31),
            cellOpacity: 55,
          ),
        ),
      );
      final read = (await tester.runAsync(TimetableStore.readSettings))!;
      expect(read.cellOpacity, 55);
      load(settings: read);
      final before = _filesIn(tmp);

      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      await settleIo(tester);
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('tt_settings_opacity')),
      );
      expect(slider.value, 55.0);
      expect(slider.label, '55%');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tt_settings_opacity_value')))
            .data,
        '55%',
      );
      expect(find.text('50%'), findsNothing);
      expect(find.text('60%'), findsNothing);
      expect(_c.settings.cellOpacity, 55);
      expect(_filesIn(tmp), before);
      final again = (await tester.runAsync(TimetableStore.readSettings))!;
      expect(again.cellOpacity, 55);
    });

    testWidgets('提醒：开关后提前时间可选；接入点回调可让开关弹回', (tester) async {
      var calls = 0;
      await pumpPage(
        tester,
        TimetableSettingsPage(
          controller: _c,
          showReminderCard: true,
          onReminderToggle: (context, enable) async {
            calls++;
            return false; // 模拟权限被拒
          },
        ),
      );
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      expect(calls, 1);
      expect(_c.settings.reminderEnabled, isFalse);

      await pumpPage(
        tester,
        TimetableSettingsPage(controller: _c, showReminderCard: true),
      );
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      expect(_c.settings.reminderEnabled, isTrue);
      await tester.tap(find.byKey(const Key('tt_settings_reminder_lead')));
      await tester.pumpAndSettle();
      for (final m in [5, 10, 15, 20, 30]) {
        expect(find.byKey(Key('tt_settings_lead_$m')), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('tt_settings_lead_20')));
      await tester.pumpAndSettle();
      await settleIo(tester);
      expect(_c.settings.reminderLeadMinutes, 20);
    });

    testWidgets('ST19 外观页暂时不展示配色方案 A/B/C 入口', (tester) async {
      await pumpPage(tester, TimetableSettingsPage(controller: _c));
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_settings_palette')), findsNothing);
      expect(find.text('A 柔和'), findsNothing);
      expect(find.text('B 马卡龙'), findsNothing);
      expect(find.text('C 莫兰迪'), findsNothing);
      // storage 字段仍可读（默认 A），不因隐藏入口而丢失。
      expect(_c.settings.paletteScheme, 'A');
    });
  });

  group('格子接设置', () {
    Future<void> pumpGrid(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: _c,
              builder: (context, _) => WeekGrid(week: 7, controller: _c),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    TimetableSettings base() => TimetableSettings(
      termStartDate: DateTime(2026, 8, 31),
      periodHeight: 90,
    );

    testWidgets('ST04 关地点：格内无 @ 行', (tester) async {
      load(
        settings: base().copyWith(showLocation: false),
        manual: [_course('a', '测试课甲')],
      );
      await pumpGrid(tester);
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('测试课甲'), findsOneWidget);
    });

    testWidgets('ST05 开老师：老师在地点下面；默认关时不显示', (tester) async {
      load(settings: base(), manual: [_course('a', '测试课甲', start: 1)]);
      await pumpGrid(tester);
      expect(find.byKey(const Key('course_cell_teacher')), findsNothing);
      load(
        settings: base().copyWith(showTeacher: true),
        manual: [_course('a', '测试课甲', start: 1)],
      );
      await pumpGrid(tester);
      final teacher = find.byKey(const Key('course_cell_teacher'));
      expect(teacher, findsOneWidget);
      expect(tester.widget<Text>(teacher).data, '教师A');
      expect(
        tester.getTopLeft(teacher).dy >
            tester.getTopLeft(find.textContaining('@')).dy,
        isTrue,
      );
    });

    testWidgets('ST09 文字大小三档：课名 10.8 / 12 / 13.8', (tester) async {
      for (final (scale, size) in [
        (CellFontScale.small, 10.8),
        (CellFontScale.standard, 12.0),
        (CellFontScale.large, 13.8),
      ]) {
        load(
          settings: base().copyWith(fontScale: scale),
          manual: [_course('a', '测试课甲')],
        );
        await pumpGrid(tester);
        final name = tester.widget<CourseNameText>(find.byType(CourseNameText));
        expect(name.style.fontSize, closeTo(size, 0.001));
      }
    });

    test('ST10 最小 10sp 夹紧', () {
      const scaler = TextScaler.linear(0.85);
      final v = CourseCell.cellFontSize(12, 0.9, scaler);
      expect(v * 0.85, closeTo(10, 0.001));
    });

    testWidgets('ST13 不透明度只作用于底色：文字/角标/圆点不变淡', (tester) async {
      load(
        settings: base().copyWith(cellOpacity: 30),
        manual: [_course('a', '测试课甲'), _course('b', '测试课乙')],
      );
      await pumpGrid(tester);
      final cell = tester.widget<CourseCell>(find.byType(CourseCell));
      final ink = tester.widget<Ink>(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.byType(Ink),
        ),
      );
      final bg = (ink.decoration! as BoxDecoration).color!;
      final pair = coursePairFor(_c, cell.cell.course);
      expect(bg, Color.lerp(TimetableTheme.pageBg, pair.bg, 0.3));
      expect(bg.a, 1.0);
      final fg = pair.fg;
      final name = tester.widget<CourseNameText>(find.byType(CourseNameText));
      expect(name.style.color, fg);
      final dot = tester.widget<Container>(
        find.byKey(const Key('course_cell_conflict_dot')),
      );
      expect((dot.decoration! as BoxDecoration).color, fg);
      expect(fg.a, 1.0);
    });

    testWidgets('ST13b 不透明度 55：格子底色按 55% 往页面底色混合', (tester) async {
      load(
        settings: base().copyWith(cellOpacity: 55),
        manual: [_course('a', '测试课甲')],
      );
      await pumpGrid(tester);
      expect(_c.settings.cellOpacity, 55);
      final cell = tester.widget<CourseCell>(find.byType(CourseCell));
      final ink = tester.widget<Ink>(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.byType(Ink),
        ),
      );
      final bg = (ink.decoration! as BoxDecoration).color!;
      final raw = coursePairFor(_c, cell.cell.course).bg;
      expect(bg, TimetableTheme.blendCellBg(raw, 55));
      expect(bg, Color.lerp(TimetableTheme.pageBg, raw, 0.55));
      expect(bg, isNot(TimetableTheme.blendCellBg(raw, 50)));
      expect(bg, isNot(TimetableTheme.blendCellBg(raw, 60)));
      expect(bg.a, 1.0);
    });

    testWidgets('换配色 B：未自选时格子仍走 id 哈希 12 预设（忽略 A/B/C）', (tester) async {
      load(
        settings: base().copyWith(paletteScheme: 'B'),
        manual: [_course('a', '测试课甲', colorIndex: 12)],
      );
      await pumpGrid(tester);
      final cell = tester.widget<CourseCell>(find.byType(CourseCell));
      final pair = coursePairFor(_c, cell.cell.course);
      final ink = tester.widget<Ink>(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.byType(Ink),
        ),
      );
      expect((ink.decoration! as BoxDecoration).color, pair.bg);
      final name = tester.widget<CourseNameText>(find.byType(CourseNameText));
      expect(name.style.color, pair.fg);
      // 不再等于旧 B 柔和色板。
      expect(pair.bg, isNot(_hex('F2CFA8')));
    });

    testWidgets('每周第一天=周日：周日放第一列，日期 10/18，月份按周一', (tester) async {
      load(
        settings: base().copyWith(weekStartsOnMonday: false),
        manual: [_course('a', '测试课甲')],
      );
      await pumpGrid(tester);
      final xs = {
        for (final d in ['日', '一', '六']) d: tester.getTopLeft(find.text(d)).dx,
      };
      expect(xs['日']! < xs['一']!, isTrue);
      expect(xs['一']! < xs['六']!, isTrue);
      expect(find.text('18'), findsOneWidget); // 第 7 周周日 10/18
      expect(find.text('10月'), findsOneWidget);
    });
  });

  group('B/C 配色（§13.7）', () {
    const bBg = [
      'A8D8FF', 'FFC2A8', 'B5E5B9', 'D5C2FF', 'FFE29A', '9FE3DD', 'FFB8D1', //
      'C9D3E6', 'B3BEFF', 'D6EBA0', 'FFB3B3', 'A3E6CF', 'F2CFA8', 'E8BFF2',
      'FFBDE6', 'AEE0F5',
    ];
    const cBg = [
      'B7C9D6', 'D8B9A8', 'B9C8B0', 'C6B8D0', 'D9CBA6', 'A9C6C1', 'D4AFB9', //
      'C2C2BA', 'B3B8D3', 'C8CDA6', 'D6ADA8', 'A8C4B4', 'D2BFA6', 'CDB4C9',
      'D9B3C3', 'ADC3D3',
    ];

    test('ST17 色值：B、C 各 16 色，共用一个深色文字色', () {
      final b = TimetableTheme.pairsOf(CoursePaletteScheme.macaron);
      final c = TimetableTheme.pairsOf(CoursePaletteScheme.morandi);
      expect(b, hasLength(16));
      expect(c, hasLength(16));
      for (var i = 0; i < 16; i++) {
        expect(b[i].bg, _hex(bBg[i]), reason: 'B $i');
        expect(b[i].fg, _hex('1F2430'));
        expect(c[i].bg, _hex(cBg[i]), reason: 'C $i');
        expect(c[i].fg, _hex('2A2E35'));
      }
    });

    test('ST17/ST18 对比度：三套 × 16 色 × 100..30% 均 ≥ 4.5，最低值与规范一致', () {
      const expected = {
        CoursePaletteScheme.soft: (5.5, 5.7, 5.8),
        CoursePaletteScheme.macaron: (8.66, 11.25, 12.43),
        CoursePaletteScheme.morandi: (6.75, 9.36, 10.58),
      };
      for (final scheme in CoursePaletteScheme.values) {
        final mins = <int, double>{};
        for (final p in TimetableTheme.pairsOf(scheme)) {
          double? prev;
          for (var op = 100; op >= 30; op -= 10) {
            final bg = TimetableTheme.blendCellBg(p.bg, op);
            final ratio = _contrast(bg, p.fg);
            expect(ratio >= 4.5, isTrue, reason: '$scheme $op');
            if (prev != null) expect(ratio >= prev - 1e-9, isTrue);
            prev = ratio;
            mins[op] = math.min(mins[op] ?? 99, ratio);
          }
        }
        final (m100, m50, m30) = expected[scheme]!;
        // A 的规范值只给到一位小数（§13.5），按 0.1 容差；B/C 按用例 ≤ 0.05。
        final tol = scheme == CoursePaletteScheme.soft ? 0.1 : 0.05;
        expect(mins[100]!, closeTo(m100, tol), reason: '$scheme 100');
        expect(mins[50]!, closeTo(m50, tol), reason: '$scheme 50');
        expect(mins[30]!, closeTo(m30, tol), reason: '$scheme 30');
      }
    });

    test('近似对表：B、C 各 9 对，写死与规范一致', () {
      expect(kNearColorPairs[CoursePaletteScheme.macaron], const [
        (0, 7), (0, 15), (3, 8), (3, 13), (4, 12), (5, 11), (6, 14), (7, 8), //
        (13, 14),
      ]);
      expect(kNearColorPairs[CoursePaletteScheme.morandi], const [
        (0, 15), (2, 9), (3, 13), (4, 7), (4, 9), (4, 12), (6, 14), (7, 9), //
        (13, 14),
      ]);
      // C 的 (2,7) 23.0°、(1,12) 23.3° 都不算。
      expect(colorsNear(2, 7, scheme: CoursePaletteScheme.morandi), isFalse);
      expect(colorsNear(1, 12, scheme: CoursePaletteScheme.morandi), isFalse);
    });

    test('CA16 换方案：自动色按新方案重算顺延，手动色号保留，不落盘', () async {
      final a = _nameWithHash(1);
      final b = _nameWithHash(12, after: a);
      final cName = _nameWithHash(5);
      final d = _nameWithHash(11, after: cName);
      final n4 = _nameWithHash(4);
      final manual = [
        _course('a', a, day: 1, start: 1),
        _course('b', b, day: 1, start: 3),
        _course('c', cName, day: 3, start: 1),
        _course('d', d, day: 3, start: 3),
        _course('z', '测试课Z', day: 5, start: 1, colorIndex: 12),
        _course('n', n4, day: 5, start: 3),
      ];
      load(manual: manual);
      Map<String, int> colors() => {
        for (final x in _c.manualCourses) x.id: _c.colorIndexOf(x),
      };
      final settingsFile = File('${tmp.path}/timetable/settings.json');
      final expected = {
        'A': {'b': 13, 'd': 11, 'z': 12, 'n': 5},
        'B': {'b': 12, 'd': 12, 'z': 12, 'n': 5},
        'C': {'b': 12, 'd': 11, 'z': 12, 'n': 5},
      };
      Map<String, int>? first;
      for (final k in ['A', 'B', 'C', 'A']) {
        await _c.updateSettings(_c.settings.copyWith(paletteScheme: k));
        final m = colors();
        expect(m['a'], 1, reason: k);
        expect(m['c'], 5, reason: k);
        for (final e in expected[k]!.entries) {
          expect(m[e.key], e.value, reason: '$k ${e.key}');
        }
        first ??= m;
        // 手动色号仍是 12；课程数据不写顺延后的色号。
        expect(_c.manualCourses.firstWhere((x) => x.id == 'z').colorIndex, 12);
        expect(
          _c.manualCourses
              .where((x) => x.id != 'z')
              .every((x) => x.colorIndex == null),
          isTrue,
        );
        if (settingsFile.existsSync()) {
          final text = settingsFile.readAsStringSync();
          expect(text.contains('"paletteScheme"'), isTrue);
          expect(text.contains('colorIndex'), isFalse);
        }
      }
      expect(colors(), first); // 切回 A 与初始一致
    });
  });
}
