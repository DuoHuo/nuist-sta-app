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
class ScheduleEventCell extends StatelessWidget {
  const ScheduleEventCell({
    super.key,
    required this.controller,
    required this.event,
    required this.width,
    required this.height,
    required this.radius,
    this.stackCount = 1,
    this.onTap,
  });

  final TimetableController controller;
  final ScheduleEvent event;
  final double width;
  final double height;
  final double radius;
  final int stackCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = TimetableTheme.colorsOf(context).isDark;
    final bg = scheduleCellBg(controller, event, dark: dark);
    final autoFg = scheduleCellFg(controller, event, dark: dark);
    // item 14：考试格也受「文字颜色」白字 / 黑字强制。
    final fg = event.isExam
        ? TimetableTheme.cellTextFor(autoFg, controller.settings.cellTextColor)
        : autoFg;
    final stacked = stackCount > 1;
    final showLoc =
        controller.settings.showLocation && event.location.isNotEmpty;
    return Semantics(
      button: true,
      label: [
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
                        : SchedulePill(
                            key: Key(
                              event.isExam
                                  ? 'schedule_cell_exam_pill'
                                  : 'schedule_cell_other_pill',
                            ),
                            text: schedulePillLabel(event),
                            color: fg,
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
