import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_alert.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_copy.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';

TimetableChangeRecord _rec({
  required String id,
  required TimetableChangeType type,
  String name = '测试课',
  String fp = 'fp1',
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
  bool notified = false,
  DateTime? time,
}) => TimetableChangeRecord(
  id: id,
  time: time ?? DateTime(2026, 10, 27, 14, 32),
  type: type,
  slotKey: 'k|$id',
  fingerprint: fp,
  courseName: name,
  before: before,
  after: after,
  notified: notified,
);

Map<String, dynamic> _snap({
  int day = 1,
  int start = 1,
  int end = 2,
  String loc = '明德楼B210',
  String teacher = '张三',
  String weeks = '1111',
  int istk = 0,
}) => {
  'KCH': '1',
  'KXH': '1',
  'KCM': 'x',
  'SKXQ': day,
  'KSJC': start,
  'JSJC': end,
  'SKZC': weeks,
  'JASMC': loc,
  'SKJS': teacher,
  'ISTK': istk,
};

void main() {
  setUp(() {
    TimetableChangeLogStore.debugMemory = [];
  });
  tearDown(() {
    TimetableChangeLogStore.debugMemory = null;
  });

  group('TimetableChangeFormat', () {
    test('时间/地点/教师/调课标记摘要', () {
      expect(TimetableChangeFormat.weekdayZh(3), '周三');
      expect(
        TimetableChangeFormat.timeOf(_snap(day: 3, start: 5, end: 6)),
        '周三 5–6节',
      );
      final added = _rec(
        id: 'a',
        type: TimetableChangeType.added,
        name: '大学英语',
        after: _snap(day: 3, start: 5, end: 6, loc: '明德楼B210'),
      );
      expect(
        TimetableChangeFormat.alertBody(added),
        '大学英语 · 周三 5–6节 · 明德楼B210',
      );
      final time = _rec(
        id: 't',
        type: TimetableChangeType.timeChanged,
        name: '数据结构',
        before: _snap(day: 1, start: 3, end: 4),
        after: _snap(day: 2, start: 5, end: 6),
      );
      expect(TimetableChangeFormat.alertBody(time), '数据结构 周一 3–4节 → 周二 5–6节');
      expect(
        TimetableChangeFormat.groupTitle(
          DateTime(2026, 10, 27, 14, 32),
          now: DateTime(2026, 10, 27, 18),
        ),
        '今天 14:32',
      );
      expect(
        TimetableChangeFormat.groupTitle(
          DateTime(2026, 10, 20, 9, 1),
          now: DateTime(2026, 10, 27, 18),
        ),
        '10月20日 09:01',
      );
    });
  });

  testWidgets('空列表不弹', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showTimetableChangeAlert(ctx, records: const []),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
  });

  testWidgets('展示最多 5 行，超出显示等共 N 项；知道了标记 notified', (tester) async {
    final records = [
      for (var i = 0; i < 7; i++)
        _rec(
          id: 'r$i',
          type: TimetableChangeType.added,
          name: '课$i',
          fp: 'fp$i',
          after: _snap(day: 1, start: 1, end: 2),
        ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(records);

    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showTimetableChangeAlert(ctx, records: records),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_0')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_4')), findsOneWidget);
    expect(find.byKey(const Key('tt_change_alert_row_5')), findsNothing);
    expect(find.text(TimetableCopy.changeAlertMoreLabel(7)), findsOneWidget);
    expect(find.text(TimetableChangeType.added.labelZh), findsWidgets);

    await tester.tap(find.byKey(const Key('tt_change_alert_got_it')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_alert_title')), findsNothing);
    final all = await TimetableChangeLogStore.readAll();
    expect(all.every((r) => r.notified), isTrue);
  });

  testWidgets('查看记录标记 notified 并打开记录页', (tester) async {
    final records = [
      _rec(
        id: '1',
        type: TimetableChangeType.removed,
        name: '形势与政策',
        fp: 'only',
        before: _snap(day: 1, start: 1, end: 2),
      ),
    ];
    TimetableChangeLogStore.debugMemory = List.of(records);

    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showTimetableChangeAlert(ctx, records: records),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_change_alert_view_log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_change_log_page')), findsOneWidget);
    expect(find.text('形势与政策'), findsOneWidget);
    final all = await TimetableChangeLogStore.readAll();
    expect(all.single.notified, isTrue);
  });
}
