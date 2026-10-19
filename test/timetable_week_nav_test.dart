// spec-next-1019 item 3（回到本周 / 选周动画时长）与 item 5（顶栏周条）。
// 全部为构造数据，不读真实样例。
// ignore_for_file: unused_element

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
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
  String weeksLabel = '',
  String location = '测试楼 A101',
  String teacher = '张老师',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      weeksLabel: weeksLabel,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _io(WidgetTester tester, [int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void _setUpController() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_next');
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
}

void main() {
  _setUpController();

  group('item 3 weekJumpDuration', () {
    test('NAV01 1→250、2→300、6→500、10→500（上限），负数按绝对值', () {
      expect(weekJumpDuration(1), const Duration(milliseconds: 250));
      expect(weekJumpDuration(2), const Duration(milliseconds: 300));
      expect(weekJumpDuration(6), const Duration(milliseconds: 500));
      expect(weekJumpDuration(10), const Duration(milliseconds: 500));
      expect(weekJumpDuration(-2), const Duration(milliseconds: 300));
      expect(weekJumpDuration(0), const Duration(milliseconds: 250));
    });
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: const TimetablePage(),
      ),
    );
    await _io(tester, 5);
  }

  group('item 3 回到本周', () {
    testWidgets('NAV02 跨 10 周：直接动画（不先瞬移到相邻周），500ms 内到本周', (tester) async {
      _load(manual: [_course('a', '测试课甲')], week: 17);
      await pumpPage(tester);
      expect(_c.viewingWeek, 17);
      await tester.tap(find.text('回到本周'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 没有先瞬移到第 8 周：动画刚开始仍在第 17 周附近。
      expect(_c.viewingWeek, greaterThan(_week + 5));
      await tester.pump(const Duration(milliseconds: 520));
      expect(_c.viewingWeek, _week);
      await tester.pumpAndSettle();
      expect(find.text('回到本周'), findsNothing);
    });
  });

  group('item 5 顶栏周条', () {
    final strip = find.byKey(const Key('timetable_week_strip'));
    Finder chip(int w) => find.byKey(ValueKey('week_chip_$w'));
    Material chipMaterial(WidgetTester tester, int w) =>
        tester.widget<Material>(
          find.descendant(of: chip(w), matching: find.byType(Material)).first,
        );

    testWidgets('NAV03 点周数展开周条，再点收起；读屏「第 N 周」', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester);
      expect(strip, findsNothing);
      await tester.tap(find.text('第 7 周'));
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget);
      expect(find.bySemanticsLabel('第 7 周，本周'), findsOneWidget);
      expect(find.bySemanticsLabel('第 6 周'), findsOneWidget);
      await tester.tap(find.text('第 7 周'));
      await tester.pumpAndSettle();
      expect(strip, findsNothing);
      semantics.dispose();
    });

    testWidgets('NAV04 选中周实心、本周描边；选某周后收起并翻到该周', (tester) async {
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester);
      await tester.tap(find.text('第 7 周'));
      await tester.pumpAndSettle();
      final colors = TimetableColors.light;
      expect(chipMaterial(tester, 7).color, colors.accent);
      expect(chipMaterial(tester, 6).color, colors.chipBg);
      await tester.tap(chip(5));
      await tester.pump();
      expect(strip, findsNothing, reason: '选中后立即收起');
      // 2 周 → 300ms 动画，开始时还没到。
      expect(_c.viewingWeek, isNot(5));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, 5);
      await tester.tap(find.textContaining('第 5 周'));
      await tester.pumpAndSettle();
      expect(chipMaterial(tester, 5).color, colors.accent);
      final current = chipMaterial(tester, 7);
      expect(current.color, colors.chipBg);
      expect((current.shape! as StadiumBorder).side.color, colors.accent);
    });

    testWidgets('NAV05 减少动画：选周直接跳转', (tester) async {
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester, disableAnimations: true);
      await tester.tap(find.text('第 7 周'));
      await tester.pump();
      await tester.tap(chip(5));
      await tester.pump();
      expect(_c.viewingWeek, 5);
    });
  });
}
