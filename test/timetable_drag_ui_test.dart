// 长按拖动调课 UI（spec §13.2；用例 23.11 DR 系列）。全部为构造数据，不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

const _w16 = '1111111111111111';
const _week = 7; // 2026-10-12 周一 = 第 7 周（开学 08-31）

Course _manual(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = _w16,
}) => Course(
  id: id,
  name: name,
  slots: [CourseSlot(day: day, startNode: start, endNode: end, weeks: weeks)],
);

Course _jwxt(String id, String name, {int day = 1, int start = 1}) => Course(
  id: id,
  name: name,
  code: id,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: _w16,
      weeksLabel: '1-16周',
    ),
  ],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final origClock = TimetableController.clock;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
  );

  void load({List<Course> jwxt = const [], List<Course> manual = const []}) {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt,
        settings: settings,
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: _week,
      manualCourses: manual,
    );
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tt_drag_ui');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  var taps = <String>[];

  Future<void> pumpGrid(WidgetTester tester) async {
    taps = [];
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => WeekGrid(
              week: _week,
              controller: c,
              onCourseTap: (cell) => taps.add(cell.course.name),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 一列宽、一节高（与 WeekGrid 布局一致：7 列，格高 64）。
  Size cellStep(WidgetTester tester) {
    final w = tester.getSize(find.byType(WeekGrid)).width;
    return Size((w - 34) / 7, 64);
  }

  Finder cellOf(String name) => find.ancestor(
    of: find.textContaining(name.substring(0, 2)),
    matching: find.byType(CourseCell),
  );

  /// 按住 [hold] 后（可选）移动 [by] 再松手。
  Future<void> longDrag(
    WidgetTester tester,
    Finder target, {
    Duration hold = const Duration(milliseconds: 850),
    List<Offset> moves = const [],
  }) async {
    final g = await tester.startGesture(tester.getCenter(target.first));
    await tester.pump(hold);
    for (final m in moves) {
      await g.moveBy(m);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('DR01 按住 0.5 秒松开：不进入拖动，按普通点击打开详情', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    await longDrag(
      tester,
      cellOf('甲课程'),
      hold: const Duration(milliseconds: 500),
    );
    expect(taps, ['甲课程']);
    expect(find.text('此更改应用范围？'), findsNothing);
  });

  testWidgets('DR02 按住 0.8 秒不移动：无任何反馈；松手不弹面板、不点开', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final g = await tester.startGesture(tester.getCenter(cellOf('甲课程').first));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(find.byType(CourseCell), findsOneWidget);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(taps, isEmpty);
  });

  testWidgets('DR03/DR11/DR12 长按后移动：格子按像素跟手（不吸附、带阴影不缩放）、原位空出；'
      '松手就近落位后弹三项面板', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    final originRect = tester.getRect(cellOf('甲课程').first);
    final origin = originRect.topLeft;
    final g = await tester.startGesture(tester.getCenter(cellOf('甲课程').first));
    await tester.pump(const Duration(milliseconds: 850));
    // 分两步移动到非整格位置：格子连续跟手（保持抓取点），不按格吸附。
    await g.moveBy(Offset(step.width * 0.7, step.height * 0.3));
    await tester.pump();
    final dragging = find.byKey(const Key('week_grid_dragging_cell'));
    expect(dragging, findsOneWidget);
    var at = tester.getTopLeft(dragging);
    expect(at.dx - origin.dx, closeTo(step.width * 0.7, 0.5));
    expect(at.dy - origin.dy, closeTo(step.height * 0.3, 0.5));
    await g.moveBy(Offset(step.width * 0.7, step.height * 1.3));
    await tester.pump();
    at = tester.getTopLeft(dragging);
    expect(at.dx - origin.dx, closeTo(step.width * 1.4, 0.5));
    expect(at.dy - origin.dy, closeTo(step.height * 1.6, 0.5));
    // 大小不变（不缩放），高度 2 节；带约 elevation 6 的阴影；无落点框。
    final r = tester.getRect(dragging);
    expect(r.width, closeTo(originRect.width, 0.01));
    expect(r.height, closeTo(2 * 64 - 3, 0.5));
    final shadow = tester.widget<DecoratedBox>(
      find.byKey(const Key('week_grid_dragging_shadow')),
    );
    expect(
      (shadow.decoration as BoxDecoration).boxShadow,
      kElevationToShadow[6],
    );
    expect(find.byType(CourseCell), findsNWidgets(2)); // 原格（透明）+ 浮动格
    // 原位置的格子保布局但不可见（Visibility，不留虚影也不半透明栅格化）。
    final hidden = tester.widget<Visibility>(
      find
          .ancestor(
            of: find.byType(CourseCell).first,
            matching: find.byType(Visibility),
          )
          .first,
    );
    expect(hidden.visible, isFalse);
    await g.up();
    await tester.pump();
    // 先约 150ms 滑进落点，再弹面板。中心在第 2 列（1.9 列）→ 周二；
    // 上沿 1.6 节 → 最近的节次线 → 第 3 节。
    expect(find.text('此更改应用范围？'), findsNothing);
    await tester.pumpAndSettle();
    at = tester.getTopLeft(dragging);
    expect(at.dx - origin.dx, closeTo(step.width, 0.5));
    expect(at.dy - origin.dy, closeTo(step.height * 2, 0.5));
    expect(find.text('此更改应用范围？'), findsOneWidget);
    // 第 1 条：「只改这一天（M月D日）」（默认，第一项）/「所有周」。
    expect(find.textContaining('只改这一天（'), findsOneWidget);
    expect(find.text('所有周'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.textContaining('跨周'), findsNothing);
    expect(find.textContaining('按天'), findsNothing);
    final y1 = tester.getTopLeft(find.textContaining('只改这一天（')).dy;
    final y2 = tester.getTopLeft(find.text('所有周')).dy;
    final y3 = tester.getTopLeft(find.text('取消')).dy;
    expect(y1 < y2 && y2 < y3, isTrue);
  });

  testWidgets('DR05/DR08 拖出网格：限制在网格内，不取消，仍弹面板', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final g = await tester.startGesture(tester.getCenter(cellOf('甲课程').first));
    await tester.pump(const Duration(milliseconds: 850));
    await g.moveBy(const Offset(2000, 3000));
    await tester.pump();
    final grid = tester.getRect(find.byType(WeekGrid));
    final r = tester.getRect(find.byKey(const Key('week_grid_dragging_cell')));
    expect(r.right <= grid.right + 0.5, isTrue);
    expect(r.bottom <= grid.bottom + 0.5, isTrue);
    // 反方向拖出网格：同样夹紧在左上边界内。
    await g.moveBy(const Offset(-5000, -6000));
    await tester.pump();
    final r2 = tester.getRect(find.byKey(const Key('week_grid_dragging_cell')));
    final cells = tester.getRect(cellOf('甲课程').first);
    expect(r2.left, closeTo(cells.left, 0.5));
    expect(r2.top, closeTo(cells.top, 0.5));
    await g.moveBy(const Offset(5000, 6000));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsOneWidget);
  });

  testWidgets('DR13 选「取消」：格子回原位，数据不变', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    await longDrag(tester, cellOf('甲课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drag_scope_cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 面板收起
    // 约 150ms 滑回原位后才消失。
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(c.manualCourses.single.slots.single.day, 1);
    expect(c.slotOverrides, isEmpty);
  });

  testWidgets('DR14 点遮罩 / 下拉关闭面板：都等同取消', (tester) async {
    load(jwxt: [_jwxt('K1|01', '乙课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    // 点遮罩。
    await longDrag(tester, cellOf('乙课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(c.slotOverrides, isEmpty);
    // 下拉关闭。
    await longDrag(tester, cellOf('乙课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    await tester.fling(find.text('此更改应用范围？'), const Offset(0, 600), 2000);
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(c.slotOverrides, isEmpty);
    expect(c.courses.single.slots.single.day, 1);
  });

  testWidgets('DR15 拖回原位置松手：不弹面板，不写任何东西', (tester) async {
    load(jwxt: [_jwxt('K1|01', '乙课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    await longDrag(
      tester,
      cellOf('乙课程'),
      moves: [
        Offset(step.width, step.height),
        Offset(-step.width, -step.height),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(c.slotOverrides, isEmpty);
  });

  testWidgets('DR17 只改本周：调用 moveSlot，新时段只有本周；无撤销', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    await longDrag(
      tester,
      cellOf('甲课程'),
      moves: [Offset(step.width * 2, step.height * 2)],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drag_scope_this_week')));
    await tester.pump();
    await settleIo(tester);
    final slots = c.manualCourses.single.slots;
    expect(slots, hasLength(2));
    final moved = slots.firstWhere((s) => s.day == 3);
    expect((moved.startNode, moved.endNode), (3, 4));
    expect(weeksOf(moved), [_week]);
    expect(find.text('撤销'), findsNothing);
    expect(find.byType(SnackBar), findsNothing); // 无冲突不提示
  });

  testWidgets('DR27 落点冲突：弹浮动 SnackBar「与 Y 时间冲突」，不拦截', (tester) async {
    load(manual: [_manual('m1', '甲课程'), _manual('m2', '丙课程', day: 2)]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    await longDrag(tester, cellOf('甲课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drag_scope_all_weeks')));
    await tester.pump();
    await settleIo(tester);
    expect(find.text('与丙课程时间冲突'), findsOneWidget);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.behavior, SnackBarBehavior.floating);
    expect(bar.action, isNull);
    // 修改已生效：所有周甲课程都在周二；冲突格按「2 门」样式显示。
    final slots = c.manualCourses.firstWhere((x) => x.id == 'm1').slots;
    expect(slots.any((s) => s.day == 2 && weeksOf(s).contains(_week)), isTrue);
    expect(find.byKey(const Key('course_cell_stack_badge')), findsOneWidget);
  });

  testWidgets('DR15b 拖回原位：松手后约 150ms 滑回原位，不弹面板', (tester) async {
    load(jwxt: [_jwxt('K1|01', '乙课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);
    final home = tester.getTopLeft(cellOf('乙课程').first);
    final g = await tester.startGesture(tester.getCenter(cellOf('乙课程').first));
    await tester.pump(const Duration(milliseconds: 850));
    // 中心仍在本列、上沿离第 1 节线最近 → 落回原位。
    await g.moveBy(Offset(step.width * 0.4, step.height * 0.4));
    await tester.pump();
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final dragging = find.byKey(const Key('week_grid_dragging_cell'));
    expect(dragging, findsOneWidget); // 正在滑回
    final mid = tester.getTopLeft(dragging);
    expect(
      mid.dx > home.dx + 0.5 && mid.dx < home.dx + step.width * 0.4,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(dragging, findsNothing);
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(c.slotOverrides, isEmpty);
  });

  testWidgets('DR16 隐藏的周末列落不到：拖到最右只到周五', (tester) async {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: const [],
        settings: settings.copyWith(showSaturday: false, showSunday: false),
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: _week,
      manualCourses: [_manual('m1', '甲课程')],
    );
    await pumpGrid(tester);
    expect(c.visibleDays(_week), [1, 2, 3, 4, 5]);
    await longDrag(tester, cellOf('甲课程'), moves: [const Offset(3000, 0)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drag_scope_all_weeks')));
    await tester.pump();
    await settleIo(tester);
    final slots = c.manualCourses.single.slots;
    expect(slots.any((s) => s.day == 5 && s.startNode == 1), isTrue);
    expect(slots.any((s) => s.day > 5), isFalse);
  });

  testWidgets('范围面板：标题全角问号、纯白底无 surface tint、拖动条同课程详情', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.pink),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDragScopeSheet(context, week: _week),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('此更改应用范围？'), findsOneWidget);
    expect('此更改应用范围？'.codeUnits.last, 0xFF1F);
    final sheet = tester.widget<Material>(
      find.byKey(const Key('drag_scope_sheet')),
    );
    expect(sheet.color, const Color(0xFFFFFFFF));
    expect(sheet.surfaceTintColor, Colors.transparent);
    expect(sheet.elevation, 0);
    // 外层 BottomSheet 透明，不再叠 M3 的底色/tint。
    final bs = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(bs.backgroundColor, Colors.transparent);
    // 拖动条：与课程详情同一个 widget。
    final handle = find.byKey(const Key('sheet_drag_handle'));
    expect(handle, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('drag_scope_sheet')),
        matching: find.byType(SheetDragHandle),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(handle), const Size(36, 4));
    expect(
      tester.getTopLeft(handle).dy <
          tester.getTopLeft(find.text('此更改应用范围？')).dy,
      isTrue,
    );
  });

  testWidgets('A11Y 只改本周后：拆出的单周次课朗读/胶囊不含「单周」「双周」；'
      '未调动的多周单周课仍是「单周」', (tester) async {
    load(
      jwxt: [
        _jwxt('K1|01', '乙课程'),
        Course(
          id: 'K2|01',
          name: '丁课程',
          code: 'K2|01',
          source: CourseSource.jwxt,
          slots: [
            CourseSlot(
              day: 2,
              startNode: 5,
              endNode: 6,
              weeks: '10' * 8,
              weeksLabel: '1-15周(单)',
            ),
          ],
        ),
        Course(
          id: 'K3|01',
          name: '戊课程',
          code: 'K3|01',
          source: CourseSource.jwxt,
          slots: [
            CourseSlot(
              day: 5,
              startNode: 1,
              endNode: 2,
              weeks: '10' * 8,
              weeksLabel: '1-15周(单)',
            ),
          ],
        ),
      ],
    );
    for (final (id, day) in [('K1|01', 1), ('K2|01', 2)]) {
      final r = (await tester.runAsync(
        () => c.moveSlot(
          c.courses.firstWhere((x) => x.id == id),
          0,
          toDay: day + 2,
          toStartPeriod: 9,
          week: _week,
          scope: MoveScope.thisWeek,
        ),
      ))!;
      expect(r.status, MoveStatus.moved);
    }
    await pumpGrid(tester);
    String labelOf(String name) => tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.ancestor(
                  of: find.textContaining(name.substring(0, 2)),
                  matching: find.byType(CourseCell),
                ),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties
        .label!;
    final moved = labelOf('乙课程');
    expect(moved, contains('第9-10节'));
    expect(moved, isNot(contains('单周')));
    expect(moved, isNot(contains('双周')));
    // 丁课程（单周）只改本周后，调到新位置的只有第 7 周一周 → 不标单/双周。
    expect(labelOf('丁课程'), isNot(contains('单周')));
    expect(labelOf('丁课程'), isNot(contains('双周')));
    expect(labelOf('戊课程'), contains('单周'));
    expect(find.text('单周'), findsOneWidget); // 只有未调动的多周单周课有胶囊
  });

  void loadNc({List<Course> jwxt = const [], List<Course> manual = const []}) {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt,
        settings: settings.copyWith(showNonCurrentWeek: true),
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: _week,
      manualCourses: manual,
    );
  }

  String cellLabel(WidgetTester tester, String name) => tester
      .widget<Semantics>(
        find
            .descendant(of: cellOf(name), matching: find.byType(Semantics))
            .first,
      )
      .properties
      .label!;

  Finder pillIn(String name, String pill) =>
      find.descendant(of: cellOf(name), matching: find.text(pill));

  testWidgets('DR53 只改本周拆出的单周次（教务单周课）：无单/双周胶囊，朗读不含', (tester) async {
    load(
      jwxt: [
        Course(
          id: 'K2|01',
          name: '丁课程',
          code: 'K2|01',
          source: CourseSource.jwxt,
          slots: [
            CourseSlot(
              day: 2,
              startNode: 5,
              endNode: 6,
              weeks: '10' * 8,
              weeksLabel: '1-15周(单)',
            ),
          ],
        ),
      ],
    );
    final r = (await tester.runAsync(
      () => c.moveSlot(
        c.courses.single,
        0,
        toDay: 4,
        toStartPeriod: 9,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    ))!;
    expect(r.status, MoveStatus.moved);
    await pumpGrid(tester);
    expect(cellLabel(tester, '丁课程'), contains('第9-10节'));
    for (final p in ['单周', '双周']) {
      expect(pillIn('丁课程', p), findsNothing);
      expect(cellLabel(tester, '丁课程'), isNot(contains(p)));
    }
  });

  testWidgets('DR53b 教务课本来只有一周（仅第 7 周）：不标单周', (tester) async {
    load(
      jwxt: [
        Course(
          id: 'K4|01',
          name: '己课程',
          code: 'K4|01',
          source: CourseSource.jwxt,
          slots: [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: '0000001000000000',
              weeksLabel: '7周',
            ),
          ],
        ),
      ],
    );
    await pumpGrid(tester);
    expect(find.byType(CourseCell), findsOneWidget);
    for (final p in ['单周', '双周']) {
      expect(pillIn('己课程', p), findsNothing);
      expect(cellLabel(tester, '己课程'), isNot(contains(p)));
    }
  });

  testWidgets('DR53c 手动课只改本周拆出的一周：不标单/双周；原时段其余单周仍标', (tester) async {
    load(manual: [_manual('m1', '庚课程', weeks: '10' * 8)]);
    final r = (await tester.runAsync(
      () => c.moveSlot(
        c.manualCourseById('m1')!,
        0,
        toDay: 3,
        toStartPeriod: 9,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    ))!;
    expect(r.status, MoveStatus.moved);
    final split = c
        .manualCourseById('m1')!
        .slots
        .where((s) => s.day == 3 && s.startNode == 9)
        .single;
    expect('1'.allMatches(split.weeks).length, 1);
    await pumpGrid(tester);
    expect(find.byType(CourseCell), findsOneWidget);
    for (final p in ['单周', '双周']) {
      expect(pillIn('庚课程', p), findsNothing);
      expect(cellLabel(tester, '庚课程'), isNot(contains(p)));
    }
  });

  testWidgets('DR54 显示非本周 + 教务课只改本周：原位置不留「[非本周]」虚影', (tester) async {
    loadNc(jwxt: [_jwxt('K1|01', '乙课程')]);
    final r = (await tester.runAsync(
      () => c.moveSlot(
        c.courses.single,
        0,
        toDay: 3,
        toStartPeriod: 9,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    ))!;
    expect(r.status, MoveStatus.moved);
    await pumpGrid(tester);
    expect(find.byType(CourseCell), findsOneWidget);
    expect(find.textContaining('非本周'), findsNothing);
    expect(cellLabel(tester, '乙课程'), contains('第9-10节'));
  });

  testWidgets('V05f 非本周灰格：长按 + 移动不拖起、不弹范围面板、不写覆盖；点按仍打开详情', (tester) async {
    // 双周课：第 7 周为非本周灰格。
    loadNc(manual: [_manual('m1', '丙课程', weeks: '01' * 8)]);
    await pumpGrid(tester);
    // §13.8：非本周格课名无前缀，带「非本周」胶囊。
    expect(find.text('丙课程'), findsOneWidget);
    expect(find.text('非本周'), findsOneWidget);
    final before = c.manualCourseById('m1')!.slots;
    final step = cellStep(tester);
    final g = await tester.startGesture(tester.getCenter(cellOf('丙课程').first));
    await tester.pump(const Duration(milliseconds: 900));
    await g.moveBy(Offset(step.width * 1.2, step.height * 2.2));
    await tester.pump();
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('此更改应用范围？'), findsNothing);
    expect(taps, isEmpty);
    expect(c.slotOverrides, isEmpty);
    final after = c.manualCourseById('m1')!.slots;
    expect(after.length, before.length);
    expect(after.single.day, 1);
    expect(after.single.startNode, 1);
    expect(after.single.weeks, '01' * 8);
    await tester.tap(cellOf('丙课程').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, ['丙课程']);
  });

  testWidgets('拖动手势不影响 PageView 左右翻周', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final pc = PageController(initialPage: _week - 1);
    addTearDown(pc.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView.builder(
            controller: pc,
            itemCount: 16,
            itemBuilder: (context, i) => WeekGrid(week: i + 1, controller: c),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.fling(cellOf('甲课程'), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(pc.page, _week.toDouble());
    expect(find.text('此更改应用范围？'), findsNothing);
  });

  group('详情页恢复原位置', () {
    Future<void> pumpDetail(WidgetTester tester, GridCell cell) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      showCourseDetailSheet(context, cell: cell, controller: c),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('DR35/DR37 调过的教务课：显示原时间，点「恢复原位置」清掉记录', (tester) async {
      load(jwxt: [_jwxt('K1|01', '乙课程')]);
      final course = c.courses.single;
      final r = (await tester.runAsync(
        () => c.moveSlot(
          course,
          0,
          toDay: 3,
          toStartPeriod: 5,
          week: _week,
          scope: MoveScope.thisWeek,
        ),
      ))!;
      expect(r.status, MoveStatus.moved);
      final cell = c.cellsForDay(_week, 3).single;
      await pumpDetail(tester, cell);
      expect(find.text('已调课：原 周一 第 1–2 节'), findsOneWidget);
      expect(find.text('恢复原位置'), findsOneWidget);
      await tester.tap(find.byKey(const Key('course_detail_restore')));
      await tester.pump();
      await settleIo(tester);
      await tester.pumpAndSettle();
      expect(c.slotOverrides, isEmpty);
      expect(c.cellsForDay(_week, 3), isEmpty);
      expect(c.cellsForDay(_week, 1), hasLength(1));
      expect(find.text('已调课：原 周一 第 1–2 节'), findsNothing);
    });

    testWidgets('DR36 调过的手动课：无「已调课」行、无「恢复原位置」', (tester) async {
      load(manual: [_manual('m1', '甲课程')]);
      await tester.runAsync(
        () => c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 3,
          toStartPeriod: 5,
          week: _week,
          scope: MoveScope.thisWeek,
        ),
      );
      final cell = c.cellsForDay(_week, 3).single;
      await pumpDetail(tester, cell);
      expect(find.textContaining('已调课'), findsNothing);
      expect(find.text('恢复原位置'), findsNothing);
    });
  });
}
