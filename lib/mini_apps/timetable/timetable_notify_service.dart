import 'dart:async';

import 'timetable_controller.dart';
import 'timetable_course_color.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_notify_plan.dart';

/// 上课提醒 + 桌面小组件的编排层：从 [TimetableController] 取课，算好后交给原生。
///
/// UI 只需要：
/// - 读写设置：[reminderEnabled] / [reminderLeadMinutes] / [setReminderEnabled] /
///   [setReminderLeadMinutes]（等价于 `controller.updateSettings(copyWith(...))`，
///   改设置后会自动重排，无需手动调 [reschedule]）；
/// - 权限：[permissionStatus] / [requestNotificationPermission] /
///   [openExactAlarmSettings] / [openBatteryOptimizationSettings]；
/// - 小组件：[refreshWidget]。
///
/// 课表数据变化（同步、编辑、手动课、调课、单日修改、设置、解绑）通过
/// [TimetableController.scheduleChanged] 自动触发重排；App 启动 / 回前台由
/// TimetableLifecycleScope 调 [reschedule]。
class TimetableNotifyService {
  TimetableNotifyService({
    TimetableController? controller,
    TimetableNotifyBridge? bridge,
    DateTime Function()? clock,
  }) : _ctl = controller ?? TimetableController.instance,
       _bridge = bridge ?? TimetableNotifyBridge.instance,
       _clock = clock ?? DateTime.now;

  static final TimetableNotifyService instance = TimetableNotifyService();

  final TimetableController _ctl;
  final TimetableNotifyBridge _bridge;
  final DateTime Function() _clock;

  StreamSubscription<ScheduleChangeReason>? _changeSub;
  StreamSubscription<TimetableSyncOutcome>? _syncSub;
  Future<void>? _started;
  Timer? _debounce;
  bool _lastSyncFailed = false;

  /// 幂等启动：订阅课表变化并做一次重排。
  Future<void> ensureStarted() => _started ??= _start();

  Future<void> _start() async {
    await _ctl.ensureStarted();
    _changeSub = _ctl.scheduleChanged.listen((r) {
      if (r == ScheduleChangeReason.unbind) {
        // 解绑：取消全部提醒，开关保留。
        unawaited(_bridge.cancelReminders());
      }
      _scheduleSoon();
    });
    _syncSub = _ctl.syncOutcomes.listen((o) {
      _lastSyncFailed = !o.success;
      _scheduleSoon();
    });
    await reschedule();
  }

  /// 释放订阅（测试用）。
  Future<void> dispose() async {
    _debounce?.cancel();
    await _changeSub?.cancel();
    await _syncSub?.cancel();
    _started = null;
  }

