import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'timetable_schedule_home_row.dart';
import 'timetable_controller.dart';
import 'timetable_schedule_event.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_week_layout.dart';
import 'timetable_course_color.dart';

const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 明天跨周（如今天周日）时附带周次：「明天（周一·第 7 周）」；否则「明天（周X）」。
String tomorrowLabel(DateTime tomorrow, DateTime? termStart) {
  final start = termStart;
  if (start == null) return tomorrowLabelForWeeks(tomorrow, null, null);
  final today = tomorrow.subtract(const Duration(days: 1));
  return tomorrowLabelForWeeks(
    tomorrow,
    teachingWeekOf(start, tomorrow),
    teachingWeekOf(start, today),
  );
}

/// 同 [tomorrowLabel]，周次由调用方给出（首页用 controller.actualWeek，未钳制）。
/// 明天真实周 ≥1 且与今天不同才带周次（如 08-30 周日 → 「明天（周一·第 1 周）」）。
String tomorrowLabelForWeeks(
  DateTime tomorrow,
  int? tomorrowWeek,
  int? todayWeek,
) {
  final wd = _weekdayCn[tomorrow.weekday - 1];
  final tw = tomorrowWeek;
  if (tw != null && tw >= 1 && tw != todayWeek) {
    return '明天（周$wd·第 $tw 周）';
  }
  return '明天（周$wd）';
}

/// 首页倒计时（§13.11）：< 60 分钟「N 分钟后上课」；≥ 60「X 小时 Y 分后上课」，
/// Y = 0 时「X 小时后上课」。
String formatClassCountdown(int minutes) {
  final m = minutes < 0 ? 0 : minutes;
  // 不足 1 分钟（向下取整为 0）不显示「0 分钟后上课」。
  if (m == 0) return '即将上课';
  if (m < 60) return '$m 分钟后上课';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '$h 小时后上课' : '$h 小时 $r 分后上课';
}

/// 首页「今日课表」卡片（spec §6），课表唯一入口。
class TimetableHomeCard extends StatefulWidget {
  const TimetableHomeCard({super.key, this.now});

  /// 测试用：替换「现在」；为空时取当前时间。
  @visibleForTesting
  final DateTime Function()? now;

  @override
  State<TimetableHomeCard> createState() => _TimetableHomeCardState();
}

