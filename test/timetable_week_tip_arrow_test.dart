// 规格 §5：周课表顶栏「第 N 周」旁小尖头。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_appearance_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

final _c = TimetableController.instance;

const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(String id, String name) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '1' * 20,
      location: '测试楼 A101',
      teacher: '张老师',
    ),
  ],
);

void _load({int week = _week}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: const [],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: [_course('a', '测试课甲')],
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

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_tip_arrow');
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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
    await _io(tester, 5);
  }

  final arrow = find.byKey(const Key('timetable_week_tip_arrow'));
  final strip = find.byKey(const Key('timetable_week_strip'));

  group('§5 周数旁小尖头', () {
    testWidgets('TA01 顶栏有 arrow_drop_down、16dp、跟周数同色', (tester) async {
      _load();
      await pumpPage(tester);
      expect(arrow, findsOneWidget);
      final icon = tester.widget<Icon>(arrow);
      expect(icon.icon, Icons.arrow_drop_down);
      expect(icon.size, 16);
      final ctx = tester.element(arrow);
      expect(icon.color, TimetableTheme.colorsOf(ctx).titleText);
    });

    testWidgets('TA02 尖头在「第 N 周」后、「(非本周)」前；间距 2dp', (tester) async {
      _load(week: 9);
      await pumpPage(tester);
      expect(find.textContaining('第 9 周', findRichText: true), findsWidgets);
      expect(arrow, findsOneWidget);
      final pad = tester.widget<Padding>(
        find.ancestor(of: arrow, matching: find.byType(Padding)).first,
      );
      expect(pad.padding, const EdgeInsets.only(left: 2));
    });

    testWidgets('TA03 打开周条尖头转 180°（150ms），再点复原', (tester) async {
      _load();
      await pumpPage(tester);
      expect(strip, findsNothing);
      AnimatedRotation rot() => tester.widget<AnimatedRotation>(
        find.ancestor(of: arrow, matching: find.byType(AnimatedRotation)),
      );
      expect(rot().turns, 0);
      expect(rot().duration, const Duration(milliseconds: 150));

      await tester.tap(find.textContaining('第 $_week 周'));
      await tester.pump(); // start
      await tester.pump(const Duration(milliseconds: 150));
      expect(strip, findsOneWidget);
      expect(rot().turns, 0.5);

      await tester.tap(find.textContaining('第 $_week 周'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(strip, findsNothing);
      expect(rot().turns, 0);
    });

    testWidgets('TA04 点击区高 ≥40dp、左右内边距 8dp', (tester) async {
      _load();
      await pumpPage(tester);
      final ink = find.ancestor(of: arrow, matching: find.byType(InkWell));
      expect(ink, findsOneWidget);
      final box = tester.getSize(ink);
      expect(box.height, greaterThanOrEqualTo(40));
      final container = tester.widget<Container>(
        find.descendant(of: ink, matching: find.byType(Container)).first,
      );
      expect(
        container.padding,
        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      );
      expect(container.constraints?.minHeight, 40);
      // 圆角 8dp
      final well = tester.widget<InkWell>(ink);
      expect(well.borderRadius, BorderRadius.circular(8));
    });

    testWidgets('TA05 外观预览不加尖头', (tester) async {
      _load();
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: TimetableAppearancePage(controller: _c)),
      );
      await tester.pump();
      await _io(tester, 3);
      expect(arrow, findsNothing);
      // 折叠栏文案里可有「第 N 周」，但不应有 tip arrow。
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    });

    testWidgets('TA06 非本周时尖头仍跟 titleText，不跟 hint', (tester) async {
      _load(week: 9);
      await pumpPage(tester);
      final icon = tester.widget<Icon>(arrow);
      final ctx = tester.element(arrow);
      final colors = TimetableTheme.colorsOf(ctx);
      expect(icon.color, colors.titleText);
      expect(icon.color, isNot(colors.hint));
    });
  });
}
