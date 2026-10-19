import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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

/// 首页「上课中」（spec-next item 4）：距下课 [minutes] 分钟，向下取整、至少 1；
/// ≥ 60 分钟「X 小时 Y 分钟」，Y = 0 时省略。
String formatClassRemaining(int minutes) {
  final m = minutes < 1 ? 1 : minutes;
  if (m < 60) return '上课中·还剩 $m 分钟';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '上课中·还剩 $h 小时' : '上课中·还剩 $h 小时 $r 分钟';
}

/// 兼容旧测试：默认上限；实际截断读 [TimetableSettings.homeMaxItems]。
const int kHomeMaxItems = kDefaultHomeMaxItems;

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

  /// item 2：本卡片发起的手动同步还没出结果（只为它弹失败提示）。
  bool _homeSyncPending = false;
  StreamSubscription<TimetableSyncOutcome>? _outcomeSub;

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted();
    _outcomeSub = _controller.syncOutcomes.listen(_onSyncOutcome);
  }

  @override
  void dispose() {
    _outcomeSub?.cancel();
    super.dispose();
  }

  /// item 2：标题行刷新按钮，与课表顶栏同步图标同一个 [TimetableController.manualSync]；
  /// 未绑定门户时去登录。
  Future<void> _manualSync() async {
    if (_controller.syncStatus == TimetableSyncStatus.syncing) return;
    _homeSyncPending = true;
    final started = await _controller.manualSync();
    if (started) return;
    _homeSyncPending = false;
    if (!_controller.portalBound && mounted) await _openLogin();
  }

  /// 手动同步失败的提示与课表页 AS-1 一致（登录过期由课表页 / 设置处理，不在这里弹）。
  void _onSyncOutcome(TimetableSyncOutcome outcome) {
    if (!_homeSyncPending || outcome.automatic || !mounted) return;
    _homeSyncPending = false;
    if (outcome.success ||
        outcome.failure == TimetableSyncFailure.sessionExpired) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final network =
        outcome.failure == TimetableSyncFailure.network ||
        outcome.failure == TimetableSyncFailure.server;
    final text = !network
        ? '同步失败，请稍后再试'
        : (outcome.failure == TimetableSyncFailure.network && outcome.offline
              ? '同步失败，请检查网络'
              : '同步超时，请稍后再试');
    var fired = false;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        key: const Key('home_card_sync_snackbar'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        persist: false,
        content: Text(text),
        action: network
            ? SnackBarAction(
                label: '重试',
                onPressed: () {
                  if (fired) return;
                  fired = true;
                  messenger.hideCurrentSnackBar();
                  _manualSync();
                },
              )
            : null,
      ),
    );
  }

  void _openTimetable() => context.push('/apps/timetable');

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
        final colors = TimetableTheme.colorsOf(context);
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
        // spec-next-1020 item 4：上过的不显示；截断到 homeMaxItems，无「更多」。
        final pending = entries.where((e) => !e.isDone(now)).toList();
        final maxItems = _controller.settings.homeMaxItems;
        final visible = pending.take(maxItems).toList();
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
            syncing: _controller.syncStatus == TimetableSyncStatus.syncing,
            onRefresh: _manualSync,
          );
          final all = mergeHomeEntries(
            _controller,
            tomorrow.courses,
            tomorrowEvents,
          );
          final list = all.take(maxItems).toList();
          body = [
            Column(
              key: const Key('home_tomorrow_section'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in list)
                  _entryRow(entry, now, onCourseTap: (_) => _openTimetable()),
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
            syncing: _controller.syncStatus == TimetableSyncStatus.syncing,
            onRefresh: _manualSync,
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
                _entryRow(
                  entry,
                  now,
                  // 10/19：点课程行与点卡片相同，只打开课表页，不再弹详情 / 编辑。
                  onCourseTap: (_) => _openTimetable(),
                ),
            ];
          }
        }

        return Material(
          color: colors.surface,
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
                      style: TimetableTheme.microStyle(color: colors.warning),
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
      return _CourseRow(
        item: course,
        now: now,
        onTap: () => onCourseTap(course),
      );
    }
    return ScheduleHomeRow(
      controller: _controller,
      event: entry.event!,
      done: entry.isDone(now),
      onTap: _openTimetable,
    );
  }

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
    final label = text;
    return Builder(
      builder: (context) => Padding(
        key: const Key('home_tomorrow_note'),
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          label,
          style: TimetableTheme.microStyle(
            color: TimetableTheme.colorsOf(context).labelText,
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 卡片标题行（今天 / 明天共用，保证样式一致）：图标 + 标题 + 副标题 + 刷新 + 箭头。
class _CardHeader extends StatelessWidget {
  const _CardHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.syncing,
    required this.onRefresh,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// item 2：同步中（刷新图标旋转）。
  final bool syncing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Icon(Icons.calendar_today_outlined, size: 18, color: colors.accent),
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
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
                Text(
                  subtitle,
                  key: const Key('home_card_subtitle'),
                  style: TimetableTheme.microStyle(color: colors.hint),
                ),
              ],
            ),
          ),
          _RefreshButton(syncing: syncing, onTap: onRefresh),
          Icon(Icons.chevron_right, color: colors.chevron, size: 20),
        ],
      ),
    );
  }
}

