import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/app_navigation.dart';
import '../../core/navigation/app_page.dart';
import '../../core/app_snack_bar.dart';
import 'timetable_schedule_event_detail_sheet.dart';
import 'timetable_schedule_event.dart';
import 'timetable_change_alert.dart';
import 'timetable_controller.dart';
import 'timetable_export_page.dart';
import 'timetable_import_page.dart';
import 'timetable_perf.dart';
import 'timetable_settings_page.dart';
import 'timetable_switcher_sheet.dart';
import 'timetable_theme.dart';
import 'timetable_course_detail_sheet.dart';
import 'timetable_week_grid.dart';

/// 课表周视图主页：顶栏 + PageView 翻周 + 网格。
class TimetablePage extends StatefulWidget {
  const TimetablePage({super.key, this.focusTomorrow = false, this.focusEvent});

  /// 从明日通知进入时定位到明天所在周。
  final bool focusTomorrow;

  /// 从考试安排进入时，定位并短暂强调这一场考试。
  final ScheduleEvent? focusEvent;

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  final _host = TimetableController.instance;
  TimetableController get _controller => _host.viewingController;
  TimetableController? _attachedViewing;
  StreamSubscription<TimetableSyncOutcome>? _viewingOutcomeSub;
  PageController? _pageController;
  bool _ready = false;
  Object? _weekPagerInputs;
  Widget? _weekPager;
  double? _dragStartPage;
  bool _viewingWeekCleared = false;
  bool _syncAlertQueued = false;
  bool _syncAlertScheduled = false;
  bool _openingEntryDetail = true;
  ScheduleEvent? _focusedEvent;
  bool _eventFocusRevealed = false;
  String? _focusUnavailableMessage;

  /// 每次同步结束的结果（成功 / 失败、是否自动），决定弹哪种 SnackBar。
  StreamSubscription<TimetableSyncOutcome>? _outcomeSub;

  /// 同一次登录过期在本进程内只提示一次：弹过后置 true，
  /// [TimetableController.portalSessionExpired] 清掉后复位（见 [_watchSessionExpiry]）。
  static bool _sessionExpiryNotified = false;
  static bool _sessionExpiryWatching = false;

  /// AS-1：顶栏同步图标是否显示失败圆点（最近一次自动同步失败，下次成功后清除）。
  bool get _showSyncErrorDot => _host.lastAutoSyncFailed;

  /// 学期固定为 20 周，包含没有课程的周。
  int get _totalWeeks => _controller.totalWeeks;

  @override
  void initState() {
    super.initState();
    TimetablePerf.start();
    _host.addListener(_onHostChanged);
    _host.addListener(_maybeShowSessionExpired);
    _host.addListener(_queuePendingChangeAlert);
    _outcomeSub = _host.syncOutcomes.listen(_onSyncOutcome);
    _syncViewingListener();
    _watchSessionExpiry(_host);
    _bootstrap();
  }

  void _onHostChanged() {
    _syncViewingListener();
    _syncPageToViewingWeek();
    _queuePendingChangeAlert();
  }

