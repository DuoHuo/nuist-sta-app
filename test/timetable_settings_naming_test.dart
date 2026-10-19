// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

final _c = TimetableController.instance;

/// 第 7 周（单周）：10/12–10/18；开学 2026-08-31。
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  String classId = '',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  classId: classId,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  TimetableSettings? settings,
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: settings ?? TimetableSettings(termStartDate: _termStart),
      syncedAt: syncedAt,
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _settleIo(WidgetTester tester) async {
  // 同步进行中（成功时写盘、过期时写 sync_state.json）多等几轮真实 IO。
  for (var i = 0; i < 5 || (_c.loading && i < 100); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _bigView(WidgetTester tester, {Size size = const Size(1080, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ui');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
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
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------- NW
  group('SN 设置项命名（§13.16）', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      _bigView(tester, size: const Size(1080, 6000));
      await tester.pumpWidget(
        MaterialApp(
          home: TimetableSettingsPage(
            controller: _c,
            onOpenAccount: () async {},
          ),
        ),
      );
      await tester.pump();
    }

    Finder inGroup(String g, String text) => find.descendant(
      of: find.byKey(Key('tt_settings_group_$g')),
      matching: find.text(text),
    );

    testWidgets('SN01/SN02 标题「设置」，各卡片行名逐字一致；选项与二级页标题', (tester) async {
      _load();
      await pumpSettings(tester);
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
      for (final t in ['周六', '非本周课程', '地点', '老师', '一周起始']) {
        expect(inGroup('display', t), findsOneWidget, reason: t);
      }
      expect(inGroup('display', '周一'), findsOneWidget);
      expect(inGroup('display', '周日'), findsNWidgets(2));
      for (final t in ['配色与预览', '字号', '小', '标准', '大', '格子高度']) {
        expect(inGroup('appearance', t), findsOneWidget, reason: t);
      }
      expect(inGroup('home', '显示明天的课'), findsOneWidget);
      expect(inGroup('exam', '显示考试'), findsOneWidget);
      expect(inGroup('other', '教务账号'), findsOneWidget);
      expect(inGroup('other', '恢复教务课程'), findsOneWidget);
      // SN05 旧长名不残留。
      for (final t in [
        '显示周六',
        '显示周日',
        '显示非本周课程',
        '格子里显示',
        '每周第一天',
        '课程配色',
        '格子文字大小',
        '格子不透明度',
        '首页卡片显示明天的课',
        '在课表中显示考试',
        '恢复全部教务课程',
        '课表设置',
      ]) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '外观'), findsOneWidget);
      for (final t in ['文字颜色', '不透明度', '今日课表最多显示', '考试颜色']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      // 配色方案 A/B/C 入口暂时隐藏。
      expect(find.byKey(const Key('tt_settings_palette')), findsNothing);
      expect(find.widgetWithText(AppBar, '配色'), findsNothing);
    });

    test('SN05 lib 界面文案不残留旧长名', () {
      const old = [
        "'显示周六'",
        "'显示周日'",
        "'显示非本周课程'",
        "'格子里显示地点'",
        "'格子里显示老师'",
        "'每周第一天'",
        "'课程配色'",
        "'格子文字大小'",
        "'格子不透明度'",
        "'首页卡片显示明天的课'",
        "'在课表中显示考试'",
        "'恢复全部教务课程'",
        "'课表设置'",
      ];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final o in old) {
          expect(src.contains(o), isFalse, reason: '${f.path}: $o');
        }
      }
    });

    testWidgets('SN03 读屏「卡片名，行名」', (tester) async {
      final semantics = tester.ensureSemantics();
      _load();
      await pumpSettings(tester);
      for (final l in [
        '显示，周六',
        '显示，周日',
        '显示，非本周课程',
        '显示，地点',
        '显示，老师',
        '显示，一周起始',
        '外观，配色与预览',
        '外观，字号',
        '外观，格子高度',
        '首页，显示明天的课',
        '考试，显示考试',
        '其他，教务账号',
        '其他，恢复教务课程',
      ]) {
        expect(
          find.bySemanticsLabel(RegExp('^${RegExp.escape(l)}(\$|\\n)')),
          findsOneWidget,
          reason: l,
        );
      }
      semantics.dispose();
    });

    testWidgets('SN04 旧 settings.json（非默认值）：值全部保留，改一项后 key 集合不变', (
      tester,
    ) async {
      final file = File('${tmp.path}/settings.json');
      final stored = {
        'termStartDate': '2026-08-31',
        'showSaturday': false,
        'showSunday': false,
        'showNonCurrentWeek': true,
        'showLocation': false,
        'showTeacher': true,
        'weekStartsOnMonday': false,
        'fontScale': 'large',
        'cellOpacity': 60,
        'periodHeight': 80,
        'paletteScheme': 'B',
        'showTomorrowOnHome': false,
        'showExams': false,
        'examColor': 0xFF1565C0,
      };
      file.writeAsStringSync(jsonEncode(stored));
      _c.debugReset();
      await tester.runAsync(_c.ensureStarted);
      await pumpSettings(tester);
      bool sw(String key) => tester
          .widget<Switch>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Switch),
            ),
          )
          .value;
      expect(sw('tt_settings_saturday'), isFalse);
      expect(sw('tt_settings_sunday'), isFalse);
      expect(sw('tt_settings_non_current'), isTrue);
      expect(sw('tt_settings_show_location'), isFalse);
      expect(sw('tt_settings_show_teacher'), isTrue);
      expect(sw('tt_settings_show_tomorrow'), isFalse);
      expect(sw('tt_settings_show_exams'), isFalse);
      expect(find.text('80'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      expect(find.text('60%'), findsOneWidget);
      expect(find.textContaining('马卡龙'), findsOneWidget);
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const Key('tt_settings_exam_color_swatch')),
                    )
                    .decoration!
                as BoxDecoration)
            .color,
        TimetableTheme.examCellBg(const Color(0xFF1565C0)),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      final keysBefore = (jsonDecode(file.readAsStringSync()) as Map).keys
          .toSet();
      await tester.tap(find.byKey(const Key('tt_settings_show_exams')));
      await _settleIo(tester);
      final after = jsonDecode(file.readAsStringSync()) as Map;
      expect(after.keys.toSet(), keysBefore);
      expect(after['showExams'], isTrue);
      for (final e in stored.entries) {
        if (e.key == 'showExams') continue;
        expect(after[e.key], e.value, reason: e.key);
      }
    });

    testWidgets('EX03 考试颜色与课程同套 12 预设；外观页选预设写入 examColor', (tester) async {
      expect(
        TimetableTheme.examColorOptions,
        TimetableTheme.coursePresetColors,
      );
      expect(TimetableTheme.coursePresetColors, hasLength(12));
      expect(kDefaultExamColor, 0xFFC62828);
      _load();
      await pumpSettings(tester);
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_settings_exam_color')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_color_preset_6')));
      await _settleIo(tester);
      expect(
        _c.settings.examColor,
        TimetableTheme.coursePresetColors[6].toARGB32(),
      );
    });

    testWidgets('恢复教务课程：二次确认；取消不动，确认后 restoreAllJwxt 清掉调课记录', (tester) async {
      _load(jwxt: [_course('K1|01', '测试课甲', source: CourseSource.jwxt)]);
      final r = (await tester.runAsync(
        () => _c.moveSlot(
          _c.courses.single,
          0,
          toDay: 3,
          toStartPeriod: 9,
          week: _week,
          scope: MoveScope.thisWeek,
        ),
      ))!;
      expect(r.status, MoveStatus.moved);
      expect(_c.slotOverrides, hasLength(1));
      await pumpSettings(tester);
      await tester.tap(find.byKey(const Key('tt_settings_restore_jwxt')));
      await tester.pumpAndSettle();
      expect(
        find.text(TimetableSettingsPage.restoreConfirmText),
        findsOneWidget,
      );
      expect(
        TimetableSettingsPage.restoreConfirmText,
        '恢复所有教务课程和考试？你的修改、删除和调课都会清除。',
      );
      await tester.tap(find.byKey(const Key('tt_restore_jwxt_cancel')));
      await tester.pumpAndSettle();
      expect(_c.slotOverrides, hasLength(1));
      await tester.tap(find.byKey(const Key('tt_settings_restore_jwxt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_restore_jwxt_confirm')));
      await _settleIo(tester);
      expect(_c.slotOverrides, isEmpty);
      expect(find.text('已恢复教务课程'), findsOneWidget);
    });

    testWidgets('EX05 干净安装：设置「考试」卡片「显示考试」默认开', (tester) async {
      expect(File('${tmp.path}/settings.json').existsSync(), isFalse);
      _c.debugReset();
      await tester.runAsync(_c.ensureStarted);
      expect(_c.settings.showExams, isTrue);
      await pumpSettings(tester);
      expect(inGroup('exam', '显示考试'), findsOneWidget);
      final sw = tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const Key('tt_settings_show_exams')),
          matching: find.byType(Switch),
        ),
      );
      expect(sw.value, isTrue);
    });
  });

  // ---------------------------------------------------------------- AS
}
