import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'timetable_controller.dart';
import 'timetable_exams_card.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_theme.dart';

/// 「考试安排」全屏页（exam-schedule 小程序的 entry）。
/// 上半部分列即将到来的考试（同主页卡片），下半部分列已结束的考试；
/// 数据复用 [TimetableController]，点击任意行进课表查看当周位置。
class TimetableExamsPage extends StatelessWidget {
  const TimetableExamsPage({super.key});

  void _openTimetable(BuildContext context) => context.push('/apps/timetable');

  @override
  Widget build(BuildContext context) {
    final controller = TimetableController.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('考试安排')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final now = DateTime.now();
          final upcoming = upcomingExams(controller, today: now);
          final past = pastExams(controller, today: now);
          final colors = TimetableTheme.colorsOf(context);

          if (upcoming.isEmpty && past.isEmpty) {
            return Center(
              child: Text(
                controller.portalBound ? '本学期暂无考试安排' : '登录教务后自动显示考试安排',
                style: TimetableTheme.bodyStyle(color: colors.hint),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              if (upcoming.isNotEmpty) ...[
                _GroupHeader(text: '即将到来（${upcoming.length}）'),
                for (final e in upcoming)
                  _ExamTile(
                    controller: controller,
                    event: e,
                    today: now,
                    onTap: () => _openTimetable(context),
                  ),
              ],
              if (past.isNotEmpty) ...[
                const SizedBox(height: 12),
                _GroupHeader(text: '已结束（${past.length}）'),
                for (final e in past)
                  _ExamTile(
                    controller: controller,
                    event: e,
                    today: now,
                    onTap: () => _openTimetable(context),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 已结束的考试（日期早于今天），按日期倒序（最近的在前）。
List<ScheduleEvent> pastExams(
  TimetableController controller, {
  required DateTime today,
}) {
  if (!controller.settings.showExams) return const [];
  final day = DateTime(today.year, today.month, today.day);
  final exams = [
    for (final e in controller.scheduleEvents)
      if (e.isExam &&
          DateTime(e.date.year, e.date.month, e.date.day).isBefore(day))
        e,
  ];
  exams.sort((a, b) {
    final d = DateTime(
      b.date.year,
      b.date.month,
      b.date.day,
    ).compareTo(DateTime(a.date.year, a.date.month, a.date.day));
    if (d != 0) return d;
    return b.start.compareTo(a.start);
  });
  return exams;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
      child: Text(
        text,
        style: TimetableTheme.captionStyle(color: colors.labelText),
      ),
    );
  }
}

/// 考试列表的一项：卡片式，含科目、胶囊、日期倒计时、时间、考场与座位备注。
class _ExamTile extends StatelessWidget {
  const _ExamTile({
    required this.controller,
    required this.event,
    required this.today,
    required this.onTap,
  });

  final TimetableController controller;
  final ScheduleEvent event;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final accent = scheduleAccentOnWhite(controller, event);
    final done = examDaysAway(today, event.date) < 0;
    final fg = done ? colors.hint : colors.titleText;
    final subStyle = TimetableTheme.microStyle(
      color: done ? colors.hint : colors.labelText,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: colors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
      ),
      child: InkWell(
        key: Key('exams_page_row_${event.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SchedulePill(
                    text: schedulePillLabel(event),
                    color: done ? colors.hint : accent,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  scheduleDateText(event.date),
                  examCountdownLabel(today, event.date),
                  scheduleTimeText(event),
                ].join(' · '),
                style: subStyle,
              ),
              if (event.location.isNotEmpty)
                Text('@${event.location}', style: subStyle),
              if (event.note.isNotEmpty) Text(event.note, style: subStyle),
            ],
          ),
        ),
      ),
    );
  }
}
