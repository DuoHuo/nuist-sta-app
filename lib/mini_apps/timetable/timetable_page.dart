import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'timetable_schedule_event_detail_sheet.dart';
import 'timetable_controller.dart';
import 'timetable_perf.dart';
import 'timetable_settings_page.dart';
import 'timetable_theme.dart';
import 'timetable_course_detail_sheet.dart';
import 'timetable_week_grid.dart';

/// 课表周视图主页：顶栏 + PageView 翻周 + 网格。
class TimetablePage extends StatefulWidget {
  const TimetablePage({super.key});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  final _controller = TimetableController.instance;
  PageController? _pageController;
  bool _ready = false;

  /// 每次同步结束的结果（成功 / 失败、是否自动），决定弹哪种 SnackBar。
  StreamSubscription<TimetableSyncOutcome>? _outcomeSub;

  /// 同一次登录过期在本进程内只提示一次：弹过后置 true，
  /// [TimetableController.portalSessionExpired] 清掉后复位（见 [_watchSessionExpiry]）。
  static bool _sessionExpiryNotified = false;
  static bool _sessionExpiryWatching = false;

  /// AS-1：顶栏同步图标是否显示失败圆点（最近一次自动同步失败，下次成功后清除）。
  bool get _showSyncErrorDot => _controller.lastAutoSyncFailed;

  /// 学期总周数（controller 按 SKZC 最后一个 1 与 20 取大）。
  int get _totalWeeks => _controller.totalWeeks;

  @override
  void initState() {
    super.initState();
    TimetablePerf.start();
    _controller.addListener(_syncPageToViewingWeek);
    _controller.addListener(_maybeShowSessionExpired);
    _outcomeSub = _controller.syncOutcomes.listen(_onSyncOutcome);
    _watchSessionExpiry(_controller);
    _bootstrap();
  }

  /// 过期标记清掉（重新登录 / 解绑 / 同步成功）后，下一次过期要再提示一次。
  /// 挂在 controller 上（单例、只挂一次），课表页没打开时清掉也能复位。
  static void _watchSessionExpiry(TimetableController c) {
    if (_sessionExpiryWatching) return;
    _sessionExpiryWatching = true;
    c.addListener(() {
      if (!c.portalSessionExpired) _sessionExpiryNotified = false;
    });
  }

