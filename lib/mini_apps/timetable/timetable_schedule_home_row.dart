import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';

/// 首页卡片的一项：课程（[course]）或日程（[event]），按开始时间混排（§14.3/§14.4）。
@immutable
class HomeEntry {
  const HomeEntry.course(TodayCourseItem this.course, this.startMinutes)
    : event = null;
  HomeEntry.event(ScheduleEvent this.event)
    : course = null,
      startMinutes = event.start.totalMinutes;

  final TodayCourseItem? course;
  final ScheduleEvent? event;
  final int startMinutes;

  /// 课程按 [TodayCourseStatus.done]；日程按结束时刻（当分钟仍算未结束，同课程）。
  bool isDone(DateTime now) {
    final c = course;
    if (c != null) return c.status == TodayCourseStatus.done;
    final e = event!;
    final end = DateTime(
      now.year,
      now.month,
      now.day,
      e.end.hour,
      e.end.minute,
    );
    return now.isAfter(end);
  }
}

/// 把 [courses] 与 [events]（应为 [TimetableController.scheduleEventsOn] 结果，
/// 已按 showExams 过滤）按开始时间混排；同一时刻课程在前。
List<HomeEntry> mergeHomeEntries(
  TimetableController controller,
  List<TodayCourseItem> courses,
  List<ScheduleEvent> events,
) {
  final out = <HomeEntry>[
    for (final c in courses)
      HomeEntry.course(
        c,
        TimeOfDayMinutes.tryParse(controller.periodStart(c.slot.startNode))
                ?.totalMinutes ??
            c.slot.startNode * 60,
      ),
    for (final e in events) HomeEntry.event(e),
  ];
  // List.sort 不稳定：用原下标兜底，保证课程之间、日程之间原顺序不变。
  final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
  indexed.sort((a, b) {
    final t = a.$2.startMinutes.compareTo(b.$2.startMinutes);
    if (t != 0) return t;
    final ka = a.$2.course != null ? 0 : 1;
    final kb = b.$2.course != null ? 0 : 1;
    if (ka != kb) return ka.compareTo(kb);
    return a.$1.compareTo(b.$1);
  });
  return [for (final p in indexed) p.$2];
}

/// 首页卡片里的日程行：色条 + 名称 + 「@地点 · 时间」+ 胶囊（考试 / 日程）。
/// 行高、色条、间距与课程行一致。
class ScheduleHomeRow extends StatelessWidget {
  const ScheduleHomeRow({
    super.key,
    required this.controller,
    required this.event,
    required this.done,
    required this.onTap,
  });

  final TimetableController controller;
  final ScheduleEvent event;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = scheduleAccentOnWhite(controller, event);
    final fg = done ? AppColors.hint : AppColors.titleText;
    return InkWell(
      key: Key('home_event_row_${event.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        // 色条随内容高度伸缩（不固定高度）：课名 / 地点换行时整行变高。
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: done ? AppColors.divider : accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              event.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                                color: fg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SchedulePill(
                            key: Key(
                              event.isExam
                                  ? 'home_event_exam_pill'
                                  : 'home_event_other_pill',
                            ),
                            text: schedulePillLabel(event),
                            color: done ? AppColors.hint : accent,
                          ),
                        ],
                      ),
                      Text(
                        [
                          if (event.location.isNotEmpty) '@${event.location}',
                          scheduleTimeText(event),
                        ].join(' · '),
                        style: TimetableTheme.microStyle(
                          color: done ? AppColors.hint : AppColors.labelText,
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
    );
  }
}
