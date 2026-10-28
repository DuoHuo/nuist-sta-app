import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_log_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_copy.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

import 'dart:io';

TimetableChangeRecord _rec({
  required String id,
  required TimetableChangeType type,
  required String fp,
  String name = '课',
  DateTime? time,
  String courseWeeks = '',
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
}) => TimetableChangeRecord(
  id: id,
  time: time ?? DateTime(2026, 10, 27, 14, 32),
  type: type,
  slotKey: 'k|$id',
  fingerprint: fp,
  courseName: name,
  courseWeeks: courseWeeks,
  before: before,
  after: after,
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_change_log_');
    TimetableStore.debugDirectory = tmp;
    TimetableChangeLogStore.debugMemory = [];
    c.debugReset();
  });
  tearDown(() {
    TimetableChangeLogStore.debugMemory = null;
    TimetableStore.debugDirectory = null;
    c.debugReset();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('空态', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const TimetableChangeLogPage()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_empty')), findsOneWidget);
    expect(find.text(TimetableCopy.changeLogEmpty), findsOneWidget);
  });

  testWidgets('按 fingerprint 分组倒序展示', (tester) async {
    TimetableChangeLogStore.debugMemory = [
      _rec(
        id: 'old1',
        type: TimetableChangeType.added,
        fp: 'old',
        name: '旧课',
        time: DateTime(2026, 10, 20, 9, 1),
        after: {
          'SKXQ': 1,
          'KSJC': 1,
          'JSJC': 2,
          'JASMC': '',
          'SKJS': '',
          'SKZC': '1',
          'ISTK': 0,
          'KCH': '',
          'KXH': '',
          'KCM': '',
        },
      ),
      _rec(
        id: 'new1',
        type: TimetableChangeType.locationChanged,
        fp: 'new',
        name: '高等数学',
        time: DateTime(2026, 10, 27, 14, 32),
        before: {
          'SKXQ': 1,
          'KSJC': 1,
          'JSJC': 2,
          'JASMC': '明德楼B210',
          'SKJS': '',
          'SKZC': '1',
          'ISTK': 0,
          'KCH': '',
          'KXH': '',
          'KCM': '',
        },
        after: {
          'SKXQ': 1,
          'KSJC': 1,
          'JSJC': 2,
          'JASMC': '文德楼A108',
          'SKJS': '',
          'SKZC': '1',
          'ISTK': 0,
          'KCH': '',
          'KXH': '',
          'KCM': '',
        },
      ),
      _rec(
        id: 'new2',
        type: TimetableChangeType.removed,
        fp: 'new',
        name: '形势与政策',
        time: DateTime(2026, 10, 27, 14, 32),
        before: {
          'SKXQ': 1,
          'KSJC': 1,
          'JSJC': 2,
          'JASMC': '',
          'SKJS': '',
          'SKZC': '1',
          'ISTK': 0,
          'KCH': '',
          'KXH': '',
          'KCM': '',
        },
      ),
    ];
    // readNewestFirst reverses readAll order — seed oldest→newest
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const TimetableChangeLogPage()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_group_0')), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('形势与政策'), findsOneWidget);
    expect(find.text('旧课'), findsOneWidget);
    expect(find.textContaining('明德楼B210'), findsOneWidget);
    expect(find.textContaining('文德楼A108'), findsOneWidget);
  });

  testWidgets('设置其他卡进入变动记录', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: TimetableSettingsPage(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_management_entry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tt_settings_change_log')),
      200,
    );
    // scrollUntilVisible 发出的滚动仍可能在布局中，等它结束再定位和点击。
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('tt_settings_change_log'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('影响范围在${dark ? '深色' : '浅色'}小屏和大字体下完整展示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<String, dynamic> snap(String weeks, {int day = 3}) => {
        'SKXQ': day,
        'KSJC': 5,
        'JSJC': 6,
        'SKZC': weeks,
        'JASMC': '新教室',
      };
      TimetableChangeLogStore.debugMemory = [
        _rec(
          id: 'all',
          type: TimetableChangeType.teacherChanged,
          fp: 'all',
          name: '全部周次变动',
          courseWeeks: '1111',
          before: {...snap('1111'), 'SKJS': '原教师'},
          after: {...snap('1111'), 'SKJS': '新教师'},
        ),
        _rec(
          id: 'one',
          type: TimetableChangeType.locationChanged,
          fp: 'one',
          name: '某次课变动',
          courseWeeks: '111111',
          before: {...snap('00001'), 'JASMC': '原教室'},
          after: snap('00001'),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: const TimetableChangeLogPage(),
        ),
      );
      await tester.pumpAndSettle();
      const partialScope = '第 5 周 · 周三 5–6节';
      const fullScope = '全部周次（第 1–4 周） · 周三 5–6节';
      expect(find.text(partialScope), findsOneWidget);
      expect(find.text(fullScope), findsOneWidget);
      expect(find.textContaining('影响范围：'), findsNothing);

      final typeTop = tester.getTopLeft(find.text('地点变动')).dy;
      final scopeTop = tester.getTopLeft(find.text(partialScope)).dy;
      expect((typeTop - scopeTop).abs(), lessThan(4));
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(812, 375));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