  /// 开学日/本周变化（如同步后）时让 PageView 跟随 viewingWeek，
  /// 避免顶栏周次与网格日期错位。
  void _syncPageToViewingWeek() {
    final pc = _pageController;
    if (pc == null) return;
    if (!pc.hasClients) {
      // PageView 可能在本帧才挂载（如空课表 → 同步出课程），挂载后再对齐。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && pc.hasClients) _syncPageToViewingWeek();
      });
      return;
    }
    // totalWeeks 缩小（如删掉第 20 周的课）时把浏览周拉回范围内。
    if (_controller.viewingWeek > _totalWeeks) {
      _controller.setViewingWeek(_totalWeeks);
      return; // setViewingWeek 会再次通知本监听。
    }
    final target = _pageFor(_controller.viewingWeek);
    final page = pc.page?.round() ?? pc.initialPage;
    if (page != target) pc.jumpToPage(target);
  }

  /// 周次 → PageView 下标，钳到 0..totalWeeks-1。
  int _pageFor(int week) => (week - 1).clamp(0, _totalWeeks - 1);

  /// 本周已超出学期总周数（课程已结束）。
  bool get _termEnded => _controller.currentWeek > _totalWeeks;

  Future<void> _bootstrap() async {
    await _controller.ensureStarted();
    if (!mounted) return;
    _pageController = PageController(
      initialPage: _pageFor(_controller.viewingWeek),
    );
    setState(() => _ready = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 打开页面时已处于过期状态（如上次进程留下的）：也提示一次。
      _maybeShowSessionExpired();
      _openPendingCourse();
    });
    await _controller.autoSyncIfNeeded();
  }

  /// 打开门户绑定状态页（登录 / 解绑）。回来后只刷新绑定状态（UI）；登录成功的
  /// 同步由门户绑定页（portal_status_page）自己调用 onLoginSucceeded，这里不重复调用。
  Future<void> _openLogin() async {
    await context.push('/portal-bind');
    if (!mounted) return;
    await _controller.refreshPortalBound();
  }

  /// 顶栏同步图标：[TimetableController.manualSync]（不受节流）；未绑定门户时直接去登录，
  /// 不发请求也不弹网络失败。
  Future<void> _manualSync() async {
    final started = await _controller.manualSync();
    if (!started && !_controller.portalBound && mounted) await _openLogin();
  }

  Future<void> _openPendingCourse() async {
    final pending = _controller.consumePendingOpen();
    if (pending == null || !mounted) return;
    _controller.goToCurrentWeek();
    final page = _pageFor(_controller.viewingWeek);
    if (_pageController != null && _pageController!.hasClients) {
      _pageController!.jumpToPage(page);
    }
    final cell = _controller.findCell(
      courseId: pending.courseId,
      day: pending.day,
      startNode: pending.startNode,
      endNode: pending.endNode,
    );
    if (cell == null || !mounted) return;
    await showCourseDetailSheet(context, cell: cell, controller: _controller);
  }

  /// 登录过期（自动或手动同步都算）：浮动 SnackBar「登录已过期」+「重新登录」6 秒。
  /// 只在 [TimetableController.portalSessionExpired] 变为 true 后提示一次；页面打开时
  /// 已过期也提示一次。自动失败的圆点照常显示。
  void _maybeShowSessionExpired() {
    if (!mounted || !_ready) return;
    if (!_controller.portalSessionExpired || _sessionExpiryNotified) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _sessionExpiryNotified = true;
    messenger.hideCurrentSnackBar();
    var fired = false;
    messenger.showSnackBar(
      SnackBar(
        key: const Key('timetable_sync_snackbar'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        // 带操作的 SnackBar 默认不自动关闭（persist），这里显式到时关闭。
        persist: false,
        content: const Text('登录已过期'),
        action: SnackBarAction(
          key: const Key('timetable_sync_relogin'),
          label: '重新登录',
          onPressed: () {
            if (fired) return;
            fired = true;
            messenger.hideCurrentSnackBar();
            // 只跳转登录页，不清除任何课表缓存。
            if (mounted) _openLogin();
          },
        ),
      ),
    );
  }

  /// 同步结束（[TimetableController.syncOutcomes]）后的浮动 SnackBar（不占布局）。
  /// - 成功（手动 / 自动，是否在本周都一样）：只弹 2 秒「已同步」，无操作，浏览周不动
  ///   （产品 10/18，SW01 / SW03）。
  /// - 失败：登录过期见 [_maybeShowSessionExpired]；自动同步失败不弹（AS-1，只画圆点）；
  ///   手动同步失败 4 秒，按失败类型给出文案与操作。
  void _onSyncOutcome(TimetableSyncOutcome outcome) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    if (outcome.success) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          key: Key('timetable_sync_snackbar'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
          persist: false,
          content: Text('已同步'),
        ),
      );
      return;
    }
    if (outcome.failure == TimetableSyncFailure.sessionExpired) return;
    if (outcome.automatic) return;
    final String text;
    SnackBarAction? action;
    switch (outcome.failure) {
      case TimetableSyncFailure.network:
      case TimetableSyncFailure.server:
        // 断网 →「请检查网络」；超时类（network 但非断网）与服务端错误 →「同步超时」。
        text =
            outcome.failure == TimetableSyncFailure.network && outcome.offline
            ? '同步失败，请检查网络'
            : '同步超时，请稍后再试';
        var fired = false;
        action = SnackBarAction(
          key: const Key('timetable_sync_retry'),
          label: '重试',
          onPressed: () {
            if (fired) return;
            fired = true;
            messenger.hideCurrentSnackBar();
            _manualSync();
          },
        );
      case TimetableSyncFailure.sessionExpired:
      case TimetableSyncFailure.unknown:
      case TimetableSyncFailure.none:
        text = '同步失败，请稍后再试';
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        key: const Key('timetable_sync_snackbar'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        // 「重试」等操作不让它常驻：4 秒到时自动关闭。
        persist: false,
        content: Text(text),
        action: action,
      ),
    );
  }

  @override
  void dispose() {
    _outcomeSub?.cancel();
    _controller.removeListener(_maybeShowSessionExpired);
    _controller.removeListener(_syncPageToViewingWeek);
    _pageController?.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    _controller.setViewingWeek(index + 1);
  }

  /// item 5：顶栏周数下方的横向周条是否展开。
  bool _weekStripOpen = false;

  void _toggleWeekStrip() => setState(() => _weekStripOpen = !_weekStripOpen);

  /// 周条选中某周：先收起，再按 item 3 的规则（[animateWeekPage]）翻过去。
  Future<void> _selectWeek(int week) async {
    setState(() => _weekStripOpen = false);
    final pc = _pageController;
    if (pc != null && pc.hasClients) {
      await animateWeekPage(
        pc,
        _pageFor(week),
        reduceMotion: MediaQuery.of(context).disableAnimations,
      );
    }
    if (mounted) _controller.setViewingWeek(week);
  }

  /// 周条展开 / 收起 200ms；减少动画时不套 AnimatedSize，直接出现 / 消失。
  Widget _weekStripSlot(BuildContext context) {
    final strip = _weekStripOpen
        ? _WeekStrip(
            total: _totalWeeks,
            current: _controller.currentWeek,
            selected: _controller.viewingWeek,
            onSelect: (w) => unawaited(_selectWeek(w)),
          )
        : const SizedBox(width: double.infinity);
    if (MediaQuery.of(context).disableAnimations) return strip;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: strip,
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TimetableSettingsPage(
          controller: _controller,
          onOpenAccount: _openLogin,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Scaffold(
      backgroundColor: colors.pageBg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            if (!_ready || _pageController == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return Stack(
              children: [
                Column(
                  children: [
                    _TopBar(
                      week: _controller.viewingWeek,
                      isCurrent: _controller.isViewingCurrentWeek,
                      endedCurrentWeek: _termEnded
                          ? _controller.currentWeek
                          : null,
                      dateLabel: _dateLabel(),
                      weekPending: _controller.weekPending,
                      onWeekTap: _toggleWeekStrip,
                      // §14.1：「+」三选一（课程 / 考试 / 其他）；「课程」仍是原手动课表单。
                      onAdd: () =>
                          showAddEntrySheet(context, controller: _controller),
                      onSync: _manualSync,
                      syncing:
                          _controller.syncStatus == TimetableSyncStatus.syncing,
                      syncError: _showSyncErrorDot,
                      onSettings: _openSettings,
                    ),
                    // item 5：点顶栏周数展开 / 收起的横向周条（200ms）。
                    _weekStripSlot(context),
                    Expanded(
                      // 只有日程（考试 / 其他）没有课程时也显示周视图。
                      child:
                          _controller.hasCourses ||
                              _controller.scheduleEvents.isNotEmpty
                          ? PageView.builder(
                              controller: _pageController,
                              itemCount: _totalWeeks,
                              onPageChanged: _onPageChanged,
                              itemBuilder: (context, index) {
                                final week = index + 1;
                                if (TimetablePerf.armed) {
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) => TimetablePerf.markGridFirstFrame(
                                      courses: _controller.courses.length,
                                    ),
                                  );
                                }
                                return WeekGrid(
                                  week: week,
                                  controller: _controller,
                                  onCourseTap: (cell) => showCourseDetailSheet(
                                    context,
                                    cell: cell,
                                    controller: _controller,
                                  ),
                                );
                              },
                            )
                          : _EmptyState(
                              loggedIn: _controller.portalBound,
                              loading: _controller.loading,
                              onLogin: _openLogin,
                            ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _dateLabel() {
    final now = DateTime.now();
    return '${now.year}/${now.month}/${now.day}';
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.week,
    required this.isCurrent,
    this.endedCurrentWeek,
    required this.dateLabel,
    this.weekPending = false,
    this.syncing = false,
    this.syncError = false,
    required this.onWeekTap,
    required this.onAdd,
    required this.onSync,
    required this.onSettings,
  });

  final int week;
  final bool isCurrent;

  /// 本周已超出学期总周数时为本周周次（显示「课程已结束」，不显示「非本周」）。
  final int? endedCurrentWeek;
  final String dateLabel;
  final bool weekPending;
  final bool syncing;

  /// AS-1：上次自动同步失败（同步图标右上角画圆点，读屏「同步，上次同步失败」）。
  final bool syncError;
  final VoidCallback onWeekTap;
  final VoidCallback onAdd;
  final VoidCallback onSync;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    // 最小高度而非固定高度：大字号下可增高，不裁切。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TimetableTheme.appBarHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onWeekTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text.rich(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        TextSpan(
                          style: TimetableTheme.displayStyle(
                            color: colors.titleText,
                          ),
                          children: [
                            TextSpan(text: '第 $week 周'),
                            if (!isCurrent && endedCurrentWeek == null)
                              TextSpan(
                                text: '(非本周)',
                                style: TimetableTheme.displayStyle(
                                  color: colors.hint,
                                ).copyWith(fontSize: 14),
                              ),
                          ],
                        ),
                      ),
                      if (endedCurrentWeek != null && !weekPending)
                        Text(
                          '本周第 $endedCurrentWeek 周 · 课程已结束',
                          key: const Key('timetable_term_ended'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TimetableTheme.microStyle(color: colors.hint),
                        )
                      else if (weekPending)
                        Text(
                          '周次待同步 · 点此选择',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TimetableTheme.microStyle(
                            color: colors.warning,
                          ),
                        )
                      else
                        Text(
                          dateLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TimetableTheme.microStyle(color: colors.hint),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _IconBtn(icon: Icons.add, onTap: onAdd, tooltip: '添加'),
            if (syncing)
              const SizedBox(
                key: Key('timetable_syncing_indicator'),
                width: TimetableTheme.iconTapSize,
                height: TimetableTheme.iconTapSize,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Semantics(
                key: const Key('timetable_sync_button'),
                container: true,
                button: true,
                excludeSemantics: true,
                label: syncError ? '同步，上次同步失败' : '同步',
                onTap: onSync,
                // 圆点叠在图标上，不改按钮尺寸（48×48）。
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _IconBtn(icon: Icons.sync, onTap: onSync, tooltip: '同步'),
                    if (syncError)
                      const Positioned(
                        top: 10,
                        right: 10,
                        child: IgnorePointer(
                          child: SizedBox(
                            key: Key('timetable_sync_error_dot'),
                            width: TimetableTheme.syncErrorDotSize,
                            height: TimetableTheme.syncErrorDotSize,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: TimetableTheme.syncErrorDot,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            _IconBtn(
              key: const Key('timetable_settings_button'),
              icon: Icons.settings_outlined,
              onTap: onSettings,
              tooltip: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: TimetableTheme.iconTapSize,
      height: TimetableTheme.iconTapSize,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, size: TimetableTheme.iconSize),
        color: TimetableTheme.colorsOf(context).titleText,
      ),
    );
  }
}

/// 空状态：未绑定显示「去登录」；已绑定不再有「立即同步」按钮（10/18 定：同步只走
/// 自动同步和顶栏同步图标）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.loggedIn,
    required this.loading,
    required this.onLogin,
  });

  final bool loggedIn;
  final bool loading;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_view_week_outlined,
              size: 56,
              color: colors.hint.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              '还没有课程',
              style: TimetableTheme.titleStyle(color: colors.titleText),
            ),
            const SizedBox(height: 8),
            Text(
              loggedIn ? '点右上角同步图标，从教务同步本学期课表' : '登录统一门户后自动同步课表',
              textAlign: TextAlign.center,
              style: TimetableTheme.captionStyle(color: colors.hint),
            ),
            if (!loggedIn) ...[
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('timetable_empty_login'),
                onPressed: loading ? null : onLogin,
                style: FilledButton.styleFrom(backgroundColor: colors.accent),
                child: const Text('去登录'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// item 3：翻过 [weeks] 周的动画时长：1 周 250ms，每多 1 周 +50ms，上限 500ms。
Duration weekJumpDuration(int weeks) {
  final n = weeks.abs() < 1 ? 1 : weeks.abs();
  return Duration(milliseconds: (250 + 50 * (n - 1)).clamp(250, 500));
}

/// 翻到 [target] 页（周条点本周 / 选周共用）：时长见 [weekJumpDuration]，曲线
/// easeOutCubic，始终直接滑过去（产品 10/19：不再先瞬移到相邻页）；[reduceMotion]
/// （系统关闭动画）时直接跳。
Future<void> animateWeekPage(
  PageController pc,
  int target, {
  required bool reduceMotion,
}) async {
  final from = pc.page?.round() ?? pc.initialPage;
  final delta = target - from;
  if (delta == 0) return;
  if (reduceMotion) {
    pc.jumpToPage(target);
    return;
  }
  final duration = weekJumpDuration(delta);
  await pc.animateToPage(
    target,
    duration: duration,
    curve: Curves.easeOutCubic,
  );
}

/// item 5：横向周条（1…N 周胶囊）。本周描边，当前选中实心；读屏「第 N 周」。
class _WeekStrip extends StatefulWidget {
  const _WeekStrip({
    required this.total,
    required this.current,
    required this.selected,
    required this.onSelect,
  });

  final int total;
  final int current;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<_WeekStrip> createState() => _WeekStripState();
}

class _WeekStripState extends State<_WeekStrip> {
  static const double _chipW = 48;
  static const double _currentChipW = 56;
  static const double _gap = 8;

  late final ScrollController _scroll = ScrollController(
    // 展开时让选中周大致居中（前面留 2 个胶囊）。
    initialScrollOffset: ((widget.selected - 3) * (_chipW + _gap))
        .clamp(0, double.infinity)
        .toDouble(),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return SizedBox(
      key: const Key('timetable_week_strip'),
      height: 56,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: widget.total,
        separatorBuilder: (_, _) => const SizedBox(width: _gap),
        itemBuilder: (context, i) {
          final week = i + 1;
          final isCurrent = week == widget.current;
          final isSelected = week == widget.selected;
          return Semantics(
            key: ValueKey('week_chip_$week'),
            button: true,
            selected: isSelected,
            excludeSemantics: true,
            label: isCurrent ? '第 $week 周，本周' : '第 $week 周',
            onTap: () => widget.onSelect(week),
            child: Material(
              color: isSelected ? colors.accent : colors.chipBg,
              shape: StadiumBorder(
                side: isCurrent && !isSelected
                    ? BorderSide(color: colors.accent, width: 1.5)
                    : BorderSide.none,
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => widget.onSelect(week),
                child: SizedBox(
                  // spec-next-1020 item 6：本周胶囊文案「本周」，点它即回到本周。
                  width: isCurrent ? _currentChipW : _chipW,
                  child: Center(
                    child: Text(
                      isCurrent ? '本周' : '$week',
                      key: isCurrent
                          ? const Key('timetable_week_strip_current')
                          : null,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        // 选中为 accent 实心底，上面压白字。
                        color: isSelected
                            ? Colors.white
                            : (isCurrent ? colors.accent : colors.titleText),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
