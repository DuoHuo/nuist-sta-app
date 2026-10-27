import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'timetable_controller.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_event_layout.dart';
import 'timetable_theme.dart';

/// 课表考试在主页的直观入口（issue #30）：列出今天起往后的全部考试。
/// 数据直接复用 [TimetableController.scheduleEvents]（课表同步时已从教务拉取），
/// 不重复请求、不修改课表任何已有实现。
///
/// 「有考试就显示」：只要存在日期不早于今天的考试就列出，不设天数上限；
/// 一场都没有时整张卡片隐藏（主页只少这一张卡，宫格入口仍在）。

/// 今天（[today]，只取年月日）起往后的全部考试，按日期升序、同日按开始时间。
/// 受「显示考试」开关控制：关时返回空（与课表 / 首页课程卡对考试的处理一致）。
List<ScheduleEvent> upcomingExams(
  TimetableController controller, {
  required DateTime today,
}) {
  if (!controller.settings.showExams) return const [];
  final day = DateTime(today.year, today.month, today.day);
  final exams = [
    for (final e in controller.scheduleEvents)
      if (e.isExam &&
          !DateTime(e.date.year, e.date.month, e.date.day).isBefore(day))
        e,
  ];
  exams.sort((a, b) {
    final d = DateTime(
      a.date.year,
      a.date.month,
      a.date.day,
    ).compareTo(DateTime(b.date.year, b.date.month, b.date.day));
    if (d != 0) return d;
    return a.start.compareTo(b.start);
  });
  return exams;
}

/// 距今天的天数（today / date 都只取年月日）。date 早于今天返回负数。
int examDaysAway(DateTime today, DateTime date) {
  final t = DateTime(today.year, today.month, today.day);
  final d = DateTime(date.year, date.month, date.day);
  return d.difference(t).inDays;
}

/// 倒计时文案：今天 / 明天 / 后天 / 还有 X 天；已过去 → 「已结束」。
String examCountdownLabel(DateTime today, DateTime date) {
  final n = examDaysAway(today, date);
  if (n < 0) return '已结束';
  if (n == 0) return '今天';
  if (n == 1) return '明天';
  if (n == 2) return '后天';
  return '还有 $n 天';
}

/// 主页「考试安排」卡片。
class TimetableExamsCard extends StatefulWidget {
  const TimetableExamsCard({super.key, this.now});

  /// 测试用：替换「现在」；为空时取当前时间。
  @visibleForTesting
  final DateTime Function()? now;

  @override
  State<TimetableExamsCard> createState() => _TimetableExamsCardState();
}

class _TimetableExamsCardState extends State<TimetableExamsCard> {
  final _controller = TimetableController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  void _openExams() => context.push('/apps/exam-schedule');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final now = widget.now?.call() ?? DateTime.now();
        final exams = upcomingExams(_controller, today: now);
        // 一场近期考试都没有：整张卡片隐藏。
        if (exams.isEmpty) return const SizedBox.shrink();

        final colors = TimetableTheme.colorsOf(context);
        return Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              TimetableTheme.cardPaddingH,
              TimetableTheme.cardPaddingV,
              TimetableTheme.cardPaddingH,
              8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(count: exams.length, onTap: _openExams),
                const SizedBox(height: 6),
                for (final e in exams)
                  _ExamRow(
                    controller: _controller,
                    event: e,
                    today: now,
                    onTap: _openExams,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 卡片标题行：图标 + 「考试安排」+ 数量 + 箭头（点击进考试列表页）。
class _Header extends StatelessWidget {
  const _Header({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Icon(Icons.event_note_outlined, size: 18, color: colors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '考试安排',
                  key: const Key('exams_card_title'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
                Text(
                  '近期 $count 场',
                  key: const Key('exams_card_count'),
                  style: TimetableTheme.microStyle(color: colors.hint),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: colors.chevron, size: 20),
        ],
      ),
    );
  }
}

/// 一场考试的一行：色条 + 科目（考试胶囊）/ 日期 · 倒计时 · 时间 / 考场 / 座位备注。
class _ExamRow extends StatelessWidget {
  const _ExamRow({
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
    return InkWell(
      key: Key('exams_card_row_${event.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // 与课程行一致：项内上下 8、项间距 2。
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: done ? colors.divider : accent,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
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
                            key: const Key('exams_card_exam_pill'),
                            text: schedulePillLabel(event),
                            color: done ? colors.hint : accent,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          scheduleDateText(event.date),
                          examCountdownLabel(today, event.date),
                          scheduleTimeText(event),
                        ].join(' · '),
                        key: const Key('exams_card_row_time'),
                        style: subStyle,
                      ),
                      if (event.location.isNotEmpty)
                        Text(
                          '@${event.location}',
                          key: const Key('exams_card_row_location'),
                          style: subStyle,
                        ),
                      if (event.note.isNotEmpty)
                        Text(
                          event.note,
                          key: const Key('exams_card_row_note'),
                          style: subStyle,
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
