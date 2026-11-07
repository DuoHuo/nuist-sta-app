import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'timetable_day_swap_ui.dart';
import 'timetable_edit_scope_sheet.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_detail_sheet.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';
import 'timetable_theme.dart';
import 'timetable_course_cell.dart';
import 'timetable_course_detail_sheet.dart' show SheetDragHandle;
import 'timetable_schedule_event_cell.dart';

const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 面板「此更改应用范围？」的结果；null（点遮罩/下拉关闭）等同取消。
/// 拖动松手后的范围选择。第 1 条起面板只给「只改这一天」（[thisWeek]）/「所有周」
/// （[allWeeks]）；[fromThisWeek] 保留给旧调用方，面板不再提供。
enum DragScopeChoice { thisWeek, fromThisWeek, allWeeks, cancel }

/// 落点恰好在两列分界 / 两节中间时取哪一边。
enum DropTieBreak {
  /// 前一天（左边一列）/ 前一节。
  earlier,

  /// 后一天 / 后一节。
  later,
}

/// 落点平局规则（产品 10/18 定稿：取左边一列、前一节）。
const DropTieBreak kDropTieBreak = DropTieBreak.earlier;

/// 松手落点（纯函数，便于单测）。
///
/// [left]/[top] 为浮动格「格位」（含 [TimetableTheme.cellMargin] 外边距，宽 = [dayWidth]）
/// 的左上角，网格坐标（0 = 第一列左边 / 第 1 节上沿）。
/// - 星期：格子水平中心所在的可见列（[visibleDays] 只含显示的列，隐藏的周末永远落不到）；
/// - 起始节：离格子上沿最近的节次线（四舍五入）；
/// - 夹紧：列在 0..列数-1；起始节在 1..[lastPeriod]-[span]+1，整门课放得下；
/// - 恰好平局按 [tieBreak]。
({int column, int day, int startPeriod}) resolveDropSlot({
  required double left,
  required double top,
  required double dayWidth,
  required double periodHeight,
  required List<int> visibleDays,
  required int span,
  required int lastPeriod,
  DropTieBreak tieBreak = kDropTieBreak,
}) {
  assert(visibleDays.isNotEmpty);
  final earlier = tieBreak == DropTieBreak.earlier;
  var column = 0;
  if (dayWidth > 0) {
    final x = (left + dayWidth / 2) / dayWidth;
    final f = x.floorToDouble();
    column = (x == f && earlier) ? f.toInt() - 1 : f.toInt();
  }
  column = column.clamp(0, visibleDays.length - 1);
  var line = 0;
  if (periodHeight > 0) {
    final y = top / periodHeight;
    final f = y.floorToDouble();
    final frac = y - f;
    line = frac > 0.5 || (frac == 0.5 && !earlier) ? f.toInt() + 1 : f.toInt();
  }
  final maxStart = math.max(1, lastPeriod - span + 1);
  final start = (line + 1).clamp(1, maxStart);
  return (column: column, day: visibleDays[column], startPeriod: start);
}

/// 单周：表头 + 节次列 + 课程网格。
///
/// 长按拖动调课（spec §13.2）：按住约 0.8 秒且手指开始移动后格子才拖起来；
/// 格子按像素连续跟手（保持抓取点，带阴影、不缩放），原位置空出；限制在网格内，
/// 不翻周，拖出网格不取消；拖动中不画落点框、不提示撞课。松手按 [resolveDropSlot]
/// 就近落位并用约 150ms 滑进格位：落回原位什么都不做（滑回原位），否则弹范围面板；
/// 取消（含点遮罩/下拉）时滑回原位。
/// 震动（§13.14，只用系统 HapticFeedback，不加权限）：拖起 mediumImpact，
/// 落进新格 lightImpact；换格、落回原位、取消都不震。
class WeekGrid extends StatefulWidget {
  const WeekGrid({
    super.key,
    required this.week,
    required this.controller,
    this.onCourseTap,
    this.onEventTap,
    this.focusedEvent,
    this.revealFocusedEvent = true,
    this.onFocusedEventRevealed,
    this.enableDrag = true,
    this.previewMode = false,
  });

  final int week;
  final TimetableController controller;
  final void Function(GridCell cell)? onCourseTap;

  /// 点日程格（考试 / 其他，§14.2）；为空时打开日程详情弹层。
  final void Function(ScheduleEvent event)? onEventTap;

  /// 从考试安排进入时临时展示并强调的日程，不改动显示设置。
  final ScheduleEvent? focusedEvent;

  /// 是否执行本次自动定位；翻离目标周再回来时不重复滚动或弹详情。
  final bool revealFocusedEvent;

  /// 自动定位开始后通知页面消费本次请求。
  final VoidCallback? onFocusedEventRevealed;

  /// 是否允许长按拖动调课。
  final bool enableDrag;

  /// 外观页缩略预览：禁点击/长按/拖动，只随设置即时重绘。
  final bool previewMode;

  @override
  State<WeekGrid> createState() => _WeekGridState();
}

/// 拖动中的状态。
class _DragState {
  _DragState({
    required this.cell,
    required this.slotIndex,
    required this.originColumn,
  });

  final GridCell cell;
  final int slotIndex;

  /// 原位置所在列（visibleDays 中的下标）。
  final int originColumn;

  /// 手指开始移动后才为 true（按住不动没有任何反馈）。
  bool moving = false;

  /// 手指相对按下点的位移（格子 = 原位置 + 位移，抓取点不跳）。
  Offset offset = Offset.zero;

  /// 松手后格子滑向的左上角（网格坐标）；null = 仍在跟手。
  Offset? settleTo;

  /// 松手后（滑动、等待面板/写入期间）为 true：拖动手势已结束。
  bool resolving = false;
}

class _WeekGridState extends State<WeekGrid> {
  _DragState? _drag;
  final _dragUpdates = ValueNotifier<int>(0);

  /// 松手后格子滑进落点 / 滑回原位的时长。
  static const Duration _settleDuration = Duration(milliseconds: 150);

  /// 浮动格阴影（约 Material elevation 6）。
  static final List<BoxShadow> _dragShadow = kElevationToShadow[6]!;

  TimetableController get controller => widget.controller;
  int get week => widget.week;

  // 最近一次布局的几何参数（拖动吸附用）。
  List<int> _days = const [];
  double _dayW = 0;
  double _periodH = 0;
  int _nodes = 0;

