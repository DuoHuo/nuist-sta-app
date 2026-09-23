// 空教室页面在手机宽度下渲染有数据的列表：不溢出、表头钉住、筛选可用。
//
// 页面数据用 debugSetResult 注入，不碰门户和网络；房间数据按 2026-09 教务真实
// 返回的形状造。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_controller.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_page.dart';

ClassroomDay _fakeDay() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  const building = Building(code: '1-120', name: '文德楼');
  final calendar = TermCalendar(
    termCode: '2026-2027-1',
    week: 4,
    weekday: today.weekday,
    groups: PeriodGroup.defaults,
  );
  Map<String, dynamic> row(
    String name,
    String type,
    int floor,
    int seats,
    List<String?> jc,
  ) => {
    'JASMC': name,
    'JASLXDM_DISPLAY': type,
    'LC': floor,
    'SKZWS': seats,
    for (var i = 0; i < jc.length; i++) 'JC${i + 1}': jc[i],
  };
  const free = <String?>[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
  ];
  final rows = <Map<String, dynamic>>[
    row('文德N101A', '多媒体教室', 1, 180, [
      '0_01',
      '0_01',
      '0_01',
      '0_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '0_01',
    ]),
    row('文德N102', '多媒体教室', 1, 120, [
      '1_01',
      '1_01',
      null,
      null,
      null,
      null,
      '1_04',
      '1_04',
      null,
      null,
      null,
    ]),
    row('文德C104', '实验室', 1, 36, free),
    row('文德N201', '多媒体教室', 2, 90, free),
    row('文德N202', '考研自习室', 2, 60, [
      null,
      null,
      null,
      null,
      null,
      '1_01',
      null,
      null,
      null,
      null,
      null,
    ]),
    row('文德N203', '多媒体教室', 2, 90, [
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_02',
      '1_02',
      '1_02',
    ]),
    row('文德N301', '大外部语音室', 3, 48, free),
    row('文德N302', '多媒体教室', 3, 150, [
      null,
      null,
      '1_01',
      '1_01',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
    ]),
    row('文德S401', '教师办公室', 4, 0, free),
    row('室外教室-雷丁', '实验室', 0, 0, free),
    for (var i = 1; i <= 12; i++)
      row('文德N5${i.toString().padLeft(2, '0')}', '多媒体教室', 5, 60, free),
  ];
  return ClassroomDay(
    date: today,
    building: building,
    calendar: calendar,
    rooms: [for (final r in rows) Classroom.fromRow(r, 11)],
    fetchedAt: now,
  );
}

Future<void> _pumpPage(WidgetTester tester, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final day = _fakeDay();
  final c = FreeClassroomController.instance;
  c.debugSetResult(
    day,
    buildings: [
      day.building,
      const Building(code: '1-202', name: '明德楼'),
    ],
  );
  // 控制器是单例，上一个用例点过的筛选会留到下一个用例，先清掉。
  c.setZone(null);
  c.setFloor(null);
  c.setType(null);
  c.setMinSeats(0);
  await tester.pumpWidget(const MaterialApp(home: FreeClassroomPage()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('360 宽下列表、表头、筛选卡都布局出来且无溢出', (tester) async {
    await _pumpPage(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('文德楼'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    for (final label in ['1-2', '3-4', '5-6', '7-8', '9-11']) {
      expect(find.text(label), findsOneWidget, reason: '时段表头 $label');
    }
    expect(find.text('所选时段全部空闲'), findsOneWidget);
    // 办公室在「全部教室」视图下不算空教室；实验室排在普通教室之后。
    expect(find.text('文德S401'), findsNothing);
    expect(find.textContaining('间可用'), findsOneWidget);
  });

  testWidgets('滚到底时段表头仍钉在顶部，点表头切换时段会重排', (tester) async {
    await _pumpPage(tester);
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('间可用'), findsOneWidget);
    expect(find.text('1-2').hitTestable(), findsOneWidget);

    await tester.tap(find.text('1-2'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('412 宽（常见安卓）同样无溢出', (tester) async {
    await _pumpPage(tester, width: 412);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('全占用的教室默认折叠在最底部，点段标题可展开', (tester) async {
    await _pumpPage(tester);
    // 文德N203 整天有课：不算「可用」，但要出现在折叠段里。
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();
    final busyHeader = find.text('所选时段全部占用');
    expect(busyHeader, findsOneWidget);
    expect(find.text('文德N203'), findsNothing);

    await tester.tap(busyHeader);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('文德N203'), findsOneWidget);

    // 折叠对三段统一：全空那段也能收起。
    await tester.drag(list, const Offset(0, 4000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('所选时段全部空闲'));
    await tester.pumpAndSettle();
    expect(find.text('文德N201'), findsNothing);
  });

  testWidgets('分区筛选只留下对应区的教室', (tester) async {
    await _pumpPage(tester);
    expect(find.text('N 区'), findsOneWidget);
    expect(find.text('C 区'), findsOneWidget);
    expect(find.text('S 区'), findsOneWidget);

    await tester.tap(find.text('C 区'));
    await tester.pumpAndSettle();
    expect(find.text('文德C104'), findsOneWidget);
    expect(find.text('文德N201'), findsNothing);
    expect(find.text('文德N101A'), findsNothing);
  });

  testWidgets('选中的时段列不会因为已经过去而画淡', (tester) async {
    await _pumpPage(tester);
    // 五个时段全选上后，每一行五个状态格都必须是实色，哪怕其中有些时段
    // 在今天已经结束。表头那行小字是否出现取决于跑测试的时刻，直接调控制器。
    FreeClassroomController.instance.selectAllGroups();
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('文德N201'),
      matching: find.byType(InkWell),
    );
    final cells = tester.widgetList<Opacity>(
      find.descendant(of: row, matching: find.byType(Opacity)),
    );
    expect(cells.length, 5);
    expect(cells.map((o) => o.opacity), everyElement(1.0));
  });
}