  void _scheduleSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(reschedule());
    });
  }

  // ---- 设置 ----

  /// 是否开启上课提醒（默认关）。
  bool get reminderEnabled => _ctl.settings.reminderEnabled;

  /// 提前分钟数，取值见 [kReminderLeadOptions]（默认 15）。
  int get reminderLeadMinutes => _ctl.settings.reminderLeadMinutes;

  /// 开关提醒。打开时会请求通知权限（Android 13+）；不论授权结果开关都保持
  /// 用户选择，返回最新权限状态供 UI 决定是否提示（无精确闹钟权限 → 提示去授权，
  /// 提醒已退化为非精确）。
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    if (enabled) await _bridge.requestNotificationPermission();
    if (enabled != reminderEnabled) {
      await _ctl.updateSettings(
        _ctl.settings.copyWith(reminderEnabled: enabled),
      );
    }
    return _bridge.permissionStatus();
  }

  /// 修改提前量：只接受 [kReminderLeadOptions]（5/10/15/30），其他值按 15 处理。
  Future<void> setReminderLeadMinutes(int minutes) async {
    final v = TimetableSettings.sanitizeLeadMinutes(minutes);
    if (v == reminderLeadMinutes) return;
    await _ctl.updateSettings(_ctl.settings.copyWith(reminderLeadMinutes: v));
  }

  // ---- 小组件显示开关（默认全开）----

  bool get widgetShowTeacher => _ctl.settings.widgetShowTeacher;
  bool get widgetShowLocation => _ctl.settings.widgetShowLocation;
  bool get widgetShowCountdown => _ctl.settings.widgetShowCountdown;
  bool get widgetShowCount => _ctl.settings.widgetShowCount;
  bool get widgetShowPeriod => _ctl.settings.widgetShowPeriod;
  int get widgetCourseCount => _ctl.settings.widgetCourseCount;

  /// 五个开关一次取齐。
  WidgetPrefs widgetPrefs() {
    final s = _ctl.settings;
    return WidgetPrefs(
      showTeacher: s.widgetShowTeacher,
      showLocation: s.widgetShowLocation,
      showCountdown: s.widgetShowCountdown,
      showCount: s.widgetShowCount,
      showPeriod: s.widgetShowPeriod,
      courseCount: s.widgetCourseCount,
    );
  }

  /// 保存设置并**立即**刷新小组件（无需调用方再刷新）。
  Future<void> _setWidgetPref(TimetableSettings next) async {
    await _ctl.updateSettings(next);
    await refreshWidget();
  }

  Future<void> setWidgetShowTeacher(bool v) =>
      _setWidgetPref(_ctl.settings.copyWith(widgetShowTeacher: v));
  Future<void> setWidgetShowLocation(bool v) =>
      _setWidgetPref(_ctl.settings.copyWith(widgetShowLocation: v));
  Future<void> setWidgetShowCountdown(bool v) =>
      _setWidgetPref(_ctl.settings.copyWith(widgetShowCountdown: v));
  Future<void> setWidgetShowCount(bool v) =>
      _setWidgetPref(_ctl.settings.copyWith(widgetShowCount: v));
  Future<void> setWidgetShowPeriod(bool v) =>
      _setWidgetPref(_ctl.settings.copyWith(widgetShowPeriod: v));

  /// 同时显示课程数，只接受 1 / 2 / 3；其他值回落到 2。
  Future<void> setWidgetCourseCount(int n) => _setWidgetPref(
    _ctl.settings.copyWith(
      widgetCourseCount: TimetableSettings.sanitizeCourseCount(n),
    ),
  );

  // ---- 权限 ----

  Future<NotifyPermissionStatus> permissionStatus() =>
      _bridge.permissionStatus();

  Future<bool> requestNotificationPermission() =>
      _bridge.requestNotificationPermission();

  Future<bool> openExactAlarmSettings() => _bridge.openExactAlarmSettings();

  Future<bool> openBatteryOptimizationSettings() =>
      _bridge.openBatteryOptimizationSettings();

  Future<bool> openNotificationSettings() => _bridge.openNotificationSettings();

  Future<bool> pinWidget({required bool square}) =>
      _bridge.pinWidget(square: square);

  // ---- 计算 ----

  /// 某天的课，包含调课、单日编辑及实验/体育的实际时刻。
  List<NotifyClass> classesOn(DateTime date) {
    final out = <NotifyClass>[
      for (final item in _ctl.coursesOnDate(date)) ?_notifyClass(date, item),
    ];
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  NotifyClass? _notifyClass(DateTime date, TodayCourseItem item) {
    // 与首页 / 周格同一入口，保证小组件 payload 的时刻与 UI 一致。
    final time = _ctl.timeForSlot(item.course, item.slot, date: date);
    final start = _at(date, time.start);
    final end = _at(date, time.end);
    if (start == null || end == null) return null;
    return NotifyClass(
      name: item.course.displayName,
      location: item.slot.location,
      start: start,
      end: end,
      courseId: item.course.id,
      teachers: widgetTeachers(item.slot.teacher),
      startNode: item.slot.startNode,
      endNode: item.slot.endNode,
      barColor: coursePairFor(_ctl, item.course).bg.toARGB32(),
      barColorDark: coursePairFor(_ctl, item.course, dark: true).bg.toARGB32(),
    );
  }

  NotifyClass? _tomorrowFirst(DateTime date) {
    final first = _ctl.firstCourseTomorrow(now: date);
    if (first == null) return null;
    return _notifyClass(DateTime(date.year, date.month, date.day + 1), first);
  }

  static DateTime? _at(DateTime day, String? hhmm) {
    if (hhmm == null) return null;
    final p = hhmm.split(':');
    if (p.length < 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return DateTime(day.year, day.month, day.day, h, m);
  }

  /// 当前应排的提醒（关闭 / 未绑定 → 空）。
  List<ReminderAlarm> currentPlan() {
    if (!reminderEnabled || !_ctl.portalBound) return const [];
    return planReminders(
      now: _clock(),
      leadMinutes: reminderLeadMinutes,
      classesOn: classesOn,
    );
  }

  /// 当前小组件 payload。
  Map<String, Object?> currentWidgetPayload() {
    final now = _clock();
    final synced = _ctl.syncedAt;
    final stale =
        !_ctl.portalBound ||
        !_ctl.hasCourses ||
        synced == null ||
        now.difference(synced) > const Duration(days: 7);
    final state = stale
        ? WidgetDataState.needsUpdate
        : (_lastSyncFailed ? WidgetDataState.loadFailed : WidgetDataState.ok);
    return buildWidgetPayload(
      now: now,
      classesOn: classesOn,
      weekOf: _ctl.actualWeek,
      state: state,
      hasCache: _ctl.hasCourses,
      lastSyncedAt: synced,
      prefs: widgetPrefs(),
      tomorrowFirst: _tomorrowFirst(now),
      tomorrowFirstOn: _tomorrowFirst,
    );
  }

  /// 重排提醒并刷新小组件。数据或设置变化后会自动调用；UI 一般无需手动调。
  Future<void> reschedule() async {
    try {
      final plan = currentPlan();
      await _bridge.scheduleReminders([for (final a in plan) a.toJson()]);
    } catch (_) {}
    await refreshWidget();
  }

  /// 只刷新小组件（写入最新 payload）。
  Future<void> refreshWidget() async {
    try {
      await _bridge.updateWidget(currentWidgetPayload());
    } catch (_) {}
  }
}
