import 'package:flutter/material.dart';

import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_controller.dart';
import 'timetable_theme.dart';

/// 周视图里的一格日程（考试 / 其他，spec §14.2–§14.4）。
///
/// 不可拖动（不挂长按识别器）。考试：底色 = 设置 examColor、白字、「考试」胶囊；
/// 其他：按名称取配色、「日程」胶囊。胶囊样式与课程格「单周」胶囊一致。
/// [stackCount] > 1（同时段还有别的日程）时显示冲突圆点与「N 门」。
///
/// [activeThisWeek]：考试在「查看周 ≠ 本周」时为 false → 非本周灰显，同时显示
/// 「考试」与「非本周」两个胶囊（互不覆盖）。
class ScheduleEventCell extends StatelessWidget {
  const ScheduleEventCell({
    super.key,
    required this.controller,
    required this.event,
    required this.width,
    required this.height,
    required this.radius,
    this.stackCount = 1,
    this.activeThisWeek = true,
    this.onTap,
  });

  final TimetableController controller;
  final ScheduleEvent event;
  final double width;
  final double height;
  final double radius;
  final int stackCount;

  /// 考试：查看周是否为本周。false → 灰显 + 双胶囊。
  final bool activeThisWeek;
  final VoidCallback? onTap;

  static const String offWeekLabel = '非本周';

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final dark = colors.isDark;
    final offWeek = event.isExam && !activeThisWeek;
    final bg = scheduleCellBg(
      controller,
      event,
      dark: dark,
      activeThisWeek: activeThisWeek,
    );
    final autoFg = scheduleCellFg(
      controller,
      event,
      dark: dark,
      activeThisWeek: activeThisWeek,
    );
    // item 14：考试格也受「文字颜色」白字 / 黑字强制；非本周灰显仍用 offWeekText。
    final fg = offWeek
        ? autoFg
        : event.isExam
        ? TimetableTheme.cellTextFor(autoFg, controller.settings.cellTextColor)
        : autoFg;
    final stacked = stackCount > 1;
    final showLoc =
        controller.settings.showLocation && event.location.isNotEmpty;
    return Semantics(
      button: true,
      label: [
        if (offWeek) offWeekLabel,
        schedulePillLabel(event),
        event.title,
        scheduleTimeText(event),
        if (event.location.isNotEmpty) event.location,
        if (stacked) '本时段 $stackCount 项',
      ].join('，'),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('schedule_cell_${event.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Ink(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(radius),
              border: offWeek
                  ? Border.all(
                      color: colors.offWeekBorder,
                      width: TimetableTheme.offWeekBorderWidth,
                    )
                  : null,
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    4,
                    4,
                    4,
                    4 + _badgeReserve,
                  ),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.topStart,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TimetableTheme.cellStyle(color: fg),
                          ),
                          Text(
                            scheduleTimeText(event),
                            maxLines: 2,
                            style: TimetableTheme.cellSubStyle(color: fg),
                          ),
                          if (showLoc)
                            Text(
                              '@${event.location}',
                              style: TimetableTheme.cellSubStyle(color: fg),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (stacked)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      key: const Key('schedule_cell_conflict_dot'),
                      width: TimetableTheme.conflictDotSize,
                      height: TimetableTheme.conflictDotSize,
                      decoration: BoxDecoration(
                        color: fg,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 3,
                  child: Center(
                    child: stacked
                        ? SchedulePill(
                            key: const Key('schedule_cell_stack_badge'),
                            text: '$stackCount 门',
                            color: fg,
                          )
                        : Wrap(
                            spacing: 2,
                            alignment: WrapAlignment.center,
                            children: [
                              SchedulePill(
                                key: Key(
                                  event.isExam
                                      ? 'schedule_cell_exam_pill'
                                      : 'schedule_cell_other_pill',
                                ),
                                text: schedulePillLabel(event),
                                color: fg,
                              ),
                              if (offWeek)
                                // 「非本周」已在语义标签念过，胶囊不再重复。
                                ExcludeSemantics(
                                  child: SchedulePill(
                                    key: const Key(
                                      'schedule_cell_off_week_pill',
                                    ),
                                    text: offWeekLabel,
                                    color: fg,
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const double _badgeReserve = 10;
}
