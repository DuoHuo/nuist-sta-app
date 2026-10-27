// spec-next-1019 item 14：全局「文字颜色」自动 / 白字 / 黑字。构造数据，不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_appearance_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31);

final _course = Course(
  id: 'a',
  name: '测试课甲',
  source: CourseSource.manual,
  slots: const [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '11111111111111111111',
      location: '测试楼 A101',
      teacher: '张老师',
    ),
  ],
);

void _load(CellTextColorMode mode) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: _termStart,
        cellTextColor: mode,
      ),
    ),
    viewingWeek: 7,
    manualCourses: [_course],
  );
}

Future<void> _io(WidgetTester tester) async {
  // 在 FakeAsync 结束前排空设置保存的多次异步 IO，避免 Windows 文件句柄残留。
  for (var i = 0; i < 20; i++) {
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
    tmp = Directory.systemTemp.createTempSync('tt_text');
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

  group('TX 持久化', () {
    test('TX01 toJson / fromJson 往返三个选项', () {
      for (final mode in CellTextColorMode.values) {
        final s = TimetableSettings(cellTextColor: mode);
        final back = TimetableSettings.fromJson(s.toJson());
        expect(back.cellTextColor, mode);
        expect(s.toJson()['cellTextColor'], mode.name);
      }
    });

    test('TX02 旧文件缺 cellTextColor 键 / 值不认识 → 自动', () {
      final json = const TimetableSettings().toJson()..remove('cellTextColor');
      expect(
        TimetableSettings.fromJson(json).cellTextColor,
        CellTextColorMode.auto,
      );
      json['cellTextColor'] = 'purple';
      expect(
        TimetableSettings.fromJson(json).cellTextColor,
        CellTextColorMode.auto,
      );
      expect(const TimetableSettings().cellTextColor, CellTextColorMode.auto);
    });

    test('TX03 写盘后重读保持（settings.json）', () async {
      final s = TimetableSettings(
        termStartDate: _termStart,
        cellTextColor: CellTextColorMode.black,
      );
      await TimetableStore.saveSettings(s);
      final back = await TimetableStore.readSettings();
      expect(back.cellTextColor, CellTextColorMode.black);
    });
  });

  group('TX 格子文字颜色', () {
    for (final dark in [false, true]) {
      for (final mode in CellTextColorMode.values) {
        testWidgets('TX04 ${dark ? '深色' : '浅色'} · ${mode.name}：课程格与考试格文字颜色', (
          tester,
        ) async {
          _load(mode);
          await tester.runAsync(
            () => _c.addScheduleEvent(
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
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? appDarkTheme() : appLightTheme(),
              home: Scaffold(body: WeekGrid(week: 7, controller: _c)),
            ),
          );
          await _io(tester);
          // 未自选时格子走课名哈希 12 预设（非 A/B/C）。
          final pair = coursePairFor(_c, _course, dark: dark);
          final expected = switch (mode) {
            CellTextColorMode.auto => pair.fg,
            CellTextColorMode.white => const Color(0xFFFFFFFF),
            CellTextColorMode.black => const Color(0xFF1F2329),
          };
          final colors = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byType(CourseCell),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.style?.color)
              .toSet();
          expect(colors, contains(expected));
          final id = _c.scheduleEvents.first.id;
          final examColors = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byKey(Key('schedule_cell_$id')),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.style?.color)
              .toSet();
          expect(
            examColors,
            contains(
              mode == CellTextColorMode.auto
                  ? TimetableTheme.examText
                  : expected,
            ),
          );
        });
      }
    }
  });

  testWidgets('TX05 外观页有「文字颜色」三段，选「黑」写入设置', (tester) async {
    _load(CellTextColorMode.auto);
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await _io(tester);
    final seg = find.byKey(const Key('tt_settings_cell_text_color'));
    expect(seg, findsOneWidget);
    for (final label in ['自动', '白', '黑']) {
      expect(find.descendant(of: seg, matching: find.text(label)), findsOne);
    }
    await tester.tap(find.descendant(of: seg, matching: find.text('黑')));
    await _io(tester);
    expect(_c.settings.cellTextColor, CellTextColorMode.black);
  });
}