  ScheduleEvent? get _focusedEvent {
    final target = widget.focusedEvent;
    if (target == null || widget.previewMode) return null;
    final event = controller.scheduleEvents
        .where((e) => e.id == target.id)
        .firstOrNull;
    return event != null && controller.actualWeek(event.date) == week
        ? event
        : null;
  }

  @override
  void initState() {
    super.initState();
    _revealUnplacedEvent();
  }

  @override
  void didUpdateWidget(covariant WeekGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusedEvent != widget.focusedEvent) {
      _revealUnplacedEvent();
    }
  }

  @override
  void dispose() {
    _dragUpdates.dispose();
    super.dispose();
  }

  void _revealUnplacedEvent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.revealFocusedEvent) return;
      final event = _focusedEvent;
      if (event != null &&
          scheduleNodeRange(controller.periods, event.start, event.end) ==
              null) {
        widget.onFocusedEventRevealed?.call();
        _openEvent(context, event);
      }
    });
  }

  List<ScheduleGridItem> _scheduleItemsForDay(int day) {
    final items = scheduleItemsForColumn(controller, week, day);
    final event = _focusedEvent;
    if (event != null &&
        event.date.weekday == day &&
        !items.any((item) => item.event.id == event.id)) {
      final range = scheduleNodeRange(
        controller.periods,
        event.start,
        event.end,
      );
      if (range != null) {
        items.add(
          ScheduleGridItem(
            event: event,
            startNode: range.startNode,
            endNode: range.endNode,
          ),
        );
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final nodes = settings.nodesPerDay.clamp(1, TimetableTheme.maxNodesPerDay);
    final periodH = settings.periodHeight.clamp(
      TimetableTheme.periodHeightMin,
      TimetableTheme.periodHeightMax,
    );
    final radius = settings.cellRadius;
    // 列顺序（含「每周第一天」与周末自动显示）由数据层给出；周次仍按周一开头。
    // 周末列：当周周六/周日有可见日程时也自动显示（§14.2，同「有课自动显示」）。
    final days = [...visibleDaysWithEvents(controller, week)];
    final focusedEvent = _focusedEvent;
    if (focusedEvent != null && !days.contains(focusedEvent.date.weekday)) {
      days.add(focusedEvent.date.weekday);
      days.sort(
        (a, b) => settings.weekStartsSunday
            ? (a % 7).compareTo(b % 7)
            : a.compareTo(b),
      );
    }
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    // item 7：第 N 节下方的「其他」行，只放本周的无节次教务课。
    final others = otherCoursesForWeek(controller, week);

    return LayoutBuilder(
      builder: (context, constraints) {
        final periodW = TimetableTheme.periodColumnWidth;
        final dayW = (constraints.maxWidth - periodW) / days.length;
        final gridH = periodH * nodes;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        _days = days;
        _dayW = dayW;
        _periodH = periodH;
        _nodes = nodes;

        return Column(
          children: [
            SizedBox(
              height: TimetableTheme.weekHeaderHeight,
              child: Row(
                children: [
                  SizedBox(
                    width: periodW,
                    child: Center(
                      child: Text(
                        '${controller.monthLabelOf(week)}月',
                        style: TimetableTheme.microStyle(
                          color: TimetableTheme.colorsOf(context).hint,
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < days.length; i++)
                    Builder(
                      builder: (context) {
                        final date = controller.dateOfColumn(week, days[i]);
                        // EV-2：与任何节次都不重叠的日程不进网格，在日期下画圆点，
                        // 点表头列出。
                        final unplaced = scheduleUnplacedForColumn(
                          controller,
                          week,
                          days[i],
                        );
                        final focusHeader =
                            focusedEvent != null &&
                            focusedEvent.date.weekday == days[i] &&
                            scheduleNodeRange(
                                  controller.periods,
                                  focusedEvent.start,
                                  focusedEvent.end,
                                ) ==
                                null;
                        if (focusHeader &&
                            !unplaced.any((e) => e.id == focusedEvent.id)) {
                          unplaced.add(focusedEvent);
                        }
                        Widget header = _DayHeader(
                          label: _weekdayLabels[days[i] - 1],
                          day: date.day,
                          isToday:
                              date.year == todayDate.year &&
                              date.month == todayDate.month &&
                              date.day == todayDate.day,
                          headerTextSize: settings.headerTextSize,
                          dotColor: unplaced.isEmpty
                              ? null
                              : scheduleUnplacedDotColor(controller, unplaced),
                          swapped: controller.isSwappedDate(date),
                        );
                        if (!widget.previewMode && unplaced.isNotEmpty) {
                          header = Semantics(
                            button: true,
                            excludeSemantics: true,
                            label: scheduleUnplacedSemantics(
                              days[i],
                              unplaced.length,
                            ),
                            child: GestureDetector(
                              key: ValueKey('day_header_unplaced_${days[i]}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _showUnplacedSheet(
                                context,
                                days[i],
                                unplaced,
                              ),
                              child: header,
                            ),
                          );
                        }
                        // 第 8 条：长按表头整天调课 / 撤销调课。
                        if (!widget.previewMode) {
                          header = GestureDetector(
                            key: ValueKey('day_header_${days[i]}'),
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () =>
                                showDaySwapSheet(context, controller, date),
                            child: header,
                          );
                        } else {
                          header = KeyedSubtree(
                            key: ValueKey('day_header_${days[i]}'),
                            child: header,
                          );
                        }
                        return SizedBox(
                          width: dayW,
                          child: focusHeader
                              ? _FocusedScheduleTarget(
                                  eventId: focusedEvent.id,
                                  reveal: widget.revealFocusedEvent,
                                  onRevealed: widget.onFocusedEventRevealed,
                                  radius: TimetableTheme.todayHeaderRadius,
                                  scrollIntoView: false,
                                  child: header,
                                )
                              : header,
                        );
                      },
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    SizedBox(
                      height: gridH,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: periodW,
                            height: gridH,
                            child: Column(
                              children: [
                                for (var n = 1; n <= nodes; n++)
                                  SizedBox(
                                    height: periodH,
                                    child: _PeriodLabel(
                                      node: n,
                                      period: controller.periodAt(n),
                                      showTimes: settings.showPeriodTimes,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SizedBox(
                              height: gridH,
                              child: Stack(
                                children: [
                                  // 网格与浮动格分开记录绘制指令，跟手位移时复用底层课程。
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      key: const Key('week_grid_static_layer'),
                                      child: Stack(
                                        children: [
                                          if (settings.showGridLines)
                                            CustomPaint(
                                              size: Size(
                                                dayW * days.length,
                                                gridH,
                                              ),
                                              painter: _GridPainter(
                                                days: days.length,
                                                nodes: nodes,
                                                periodH: periodH,
                                                dayW: dayW,
                                                color: TimetableTheme.colorsOf(
                                                  context,
                                                ).divider,
                                              ),
                                            ),
                                          for (
                                            var di = 0;
                                            di < days.length;
                                            di++
                                          )
                                            ..._cellsFor(
                                              context,
                                              day: days[di],
                                              dayIndex: di,
                                              dayW: dayW,
                                              periodH: periodH,
                                              radius: radius,
                                              nodes: nodes,
                                              dpr: dpr,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  ?_draggedCell(dayW, periodH, radius),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (others.isNotEmpty)
                      _OtherCoursesRow(
                        courses: others,
                        periodW: periodW,
                        onTap: widget.previewMode
                            ? (_) {}
                            : (c) => _showOtherCourseSheet(context, c),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _isDragged(GridCell c) {
    final d = _drag;
    if (d == null || !(d.moving || d.resolving)) return false;
    final a = c.slot, b = d.cell.slot;
    return c.course.id == d.cell.course.id &&
        a.day == b.day &&
        a.startNode == b.startNode &&
        a.endNode == b.endNode &&
        a.weeks == b.weeks;
  }

  List<Widget> _cellsFor(
    BuildContext context, {
    required int day,
    required int dayIndex,
    required double dayW,
    required double periodH,
    required double radius,
    required int nodes,
    required double dpr,
  }) {
    final widgets = <Widget>[];
    final dayCells = [
      for (final c in controller.cellsForDay(week, day))
        if (!isMovedAwayGhost(c, week)) c,
    ];
    // 日程（考试 / 其他，§14.2）：按时间映射到节次，夹在可见节数内（不消失）。
    // 考试受显示开关控制；从考试安排选中的目标在本页临时展示。
    final events = [
      for (final e in _scheduleItemsForDay(day))
        ScheduleGridItem(
          event: e.event,
          startNode: e.startNode.clamp(1, nodes),
          endNode: e.endNode.clamp(1, nodes),
          activeThisWeek: e.activeThisWeek,
        ),
    ];
    final absorbed = <String>{};
    for (final group in _groupsForEventFocus(dayCells, events)) {
      // 与本周课重叠的日程并入该组：计入「N 门」与冲突圆点，点开时一起列出。
      // 非本周灰格与日程重叠时让位不画（同灰格让位本周课）。
      final overlapping = [
        for (final e in events)
          if (e.overlapsNodes(group.startNode, group.endNode)) e,
      ];
      if (group.active.isEmpty && overlapping.isNotEmpty) continue;
      final extra = group.active.isEmpty
          ? const <ScheduleGridItem>[]
          : overlapping;
      final focusedItem = extra
          .where(
            (e) =>
                e.event.id == _focusedEvent?.id &&
                !absorbed.contains(e.event.id),
          )
          .firstOrNull;
      absorbed.addAll([for (final e in extra) e.event.id]);
      // 拖起来的那一格：原位置空出来（不留虚影）。为了不打断进行中的长按手势，
      // 原格子的 widget 保留在树里（结构不变），只是改为透明或改显示同组剩下的课。
      final dragCell = group.primary;
      var cell = dragCell;
      var stack = group.active.length;
      var hidden = false;
      if (group.cells.any(_isDragged)) {
        final rest = [
          for (final c in group.cells)
            if (!_isDragged(c)) c,
        ];
        if (rest.isEmpty) {
          hidden = true;
        } else {
          final g = SlotCellGroup(rest);
          cell = g.primary;
          stack = g.active.length;
        }
      }
      stack += extra.length;
      var groupStart = group.startNode;
      var groupEnd = group.endNode;
      for (final e in extra) {
        groupStart = math.min(groupStart, e.startNode);
        groupEnd = math.max(groupEnd, e.endNode);
      }
      if (groupStart > nodes) continue;
      final end = groupEnd.clamp(1, nodes);
      final start = groupStart.clamp(1, nodes);
      if (end < start) continue;
      // 叠放时用该组的并集节次范围，避免遮挡。
      final rawTop = (start - 1) * periodH + TimetableTheme.cellMargin;
      final rawHeight =
          (end - start + 1) * periodH - TimetableTheme.cellMargin * 2;
      final rawLeft = dayIndex * dayW + TimetableTheme.cellMargin;
      final rawWidth = dayW - TimetableTheme.cellMargin * 2;
      // 对齐到物理像素，避免 cellMargin=1.5 + 小数 dayW 落在半像素上导致文字发虚。
      final box = TimetableTheme.snapDeviceRect(
        left: rawLeft,
        top: rawTop,
        width: rawWidth,
        height: rawHeight,
        dpr: dpr,
      );
      final left = box.left;
      final top = box.top;
      final width = box.width;
      final height = box.height;
      final draggable =
          widget.enableDrag &&
          !widget.previewMode &&
          dragCell.activeThisWeek &&
          dragCell.slot.hasFixedTime;
      widgets.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          // 拖走后原位隐藏：用 Visibility 保布局，避免 Opacity 造成整格半透明栅格化发虚。
          child: Visibility(
            visible: !hidden,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: focusedItem != null
                ? _FocusedScheduleTarget(
                    eventId: focusedItem.event.id,
                    reveal: widget.revealFocusedEvent,
                    onRevealed: widget.onFocusedEventRevealed,
                    radius: radius,
                    child: ScheduleEventCell(
                      controller: controller,
                      event: focusedItem.event,
                      width: width,
                      height: height,
                      radius: radius,
                      stackCount: stack,
                      onTap: () => _showStackSheet(
                        context,
                        group.active,
                        events: [
                          focusedItem.event,
                          for (final e in extra)
                            if (e.event.id != focusedItem.event.id) e.event,
                        ],
                      ),
                    ),
                  )
                : CourseCell(
                    controller: controller,
                    cell: cell,
                    width: width,
                    height: height,
                    radius: radius,
                    stackCount: stack,
                    onTap: widget.onCourseTap == null
                        ? null
                        : stack > 1
                        ? () => _showStackSheet(
                            context,
                            group.active,
                            events: [for (final e in extra) e.event],
                          )
                        : () => widget.onCourseTap!(cell),
                    onDragStart: draggable
                        ? (_) => _onDragStart(dragCell)
                        : null,
                    onDragUpdate: draggable ? _onDragUpdate : null,
                    onDragEnd: draggable ? _onDragEnd : null,
                    onDragCancel: draggable ? _onDragCancel : null,
                  ),
          ),
        ),
      );
    }
    widgets.addAll(
      _eventCellsFor(
        context,
        items: [
          for (final e in events)
            if (!absorbed.contains(e.event.id)) e,
        ],
        dayIndex: dayIndex,
        dayW: dayW,
        periodH: periodH,
        radius: radius,
        dpr: dpr,
      ),
    );
    return widgets;
  }

  /// 考试可能跨过多段课程；把目标连通范围合成一组，避免后画的课遮住目标。
  List<SlotCellGroup> _groupsForEventFocus(
    List<GridCell> cells,
    List<ScheduleGridItem> events,
  ) {
    final groups = groupSlotCells(cells);
    final target = events
        .where((e) => e.event.id == _focusedEvent?.id)
        .firstOrNull;
    if (target == null) return groups;
    var start = target.startNode;
    var end = target.endNode;
    final connected = <SlotCellGroup>{};
    var expanded = true;
    while (expanded) {
      final oldStart = start;
      final oldEnd = end;
      for (final event in events) {
        if (event.overlapsNodes(start, end)) {
          start = math.min(start, event.startNode);
          end = math.max(end, event.endNode);
        }
      }
      for (final group in groups) {
        if (group.active.isNotEmpty &&
            group.startNode <= end &&
            start <= group.endNode) {
          connected.add(group);
          start = math.min(start, group.startNode);
          end = math.max(end, group.endNode);
        }
      }
      expanded = start != oldStart || end != oldEnd;
    }
    if (connected.isEmpty) return groups;
    return [
      for (final group in groups)
        if (!connected.contains(group)) group,
      _FocusedSlotCellGroup(
        [for (final group in connected) ...group.active],
        startNode: start,
        endNode: end,
      ),
    ];
  }

  void _openEvent(BuildContext context, ScheduleEvent e) {
    if (widget.previewMode) return;
    final cb = widget.onEventTap;
    if (cb != null) {
      cb(e);
      return;
    }
    showScheduleEventDetailSheet(context, event: e, controller: controller);
  }

  /// 不与本周课重叠的日程格（§14.2）：彼此节次重叠的成组，只画一格（按开始时间、
  /// 名称排序的第一项）并显示「N 门」与冲突圆点，点开列出；不可拖动。
  List<Widget> _eventCellsFor(
    BuildContext context, {
    required List<ScheduleGridItem> items,
    required int dayIndex,
    required double dayW,
    required double periodH,
    required double radius,
    required double dpr,
  }) {
    final sorted = List.of(items)
      ..sort((a, b) {
        final byNode = a.startNode.compareTo(b.startNode);
        if (byNode != 0) return byNode;
        final byTime = a.event.start.compareTo(b.event.start);
        if (byTime != 0) return byTime;
        return a.event.title.compareTo(b.event.title);
      });
    final clusters = <List<ScheduleGridItem>>[];
    var curEnd = -1;
    for (final e in sorted) {
      if (clusters.isNotEmpty && e.startNode <= curEnd) {
        clusters.last.add(e);
        curEnd = math.max(curEnd, e.endNode);
      } else {
        clusters.add([e]);
        curEnd = e.endNode;
      }
    }
    return [
      for (final cluster in clusters)
        () {
          final start = cluster.map((e) => e.startNode).reduce(math.min);
          final end = cluster.map((e) => e.endNode).reduce(math.max);
          final box = TimetableTheme.snapDeviceRect(
            left: dayIndex * dayW + TimetableTheme.cellMargin,
            top: (start - 1) * periodH + TimetableTheme.cellMargin,
            width: dayW - TimetableTheme.cellMargin * 2,
            height: (end - start + 1) * periodH - TimetableTheme.cellMargin * 2,
            dpr: dpr,
          );
          final width = box.width;
          final height = box.height;
          final primaryItem =
              cluster
                  .where((e) => e.event.id == _focusedEvent?.id)
                  .firstOrNull ??
              cluster.first;
          final primary = primaryItem.event;
          final cell = ScheduleEventCell(
            controller: controller,
            event: primary,
            width: width,
            height: height,
            radius: radius,
            stackCount: cluster.length,
            activeThisWeek: primaryItem.activeThisWeek,
            onTap: cluster.length > 1
                ? () => _showStackSheet(
                    context,
                    const [],
                    events: [
                      primary,
                      for (final e in cluster)
                        if (e.event.id != primary.id) e.event,
                    ],
                  )
                : () => _openEvent(context, primary),
          );
          return Positioned(
            key: ValueKey('schedule_slot_${primary.id}'),
            left: box.left,
            top: box.top,
            width: width,
            height: height,
            child: primary.id == _focusedEvent?.id
                ? _FocusedScheduleTarget(
                    eventId: primary.id,
                    reveal: widget.revealFocusedEvent,
                    onRevealed: widget.onFocusedEventRevealed,
                    radius: radius,
                    child: cell,
                  )
                : cell,
          );
        }(),
    ];
  }

  /// 跟手的格子：按像素跟手（松手后滑进落点），大小与原格一致、带阴影、不缩放；
  /// 不画落点框、不显示撞课。
  Widget? _draggedCell(double dayW, double periodH, double radius) {
    final d = _drag;
    if (d == null || !(d.moving || d.resolving)) return null;
    final span = d.cell.slot.span;
    // 浮动格与原格同大小：按原格位对齐物理像素后取宽高，避免拖动时比原格窄/高一点点。
    final origin = _slotTopLeft(d.originColumn, d.cell.slot.startNode);
    final originBox = TimetableTheme.snapDeviceRect(
      left: origin.dx,
      top: origin.dy,
      width: dayW - TimetableTheme.cellMargin * 2,
      height: span * periodH - TimetableTheme.cellMargin * 2,
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
    final height = originBox.height;
    final width = originBox.width;
    return Positioned(
      left: 0,
      top: 0,
      width: width,
      height: height,
      child: ValueListenableBuilder<int>(
        valueListenable: _dragUpdates,
        builder: (context, _, child) {
          final pos = d.settleTo ?? _followTopLeft(d);
          // 改变绘制变换而非 Positioned 的布局参数，拖动与吸附都不重排整张 Stack。
          return TweenAnimationBuilder<Offset>(
            tween: Tween(begin: pos, end: pos),
            duration: d.settleTo == null ? Duration.zero : _settleDuration,
            curve: Curves.easeOut,
            builder: (context, offset, child) =>
                Transform.translate(offset: offset, child: child),
            child: child,
          );
        },
        child: RepaintBoundary(
          key: const Key('week_grid_dragging_cell'),
          child: IgnorePointer(
            child: DecoratedBox(
              key: const Key('week_grid_dragging_shadow'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: _dragShadow,
              ),
              child: CourseCell(
                controller: controller,
                cell: GridCell(
                  course: d.cell.course,
                  slot: d.cell.slot,
                  conflictCount: 0,
                  activeThisWeek: true,
                  date: d.cell.date,
                  dateEdit: d.cell.dateEdit,
                  swappedFrom: d.cell.swappedFrom,
                ),
                width: width,
                height: height,
                radius: radius,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 第 [column] 列、第 [start] 节起的格子左上角（网格坐标，含外边距）。
  Offset _slotTopLeft(int column, int start) => Offset(
    column * _dayW + TimetableTheme.cellMargin,
    (start - 1) * _periodH + TimetableTheme.cellMargin,
  );

  /// 跟手位置：原位置 + 手指位移，夹紧在网格内（不出网格，不取消）。
  Offset _followTopLeft(_DragState d) {
    const m = TimetableTheme.cellMargin;
    final origin = _slotTopLeft(d.originColumn, d.cell.slot.startNode);
    final maxX = math.max(m, (_days.length - 1) * _dayW + m);
    final maxY = math.max(m, (_nodes - d.cell.slot.span) * _periodH + m);
    return Offset(
      (origin.dx + d.offset.dx).clamp(m, maxX),
      (origin.dy + d.offset.dy).clamp(m, maxY),
    );
  }

  /// 把浮动格滑到 [to]（约 150ms）。
  Future<void> _settleTo(_DragState d, Offset to) async {
    if (!mounted) return;
    d.settleTo = to;
    _dragUpdates.value++;
    await Future<void>.delayed(_settleDuration);
  }

  // ---- 拖动 ----

  static int _slotIndexOf(Course course, CourseSlot slot) {
    final i = course.slots.indexWhere((s) => identical(s, slot));
    if (i >= 0) return i;
    return course.slots.indexWhere(
      (s) =>
          s.day == slot.day &&
          s.startNode == slot.startNode &&
          s.endNode == slot.endNode &&
          s.weeks == slot.weeks,
    );
  }

  /// 可落的最后一节：网格可见节数与作息最后一节取小。
  int get _lastStartLimit {
    final last = controller.lastPeriod;
    return last < _nodes ? last : _nodes;
  }

  /// 长按被系统打断（如来电、手势被取消）：格子回原位，数据不变。
  void _onDragCancel() {
    final d = _drag;
    if (d == null || d.resolving) return;
    if (mounted) setState(() => _drag = null);
  }

  void _onDragStart(GridCell cell) {
    if (_drag != null) return;
    // 整天调课 / 单日修改后的格子不在 course.slots 里：按底层那次课找下标。
    var idx = _slotIndexOf(cell.course, cell.slot);
    if (idx < 0) {
      idx = controller.baseOccurrenceOf(cell, week: week)?.slotIndex ?? -1;
    }
    if (idx < 0) return;
    final col = _days.indexOf(cell.slot.day);
    if (col < 0) return;
    // 只记下，不 setState：按住不动时没有任何反馈（不震动、不放大）。
    _drag = _DragState(cell: cell, slotIndex: idx, originColumn: col);
  }

  void _onDragUpdate(LongPressMoveUpdateDetails details) {
    final d = _drag;
    if (d == null || d.resolving) return;
    final offset = details.offsetFromOrigin;
    if (!d.moving && offset == Offset.zero) return;
    if (d.moving && d.offset == offset) return;
    // §13.14：长按满 0.8s 并开始移动 = 拖起，一次中等震动；拖动中换格不震。
    d.offset = offset;
    if (!d.moving) {
      HapticFeedback.mediumImpact();
      // 仅首次拖起重建原格（隐藏/显示同组剩余课程）。后续坐标只通知浮层，
      // 不再逐帧重算所有列、冲突分组与文字布局。
      setState(() => d.moving = true);
    } else {
      _dragUpdates.value++;
    }
  }

  Future<void> _onDragEnd(LongPressEndDetails details) async {
    final d = _drag;
    if (d == null || d.resolving) return;
    if (!d.moving) {
      // 按住后没动就松手：什么都不做。
      _drag = null;
      return;
    }
    d.resolving = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final pos = _followTopLeft(d);
    final drop = resolveDropSlot(
      left: pos.dx - TimetableTheme.cellMargin,
      top: pos.dy - TimetableTheme.cellMargin,
      dayWidth: _dayW,
      periodHeight: _periodH,
      visibleDays: _days,
      span: d.cell.slot.span,
      lastPeriod: _lastStartLimit,
    );
    final toDay = drop.day;
    final toStart = drop.startPeriod;
    final home = _slotTopLeft(d.originColumn, d.cell.slot.startNode);
    if (toDay == d.cell.slot.day && toStart == d.cell.slot.startNode) {
      // 拖回原位置：滑回原位，不弹面板，不写任何东西，也不震（QA 默认，见 HP-1）。
      await _settleTo(d, home);
      if (mounted) setState(() => _drag = null);
      return;
    }
    // §13.14：松手落进新格一下轻震；之后弹面板、取消滑回都不再震。
    HapticFeedback.lightImpact();
    await _settleTo(d, _slotTopLeft(drop.column, toStart));
    if (!mounted) return;
    final choice = await showDragScopeSheet(
      context,
      week: week,
      date: d.cell.date,
    );
    if (!mounted) return;
    if (choice == null || choice == DragScopeChoice.cancel) {
      // 取消 / 点遮罩 / 下拉关闭：滑回原位，数据不变。
      await _settleTo(d, home);
      if (mounted) setState(() => _drag = null);
      return;
    }
    MoveResult result;
    try {
      result = switch (choice) {
        // 第 1 条：只改这一天（普通格仍是拖动调课「只改本周」；整天调课 / 单日修改的
        // 格写单日修改记录，见 moveOccurrenceThisDay）。
        DragScopeChoice.thisWeek => await controller.moveOccurrenceThisDay(
          d.cell,
          toDay: toDay,
          toStartPeriod: toStart,
          week: week,
        ),
        DragScopeChoice.allWeeks => await controller.moveOccurrenceAllWeeks(
          d.cell,
          toDay: toDay,
          toStartPeriod: toStart,
          week: week,
        ),
        _ => await controller.moveSlot(
          d.cell.course,
          d.slotIndex,
          toDay: toDay,
          toStartPeriod: toStart,
          week: week,
          scope: MoveScope.fromThisWeek,
        ),
      };
    } catch (_) {
      result = const MoveResult.error(MoveError.invalidSlot);
    }
    if (mounted) setState(() => _drag = null);
    switch (result.status) {
      case MoveStatus.moved:
        final msg = result.conflictMessage;
        if (msg != null) {
          messenger?.showSnackBar(
            SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)),
          );
        }
      case MoveStatus.noChange:
        break;
      case MoveStatus.error:
        messenger?.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('调课失败，课程未改动'),
          ),
        );
    }
  }

  /// 「其他」行里的一门课（item 7）：底部弹层显示课名、周次、老师、地点。
  Future<void> _showOtherCourseSheet(BuildContext context, Course course) {
    final colors = TimetableTheme.colorsOf(context);
    final slot = course.slots.isEmpty ? null : course.slots.first;
    final weeks = slot == null || slot.weeksLabel.trim().isEmpty
        ? '无固定时间'
        : slot.weeksLabel;
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('other_course_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                slot == null
                    ? course.displayName
                    : courseDisplayName(course: course, slot: slot),
                style: TimetableTheme.titleStyle(color: colors.titleText),
              ),
            ),
            for (final (icon, text) in [
              (Icons.date_range_outlined, weeks),
              if (slot != null && slot.teacher.isNotEmpty)
                (Icons.person_outline, slot.teacher),
              if (slot != null && slot.location.isNotEmpty)
                (Icons.place_outlined, slot.location),
            ])
              ListTile(
                leading: Icon(icon, size: 20, color: colors.hint),
                title: Text(
                  text,
                  style: TimetableTheme.bodyStyle(color: colors.labelText),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 当天不在节次内的日程（EV-2）：底部弹层列出，点某项打开其详情。
  Future<void> _showUnplacedSheet(
    BuildContext context,
    int day,
    List<ScheduleEvent> events,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('unplaced_events_sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '${scheduleWeekdayName(day)}不在节次内的 ${events.length} 项',
                style: TimetableTheme.titleStyle(
                  color: TimetableTheme.colorsOf(context).titleText,
                ),
              ),
            ),
            for (final e in events)
              ListTile(
                key: ValueKey('unplaced_item_${e.id}'),
                title: Text(e.title),
                subtitle: Text(
                  '${schedulePillLabel(e)} · ${scheduleTimeText(e)}'
                  '${e.location.isEmpty ? '' : ' · ${e.location}'}',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openEvent(context, e);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 同一时段多门课（含重叠的考试 / 日程）：底部弹层列出，点某项打开其详情。
  Future<void> _showStackSheet(
    BuildContext context,
    List<GridCell> cells, {
    List<ScheduleEvent> events = const [],
  }) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                events.isEmpty
                    ? '本时段 ${cells.length} 门课'
                    : '本时段 ${cells.length + events.length} 项',
                style: TimetableTheme.titleStyle(
                  color: TimetableTheme.colorsOf(context).titleText,
                ),
              ),
            ),
            for (final c in cells)
              ListTile(
                key: ValueKey('stack_item_${c.course.id}'),
                title: Text(courseDisplayName(course: c.course, slot: c.slot)),
                subtitle: Text(
                  '第 ${c.slot.startNode}–${c.slot.endNode} 节'
                  '${c.slot.location.isEmpty ? '' : ' · ${c.slot.location}'}',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onCourseTap?.call(c);
                },
              ),
            for (final e in events)
              ListTile(
                key: ValueKey('stack_item_event_${e.id}'),
                title: Text(e.title),
                subtitle: Text(
                  '${schedulePillLabel(e)} · ${scheduleTimeText(e)}'
                  '${e.location.isEmpty ? '' : ' · ${e.location}'}',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openEvent(context, e);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 范围面板浅色底色（纯白）；实际取 [TimetableColors.surface]，深色下随主题变暗。
const Color kDragScopeSheetColor = Color(0xFFFFFFFF);

/// 拖动松手后的范围面板（spec §13.2，产品经理 10/18：先做三项）。
/// 点遮罩或下拉关闭返回 null，调用方按取消处理。
///
/// 第 1 条：「只改这一天（M月D日）」（默认，第一项）/「所有周」/「取消」。
/// [date] 为空（旧调用方）时第一项显示「只改本周（第 N 周）」。
Future<DragScopeChoice?> showDragScopeSheet(
  BuildContext context, {
  required int week,
  DateTime? date,
}) {
  return showModalBottomSheet<DragScopeChoice>(
    context: context,
    isDismissible: true,
    enableDrag: true,
    // 弹层本身透明，内容用纯白 Material（elevation 0、surfaceTintColor 透明，
    // 没有 M3 surface tint）；顶部拖动条复用课程详情的 [SheetDragHandle]。
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) => Material(
      key: const Key('drag_scope_sheet'),
      color: TimetableTheme.colorsOf(sheetContext).surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TimetableTheme.sheetTopRadius),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const Center(child: SheetDragHandle()),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '此更改应用范围？',
                style: TimetableTheme.titleStyle(
                  color: TimetableTheme.colorsOf(context).titleText,
                ),
              ),
            ),
            ListTile(
              key: const Key('drag_scope_this_week'),
              title: Text(
                date == null ? '只改本周（第 $week 周）' : editScopeThisDayLabel(date),
              ),
              onTap: () =>
                  Navigator.pop(sheetContext, DragScopeChoice.thisWeek),
            ),
            ListTile(
              key: const Key('drag_scope_all_weeks'),
              title: const Text('所有周'),
              onTap: () =>
                  Navigator.pop(sheetContext, DragScopeChoice.allWeeks),
            ),
            ListTile(
              key: const Key('drag_scope_cancel'),
              title: const Text('取消'),
              onTap: () => Navigator.pop(sheetContext, DragScopeChoice.cancel),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 同一天里节次重叠（传递闭包）的一组课程格。
class SlotCellGroup {
  SlotCellGroup(this.cells);

  /// 组内格子（全为本周课，或全为非本周灰格；见 [groupSlotCells]）。
  final List<GridCell> cells;

  /// 本周有课的格子，按课名排序（「N 门」= 其数量，≥2 才叠放）。
  late final List<GridCell> active =
      cells.where((c) => c.activeThisWeek).toList()..sort(_byName);

  /// 实际绘制的一格。
  ///
  /// 按课名（[normalizeCourseName]）排序的第一门。
  GridCell get primary {
    final base = (List.of(cells)..sort(_byName)).first;
    // 冲突点/「N 门」由 WeekGrid 按本周叠放数决定，不沿用 controller 的 conflictCount。
    return GridCell(
      course: base.course,
      slot: base.slot,
      conflictCount: active.length > 1 ? active.length - 1 : 0,
      activeThisWeek: base.activeThisWeek,
      date: base.date,
      dateEdit: base.dateEdit,
      swappedFrom: base.swappedFrom,
    );
  }

  /// 组的并集节次范围（叠放时一格覆盖全部，避免遮挡）。
  int get startNode =>
      cells.map((c) => c.slot.startNode).reduce((a, b) => a < b ? a : b);

  int get endNode =>
      cells.map((c) => c.slot.endNode).reduce((a, b) => a > b ? a : b);

  static int _byName(GridCell a, GridCell b) {
    final byName =
        normalizeCourseName(courseDisplayName(course: a.course, slot: a.slot))
            .compareTo(
              normalizeCourseName(
                courseDisplayName(course: b.course, slot: b.slot),
              ),
            );
    if (byName != 0) return byName;
    return a.course.id.compareTo(b.course.id);
  }
}

/// 定位考试时的课程组范围包含连接它们的考试与日程。
class _FocusedSlotCellGroup extends SlotCellGroup {
  _FocusedSlotCellGroup(
    super.cells, {
    required this.startNode,
    required this.endNode,
  });

  @override
  final int startNode;

  @override
  final int endNode;
}

bool _periodsOverlap(GridCell a, GridCell b) =>
    a.slot.startNode <= b.slot.endNode && b.slot.startNode <= a.slot.endNode;

List<SlotCellGroup> _clusters(List<GridCell> cells) {
  final sorted = List.of(cells)
    ..sort((a, b) => a.slot.startNode.compareTo(b.slot.startNode));
  final groups = <SlotCellGroup>[];
  var current = <GridCell>[];
  var currentEnd = -1;
  for (final c in sorted) {
    if (current.isNotEmpty && c.slot.startNode <= currentEnd) {
      current.add(c);
      if (c.slot.endNode > currentEnd) currentEnd = c.slot.endNode;
    } else {
      if (current.isNotEmpty) groups.add(SlotCellGroup(current));
      current = [c];
      currentEnd = c.slot.endNode;
    }
  }
  if (current.isNotEmpty) groups.add(SlotCellGroup(current));
  return groups;
}

/// 「只改本周」后原位置剩下的时段（教务课覆盖记录，[SlotOrigin.moved] 为 false）：
/// 本周那次已调走，原位置不画「[非本周]」虚影。
bool isMovedAwayGhost(GridCell c, int week) {
  if (c.activeThisWeek) return false;
  final o = slotOriginOf(c.slot);
  return o != null && !o.moved && o.original.hasClassInWeek(week);
}

/// 把一天的格子分组，每组画一格。
///
/// - 本周有课的格子之间按节次重叠（传递）成组：同组 ≥2 门 = 本周真实冲突
///   （同星期 + 节次重叠 + 本周都有课，等价于对本周做 slotsConflict）→「N 门」+ 冲突点。
///   单双周同节次的两门课在任一周只有一门本周有课 → 正常单格。
/// - 非本周灰格（「显示非本周课程」开启时）：与任一本周课重叠则让位不画、不计数；
///   其余灰格之间同样成组，只画一格、不显示「N 门」。
///   （让位规则待设计确认，集中在此函数，便于修改。）
List<SlotCellGroup> groupSlotCells(List<GridCell> cells) {
  final active = [
    for (final c in cells)
      if (c.activeThisWeek) c,
  ];
  final ghosts = [
    for (final c in cells)
      if (!c.activeThisWeek && !active.any((a) => _periodsOverlap(a, c))) c,
  ];
  return [..._clusters(active), ..._clusters(ghosts)];
}

/// 「其他」行（item 7）：只放教务（jwxt）里没有排节次的课，手动课与日程不进来
/// （不在节次内的日程仍是表头圆点）。周次只认 weeksLabel 里读得出的「a-b周」「a周」
/// （可带单/双）；读不出或为空时每周都显示。
List<Course> otherCoursesForWeek(TimetableController c, int week) => [
  for (final course in c.otherCourses())
    if (course.source == CourseSource.jwxt && otherCourseInWeek(course, week))
      course,
];

/// [course]（无节次课）在第 [week] 周是否显示，规则见 [otherCoursesForWeek]。
bool otherCourseInWeek(Course course, int week) {
  for (final s in course.slots) {
    if (s.weeksLabel.trim().isEmpty) return true;
    final weeks = parseOtherWeeksLabel(s.weeksLabel);
    if (weeks == null || weeks.contains(week)) return true;
  }
  return course.slots.isEmpty;
}

/// 「1-16周」「2-17周(双)」「1-8,10-16周」「第3周」→ 周次集合；读不出返回 null。
Set<int>? parseOtherWeeksLabel(String label) {
  final out = <int>{};
  final re = RegExp(r'^第?(\d+)(?:[-–~至](\d+))?周?(?:[(（]?([单双])周?[)）]?)?$');
  for (final part in label.trim().split(RegExp(r'[,，、;；\s]+'))) {
    if (part.isEmpty) continue;
    final m = re.firstMatch(part);
    if (m == null) return null;
    final a = int.parse(m[1]!);
    final b = m[2] == null ? a : int.parse(m[2]!);
    if (a < 1 || b < a || b > 60) return null;
    for (var w = a; w <= b; w++) {
      if (m[3] == '单' && w.isEven) continue;
      if (m[3] == '双' && w.isOdd) continue;
      out.add(w);
    }
  }
  return out.isEmpty ? null : out;
}

class _OtherCoursesRow extends StatelessWidget {
  const _OtherCoursesRow({
    required this.courses,
    required this.periodW,
    required this.onTap,
  });

  final List<Course> courses;
  final double periodW;
  final void Function(Course course) onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Container(
      key: const Key('week_grid_other_row'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: periodW,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Center(
                child: Text(
                  '其他',
                  style: TimetableTheme.captionStyle(color: colors.labelText),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in courses)
                    Semantics(
                      button: true,
                      excludeSemantics: true,
                      label: '其他课程，${c.displayName}',
                      child: Material(
                        color: colors.chipBg,
                        shape: const StadiumBorder(),
                        child: InkWell(
                          key: ValueKey('other_course_${c.id}'),
                          customBorder: const StadiumBorder(),
                          onTap: () => onTap(c),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 32),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Text(
                                c.displayName,
                                style: TimetableTheme.captionStyle(
                                  color: colors.titleText,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 定位完成后保持描边与阴影，再淡出；只重绘强调层，不改变格子尺寸。
class _FocusedScheduleTarget extends StatefulWidget {
  const _FocusedScheduleTarget({
    required this.eventId,
    required this.radius,
    required this.child,
    this.scrollIntoView = true,
    required this.reveal,
    this.onRevealed,
  });

  final String eventId;
  final double radius;
  final Widget child;
  final bool scrollIntoView;
  final bool reveal;
  final VoidCallback? onRevealed;

  @override
  State<_FocusedScheduleTarget> createState() => _FocusedScheduleTargetState();
}

class _FocusedScheduleTargetState extends State<_FocusedScheduleTarget> {
  Timer? _holdTimer;
  bool _visible = false;
  bool _finished = false;
  int _revealGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(covariant _FocusedScheduleTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _holdTimer?.cancel();
      _visible = false;
      _finished = false;
      _scheduleReveal();
    }
  }

  void _scheduleReveal() {
    final generation = ++_revealGeneration;
    if (!widget.reveal) {
      _finished = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _revealGeneration) return;
      widget.onRevealed?.call();
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      if (widget.scrollIntoView) {
        await Scrollable.ensureVisible(
          context,
          alignment: 0.35,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
      if (!mounted || generation != _revealGeneration) return;
      setState(() => _visible = true);
      _holdTimer = Timer(const Duration(milliseconds: 1800), () {
        if (!mounted) return;
        setState(() {
          _visible = false;
          if (MediaQuery.disableAnimationsOf(context)) _finished = true;
        });
      });
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Semantics(
      selected: _visible,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (!_finished)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 350),
                  onEnd: () {
                    if (!_visible && mounted) {
                      setState(() => _finished = true);
                    }
                  },
                  child: DecoratedBox(
                    key: Key('schedule_focus_${widget.eventId}'),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.radius),
                      border: Border.all(color: colors.accent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: colors.accent.withValues(
                            alpha: colors.isDark ? 0.4 : 0.25,
                          ),
                          blurRadius: 10,
                          spreadRadius: 1,
                          blurStyle: BlurStyle.outer,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.day,
    required this.isToday,
    this.headerTextSize = kDefaultHeaderTextSize,
    this.dotColor,
    this.swapped = false,
  });

  /// 这一天参与了整天调课：星期旁显示「调」（第 8 条）。
  final bool swapped;

  final String label;
  final int day;
  final bool isToday;

  /// 表头文字大小（sp）；来自 [TimetableSettings.headerTextSize]。
  final double headerTextSize;

  /// 非空：当天有不在节次内的日程，日期下画 4dp 圆点（EV-2）。
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    // 大字号下缩放而非溢出（表头高度固定，与网格对齐）。
    final labelColor = isToday
        ? TimetableTheme.colorsOf(context).accent
        : TimetableTheme.colorsOf(context).labelText;
    final child = Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: headerTextSize,
                    fontWeight: FontWeight.w500,
                    color: labelColor,
                    height: 1.1,
                  ),
                ),
                if (swapped)
                  Padding(
                    padding: const EdgeInsets.only(left: 1),
                    child: Text(
                      '调',
                      key: const Key('day_header_swap_badge'),
                      semanticsLabel: '已调课',
                      style: TimetableTheme.microStyle(
                        color: TimetableTheme.colorsOf(context).warning,
                      ),
                    ),
                  ),
              ],
            ),
            Text(
              '$day',
              style: TimetableTheme.microStyle(
                color: isToday
                    ? TimetableTheme.colorsOf(context).accent
                    : TimetableTheme.colorsOf(context).hint,
              ),
            ),
            if (dotColor case final c?)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: SizedBox(
                  key: const Key('day_header_dot'),
                  width: 4,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!isToday) return child;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: TimetableTheme.colorsOf(context).accentSoft,
        borderRadius: BorderRadius.circular(TimetableTheme.todayHeaderRadius),
      ),
      child: child,
    );
  }
}

class _PeriodLabel extends StatelessWidget {
  const _PeriodLabel({
    required this.node,
    required this.period,
    this.showTimes = true,
  });

  final int node;
  final PeriodTime? period;
  final bool showTimes;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$node',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.05,
                color: TimetableTheme.colorsOf(context).titleText,
              ),
            ),
            if (showTimes && period != null)
              Text(
                '${period!.start}\n${period!.end}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9,
                  height: 1.05,
                  color: TimetableTheme.colorsOf(context).hint,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.days,
    required this.nodes,
    required this.periodH,
    required this.dayW,
    required this.color,
  });

  final int days;
  final int nodes;
  final double periodH;
  final double dayW;

  /// 网格线颜色（随明暗取 [TimetableColors.divider]）。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    for (var i = 0; i <= nodes; i++) {
      final y = i * periodH;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var i = 0; i <= days; i++) {
      final x = i * dayW;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.days != days ||
      oldDelegate.nodes != nodes ||
      oldDelegate.periodH != periodH ||
      oldDelegate.dayW != dayW ||
      oldDelegate.color != color;
}