/// item 2：标题行右侧刷新按钮（热区 48dp），同步中图标旋转。
class _RefreshButton extends StatefulWidget {
  const _RefreshButton({required this.syncing, required this.onTap});

  final bool syncing;
  final VoidCallback onTap;

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant _RefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    if (widget.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return SizedBox(
      width: TimetableTheme.iconTapSize,
      height: TimetableTheme.iconTapSize,
      child: IconButton(
        key: const Key('home_card_refresh'),
        tooltip: widget.syncing ? '正在同步' : '刷新课表',
        onPressed: widget.onTap,
        icon: RotationTransition(
          key: const Key('home_card_refresh_spin'),
          turns: _spin,
          child: Icon(Icons.refresh, size: 20, color: colors.labelText),
        ),
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
    final colors = TimetableTheme.colorsOf(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TimetableTheme.bodyStyle(color: colors.hint),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(
            key: actionKey,
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
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
  const _CourseRow({
    required this.item,
    required this.now,
    required this.onTap,
  });

  final TodayCourseItem item;
  final DateTime now;
  final VoidCallback onTap;

  /// "08:00" → 当天该时刻；格式不对返回 null。
  DateTime? _at(String? hhmm) {
    final parts = (hhmm ?? '').split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(now.year, now.month, now.day, h, m);
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    // 4dp 色条在卡片面色上用该色号文字色（A 柔和底色太浅，卡片底上看不出）。
    // 深色下取深色格的浅字色（item 12），在深色卡片上才看得见。
    final ctl = TimetableController.instance;
    final color = coursePairFor(ctl, item.course, dark: colors.isDark).fg;
    final done = item.status == TodayCourseStatus.done;
    final fg = done ? colors.hint : colors.titleText;
    final start = item.slot.startNode;
    final end = item.slot.endNode;
    final nodeHint = '第$start${start == end ? '' : '–$end'}节';
    final from = ctl.periodAt(start)?.start;
    final to = ctl.periodAt(end)?.end;
    // item 13 第二行：「08:00–09:40 · 第1–2节」（没有作息时间时只显示节次）。
    final timeLine = from != null && to != null
        ? '$from–$to · $nodeHint'
        : nodeHint;
    final endAt = _at(to);
    final remaining = endAt == null
        ? null
        : endAt.difference(now).inSeconds ~/ 60;
    final subStyle = TimetableTheme.microStyle(
      color: done ? colors.hint : colors.labelText,
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // spec-next-1020 item 2：项内上下 8、项间距 4（bottom 含间距）。
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        // 色条随内容高度伸缩（不固定高度）：课名 / 地点换行时整行变高。
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                margin: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: done ? colors.divider : color,
                  borderRadius: BorderRadius.circular(2),
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
                      // item 2：课名与第二行间距 2。
                      const SizedBox(height: 2),
                      // item 13：时间 · 节次 / 地点 / 老师各一行，长文本换行、不截断；
                      // 地点、老师为空时不占行。
                      Text(
                        timeLine,
                        key: const Key('home_course_time'),
                        style: subStyle,
                      ),
                      if (item.slot.location.isNotEmpty)
                        Text(
                          item.slot.location,
                          key: const Key('home_course_location'),
                          style: subStyle,
                        ),
                      if (item.slot.teacher.isNotEmpty)
                        Text(
                          item.slot.teacher,
                          key: const Key('home_course_teacher'),
                          style: subStyle,
                        ),
                      if (item.status == TodayCourseStatus.ongoing) ...[
                        const SizedBox(height: 2),
                        // item 4：「上课中·还剩 N 分钟」+ 2dp 主色进度条（已过去的比例）。
                        Text(
                          remaining == null
                              ? '上课中'
                              : formatClassRemaining(remaining),
                          key: const Key('home_course_remaining'),
                          style: TimetableTheme.microStyle(
                            color: colors.accent,
                          ),
                        ),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(1),
                          child: LinearProgressIndicator(
                            key: const Key('home_course_progress'),
                            value: (item.progress ?? 0).clamp(0.0, 1.0),
                            minHeight: 2,
                            backgroundColor: colors.divider,
                            color: colors.accent,
                          ),
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
                              color: colors.accent,
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