  void _syncViewingListener() {
    final current = _controller;
    if (identical(_attachedViewing, current)) return;
    _attachedViewing?.viewingWeekListenable.removeListener(
      _syncPageToViewingWeek,
    );
    if (!identical(_attachedViewing, _host)) {
      _attachedViewing?.removeListener(_syncPageToViewingWeek);
      _attachedViewing?.removeListener(_queuePendingChangeAlert);
    }
    _viewingOutcomeSub?.cancel();
    _viewingOutcomeSub = null;
    _attachedViewing = current;
    current.viewingWeekListenable.addListener(_syncPageToViewingWeek);
    if (!identical(current, _host)) {
      current.addListener(_syncPageToViewingWeek);
      current.addListener(_queuePendingChangeAlert);
      _viewingOutcomeSub = current.syncOutcomes.listen(_onSyncOutcome);
    }
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
    if (_viewingWeekCleared) return;
    final pc = _pageController;
    if (pc == null) return;
    if (!pc.hasClients) {
      // PageView 可能在本帧才挂载（如空课表 → 同步出课程），挂载后再对齐。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && pc.hasClients) _syncPageToViewingWeek();
      });
      return;
    }
    // 防御越界状态，确保浏览周落在学期范围内。
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
    if (!_host.isInitialized ||
        widget.focusEvent != null ||
        widget.focusTomorrow ||
        _controller.viewingWeek !=
            _controller.currentWeek.clamp(1, _totalWeeks)) {
      // 定位其他周会通知仍在栈底的页面，在首个挂载build中不能同步发通知。
      // 有课时读完本地数据即可显示；门户绑定只决定空课表的登录引导。
      await _host.ensureLocalReady();
      if (!_controller.hasCourses && _controller.scheduleEvents.isEmpty) {
        await _host.ensureStarted();
      }
    }
    if (!mounted || _viewingWeekCleared) return;
    // 退出时已清除浏览周；离开期间跨周或修改系统日期时，再对齐到本周。
    _controller.followCurrentWeekIfChanged();
    if (widget.focusEvent != null) {
      _prepareEventFocus();
    } else if (widget.focusTomorrow) {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      _controller.setViewingWeek(_controller.actualWeek(tomorrow) ?? 1);
    }
    _pageController = PageController(
      initialPage: _pageFor(_controller.viewingWeek),
    );
    setState(() => _ready = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // 打开页面时已处于过期状态（如上次进程留下的）：也提示一次。
      _maybeShowSessionExpired();
      try {
        if (widget.focusEvent != null) {
          await _showUnavailableEventFocus();
        } else {
          await _openPendingCourse();
        }
      } finally {
        _openingEntryDetail = false;
        _queuePendingChangeAlert();
      }
    });
    await _host.autoSyncIfNeeded();
    _queuePendingChangeAlert();
  }

  void _queuePendingChangeAlert() {
    if (!mounted ||
        !_ready ||
        _viewingWeekCleared ||
        _syncAlertQueued ||
        _syncAlertScheduled ||
        _openingEntryDetail ||
        _controller.loading ||
        _controller.pendingChangeAlerts.isEmpty) {
      return;
    }
    _syncAlertScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncAlertScheduled = false;
      unawaited(_maybeShowPendingChangeAlert());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _maybeShowPendingChangeAlert() async {
    if (!mounted ||
        !_ready ||
        _viewingWeekCleared ||
        _syncAlertQueued ||
        _openingEntryDetail ||
        _controller.loading ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final records = _controller.pendingChangeAlerts;
    if (records.isEmpty) return;
    _syncAlertQueued = true;
    try {
      await showTimetableChangeAlert(
        context,
        records: records,
        controller: _controller,
      );
    } finally {
      _syncAlertQueued = false;
      _queuePendingChangeAlert();
    }
  }

  @override
  void didUpdateWidget(covariant TimetablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusEvent != oldWidget.focusEvent && _ready) {
      _openingEntryDetail = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        setState(_prepareEventFocus);
        try {
          await _showUnavailableEventFocus();
        } finally {
          _openingEntryDetail = false;
          _queuePendingChangeAlert();
        }
      });
    } else if (widget.focusTomorrow && _ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final now = DateTime.now();
        final tomorrow = DateTime(now.year, now.month, now.day + 1);
        _controller.setViewingWeek(_controller.actualWeek(tomorrow) ?? 1);
      });
    }
  }

  void _prepareEventFocus() {
    _focusedEvent = null;
    _eventFocusRevealed = false;
    _focusUnavailableMessage = null;
    final target = widget.focusEvent;
    if (target == null) return;
    final event = _controller.scheduleEvents
        .where((e) => e.id == target.id)
        .firstOrNull;
    if (event == null) {
      _focusUnavailableMessage = '这场考试已更新或删除，请返回考试安排查看';
      return;
    }
    final week = _controller.actualWeek(event.date);
    if (week == null) {
      _focusUnavailableMessage = '开学日期待同步，暂时无法定位考试周次';
    } else if (week < 1 || week > _totalWeeks) {
      _focusUnavailableMessage = '考试日期不在当前学期的课表范围内';
    } else {
      _focusedEvent = event;
      _controller.setViewingWeek(week);
    }
  }

  Future<void> _showUnavailableEventFocus() async {
    final message = _focusUnavailableMessage;
    if (message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(AppSnackBar(content: Text(message)));
    final event = _controller.scheduleEvents
        .where((e) => e.id == widget.focusEvent?.id)
        .firstOrNull;
    if (event != null) {
      await showScheduleEventDetailSheet(
        context,
        event: event,
        controller: _controller,
      );
    }
  }

  /// 打开门户绑定状态页（登录 / 解绑）。回来后只刷新绑定状态（UI）；登录成功的
  /// 同步由注册表统一分发，这里不重复调用。
  Future<void> _openLogin() async {
    await AppNavigation.push(context, '/portal-bind');
    if (!mounted) return;
    await _host.refreshPortalBound();
  }

  /// 顶栏同步图标：[TimetableController.manualSync]（不受节流）；未绑定门户时直接去登录，
  /// 不发请求也不弹网络失败。导入课表不支持教务同步。
  Future<void> _manualSync() async {
    if (_controller.isImportedSchedule) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.info,
          content: const Text('导入的课表不支持从教务同步'),
        ),
      );
      return;
    }
    final started = await _controller.manualSync();
    if (!started && !_host.portalBound && mounted) await _openLogin();
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
    if (!_host.portalSessionExpired || _sessionExpiryNotified) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _sessionExpiryNotified = true;
    messenger.hideCurrentSnackBar();
    var fired = false;
    messenger.showSnackBar(
      AppSnackBar(
        key: const Key('timetable_sync_snackbar'),
        tone: AppSnackBarTone.warning,
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
      // 有未通知变动时弹摘要 sheet，不再叠「已同步」SnackBar。
      if (_controller.pendingChangeAlerts.isNotEmpty) {
        _queuePendingChangeAlert();
        return;
      }
      messenger.showSnackBar(
        AppSnackBar(
          key: Key('timetable_sync_snackbar'),
          tone: AppSnackBarTone.success,
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
      AppSnackBar(
        key: const Key('timetable_sync_snackbar'),
        tone: AppSnackBarTone.error,
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
    _viewingOutcomeSub?.cancel();
    _attachedViewing?.viewingWeekListenable.removeListener(
      _syncPageToViewingWeek,
    );
    if (!identical(_attachedViewing, _host)) {
      _attachedViewing?.removeListener(_syncPageToViewingWeek);
      _attachedViewing?.removeListener(_queuePendingChangeAlert);
    }
    _host.removeListener(_maybeShowSessionExpired);
    _host.removeListener(_onHostChanged);
    _host.removeListener(_queuePendingChangeAlert);
    _pageController?.dispose();
    _clearViewingWeek();
    super.dispose();
  }

  /// 成功退出即清理；旧页面稍后销毁时不再覆盖新打开页面的周次。
  void _clearViewingWeek() {
    if (_viewingWeekCleared) return;
    _viewingWeekCleared = true;
    _controller.clearViewingWeek();
  }

  void _onPageChanged(int index) {
    if (_viewingWeekCleared) return;
    _controller.setViewingWeek(index + 1);
  }

  bool _trackWeekDrag(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragStartPage = _pageController?.page?.roundToDouble();
    } else if (notification is ScrollEndNotification) {
      _dragStartPage = null;
    }
    return false;
  }

  /// 顶部周数与课表切换弹窗是否处于打开状态（驱动小尖头旋转）。
  bool _weekStripOpen = false;

  Future<void> _openWeekAndSchedulePopup() async {
    if (_weekStripOpen) return;
    setState(() => _weekStripOpen = true);
    try {
      await showTimetableSwitcherSheet(
        context,
        controller: _host,
        totalWeeks: _totalWeeks,
        currentWeek: _controller.currentWeek,
        selectedWeek: _controller.viewingWeek,
        onSelectWeek: (w) => unawaited(_selectWeek(w)),
      );
    } finally {
      if (mounted) setState(() => _weekStripOpen = false);
    }
  }

  int _weekSelectSeq = 0;

  /// 选中某周后按 item 3 的规则（[animateWeekPage]）翻过去。
  Future<void> _selectWeek(int week) async {
    final seq = ++_weekSelectSeq;
    // 正在吸附时改为程序化滚动不一定产生 ScrollEnd，不能沿用旧拖动的相邻周限制。
    _dragStartPage = null;
    final pc = _pageController;
    if (pc != null && pc.hasClients) {
      await animateWeekPage(
        pc,
        _pageFor(week),
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );
    }
    if (mounted && !_viewingWeekCleared && seq == _weekSelectSeq) {
      _controller.setViewingWeek(week);
    }
  }

  void _openImport() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TimetableImportPage(controller: _host),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => TimetableSettingsPage(controller: _controller),
      ),
    );
  }

  void _openExport() {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => TimetableExportPage(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) ?? true) _queuePendingChangeAlert();
    final colors = TimetableTheme.colorsOf(context);
    final scaffold = Scaffold(
      // 输入只出现在弹层，键盘升降时保持背景课表的尺寸，避免重排整个周视图。
      resizeToAvoidBottomInset: false,
      backgroundColor: colors.pageBg,
      // 键盘升起时系统底部内边距逐帧归零；保持导航栏占位，弹层输入不重排周视图。
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: ListenableBuilder(
          listenable: _host,
          builder: (context, _) {
            final active = _controller;
            return ListenableBuilder(
              listenable: identical(active, _host)
                  ? const _NoopListenable()
                  : active,
              builder: (context, _) {
                if (!_ready || _pageController == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final meta = _host.viewingScheduleMeta;
                final scheduleLabel =
                    meta?.name ?? active.settings.scheduleName;
                return Column(
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: active.viewingWeekListenable,
                      builder: (context, viewingWeek, _) => _TopBar(
                        week: viewingWeek,
                        isCurrent: active.isViewingCurrentWeek,
                        endedCurrentWeek: _termEnded
                            ? active.currentWeek
                            : null,
                        dateLabel: _dateLabel(),
                        scheduleLabel: scheduleLabel,
                        weekPending: active.weekPending,
                        onWeekTap: _openWeekAndSchedulePopup,
                        onSwitchSchedule: _openWeekAndSchedulePopup,
                        weekSelectorOpen: _weekStripOpen,
                        // §14.1：「+」三选一（课程 / 考试 / 其他）；「课程」仍是原手动课表单。
                        onAdd: (buttonContext) => showAddEntrySheet(
                          buttonContext,
                          controller: active,
                        ),
                        onSync: _manualSync,
                        syncing:
                            active.syncStatus == TimetableSyncStatus.syncing ||
                            (_host.isViewingPrimary &&
                                _host.syncStatus ==
                                    TimetableSyncStatus.syncing),
                        syncError: _showSyncErrorDot,
                        onSettings: _openSettings,
                        onExport: _openExport,
                      ),
                    ),
                    Expanded(
                      // 只有日程（考试 / 其他）没有课程时也显示周视图。
                      child:
                          active.hasCourses || active.scheduleEvents.isNotEmpty
                          ? _buildWeekPager()
                          : _EmptyState(
                              loggedIn: _host.portalBound,
                              loading: active.loading || _host.loading,
                              isImported: meta?.isImportedSchedule == true,
                              hasOtherSchedules: _host.schedules.length > 1,
                              onLogin: _openLogin,
                              onImport: _openImport,
                              onSwitchSchedule: _openWeekAndSchedulePopup,
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _clearViewingWeek();
      },
      child: scaffold,
    );
  }

  Widget _buildWeekPager() {
    final now = DateTime.now();
    final inputs = (
      _controller.weekGridContentKey,
      _controller.weekStartDate(1),
      DateTime(now.year, now.month, now.day),
      _pageController,
      _focusedEvent,
      _eventFocusRevealed,
    );
    // PageView 经过半页时会通知浏览周，只更新页头和周条。保留同一个组件，
    // 避免滚动过程中再次构建两侧周网格及其所有文字；真实内容变化仍立即更新。
    if (_weekPagerInputs == inputs) return _weekPager!;
    _weekPagerInputs = inputs;
    return _weekPager = NotificationListener<ScrollNotification>(
      onNotification: _trackWeekDrag,
      child: PageView.builder(
        controller: _pageController,
        // 自定义物理模型负责吸附，避免 PageView 再叠加默认半页阈值。
        pageSnapping: false,
        physics: _WeekPagePhysics(dragStartPage: () => _dragStartPage),
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
            revealFocusedEvent: !_eventFocusRevealed,
            onFocusedEventRevealed: () {
              _eventFocusRevealed = true;
            },
            focusedEvent:
                _focusedEvent != null &&
                    _controller.actualWeek(_focusedEvent!.date) == week
                ? _focusedEvent
                : null,
            onCourseTap: (cell) => showCourseDetailSheet(
              context,
              cell: cell,
              controller: _controller,
            ),
          );
        },
      ),
    );
  }

  String _dateLabel() {
    final now = DateTime.now();
    return '${now.year}/${now.month}/${now.day}';
  }
}

/// 低速拖过四分之一页即可翻周，跟手位移不变；速度足够时沿用快速甩动规则。
class _WeekPagePhysics extends PageScrollPhysics {
  const _WeekPagePhysics({required this.dragStartPage, super.parent});

  final double? Function() dragStartPage;

  @override
  _WeekPagePhysics applyTo(ScrollPhysics? ancestor) => _WeekPagePhysics(
    dragStartPage: dragStartPage,
    parent: buildParent(ancestor),
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final start = dragStartPage();
    if (start == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position is PageMetrics
        ? position.page!
        : position.pixels / position.viewportDimension;
    final tolerance = toleranceFor(position);
    final double targetPage;
    if (velocity.abs() > tolerance.velocity) {
      // 与 PageScrollPhysics 一样按松手速度选方向，单次拖动最多进入相邻一周。
      targetPage = (page + velocity.sign * 0.5).roundToDouble().clamp(
        start - 1,
        start + 1,
      );
    } else {
      final distance = page - start;
      targetPage = start + (distance.abs() >= 0.25 ? distance.sign : 0);
    }
    final pageExtent =
        position.viewportDimension *
        (position is PageMetrics ? position.viewportFraction : 1);
    final target = (position.pixels + (targetPage - page) * pageExtent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.week,
    required this.isCurrent,
    this.endedCurrentWeek,
    required this.dateLabel,
    required this.scheduleLabel,
    this.weekPending = false,
    this.syncing = false,
    this.syncError = false,
    required this.onWeekTap,
    required this.onSwitchSchedule,
    required this.weekSelectorOpen,
    required this.onAdd,
    required this.onSync,
    required this.onSettings,
    required this.onExport,
  });

  final int week;
  final bool isCurrent;

  /// 本周已超出学期总周数时为本周周次（显示「课程已结束」，不显示「非本周」）。
  final int? endedCurrentWeek;
  final String dateLabel;
  final String scheduleLabel;
  final bool weekPending;
  final bool syncing;

  /// AS-1：上次自动同步失败（同步图标右上角画圆点，读屏「同步，上次同步失败」）。
  final bool syncError;
  final VoidCallback onWeekTap;
  final VoidCallback onSwitchSchedule;
  final bool weekSelectorOpen;
  final void Function(BuildContext anchorContext) onAdd;
  final VoidCallback onSync;
  final VoidCallback onSettings;
  final VoidCallback onExport;

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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: onWeekTap,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 40),
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
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 2),
                                    child: AnimatedRotation(
                                      turns: weekSelectorOpen ? 0.5 : 0,
                                      duration: const Duration(
                                        milliseconds: 150,
                                      ),
                                      child: Icon(
                                        Icons.arrow_drop_down,
                                        key: const Key(
                                          'timetable_week_tip_arrow',
                                        ),
                                        size: 16,
                                        color: colors.titleText,
                                      ),
                                    ),
                                  ),
                                ),
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
                            GestureDetector(
                              key: const Key(
                                'timetable_schedule_switcher_button',
                              ),
                              behavior: HitTestBehavior.opaque,
                              onTap: onSwitchSchedule,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '$scheduleLabel · 课程已结束',
                                      key: const Key('timetable_term_ended'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TimetableTheme.microStyle(
                                        color: colors.hint,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.unfold_more,
                                    size: 12,
                                    color: colors.hint,
                                  ),
                                ],
                              ),
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
                            GestureDetector(
                              key: const Key(
                                'timetable_schedule_switcher_button',
                              ),
                              behavior: HitTestBehavior.opaque,
                              onTap: onSwitchSchedule,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '$scheduleLabel · $dateLabel',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TimetableTheme.microStyle(
                                        color: colors.hint,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.unfold_more,
                                    size: 12,
                                    color: colors.hint,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Builder(
              builder: (buttonContext) => _IconBtn(
                icon: Icons.add,
                onTap: () => onAdd(buttonContext),
                tooltip: '添加',
              ),
            ),
            _IconBtn(
              key: const Key('timetable_export_button'),
              icon: Icons.ios_share,
              onTap: onExport,
              tooltip: '导出到 WakeUp',
            ),
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
/// 自动同步和顶栏同步图标）。支持直接从 WakeUp 口令导入或切换课表。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.loggedIn,
    required this.loading,
    required this.isImported,
    required this.hasOtherSchedules,
    required this.onLogin,
    required this.onImport,
    required this.onSwitchSchedule,
  });

  final bool loggedIn;
  final bool loading;
  final bool isImported;
  final bool hasOtherSchedules;
  final VoidCallback onLogin;
  final VoidCallback onImport;
  final VoidCallback onSwitchSchedule;

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
              isImported
                  ? '该导入课表暂无课程安排'
                  : (loggedIn ? '点右上角同步图标，从教务同步本学期课表' : '登录统一门户后自动同步课表'),
              textAlign: TextAlign.center,
              style: TimetableTheme.captionStyle(color: colors.hint),
            ),
            if (!loggedIn && !isImported) ...[
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('timetable_empty_login'),
                onPressed: loading ? null : onLogin,
                style: FilledButton.styleFrom(backgroundColor: colors.accent),
                child: const Text('去登录'),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  key: const Key('timetable_empty_import_wakeup'),
                  onPressed: onImport,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('从口令导入'),
                ),
                if (hasOtherSchedules)
                  TextButton.icon(
                    key: const Key('timetable_empty_switch'),
                    onPressed: onSwitchSchedule,
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('切换课表'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoopListenable extends Listenable {
  const _NoopListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
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
