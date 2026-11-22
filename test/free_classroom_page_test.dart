// 空教室页面在手机宽度下渲染有数据的列表：不溢出、表头钉住、筛选可用。
//
// 页面数据用 debugSetResult 注入，不碰门户和网络；房间数据按 2026-09 教务真实
// 返回的形状造。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_controller.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_page.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_sheets.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_widgets.dart';

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
  testWidgets('单选面板保留数量提示并区分全部选项与取消', (tester) async {
    const options = [
      SheetOption<String>(value: null, label: '全部教室'),
      SheetOption<String>(value: '实验室', label: '实验室', hint: '3 间'),
    ];
    SheetOption<String>? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showOptionSheet<String>(
                  context,
                  title: '房间类型',
                  options: options,
                  current: '实验室',
                );
              },
              child: const Text('选择类型'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('选择类型'));
    await tester.pumpAndSettle();
    expect(find.text('3 间'), findsOneWidget);
    await tester.tap(find.text('全部教室'));
    await tester.pumpAndSettle();
    expect(picked, same(options.first));
    expect(picked?.value, isNull);

    await tester.tap(find.text('选择类型'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(tester.takeException(), isNull);
  });

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
    expect(
      find.descendant(of: row, matching: find.byType(Opacity)),
      findsNothing,
    );
    final palette = AppPalette.of(tester.element(row));
    final cells = tester.widgetList<Container>(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).borderRadius ==
                  BorderRadius.circular(6),
        ),
      ),
    );
    expect(cells.length, 5);
    expect(
      cells.map((c) => (c.decoration as BoxDecoration).color),
      everyElement(palette.success.withValues(alpha: 0.4)),
    );
  });

  testWidgets('状态格在未暗化、暗化未过、暗化已过三种状态下无 Opacity 且颜色 alpha 正确', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const building = Building(code: '1-120', name: '文德楼');
    const groups = [
      // 00:00 结束在一天中任何时刻均已过，24:00 结束在一天中任何时刻均未过。
      PeriodGroup(start: 1, end: 2, startTime: '00:00', endTime: '00:00'),
      PeriodGroup(start: 3, end: 4, startTime: '00:00', endTime: '24:00'),
      PeriodGroup(start: 5, end: 6, startTime: '00:00', endTime: '24:00'),
    ];
    final calendar = TermCalendar(
      termCode: '2026-2027-1',
      week: 4,
      weekday: today.weekday,
      groups: groups,
    );
    Classroom makeRoom(String name, List<String?> jc) => Classroom.fromRow({
      'JASMC': name,
      'JASLXDM_DISPLAY': '多媒体教室',
      'LC': 1,
      'SKZWS': 60,
      for (var i = 0; i < jc.length; i++) 'JC${i + 1}': jc[i],
    }, 6);

    final day = ClassroomDay(
      date: today,
      building: building,
      calendar: calendar,
      rooms: [
        // 分别覆盖：已过=全空 / 未过=部分 / 已选=全空
        makeRoom('测试N101', [null, null, '1_01', null, null, null]),
        // 分别覆盖：已过=部分 / 未过=全占用 / 已选=部分
        makeRoom('测试N102', ['1_01', null, '1_01', '1_01', '1_01', null]),
        // 分别覆盖：已过=全占用 / 未过=全空 / 已选=全空
        makeRoom('测试N103', ['1_01', '1_01', null, null, null, null]),
      ],
      fetchedAt: now,
    );

    final c = FreeClassroomController.instance;
    c.debugSetResult(day, buildings: [building]);
    c.setZone(null);
    c.setFloor(null);
    c.setType(null);
    c.setMinSeats(0);
    // 先回到仅选中未过时段 {1, 2}，再取消选中时段 1，形成 {2} 选中：
    // 下标 0 为暗化且已过 (0.45)，下标 1 为暗化且未过 (0.6)，下标 2 为未暗化 (1.0)。
    c.selectUpcomingGroups();
    c.toggleGroup(1);
    addTearDown(c.selectUpcomingGroups);

    await tester.pumpWidget(const MaterialApp(home: FreeClassroomPage()));
    await tester.pumpAndSettle();

    expect(find.byType(Opacity), findsNothing);

    List<Container> rowCells(String roomName) {
      final row = find.ancestor(
        of: find.text(roomName),
        matching: find.byType(InkWell),
      );
      return tester
          .widgetList<Container>(
            find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).borderRadius ==
                        BorderRadius.circular(6),
              ),
            ),
          )
          .toList();
    }

    Color cellBg(Container cell) => (cell.decoration as BoxDecoration).color!;

    Text cellText(Container cell) => tester.widget<Text>(
      find.descendant(of: find.byWidget(cell), matching: find.byType(Text)),
    );

    final palette = AppPalette.of(tester.element(find.text('测试N101')));
    final fullFreeBase = palette.success.withValues(alpha: 0.4);
    final partialBase = palette.warning.withValues(alpha: 0.18);
    final busyBase = ClassroomFillColors.busy(palette);

    final cells101 = rowCells('测试N101');
    final cells102 = rowCells('测试N102');
    final cells103 = rowCells('测试N103');
    expect(cells101, hasLength(3));
    expect(cells102, hasLength(3));
    expect(cells103, hasLength(3));

    // 下标 2：未暗化 (factor = 1.0)
    expect(cellBg(cells101[2]), fullFreeBase);
    expect(cellBg(cells102[2]), partialBase);
    expect(cellText(cells102[2]).style?.color, palette.warning);

    // 下标 1：暗化且未过 (factor = 0.6)
    expect(
      cellBg(cells103[1]),
      fullFreeBase.withValues(alpha: fullFreeBase.a * 0.6),
    );
    expect(
      cellBg(cells101[1]),
      partialBase.withValues(alpha: partialBase.a * 0.6),
    );
    expect(
      cellText(cells101[1]).style?.color,
      palette.warning.withValues(alpha: palette.warning.a * 0.6),
    );
    expect(cellBg(cells102[1]), busyBase.withValues(alpha: busyBase.a * 0.6));

    // 下标 0：暗化且已过 (factor = 0.45)
    expect(
      cellBg(cells101[0]),
      fullFreeBase.withValues(alpha: fullFreeBase.a * 0.45),
    );
    expect(
      cellBg(cells102[0]),
      partialBase.withValues(alpha: partialBase.a * 0.45),
    );
    expect(
      cellText(cells102[0]).style?.color,
      palette.warning.withValues(alpha: palette.warning.a * 0.45),
    );
    expect(cellBg(cells103[0]), busyBase.withValues(alpha: busyBase.a * 0.45));

    // 全选所有时段（包含已过时段 0）：下标 0 恢复为未暗化原色。
    c.selectAllGroups();
    await tester.pumpAndSettle();

    expect(find.byType(Opacity), findsNothing);
    final all101 = rowCells('测试N101');
    final all102 = rowCells('测试N102');
    final all103 = rowCells('测试N103');
    expect(cellBg(all101[0]), fullFreeBase);
    expect(cellBg(all102[0]), partialBase);
    expect(cellText(all102[0]).style?.color, palette.warning);
    expect(cellBg(all103[0]), busyBase);
  });
}