class _TimetableHomeCardState extends State<TimetableHomeCard> {
  final _controller = TimetableController.instance;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
  }

  void _openTimetable() => context.push('/apps/timetable');

  Future<void> _openCourse(TodayCourseItem item) async {
    _controller.goToCurrentWeek();
    _controller.requestOpenCourse(
      courseId: item.course.id,
      day: item.slot.day,
      startNode: item.slot.startNode,
      endNode: item.slot.endNode,
    );
    await context.push('/apps/timetable');
  }

  /// 登录：回来后只刷新绑定状态（UI）。登录成功的同步由门户绑定页
  /// （portal_status_page）自己调用 onLoginSucceeded，这里不重复调用。
  Future<void> _openLogin() async {
    await context.push('/portal-bind');
    if (!mounted) return;
    await _controller.refreshPortalBound();
  }

  /// 今天的最后一项（课 + 首页显示的考试/其他日程，考试受 showExams 控制）是否已结束
  /// （§13.13，产品 10/18：「最后一项」取 [TimetableController.lastVisibleItemEndToday]）。
  /// 今天什么都没有 → 视为已结束。结束时刻当分钟仍算「结束前」（与课程「上课中」
  /// 判定一致，待确认 HT-1）。
  bool _todayEnded(DateTime now) {
    final last = _controller.lastVisibleItemEndToday(now: now);
    if (last == null) return true;
    final end = DateTime(now.year, now.month, now.day, last.hour, last.minute);
    // HT02：结束的那一分钟（含 :59 秒）仍算今天，下一分钟起才算结束。
    return !now.isBefore(end.add(const Duration(minutes: 1)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final now = widget.now?.call() ?? DateTime.now();
        // 今天的真实教学周（未钳制）；开学前（<1）不显示周次。
        final week = _controller.actualWeek(now);
        final weekday = _weekdayCn[now.weekday - 1];
        final items = _controller.todayCourses(now: now);
        // §14.3/§14.4：今天的可见日程（考试受 showExams 控制）与课程按开始时间混排。
        final today = DateTime(now.year, now.month, now.day);
        final entries = mergeHomeEntries(
          _controller,
          items,
          _controller.scheduleEventsOn(today),
        );
        final visible = entries.take(4).toList();
        final remaining = entries.length - visible.length;
        final remainingAllCourses = entries
            .skip(visible.length)
            .every((e) => e.course != null);
        // 明天一栏的规则（开学前、学期结束、明天没课、开关）都在数据层。
        final tomorrow = _controller.homeTomorrow(now: now);
        final ended = _todayEnded(now);
        // 明天的日程：只在数据层给出「明天有课 / 明天没课」时并入（开关关、开学前、
        // 学期结束等情况沿用原规则）。
        final tomorrowEvents =
            tomorrow.kind == HomeTomorrowKind.courses ||
                tomorrow.kind == HomeTomorrowKind.noClass
            ? _controller.scheduleEventsOn(
                DateTime(today.year, today.month, today.day + 1),
              )
            : const <ScheduleEvent>[];
        // §13.13：今天最后一项结束后切换为明天的课，卡片样式与今天完全一致。
        // 只有日程、没有课程时也切换（B 10/18：有课程或有可见日程）。
        final hasVisibleEvents = _controller.scheduleEvents.any(
          (e) => !e.isExam || _controller.settings.showExams,
        );
        final showTomorrowCard =
            (_controller.hasCourses || hasVisibleEvents) &&
            ended &&
            (tomorrow.kind == HomeTomorrowKind.courses ||
                tomorrowEvents.isNotEmpty);

        final Widget header;
        final List<Widget> body;
        if (showTomorrowCard) {
          header = _CardHeader(
            key: const Key('home_card_header'),
            title: tomorrow.title ?? '明天',
            subtitle: items.isEmpty ? '今天没有课' : '今天的课已上完',
            onTap: _openTimetable,
          );
          final all = mergeHomeEntries(
            _controller,
            tomorrow.courses,
            tomorrowEvents,
          );
          final list = all.take(4).toList();
          final more = all.length - list.length;
          final moreAllCourses = all
              .skip(list.length)
              .every((e) => e.course != null);
          body = [
            Column(
              key: const Key('home_tomorrow_section'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in list)
                  _entryRow(entry, now, onCourseTap: (_) => _openTimetable()),
                if (more > 0) _moreLine(more, courses: moreAllCourses),
              ],
            ),
          ];
        } else {
          header = _CardHeader(
            key: const Key('home_card_header'),
            title: '今日课表',
            subtitle: week != null && week >= 1
                ? '周$weekday · 第 $week 周'
                : '周$weekday',
            onTap: _openTimetable,
          );
          // 今天还有没结束的可见日程时照常列出（EV-1：学期外 / 没有课程的日子也显示）。
          final allDone = entries.every((e) => e.isDone(now));
          // HT12：没有课程但有可见日程的人，走「已上完 / 明天没课」分支。
          if (!_controller.hasCourses && !hasVisibleEvents && allDone) {
            // 未绑定：「去登录」；已绑定不再有「立即同步」（同步只走自动同步和课表顶栏）。
            body = [
              _StatusLine(
                text: _controller.portalBound
                    ? '还没有课程，同步后自动显示'
                    : '登录教务后自动显示今日课程',
                actionKey: const Key('home_card_login'),
                actionLabel: _controller.portalBound ? null : '去登录',
                onAction: _controller.portalBound ? null : _openLogin,
              ),
            ];
          } else if (tomorrow.kind == HomeTomorrowKind.termEnded && allDone) {
            body = [
              InkWell(
                onTap: _openTimetable,
                borderRadius: BorderRadius.circular(8),
                child: _StatusLine(text: tomorrow.message ?? '本学期已结束'),
              ),
            ];
          } else if (allDone) {
            body = [
              InkWell(
                onTap: _openTimetable,
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusLine(text: entries.isEmpty ? '今天没有课' : '已上完'),
                    // 明天没课 / 距开学 N 天：今天最后一项结束后才显示。
                    if (ended) ?_tomorrowNote(tomorrow),
                  ],
                ),
              ),
            ];
          } else {
            body = [
              for (final entry in visible)
                _entryRow(entry, now, onCourseTap: _openCourse),
              if (remaining > 0)
                _moreLine(remaining, courses: remainingAllCourses),
            ];
          }
        }

        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              TimetableTheme.cardPaddingH,
              TimetableTheme.cardPaddingV,
              TimetableTheme.cardPaddingH,
              TimetableTheme.cardPaddingV,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 10),
                ...body,
                if (_controller.syncedAt != null &&
                    _controller.snapshot.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '缓存于 ${_formatTime(_controller.syncedAt!)}',
                      style: TimetableTheme.microStyle(
                        color: TimetableTheme.warning,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 一行：课程沿用 [_CourseRow]；日程用 [ScheduleHomeRow]（考试 / 日程胶囊），点开课表。
  Widget _entryRow(
    HomeEntry entry,
    DateTime now, {
    required void Function(TodayCourseItem item) onCourseTap,
  }) {
    final course = entry.course;
    if (course != null) {
      return _CourseRow(item: course, onTap: () => onCourseTap(course));
    }
    return ScheduleHomeRow(
      controller: _controller,
      event: entry.event!,
      done: entry.isDone(now),
      onTap: _openTimetable,
    );
  }

  /// 剩余全是课程时沿用「还有 N 节课」；混有日程时「还有 N 项」。
  Widget _moreLine(int n, {bool courses = true}) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      courses ? '还有 $n 节课' : '还有 $n 项',
      style: TimetableTheme.microStyle(color: TimetableTheme.accent),
    ),
  );

  /// 明天没有课程列表时的一行说明（明天没课 / 距开学 N 天）；其余情况不显示。
  /// 明天有课时整张卡切换为明天的课（见 build）。
  Widget? _tomorrowNote(HomeTomorrowInfo info) {
    final String? text;
    switch (info.kind) {
      case HomeTomorrowKind.noClass:
        text = info.message ?? '明天没课';
      case HomeTomorrowKind.beforeTerm:
        text = info.message;
      case HomeTomorrowKind.courses:
      case HomeTomorrowKind.disabled:
      case HomeTomorrowKind.unknown:
      case HomeTomorrowKind.termEnded:
        text = null;
    }
    if (text == null || text.isEmpty) return null;
    return Padding(
      key: const Key('home_tomorrow_note'),
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TimetableTheme.microStyle(color: AppColors.labelText),
      ),
    );
  }

  String _formatTime(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 卡片标题行（今天 / 明天共用，保证样式一致）：图标 + 标题 + 副标题 + 箭头。
class _CardHeader extends StatelessWidget {
  const _CardHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          const Icon(
            Icons.calendar_today_outlined,
            size: 18,
            color: TimetableTheme.accent,
          ),
          const SizedBox(width: 6),
          // 标题始终完整显示；副标题放不下时整体换到标题下一行（不挤占标题）。
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  key: const Key('home_card_title'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.titleText,
                  ),
                ),
                Text(
                  subtitle,
                  key: const Key('home_card_subtitle'),
                  style: TimetableTheme.microStyle(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: AppColors.hint, size: 20),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.text,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  final String text;
  final Key? actionKey;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TimetableTheme.bodyStyle(color: AppColors.hint),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(
            key: actionKey,
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: TimetableTheme.accent,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}

class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.item, required this.onTap});

  final TodayCourseItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 4dp 色条在白底上用该色号文字色（A 柔和底色太浅，白底上看不出）。
    final color = TimetableTheme.courseTextColor(
      courseColorIndex(TimetableController.instance, item.course),
      scheme: coursePaletteSchemeFor(TimetableController.instance),
    );
    final done = item.status == TodayCourseStatus.done;
    final fg = done ? AppColors.hint : AppColors.titleText;
    final start = item.slot.startNode;
    final end = item.slot.endNode;
    final timeHint = '第$start${start == end ? '' : '–$end'}节';

    return InkWell(
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
                  color: done ? AppColors.divider : color,
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
                      // 长课名换行显示，不截断。
                      Text(
                        item.course.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          color: fg,
                        ),
                      ),
                      Text(
                        [
                          if (item.slot.location.isNotEmpty)
                            '@${item.slot.location}',
                          timeHint,
                        ].join(' · '),
                        style: TimetableTheme.microStyle(
                          color: done ? AppColors.hint : AppColors.labelText,
                        ),
                      ),
                      if (item.status == TodayCourseStatus.ongoing) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: TimetableTheme.accent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '上课中',
                                style: TimetableTheme.microStyle(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: item.progress ?? 0,
                                  minHeight: 3,
                                  backgroundColor: AppColors.divider,
                                  color: TimetableTheme.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (item.status == TodayCourseStatus.upcoming &&
                          item.minutesUntilStart != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            formatClassCountdown(item.minutesUntilStart!),
                            key: const Key('home_course_countdown'),
                            style: TimetableTheme.microStyle(
                              color: TimetableTheme.accent,
                            ),
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
