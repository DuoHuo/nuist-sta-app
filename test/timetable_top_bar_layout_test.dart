import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

enum _State { current, nonCurrent, pending }

void _setState(_State state) {
  final pending = state == _State.pending;
  final c = TimetableController.instance;
  c.debugSetSnapshot(
    TimetableSnapshot(
      courses: [
        Course(
          id: 'ds',
          name: '数据结构与算法分析',
          source: CourseSource.jwxt,
          slots: [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: '1' * 20,
              location: '揽江楼 N407',
            ),
          ],
        ),
      ],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: pending ? null : DateTime(2026, 9, 7),
        periodHeight: TimetableTheme.periodHeight,
        cellRadius: TimetableTheme.cellRadius,
      ),
    ),
    viewingWeek: 1,
  );
  if (state == _State.nonCurrent) {
    c.setViewingWeek(c.currentWeek == 3 ? 4 : 3);
  } else if (state == _State.current) {
    c.goToCurrentWeek();
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const TimetablePage(),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() => TimetableController.instance.debugReset());

  const configs = <String, (Size, double)>{
    '360x640': (Size(360, 640), 1.0),
    '360x640 textScale 2.0': (Size(360, 640), 2.0),
    '1080x2400': (Size(1080, 2400), 1.0),
  };

  // 顶栏保留原有操作，并提供可直接点击的 WakeUp 导出入口。
  testWidgets('TB01 顶栏保留加课、WakeUp 导出、同步和设置，并提供外观菜单', (tester) async {
    _setState(_State.current);
    await _pump(tester, size: const Size(360, 640));
    expect(find.byTooltip('添加'), findsOneWidget);
    expect(find.byTooltip('同步'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.byTooltip('课表菜单'), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byKey(const Key('timetable_week_menu')), findsNothing);
    expect(
      find.byKey(const Key('timetable_appearance_menu_entry')),
      findsNothing,
    );
    expect(find.text('课表外观'), findsNothing);
    expect(find.byTooltip('分享'), findsNothing);
    expect(find.byIcon(Icons.share_outlined), findsNothing);
    expect(find.byIcon(Icons.share), findsNothing);
    expect(find.byTooltip('导出到 WakeUp'), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
    final icons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .map((b) => b.tooltip)
        .toList();
    expect(icons, ['添加', '导出到 WakeUp', '同步', '设置']);
  });

  for (final entry in configs.entries) {
    for (final state in _State.values) {
      testWidgets('顶栏无溢出：${entry.key} / ${state.name}', (tester) async {
        _setState(state);
        await _pump(tester, size: entry.value.$1, textScale: entry.value.$2);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('周', findRichText: true), findsWidgets);
        switch (state) {
          case _State.pending:
            expect(find.text('周次待同步 · 点此选择'), findsOneWidget);
          case _State.nonCurrent:
            expect(
              find.textContaining('(非本周)', findRichText: true),
              findsOneWidget,
            );
          case _State.current:
            expect(
              find.textContaining('(非本周)', findRichText: true),
              findsNothing,
            );
        }
      });
    }
  }
}
