import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import 'timetable_api.dart';
import 'timetable_colors.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_store.dart';
import 'timetable_store.dart';
import 'timetable_theme.dart';
import 'timetable_week_layout.dart';

/// 教务同步状态。
enum TimetableSyncStatus { idle, syncing, success, failure }

/// 最近一次同步失败原因。
enum TimetableSyncFailure { none, network, server, sessionExpired, unknown }

/// 将同步异常归类为 [TimetableSyncFailure]。
@visibleForTesting
TimetableSyncFailure classifySyncError(Object e) {
  if (e is JwxtSessionExpiredError) return TimetableSyncFailure.sessionExpired;
  if (e is PortalNetworkError) return TimetableSyncFailure.network;
  if (e is PortalCredentialError) return TimetableSyncFailure.sessionExpired;
  if (e is TimeoutException || e is SocketException || e is HttpException) {
    return TimetableSyncFailure.network;
  }
  if (e is JwxtHttpError) {
    if (e.status == 401) return TimetableSyncFailure.sessionExpired;
    return e.status >= 500
        ? TimetableSyncFailure.server
        : TimetableSyncFailure.unknown;
  }
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return TimetableSyncFailure.network;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code >= 500) return TimetableSyncFailure.server;
        if (code == 401) return TimetableSyncFailure.sessionExpired;
        return TimetableSyncFailure.unknown;
      default:
        final inner = e.error;
        if (inner is SocketException ||
            inner is TimeoutException ||
            inner is HttpException ||
            inner is PortalNetworkError) {
          return TimetableSyncFailure.network;
        }
        return TimetableSyncFailure.unknown;
    }
  }
  return TimetableSyncFailure.unknown;
}

/// 一次同步（任意来源）结束后的结果，见 [TimetableController.syncOutcomes] /
/// [TimetableController.lastSyncOutcome]。失败原因沿用 [TimetableSyncFailure]
/// （与 [TimetableController.syncFailure] 相同的 [classifySyncError] 分类）。
@immutable
class TimetableSyncOutcome {
  const TimetableSyncOutcome._({
    required this.success,
    required this.automatic,
    this.failure = TimetableSyncFailure.none,
    this.offline = false,
  });

  const TimetableSyncOutcome.success({required bool automatic})
    : this._(success: true, automatic: automatic);

  const TimetableSyncOutcome.failure({
    required bool automatic,
    required TimetableSyncFailure failure,
    required bool offline,
  }) : this._(
         success: false,
         automatic: automatic,
         failure: failure,
         offline: offline,
       );

  final bool success;

  /// 是否自动触发（冷启动 / 回前台 / 网络恢复 / 打开课表页的自动同步）。
  /// 手动同步图标、登录成功后的同步为 false。
  final bool automatic;

  /// 失败原因；成功为 [TimetableSyncFailure.none]。
  final TimetableSyncFailure failure;

  /// 失败且属于「网络不可用」（断网 / DNS / 连不上；与网络恢复补同步同一判定）。
  /// [failure] 为 [TimetableSyncFailure.network] 而 [offline] 为 false 即超时类。
  final bool offline;
}

/// [TimetableController.scheduleChanged] 的触发原因（提醒等后续功能订阅）。
enum ScheduleChangeReason {
  sync,
  move,
  restore,
  manualCourse,
  settings,
  unbind,
  scheduleEvent,
  courseEdit,
}

/// 课表全局状态：首页卡片与周视图共用。
class TimetableController extends ChangeNotifier {
  TimetableController._();

  static final TimetableController instance = TimetableController._();

  bool _started = false;
  Future<void>? _starting;

  TimetableSnapshot _snapshot = const TimetableSnapshot();
  int _viewingWeek = 1;
  bool _loading = false;
  String? _statusMessage;
  bool _portalBound = false;
  PendingCourseOpen? _pendingOpen;
  TimetableSyncStatus _syncStatus = TimetableSyncStatus.idle;
  TimetableSyncFailure _syncFailure = TimetableSyncFailure.none;
  Future<void>? _syncInFlight;

  List<Course> _manualCourses = const [];
  int _manualSeq = 0;

  // ---- 调课记录（教务课）----
  List<SlotOverride> _overrides = const [];
  List<Course>? _effJwxtSrc;
  List<SlotOverride>? _effOverridesSrc;
  AppliedOverrides? _effJwxt;
  Map<String, CourseEdit>? _effEditsSrc;

  final StreamController<ScheduleChangeReason> _scheduleChanged =
      StreamController<ScheduleChangeReason>.broadcast();

  /// 课表实际内容可能变化时触发：同步成功、拖动调课/恢复原位置、手动课增删改、
  /// 设置修改、解绑。提醒（设置 11）后续订阅它重排。
  Stream<ScheduleChangeReason> get scheduleChanged => _scheduleChanged.stream;

  void _fireScheduleChanged(ScheduleChangeReason r) => _scheduleChanged.add(r);

  final StreamController<TimetableSyncOutcome> _syncOutcomes =
      StreamController<TimetableSyncOutcome>.broadcast();

  /// 每次同步（任意来源）结束时触发一次：成功或失败（含失败分类、是否自动）。
  /// UI 用它决定是否弹「已同步」/「回到本周」或失败轻提示。
  Stream<TimetableSyncOutcome> get syncOutcomes => _syncOutcomes.stream;

  TimetableSyncOutcome? _lastSyncOutcome;

  /// 最近一次同步的结果（本次进程内；未同步过 / 解绑后为 null）。
  TimetableSyncOutcome? get lastSyncOutcome => _lastSyncOutcome;

  bool _lastAutoSyncFailed = false;

  /// 最近一次自动同步（冷启动 / 回前台 / 网络恢复 / 打开课表页）失败后为 true；
  /// 之后任意一次同步成功（含手动、登录）即清除。不持久化。失败原因见
  /// [syncFailure] / [lastSyncOutcome]。
  bool get lastAutoSyncFailed => _lastAutoSyncFailed;

  bool _portalSessionExpired = false;

  /// 门户 / 教务登录已过期：任意一次同步（自动或手动）因
  /// [TimetableSyncFailure.sessionExpired] 失败后为 true；登录成功
  /// （[onLoginSucceeded]）、解绑、任意一次同步成功后清除。持久化在
  /// `sync_state.json`（重启后仍在）。变化时 notifyListeners。
  bool get portalSessionExpired => _portalSessionExpired;

  Future<void> _setPortalSessionExpired(bool value) async {
    if (_portalSessionExpired == value) return;
    _portalSessionExpired = value;
    try {
      await ScheduleStore.savePortalSessionExpired(value);
    } catch (_) {
      // 写盘失败不影响内存状态与同步结果。
    }
    notifyListeners();
  }

  /// 下一次 [syncFromJwxt] 是否算自动同步（由触发入口设置，开始同步时取走）。
  bool _nextSyncAuto = false;

  /// 套用调课记录后的教务课程（缓存；教务数据或记录变化时重算）。
  /// 再套编辑/删除覆盖层（[applyCourseEdits]）。
  AppliedOverrides get _applied {
    if (_effJwxt == null ||
        !identical(_effJwxtSrc, _snapshot.courses) ||
        !identical(_effOverridesSrc, _overrides) ||
        !identical(_effEditsSrc, _courseEdits)) {
      _effJwxtSrc = _snapshot.courses;
      _effOverridesSrc = _overrides;
      _effEditsSrc = _courseEdits;
      final moved = applySlotOverrides(_snapshot.courses, _overrides);
      _effJwxt = AppliedOverrides(
        applyCourseEdits(moved.courses, _snapshot.courses, _courseEdits),
        moved.orphanIds,
      );
    }
    return _effJwxt!;
  }

  /// 当前所有调课记录（只读）。
  List<SlotOverride> get slotOverrides => List.unmodifiable(_overrides);

  /// 找不到原课/原时段（或 SKZC 对不上）、暂不渲染的记录 id。解绑后保留；
  /// 下次同步成功时按 [staleOverrideIds] 删除。
  Set<String> get orphanedOverrideIds => _applied.orphanIds;

  /// 教务快照（courses 仅含 JWXT 课程）。
  TimetableSnapshot get snapshot => _snapshot;

  /// 教务同步课程（只读）。
  List<Course> get jwxtCourses => List.unmodifiable(_snapshot.courses);

  /// 用户手动课程（独立持久化，同步/退出登录不覆盖）。
  List<Course> get manualCourses => List.unmodifiable(_manualCourses);

  Map<String, int>? _colorMap;
  List<Course>? _colorMapJwxt;
  CoursePaletteScheme? _colorMapScheme;

  /// 全学期配色表（按课名，见 [assignCourseColors]），持久化在
  /// `timetable/course_colors.json`（[TimetableStore.saveCourseColors]）。
  ///
  /// 颜色稳定规则：拖动 / 恢复原位置 / 拆分时段 / 编辑手动课 / 解绑 / 重启都不改任何课的颜色。
  /// 只在教务同步（教务快照变化）、手动课增删、换配色方案时重算（[_recomputeColors]）。
  ///
  /// 启动时直接读盘上的表（方案一致时），不重建。只有表缺失/损坏/方案不符，或测试
  /// 直接注入快照时才惰性重建（[_buildFallbackColorMap]）。
  Map<String, int> get courseColorMap {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    if (_colorMap == null ||
        !identical(_colorMapJwxt, _snapshot.courses) ||
        _colorMapScheme != scheme) {
      _colorMapJwxt = _snapshot.courses;
      _colorMapScheme = scheme;
      _colorMap = _buildFallbackColorMap(scheme);
    }
    return _colorMap!;
  }

  /// 无可用配色表时重建一次：教务课按原始位置（忽略调课记录）；手动课已存的
  /// [Course.assignedColorIndex] 当固定色参与、不重新顺延。手动课与教务课同名时
  /// 不拿手动课的 assignedColorIndex 去固定该课名（否则改名成教务课名的手动课
  /// 会抢走教务课的颜色），只参与相邻判断。
  Map<String, int> _buildFallbackColorMap(CoursePaletteScheme scheme) {
    final jwxtNames = {
      for (final c in _snapshot.courses) normalizeCourseName(c.name),
    };
    return assignCourseColors([
      ..._snapshot.courses,
      for (final c in _manualCourses)
        c.colorIndex == null &&
                c.assignedColorIndex != null &&
                !jwxtNames.contains(normalizeCourseName(c.name))
            ? c.copyWith(colorIndex: c.assignedColorIndex)
            : c,
    ], scheme: scheme);
  }

  /// 全量重算配色（手动课只固定用户自选色号），把结果写回手动课的
  /// [Course.assignedColorIndex]（仅内存；调用方负责落盘 manual_courses.json），
  /// 并总是写 course_colors.json。返回手动课是否有变化。
  /// 只有四处调用：换配色方案、同步成功、增手动课、删手动课。
  Future<bool> _recomputeColors() async {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    final map = assignCourseColors([
      ..._snapshot.courses, // 教务原始位置，不套调课记录
      for (final c in _manualCourses) c.copyWith(clearAssignedColor: true),
    ], scheme: scheme);
    _colorMap = map;
    _colorMapJwxt = _snapshot.courses;
    _colorMapScheme = scheme;
    final changed = _writeAssigned(map, onlyMissing: false);
    await TimetableStore.saveCourseColors(scheme, map);
    return changed;
  }

  bool _writeAssigned(Map<String, int> map, {required bool onlyMissing}) {
    var changed = false;
    final next = [
      for (final c in _manualCourses)
        if (c.colorIndex != null ||
            (onlyMissing && c.assignedColorIndex != null))
          c
        else
          () {
            final v =
                map[normalizeCourseName(c.name)] ??
                (onlyMissing ? _colorForOne(c) : null);
            if (v == null || v == c.assignedColorIndex) return c;
            changed = true;
            return c.copyWith(assignedColorIndex: v);
          }(),
    ];
    if (changed) _manualCourses = next;
    return changed;
  }

  /// 只给 [target] 这门手动课算一个自动色号：教务课固定在当前配色表的颜色，其他
  /// 手动课固定在 colorIndex ?? assignedColorIndex（都没有时用当前显示色），
  /// [target] 不带任何色号参与顺延。不改配色表、不改任何其他课。
  int _colorForOne(Course target) {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    final map = assignCourseColors([
      for (final c in _snapshot.courses)
        c.copyWith(colorIndex: colorIndexOf(c)),
      for (final c in _manualCourses)
        if (c.id != target.id)
          c.copyWith(
            colorIndex: c.colorIndex ?? c.assignedColorIndex ?? colorIndexOf(c),
          ),
      target.copyWith(clearColor: true, clearAssignedColor: true),
    ], scheme: scheme);
    return map[normalizeCourseName(target.name)] ?? target.resolvedColorIndex;
  }

  /// 旧数据（缺 [Course.assignedColorIndex]）：已存的当固定色，缺的从已加载的配色表
  /// 取（表里没有这门课名时只给它单独算一次）。返回是否需要落盘。
  bool _fillMissingAssignedColors() {
    if (!_manualCourses.any(
      (c) => c.colorIndex == null && c.assignedColorIndex == null,
    )) {
      return false;
    }
    return _writeAssigned(courseColorMap, onlyMissing: true);
  }

  /// 课程最终色号（0-based，与查看周无关）。
  ///
  /// 手动色号直接返回；否则查 [courseColorMap]：相邻（同天节次相接/重叠，或同节次
  /// 左右相邻两天，且周次有交集）两门课色号相同或属于当前方案近似对表
  /// （[kNearColorPairs]，A 柔和 13 对）时，课名排序靠后的那门顺延。渲染时计算，不落盘。
  int colorIndexOf(Course c) =>
      c.colorIndex ??
      (c.isManual ? c.assignedColorIndex : null) ??
      courseColorMap[normalizeCourseName(_colorNameOf(c))] ??
      c.resolvedColorIndex;

  /// 配色用课名：教务课总用教务原课名（改名不换色），手动课用自身课名。
  String _colorNameOf(Course c) {
    if (c.isManual || !_courseEdits.containsKey(c.id)) return c.name;
    return _jwxtCourseById(c.id)?.name ?? c.name;
  }

  /// 学期级冲突：与 [candidate] 同星期、节次重叠且周次相交的课程（教务+手动，跳过隐藏）。
  /// 编辑已有课程时传 [excludeId] 排除自身。
  List<Course> conflictsFor(CourseSlot candidate, {String? excludeId}) =>
      courseConflicts(combinedCourses, candidate, excludeId: excludeId);

  /// 网格展示用合并列表：教务在前、手动在后。
  List<Course> get combinedCourses =>
      List.unmodifiable([..._applied.courses, ..._manualCourses]);

  /// 同 [combinedCourses]（周视图/首页使用）。
  List<Course> get courses => combinedCourses;

  /// 学期总周数：所有课程（教务 + 手动）中最晚有课的周次；
  /// 无法解析周次的课程（未排课/「其他课程」，无 hasClassInWeek 为真的周）不计入。
  /// 没有任何可计入的课程时退回 [kDefaultTotalWeeks]。不看位串长度。
  int get totalWeeks {
    var max = 0;
    for (final c in combinedCourses) {
      final w = _lastWeekWithClass(c);
      if (w > max) max = w;
    }
    return max > 0 ? max : kDefaultTotalWeeks;
  }

  /// 课程最后一个有课的周（经 [CourseSlot.hasClassInWeek] 判定）；无则 0。
  static int _lastWeekWithClass(Course c) {
    var max = 0;
    for (final s in c.slots) {
      for (var w = s.weeks.length; w > max; w--) {
        if (s.hasClassInWeek(w)) {
          max = w;
          break;
        }
      }
    }
    return max;
  }

  /// 课程变动后把浏览周钳回 1..totalWeeks（页面无需自行处理）。
  void _clampViewingWeek() {
    _viewingWeek = _viewingWeek.clamp(1, totalWeeks);
  }

  static const kDefaultTotalWeeks = 20;

  /// 已废弃：请用 [totalWeeks]。
  @Deprecated('Use totalWeeks')
  int get maxWeeks => totalWeeks;

  /// 最近一次教务同步状态。
  TimetableSyncStatus get syncStatus => _syncStatus;

  /// 最近一次同步失败原因（同步开始/成功时为 none）。
  TimetableSyncFailure get syncFailure => _syncFailure;

  /// 最近一次同步成功。
  bool get statusIsSuccess => _syncStatus == TimetableSyncStatus.success;

  /// 是否已绑定门户凭据（测试可替换）。
  @visibleForTesting
  static Future<bool> Function() bindingCheck = _defaultBindingCheck;

  static Future<bool> _defaultBindingCheck() async =>
      await PasskeyStore.read() != null;

  /// 测试用：替换教务拉取。
  @visibleForTesting
  static Future<TimetableSnapshot> Function(
    String term, {
    TimetableSettings? baseSettings,
  })
  fetchSnapshot = _defaultFetch;

  static Future<TimetableSnapshot> _defaultFetch(
    String term, {
    TimetableSettings? baseSettings,
  }) => TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);

  /// 测试用：替换教务考试拉取（第 11 条）。课表拉取成功后才调用；抛错 = 拉取失败
  /// （已有考试保留）；返回 null = 本次不拉（已有考试保留）。
  @visibleForTesting
  static Future<List<ScheduleEvent>?> Function(String term) fetchExams =
      _defaultFetchExams;

  /// 只在课表也走真实教务时才发考试请求：测试替换了 [fetchSnapshot] 却没替换
  /// [fetchExams] 时不发真实网络请求。
  static Future<List<ScheduleEvent>?> _defaultFetchExams(String term) async {
    if (!identical(fetchSnapshot, _defaultFetch)) return null;
    return TimetableApi.fetchExams(term);
  }

  List<PeriodTime> get periods => _snapshot.periods;
  TimetableSettings get settings => _snapshot.settings;
  int get viewingWeek => _viewingWeek;
  bool get loading => _loading;
  String? get statusMessage => _statusMessage;
  bool get portalBound => _portalBound;
  bool get hasCourses =>
      !_snapshot.isEmpty || _manualCourses.any((c) => !c.hidden);
  DateTime? get syncedAt => _snapshot.syncedAt;

  /// 「今天」（Asia/Shanghai），测试可替换。
  @visibleForTesting
  static DateTime Function() clock = TimetableApi.shanghaiToday;

  DateTime get _today {
    final t = clock();
    return DateTime(t.year, t.month, t.day);
  }

  /// 无可用开学日（无 dqzc、无可信缓存、无内置配置）：周次待同步，按第 1 周展示。
  bool get weekPending => settings.termStartDate == null;

  /// 按开学日推算的「本周」；无法推算时退回 1。
  int get currentWeek {
    final start = settings.termStartDate;
    if (start == null) return 1;
    final week = teachingWeekOf(start, _today);
    if (week < 1) return 1;
    // 不按 totalWeeks 截断：返回真实教学周（可能 > totalWeeks）。
    return week;
  }

  /// [date] 所在的真实教学周（不钳制，可为 0/负数或 > totalWeeks）；
  /// 无开学日时返回 null。今日/明日课程按各自日期用它判定。
  int? actualWeek(DateTime date) {
    final start = settings.termStartDate;
    if (start == null) return null;
    return teachingWeekOf(start, DateTime(date.year, date.month, date.day));
  }

  /// 某天有课的格子：真实周 < 1 或超出位串（hasClassInWeek 为 false）即无课。
  /// 无开学日时按第 1 周（与 [weekPending] 展示一致）。
  Iterable<GridCell> _activeCellsOn(DateTime date) {
    final week = actualWeek(date) ?? 1;
    if (week < 1) return const [];
    return cellsForDay(week, date.weekday).where((c) => c.activeThisWeek);
  }

  /// 打开课表时默认浏览的周：本周，钳到 1..totalWeeks。
  int get _defaultViewingWeek => currentWeek.clamp(1, totalWeeks);

  bool get isViewingCurrentWeek => _viewingWeek == currentWeek;

  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    _manualCourses = await TimetableStore.readManualCourses();
    _overrides = await TimetableStore.readOverrides();
    _scheduleEvents = List.unmodifiable(await ScheduleStore.readEvents());
    _otherColors = Map.unmodifiable(await ScheduleStore.readOtherColors());
    _courseEdits = Map.unmodifiable(await ScheduleStore.readCourseEdits());
    _examOverrides = Map.unmodifiable(await ScheduleStore.readExamOverrides());
    _lastSyncSuccessAt = await ScheduleStore.readLastSyncSuccess();
    _portalSessionExpired = await ScheduleStore.readPortalSessionExpired();
    final cached = await TimetableStore.readSnapshot();
    final storedSettings = await TimetableStore.readSettings();
    if (cached != null) {
      _snapshot = cached.copyWith(
        settings: cached.settings.termCode.isEmpty
            ? storedSettings
            : cached.settings
                  .withDisplayPrefsFrom(storedSettings)
                  .copyWith(
                    scheduleName: storedSettings.scheduleName != '我的课表'
                        ? storedSettings.scheduleName
                        : cached.settings.scheduleName,
                  ),
      );
    } else {
      _snapshot = TimetableSnapshot(settings: storedSettings);
    }
    _snapshot = _snapshot.copyWith(
      settings: _withResolvedTermStart(
        _snapshot.settings.termCode.isEmpty
            ? _snapshot.settings.copyWith(termCode: '2026-2027-1')
            : _snapshot.settings,
      ),
    );
    if (_snapshot.periods.isEmpty) {
      _snapshot = _snapshot.copyWith(periods: defaultPeriods());
    }
    await _loadColorMap();
    if (_fillMissingAssignedColors()) {
      await TimetableStore.saveManualCourses(_manualCourses);
    }
    // 旧数据：「其他」日程的名称还没有固定色号 → 补一次并落盘（只写 schedule_events.json）。
    if (_backfillOtherColors()) {
      await ScheduleStore.saveEventsAndOtherColors(
        _scheduleEvents,
        _otherColors,
      );
    }
    _viewingWeek = _defaultViewingWeek;
    _portalBound = await bindingCheck();
    notifyListeners();
  }

  /// 启动时读 course_colors.json：方案与当前一致就直接用；缺失/损坏/方案不符/
  /// 类型不对 → 重建一次（[_buildFallbackColorMap]）并落盘。
  Future<void> _loadColorMap() async {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    StoredCourseColors? stored;
    try {
      stored = await TimetableStore.readCourseColors();
    } catch (_) {
      stored = null;
    }
    _colorMapJwxt = _snapshot.courses;
    _colorMapScheme = scheme;
    if (stored != null && stored.scheme == scheme) {
      _colorMap = stored.map;
      return;
    }
    _colorMap = _buildFallbackColorMap(scheme);
    try {
      await TimetableStore.saveCourseColors(scheme, _colorMap!);
    } catch (_) {}
  }

  void setViewingWeek(int week) {
    final clamped = week.clamp(1, totalWeeks);
    if (clamped == _viewingWeek) return;
    _viewingWeek = clamped;
    notifyListeners();
  }

  void goToCurrentWeek() => setViewingWeek(currentWeek);

  /// 「回到本周」（同 [goToCurrentWeek]；已在本周时不通知）。
  void jumpToCurrentWeek() => goToCurrentWeek();

  Future<void> updateSettings(TimetableSettings next) async {
    final previous = _snapshot.settings;
    _snapshot = _snapshot.copyWith(settings: next);
    if (previous.paletteScheme != next.paletteScheme &&
        await _recomputeColors()) {
      await TimetableStore.saveManualCourses(_manualCourses);
    }
    // 只把用户实际改动的键合并进原始 settings.json，其余原值/未知键保留。
    await TimetableStore.mergeSettingsChanges(previous, next);
    await TimetableStore.saveSnapshot(_snapshot);
    notifyListeners();
    _fireScheduleChanged(ScheduleChangeReason.settings);
  }

  /// 缓存为空或非今日同步 → 需要同步。
  bool get needsSync {
    if (!hasCourses) return true;
    final at = _snapshot.syncedAt;
    if (at == null) return true;
    final now = DateTime.now();
    return at.year != now.year || at.month != now.month || at.day != now.day;
  }

  /// 刷新门户登录状态。
  Future<bool> refreshPortalBound() async {
    _portalBound = await bindingCheck();
    notifyListeners();
    return _portalBound;
  }

  /// 页面打开时：已登录且缓存为空/过期则自动同步。
  /// 同样受 10 分钟节流（距上次成功不足则不同步）。
  Future<void> autoSyncIfNeeded() async {
    if (_loading || !needsSync) return;
    if (!_elapsedSinceSuccess(autoSyncInterval)) return;
    if (!await refreshPortalBound()) return;
    if (_loading || _syncInFlight != null) return;
    _nextSyncAuto = true;
    await syncFromJwxt();
  }

  /// 手动「立即同步」入口：未绑定门户时不发请求、不报失败，返回 false
  /// 由页面跳转登录；已绑定则同步并返回 true。
  Future<bool> syncIfBound() async {
    if (!await refreshPortalBound()) return false;
    await syncFromJwxt();
    return true;
  }

  /// 从教务 wdkb 同步课表（复用门户会话）。失败保留缓存并在同步条提示。
  /// 进行中再次调用返回同一个 Future（不重复请求）。
  Future<void> syncFromJwxt() {
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;
    if (_loading) return Future.value();
    final automatic = _nextSyncAuto;
    _nextSyncAuto = false;
    late final Future<void> f;
    f = _doSync(automatic: automatic).whenComplete(() {
      if (identical(_syncInFlight, f)) _syncInFlight = null;
    });
    _syncInFlight = f;
    return f;
  }

  Future<void> _doSync({bool automatic = false}) async {
    TimetableSyncOutcome? outcome;
    _loading = true;
    _statusMessage = '正在同步教务课表…';
    _syncStatus = TimetableSyncStatus.syncing;
    _syncFailure = TimetableSyncFailure.none;
    notifyListeners();
    try {
      final term = settings.termCode.isNotEmpty
          ? settings.termCode
          : '2026-2027-1';
      final previous = settings;
      // SW01：记下同步前是否正在看本周。
      final wasOnCurrentWeek = isViewingCurrentWeek;
      var snapshot = await fetchSnapshot(
        term,
        // 清空开学日，以便区分「本次 dqzc 推算」与「缓存/默认值」。
        baseSettings: previous.copyWith(clearTermStart: true),
      );
      if (snapshot.periods.isEmpty) {
        snapshot = snapshot.copyWith(
          periods: _snapshot.periods.isEmpty
              ? defaultPeriods()
              : _snapshot.periods,
        );
      }
      snapshot = snapshot.copyWith(
        settings: _withResolvedTermStart(snapshot.settings, cached: previous),
      );
      snapshot = snapshot.copyWith(
        // 快照只存教务课程；手动课程在独立文件，不受同步影响。
        courses: [
          for (final c in snapshot.courses)
            if (c.source == CourseSource.jwxt) c,
        ],
        syncedAt: DateTime.now(),
        clearError: true,
      );
      _snapshot = snapshot;
      // SW01（§13.10）：同步成功后停留在正在看的周（只钳到 1..totalWeeks）。
      // 同步前就在看本周、之前周次未知（无开学日）或换了学期时才跟到新的本周。
      if (wasOnCurrentWeek ||
          previous.termStartDate == null ||
          previous.termCode != _snapshot.settings.termCode) {
        _viewingWeek = _defaultViewingWeek; // 已钳到 1..totalWeeks
      } else {
        _clampViewingWeek();
      }
      await TimetableStore.saveSnapshot(_snapshot);
      // settings.json 只合并学期四键（与磁盘一致则不写）；periodHeight 原值、
      // 开关与未知键原样保留，绝不序列化整个内存设置。
      await TimetableStore.mergeTermSettings(_snapshot.settings);
      // 教务优先（jwxt §3.2）：原课被删、SKZC 与 origWeeks 不同（含缺 origWeeks
      // 的旧记录）、或原时段星期/节次变了 → 删掉记录，显示教务数据。其余保留。
      // 只在同步成功这里比较；解绑不删。
      final stale = staleOverrideIds(_snapshot.courses, _overrides);
      if (stale.isNotEmpty) {
        _overrides = List.unmodifiable([
          for (final o in _overrides)
            if (!stale.contains(o.id)) o,
        ]);
        await TimetableStore.saveOverrides(_overrides);
      }
      // 编辑/删除记录同理：原课没了、SKZC 或时段变了 → 删除（解绑/失败不删）。
      final staleEdits = staleCourseEditIds(_snapshot.courses, _courseEdits);
      if (staleEdits.isNotEmpty) {
        _courseEdits = Map.unmodifiable(
          {..._courseEdits}..removeWhere((k, _) => staleEdits.contains(k)),
        );
        await ScheduleStore.saveCourseEdits(_courseEdits);
      }
      if (await _recomputeColors()) {
        await TimetableStore.saveManualCourses(_manualCourses);
      }
      // 第 11 条：课表成功后拉考试（不受 showExams 影响）。考试失败不影响本次课表
      // 同步结果、成功时间与离线补同步逻辑，已有考试保留。
      await _syncExams(term);
      // 只有成功才重置自动同步计时。
      _lastSyncSuccessAt = syncClock();
      _lastFailureOffline = false;
      await ScheduleStore.saveLastSyncSuccess(_lastSyncSuccessAt!);
      _statusMessage = '已同步 ${_snapshot.courses.length} 门教务课程';
      _syncStatus = TimetableSyncStatus.success;
      _syncFailure = TimetableSyncFailure.none;
      _lastAutoSyncFailed = false;
      await _setPortalSessionExpired(false);
      outcome = TimetableSyncOutcome.success(automatic: automatic);
      _fireScheduleChanged(ScheduleChangeReason.sync);
    } catch (e) {
      _lastFailureOffline = _isOffline(e);
      _syncFailure = classifySyncError(e);
      if (automatic) _lastAutoSyncFailed = true;
      outcome = TimetableSyncOutcome.failure(
        automatic: automatic,
        failure: _syncFailure,
        offline: _lastFailureOffline,
      );
      _statusMessage = '同步失败：$e';
      _syncStatus = TimetableSyncStatus.failure;
      _snapshot = _snapshot.copyWith(lastError: '$e');
      if (_syncFailure == TimetableSyncFailure.sessionExpired) {
        await _setPortalSessionExpired(true);
      }
    } finally {
      _loading = false;
      if (outcome != null) _lastSyncOutcome = outcome;
      notifyListeners();
      if (outcome != null) _syncOutcomes.add(outcome);
    }
  }

  /// 测试用：跳过磁盘，直接注入快照（[manualCourses] 不传则保持不变）。
  @visibleForTesting
  void debugSetSnapshot(
    TimetableSnapshot snapshot, {
    int? viewingWeek,
    List<Course>? manualCourses,
  }) {
    _snapshot = snapshot;
    if (manualCourses != null) _manualCourses = List.of(manualCourses);
    _colorMap = null;
    _started = true;
    _viewingWeek = viewingWeek ?? _defaultViewingWeek;
    notifyListeners();
  }

  /// 测试用：重置单例状态（下次 [ensureStarted] 重新读盘）。
  @visibleForTesting
  void debugReset() {
    _started = false;
    _starting = null;
    _snapshot = const TimetableSnapshot();
    _manualCourses = const [];
    _overrides = const [];
    _effJwxt = null;
    _scheduleEvents = const [];
    _otherColors = const {};
    _courseEdits = const {};
    _examOverrides = const {};
    _lastSyncSuccessAt = null;
    _lastFailureOffline = false;
    _offlineRetryPending = false;
    _triggerBusy = false;
    _lastAutoSyncFailed = false;
    _lastSyncOutcome = null;
    _nextSyncAuto = false;
    _portalSessionExpired = false;
    _colorMap = null;
    _colorMapJwxt = null;
    _colorMapScheme = null;
    _loading = false;
    _statusMessage = null;
    _syncStatus = TimetableSyncStatus.idle;
    _syncFailure = TimetableSyncFailure.none;
    _syncInFlight = null;
    _portalBound = false;
    _pendingOpen = null;
  }

  /// 清空教务课程与 snapshot 磁盘缓存，并清除教务写入的学期元数据；
  /// 手动课程与展示设置（周末/非本周/格子高度等）保留。
  Future<void> clearJwxtCourses() async {
    // 只重置学期相关字段；展示设置（周末/非本周/格子高度/网格线等）保留在内存。
    final clearedSettings = _snapshot.settings.copyWith(
      termCode: const TimetableSettings().termCode,
      maxWeeks: const TimetableSettings().maxWeeks,
      clearTermStart: true, // termStartDate=null, termStartFromJwxt=false
    );
    _snapshot = TimetableSnapshot(
      periods: _snapshot.periods.isEmpty ? defaultPeriods() : _snapshot.periods,
      settings: clearedSettings,
    );
    // 解绑不改颜色：配色表原样保留（手动课用已存的 assignedColorIndex），不惰性重建。
    _colorMapJwxt = _snapshot.courses;
    await TimetableStore.clearJwxtSnapshot();
    // 教务考试一并清掉；手动日程、考试覆盖、课程编辑、调课记录、配色表都保留。
    if (_scheduleEvents.any((e) => e.isFromJwxt)) {
      _scheduleEvents = List.unmodifiable([
        for (final e in _scheduleEvents)
          if (!e.isFromJwxt) e,
      ]);
      await ScheduleStore.saveEventsAndOtherColors(
        _scheduleEvents,
        _otherColors,
      );
    }
    // 不序列化内存设置：只从原始 settings.json 中删除学期键。
    await TimetableStore.removeTermSettingKeys();
    _clampViewingWeek();
    notifyListeners();
  }

  /// 兼容旧调用（页面 DEBUG 菜单）：仅清教务课程，手动课程保留。
  Future<void> clearCourses() => clearJwxtCourses();

  /// 退出登录/解绑门户：默认清掉教务课程、snapshot 磁盘缓存与教务学期元数据，
  /// 手动课程与展示设置保留。
  /// [clearJwxt] 为 false 时仅更新登录态，教务缓存与手动课程都保留。
  Future<void> handleLogout({bool clearJwxt = true}) async {
    _portalBound = false;
    // 解绑后不再残留上次同步失败的状态，免得打开课表又弹失败提示。
    _statusMessage = null;
    _syncStatus = TimetableSyncStatus.idle;
    _syncFailure = TimetableSyncFailure.none;
    _lastAutoSyncFailed = false;
    _lastSyncOutcome = null;
    await _setPortalSessionExpired(false);
    // 调课记录保留（jwxt §3.2 第 7 条），重新绑定同步后重新套用。
    if (clearJwxt) {
      await clearJwxtCourses();
    } else {
      notifyListeners();
    }
    _fireScheduleChanged(ScheduleChangeReason.unbind);
  }

  // ---- 手动课程 CRUD（只作用于 isManual 课程）----

  /// 新增手动课程；id 为空时自动生成。强制 source=manual。返回保存后的课程。
  Future<Course> addManualCourse(Course course) async {
    final id = course.id.isEmpty || _idTaken(course.id)
        ? _newManualId()
        : course.id;
    final saved = course.copyWith(id: id, source: CourseSource.manual);
    _manualCourses = [..._manualCourses, saved];
    await _recomputeColors();
    await _persistManual();
    return manualCourseById(saved.id) ?? saved;
  }

  /// 按 id 更新手动课程；id 不存在或指向教务课程时抛 [StateError]。
  ///
  /// 编辑不重算配色，谁的颜色都不变：
  /// - 有自选色 → 用自选色。
  /// - 无自选色：assignedColorIndex 取 `course.assignedColorIndex ??` 原值。
  /// - 刚清掉自选色（原来有 colorIndex、这次没有），或清完后既无自选色也无
  ///   assignedColorIndex → 只给这门课按当前邻居单独算一个（[_colorForOne]），
  ///   不沿用选自选色之前留下的旧 assignedColorIndex（可能已和邻居撞色）。
  /// - 时段：表单重建的时段不带 [CourseSlot.splitFrom]；星期/节次没变的时段沿用原
  ///   splitFrom，改了星期/节次的清掉。
  Future<Course> updateManualCourse(Course course) async {
    final index = _manualCourses.indexWhere((c) => c.id == course.id);
    if (index < 0) {
      throw StateError('只能修改手动课程：${course.id}');
    }
    final old = _manualCourses[index];
    var saved = course.copyWith(
      source: CourseSource.manual,
      slots: _carrySplitFrom(old.slots, course.slots),
    );
    if (saved.colorIndex == null) {
      final cleared = old.colorIndex != null;
      final keep = cleared
          ? null
          : (course.assignedColorIndex ?? old.assignedColorIndex);
      saved = keep != null
          ? saved.copyWith(assignedColorIndex: keep)
          : saved.copyWith(assignedColorIndex: _colorForOne(saved));
    }
    _manualCourses = [..._manualCourses]..[index] = saved;
    await _persistManual();
    return manualCourseById(saved.id) ?? saved;
  }

  /// 删除手动课程；返回是否删除。教务课程 id 不会被删除（返回 false）。
  Future<bool> deleteManualCourse(String id) async {
    final next = [
      for (final c in _manualCourses)
        if (c.id != id) c,
    ];
    if (next.length == _manualCourses.length) return false;
    _manualCourses = next;
    await _recomputeColors();
    await _persistManual();
    return true;
  }

  /// 新时段没带 splitFrom 时，从同下标（或同位置）的原时段沿用；位置变了不沿用。
  static List<CourseSlot> _carrySplitFrom(
    List<CourseSlot> before,
    List<CourseSlot> after,
  ) => [
    for (var i = 0; i < after.length; i++)
      if (after[i].splitFrom != null)
        after[i]
      else
        () {
          final s = after[i];
          CourseSlot? src;
          if (i < before.length && before[i].ref == s.ref) {
            src = before[i];
          } else {
            for (final b in before) {
              if (b.ref == s.ref && b.splitFrom != null) src ??= b;
            }
          }
          final from = src?.splitFrom;
          return from == null ? s : s.withSplitFrom(from);
        }(),
  ];

  Course? manualCourseById(String id) {
    for (final c in _manualCourses) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool _idTaken(String id) =>
      _manualCourses.any((c) => c.id == id) ||
      _snapshot.courses.any((c) => c.id == id);

  String _newManualId() {
    String id;
    do {
      id = 'manual-${DateTime.now().microsecondsSinceEpoch}-${_manualSeq++}';
    } while (_idTaken(id));
    return id;
  }

  Future<void> _persistManual([
    ScheduleChangeReason reason = ScheduleChangeReason.manualCourse,
  ]) async {
    await TimetableStore.saveManualCourses(_manualCourses);
    _clampViewingWeek();
    notifyListeners();
    _fireScheduleChanged(reason);
  }

  // ---- 拖动调课（spec §13.2，jwxt §3.2）----

  /// 最后一节（作息表最大节次；没有作息时用 nodesPerDay）。
  int get lastPeriod {
    var max = 0;
    for (final p in periods) {
      if (p.node > max) max = p.node;
    }
    return max > 0 ? max : settings.nodesPerDay;
  }

  /// 把 [course] 的第 [slotIndex] 个时段（[course] 取自 [cellsForDay]/[courses]，
  /// 即套用调课后的课程）在第 [week] 周拖到 [toDay] 的 [toStartPeriod] 起，时长不变。
  ///
  /// - [MoveScope.thisWeek]：只移第 [week] 周；[MoveScope.fromThisWeek]：移该时段
  ///   第 [week] 周及以后实际有课的周，之前的周不动。
  /// - 落回原位 → [MoveStatus.noChange]，不写任何东西。
  /// - 手动课直接改时段；教务课写调课记录（同一原时段的已有记录会合并）。
  /// - 冲突不拦，结果里给出按课名排序的冲突课名。
  Future<MoveResult> moveSlot(
    Course course,
    int slotIndex, {
    required int toDay,
    required int toStartPeriod,
    required int week,
    required MoveScope scope,
  }) async {
    if (slotIndex < 0 || slotIndex >= course.slots.length) {
      return const MoveResult.error(MoveError.invalidSlot);
    }
    final slot = course.slots[slotIndex];
    if (!slot.hasFixedTime) {
      return const MoveResult.error(MoveError.invalidSlot);
    }
    if (toDay < 1 || toDay > 7 || toStartPeriod < 1) {
      return const MoveResult.error(MoveError.invalidTarget);
    }
    final toEnd = toStartPeriod + slot.span - 1;
    if (toEnd > lastPeriod) {
      return const MoveResult.error(MoveError.pastLastPeriod);
    }
    if (!slot.hasClassInWeek(week)) {
      return const MoveResult.error(MoveError.notInWeek);
    }
    if (toDay == slot.day && toStartPeriod == slot.startNode) {
      return const MoveResult.noChange();
    }
    final affected = scope == MoveScope.thisWeek
        ? [week]
        : [
            for (final w in weeksOf(slot))
              if (w >= week) w,
          ];

    if (course.isManual) {
      final index = _manualCourses.indexWhere((c) => c.id == course.id);
      if (index < 0) return const MoveResult.error(MoveError.invalidSlot);
      final stored = _manualCourses[index];
      final si = _indexOfEqualSlot(stored.slots, slot, slotIndex);
      if (si < 0) return const MoveResult.error(MoveError.invalidSlot);
      final next = stored.copyWith(
        slots: moveManualSlots(
          stored.slots,
          si,
          affected,
          toDay: toDay,
          toStart: toStartPeriod,
          toEnd: toEnd,
        ),
      );
      _manualCourses = [..._manualCourses]..[index] = next;
      await _persistManual(ScheduleChangeReason.move);
    } else {
      final origin = _jwxtOriginal(course.id, slot, slotIndex);
      if (origin == null) return const MoveResult.error(MoveError.invalidSlot);
      bool same(SlotOverride o) =>
          o.matchesKey(course.id, origin) && o.origWeeks == origin.weeks;
      var next = subtractOverrideWeeks(_overrides, same, affected);
      final backHome =
          toDay == origin.day &&
          toStartPeriod == origin.startNode &&
          toEnd == origin.endNode;
      if (!backHome) {
        next = [
          ...next,
          SlotOverride(
            id: 'ovr-${DateTime.now().microsecondsSinceEpoch}-${_manualSeq++}',
            courseId: course.id,
            origDay: origin.day,
            origStart: origin.startNode,
            origEnd: origin.endNode,
            origWeeks: origin.weeks,
            weeks: affected,
            scope: scope,
            fromWeek: week,
            toDay: toDay,
            toStart: toStartPeriod,
            toEnd: toEnd,
            createdAt: DateTime.now().toIso8601String(),
          ),
        ];
      }
      await _setOverrides(next, ScheduleChangeReason.move);
    }
    return MoveResult.moved(
      affectedWeeks: affected,
      conflictNames: _conflictNames(
        course.id,
        toDay,
        toStartPeriod,
        toEnd,
        affected,
      ),
    );
  }

  /// 详情页「恢复原位置」：删掉该时段对应教务原时段的全部调课记录。
  /// 手动课或没有调课记录时返回 false。
  Future<bool> restoreOverride(Course course, int slotIndex) async {
    if (course.isManual) return false;
    if (slotIndex < 0 || slotIndex >= course.slots.length) return false;
    final origin = _jwxtOriginal(course.id, course.slots[slotIndex], slotIndex);
    if (origin == null) return false;
    final next = [
      for (final o in _overrides)
        if (!(o.matchesKey(course.id, origin) && o.origWeeks == origin.weeks))
          o,
    ];
    if (next.length == _overrides.length) return false;
    await _setOverrides(next, ScheduleChangeReason.restore);
    return true;
  }

  /// 该时段是调过的教务课时段时返回原时间（详情页「已调课：原 周X 第 a–b 节」）；
  /// 否则 null。
  SlotOverrideInfo? overrideInfoFor(Course course, int slotIndex) {
    if (course.isManual) return null;
    if (slotIndex < 0 || slotIndex >= course.slots.length) return null;
    final o = slotOriginOf(course.slots[slotIndex]);
    if (o == null || !o.moved || o.courseId != course.id) return null;
    return SlotOverrideInfo(
      originalDay: o.original.day,
      originalStart: o.original.startNode,
      originalEnd: o.original.endNode,
    );
  }

  /// 该时段是否有调课记录（调过去的时段）。
  bool hasOverride(Course course, int slotIndex) =>
      overrideInfoFor(course, slotIndex) != null;

  // ===== 第 4/10 条：日程、教务课编辑/删除、教务考试覆盖 =====

  /// 盘上的原始日程：手动日程 + 教务考试原样（覆盖层另存，不改这里的教务条目）。
  List<ScheduleEvent> _scheduleEvents = const [];

  /// 教务课编辑 / 删除记录（按 courseId），`course_edits.json`。
  Map<String, CourseEdit> _courseEdits = const {};

  /// 教务考试覆盖（按原始 examKey），`exam_overrides.json`。
  Map<String, ExamOverride> _examOverrides = const {};

  /// 「其他」日程按名称固定的色号（`schedule_events.json` 顶层 `otherColors`）。
  /// 一经分配不再重算；删掉某名称的最后一条日程也保留（无害）。
  Map<String, int> _otherColors = const {};

  /// 「其他」日程配色表（名称 → 色号，名称按 [normalizeCourseName]）。
  Map<String, int> get otherColors => Map.unmodifiable(_otherColors);

  static String _otherKey(String name) => normalizeCourseName(name);

  /// 「其他」日程色号（0-based，同课程色板）。按名称查固定表；表里没有（理论上
  /// 不会出现）时退回名称哈希，不写盘。考试不用色号（用 settings.examColor）。
  int otherColorIndexOf(ScheduleEvent e) =>
      _otherColors[_otherKey(e.title)] ?? courseColorIndexForName(e.title);

  /// 给新名称挑色号：优先「没有任何课程使用、也没有其他名称使用」的，再退到
  /// 「没有课程使用」的，都没有（课程占满色板）→ 名称哈希。从名称哈希位起顺序找，
  /// 结果确定。只读课程颜色（[colorIndexOf]），不写 course_colors.json、不触发重算。
  int _pickOtherColor(String name) {
    final hash = courseColorIndexForName(name);
    final byCourses = <int>{
      for (final c in combinedCourses) colorIndexOf(c) % kCoursePaletteSize,
    };
    final byNames = _otherColors.values.toSet();
    for (final avoidNames in [true, false]) {
      for (var i = 0; i < kCoursePaletteSize; i++) {
        final idx = (hash + i) % kCoursePaletteSize;
        if (byCourses.contains(idx)) continue;
        if (avoidNames && byNames.contains(idx)) continue;
        return idx;
      }
    }
    return hash;
  }

  /// 确保 [name] 有固定色号；[inherit] 非空且名称未登记时直接用它（改名不变色）。
  /// 返回是否新增了条目。
  bool _ensureOtherColor(String name, {int? inherit}) {
    final key = _otherKey(name);
    if (_otherColors.containsKey(key)) return false;
    _otherColors = Map.unmodifiable({
      ..._otherColors,
      key: inherit ?? _pickOtherColor(name),
    });
    return true;
  }

  /// 启动时补齐：「其他」日程名称缺色号的各分配一次。返回是否有变化。
  bool _backfillOtherColors() {
    var changed = false;
    for (final e in _scheduleEvents) {
      if (e.kind == ScheduleKind.other && _ensureOtherColor(e.title)) {
        changed = true;
      }
    }
    return changed;
  }

  /// 课表同步成功后拉教务考试并整批替换（覆盖层由 [replaceJwxtExams] 按 examKey
  /// 保留 / 清理）。任何失败只记一条通用日志，已有考试不动。
  Future<void> _syncExams(String term) async {
    final List<ScheduleEvent>? exams;
    try {
      exams = await fetchExams(term);
    } catch (_) {
      if (kDebugMode) debugPrint('[timetable] 教务考试拉取失败，保留已有考试');
      return;
    }
    if (exams == null) return;
    try {
      await replaceJwxtExams(exams);
    } catch (_) {
      if (kDebugMode) debugPrint('[timetable] 教务考试保存失败，保留已有考试');
    }
  }

  /// 套用考试覆盖后的日程（删除的教务考试不在其中），id 不变。
  List<ScheduleEvent> get _effectiveEvents => [
    for (final e in _scheduleEvents)
      if (!e.isFromJwxt)
        e
      else if (_examOverrides[e.jwxtKey] case final o?)
        ?o.applyTo(e)
      else
        e,
  ];

  /// 全部日程（考试 + 其他，含教务与手动；已套用教务考试的编辑/删除），
  /// 未按 showExams 开关过滤。
  List<ScheduleEvent> get scheduleEvents => List.unmodifiable(_effectiveEvents);

  /// 某天要显示的日程：考试受 [TimetableSettings.showExams] 控制，「其他」不受。
  /// 按开始时间排序。
  List<ScheduleEvent> scheduleEventsOn(DateTime date) => [
    for (final e in _effectiveEvents)
      if (e.date.year == date.year &&
          e.date.month == date.month &&
          e.date.day == date.day &&
          (!e.isExam || settings.showExams))
        e,
  ]..sort((a, b) => a.start.compareTo(b.start));

  /// 首页卡片用：今天（[now] 默认 [clock]）最后一个可见项目的结束时间。
  /// 计入当天的课（已套用调课/编辑/删除）+ 可见日程（showExams 关时不计考试，
  /// 「其他」总计入）。今天什么都没有 → null。
  TimeOfDayMinutes? lastVisibleItemEndToday({DateTime? now}) {
    final n = now ?? clock();
    final today = DateTime(n.year, n.month, n.day);
    TimeOfDayMinutes? last;
    void take(TimeOfDayMinutes? t) {
      if (t != null && (last == null || t.compareTo(last!) > 0)) last = t;
    }

    if (settings.termStartDate != null) {
      for (final cell in _activeCellsOn(today)) {
        take(TimeOfDayMinutes.tryParse(periodEnd(cell.slot.endNode)));
      }
    }
    for (final e in scheduleEventsOn(today)) {
      take(e.end);
    }
    return last;
  }

  ScheduleEvent? _rawEvent(String id) {
    for (final e in _scheduleEvents) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 教务考试的原始 examKey（课程号 + 原日期 + 原开始时间），供
  /// [isJwxtOverridden] / [restoreJwxtExam] 使用；编辑后展示的日期/时间可能已变，
  /// 不要用展示事件的 [ScheduleEvent.jwxtKey]。手动日程或 id 不存在 → null。
  String? jwxtExamKeyOf(String eventId) => _rawEvent(eventId)?.jwxtKey;

  int _eventSeq = 0;

  /// 新增手动日程（考试 / 其他）。强制 source=manual；id 为空或重复时自动生成。
  Future<ScheduleEvent> addScheduleEvent(ScheduleEvent event) async {
    final id = event.id.isEmpty || _rawEvent(event.id) != null
        ? 'event-${DateTime.now().microsecondsSinceEpoch}-${_eventSeq++}'
        : event.id;
    final saved = event.copyWith(id: id, source: ScheduleSource.manual);
    if (saved.kind == ScheduleKind.other) _ensureOtherColor(saved.title);
    _scheduleEvents = List.unmodifiable([..._scheduleEvents, saved]);
    await _persistEvents();
    return saved;
  }

  /// 编辑日程（按 [event].id 找）：手动的直接改；教务考试写覆盖层（按原 examKey，
  /// 只记与教务原值不同的字段）。id 不存在返回 false。
  Future<bool> updateScheduleEvent(ScheduleEvent event) async {
    final raw = _rawEvent(event.id);
    if (raw == null) return false;
    if (raw.isFromJwxt) {
      final key = raw.jwxtKey!;
      _examOverrides = Map.unmodifiable({
        ..._examOverrides,
        key: ExamOverride.diff(raw, event),
      });
      await ScheduleStore.saveExamOverrides(_examOverrides);
      _notifyEvents();
      return true;
    }
    if (event.kind == ScheduleKind.other) {
      // 改名到已登记的名称 → 用该名称的颜色；改成新名称 → 沿用这条日程当前的颜色。
      _ensureOtherColor(
        event.title,
        inherit: raw.kind == ScheduleKind.other ? otherColorIndexOf(raw) : null,
      );
    }
    _scheduleEvents = List.unmodifiable([
      for (final e in _scheduleEvents)
        if (e.id == event.id)
          event.copyWith(source: ScheduleSource.manual)
        else
          e,
    ]);
    await _persistEvents();
    return true;
  }

  /// 删除日程：手动的直接删；教务考试写「已删除」覆盖。id 不存在返回 false。
  Future<bool> deleteScheduleEvent(String id) async {
    final raw = _rawEvent(id);
    if (raw == null) return false;
    if (raw.isFromJwxt) {
      final key = raw.jwxtKey!;
      _examOverrides = Map.unmodifiable({
        ..._examOverrides,
        key: ExamOverride(key: key, deleted: true),
      });
      await ScheduleStore.saveExamOverrides(_examOverrides);
      _notifyEvents();
      return true;
    }
    _scheduleEvents = List.unmodifiable([
      for (final e in _scheduleEvents)
        if (e.id != id) e,
    ]);
    await _persistEvents();
    return true;
  }

  /// 教务考试同步步骤（[_syncExams] 拉取成功后调用）：批量替换 source=jwxt 的日程，手动日程不动。
  /// 新列表里不再出现的 examKey 的覆盖记录删除。只应在拉取成功后调用。
  Future<void> replaceJwxtExams(List<ScheduleEvent> exams) async {
    final fresh = [
      for (final e in exams)
        e.copyWith(source: ScheduleSource.jwxt, kind: ScheduleKind.exam),
    ];
    final keys = {for (final e in fresh) e.jwxtKey};
    _scheduleEvents = List.unmodifiable([
      for (final e in _scheduleEvents)
        if (!e.isFromJwxt) e,
      ...fresh,
    ]);
    final keptOverrides = {
      for (final o in _examOverrides.values)
        if (keys.contains(o.key)) o.key: o,
    };
    if (keptOverrides.length != _examOverrides.length) {
      _examOverrides = Map.unmodifiable(keptOverrides);
      await ScheduleStore.saveExamOverrides(_examOverrides);
    }
    await ScheduleStore.saveEventsAndOtherColors(_scheduleEvents, _otherColors);
    _notifyEvents(ScheduleChangeReason.sync);
  }

  Future<void> _persistEvents() async {
    await ScheduleStore.saveEventsAndOtherColors(_scheduleEvents, _otherColors);
    _notifyEvents();
  }

  void _notifyEvents([
    ScheduleChangeReason reason = ScheduleChangeReason.scheduleEvent,
  ]) {
    notifyListeners();
    _fireScheduleChanged(reason);
  }

  Course? _jwxtCourseById(String id) {
    for (final c in _snapshot.courses) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 编辑教务课的课名 / 老师 / 地点 / 备注（只写本地覆盖层 `course_edits.json`，
  /// 不重新配色：颜色仍按教务原课名）。传 null 的项保持之前的编辑（或教务原值）。
  /// 老师/地点/备注作用于该课全部时段。课程不存在返回 false。
  Future<bool> editJwxtCourse(
    String courseId, {
    String? name,
    String? teacher,
    String? location,
    String? note,
  }) async {
    final base = _editBase(courseId);
    if (base == null) return false;
    await _setCourseEdit(
      base.copyWith(
        name: name,
        teacher: teacher,
        location: location,
        note: note,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    return true;
  }

  /// 删除教务课（本地覆盖层记「已删除」，周视图/首页隐藏）。课程不存在返回 false。
  Future<bool> deleteJwxtCourse(String courseId) async {
    final base = _editBase(courseId);
    if (base == null) return false;
    await _setCourseEdit(
      base.copyWith(deleted: true, updatedAt: DateTime.now().toIso8601String()),
    );
    return true;
  }

  /// 现有记录（指纹仍对得上时）或新记录（记下当前教务原课指纹）。
  CourseEdit? _editBase(String courseId) {
    final c = _jwxtCourseById(courseId);
    if (c == null) return null;
    final fp = courseFingerprint(c);
    final old = _courseEdits[courseId];
    if (old != null && old.origFingerprint == fp) return old;
    return CourseEdit(
      courseId: courseId,
      origFingerprint: fp,
      origName: c.name,
    );
  }

  Future<void> _setCourseEdit(CourseEdit e) async {
    await _setCourseEdits({..._courseEdits, e.courseId: e});
    _fireScheduleChanged(ScheduleChangeReason.courseEdit);
  }

  Future<void> _setCourseEdits(Map<String, CourseEdit> next) async {
    _courseEdits = Map.unmodifiable(next);
    await ScheduleStore.saveCourseEdits(_courseEdits);
    _clampViewingWeek();
    notifyListeners();
  }

  /// 这门教务课当前的编辑/删除记录（没有返回 null）。编辑页预填用。
  CourseEdit? courseEditOf(String courseId) => _courseEdits[courseId];

  /// 被删除的教务课（原始数据，供「已删除课程」列表/恢复用）。
  List<Course> get deletedJwxtCourses => [
    for (final c in _snapshot.courses)
      if (_courseEdits[c.id] case final e?
          when e.deleted && e.origFingerprint == courseFingerprint(c))
        c,
  ];

  /// 详情页「已修改」：这门教务课有调课、编辑或删除记录 / 这场教务考试有
  /// 编辑或删除记录。传 [courseId] 或 [examKey]（原始 key，见 [jwxtExamKeyOf]）之一。
  bool isJwxtOverridden({String? courseId, String? examKey}) {
    if (courseId != null) {
      return _overrides.any((o) => o.courseId == courseId) ||
          _courseEdits.containsKey(courseId);
    }
    if (examKey != null) return _examOverrides.containsKey(examKey);
    return false;
  }

  /// 详情页「恢复原课程」：清掉这门教务课的编辑、删除和全部调课记录。
  Future<bool> restoreJwxtCourse(String courseId) async {
    final hadEdit = _courseEdits.containsKey(courseId);
    if (hadEdit) {
      await _setCourseEdits({..._courseEdits}..remove(courseId));
    }
    final next = [
      for (final o in _overrides)
        if (o.courseId != courseId) o,
    ];
    if (next.length != _overrides.length) {
      await _setOverrides(next, ScheduleChangeReason.restore);
      return true;
    }
    if (hadEdit) _fireScheduleChanged(ScheduleChangeReason.restore);
    return hadEdit;
  }

  /// 详情页恢复单场教务考试（[examKey] 为原始 key）。没有覆盖返回 false。
  Future<bool> restoreJwxtExam(String examKey) async {
    if (!_examOverrides.containsKey(examKey)) return false;
    _examOverrides = Map.unmodifiable({..._examOverrides}..remove(examKey));
    await ScheduleStore.saveExamOverrides(_examOverrides);
    _notifyEvents(ScheduleChangeReason.restore);
    return true;
  }

  /// 设置「恢复教务课程」：清掉全部调课记录、教务课编辑/删除和教务考试覆盖。
  /// 什么都没有时返回 false。
  Future<bool> restoreAllJwxt() async {
    if (_overrides.isEmpty && _courseEdits.isEmpty && _examOverrides.isEmpty) {
      return false;
    }
    if (_examOverrides.isNotEmpty) {
      _examOverrides = const {};
      await ScheduleStore.saveExamOverrides(_examOverrides);
    }
    if (_courseEdits.isNotEmpty) await _setCourseEdits(const {});
    await _setOverrides(const [], ScheduleChangeReason.restore);
    return true;
  }

  // ===== 第 7 条：自动同步与节流 =====

  /// 自动同步最短间隔（距上次成功）。
  static const autoSyncInterval = Duration(minutes: 10);

  /// 回到前台时的间隔（距上次成功，严格大于）。
  static const resumeSyncInterval = Duration(minutes: 30);

  /// 节流用的「现在」（带时分秒），测试可替换。
  @visibleForTesting
  static DateTime Function() syncClock = DateTime.now;

  DateTime? _lastSyncSuccessAt;
  bool _lastFailureOffline = false;
  bool _offlineRetryPending = false;
  bool _triggerBusy = false;

  /// 最近一次同步成功时间（持久化在 `sync_state.json`，重启后仍在）。
  DateTime? get lastSyncSuccessAt => _lastSyncSuccessAt;

  bool _elapsedSinceSuccess(Duration d, {bool strict = false}) {
    final last = _lastSyncSuccessAt;
    if (last == null) return true;
    final gap = syncClock().difference(last);
    return strict ? gap > d : gap >= d;
  }

  /// 是否「网络不可用」（断网/DNS/连不上）；超时、5xx 不算。
  static bool _isOffline(Object e) {
    if (e is SocketException) return true;
    if (e is PortalNetworkError) return true;
    if (e is DioException) {
      return e.type == DioExceptionType.connectionError ||
          e.error is SocketException;
    }
    return false;
  }

  /// 统一入口。同步进行中（或另一触发尚在判断中）时忽略并返回 false。
  /// [due] 不满足、未绑定门户时也返回 false。返回 true 表示发起了同步（成败看 syncStatus）。
  Future<bool> _trigger({
    bool Function()? due,
    bool armOfflineRetry = true,
    bool automatic = false,
  }) async {
    if (_triggerBusy || _syncInFlight != null || _loading) return false;
    _triggerBusy = true;
    try {
      await ensureStarted();
      if (_syncInFlight != null || _loading) return false;
      if (due != null && !due()) return false;
      if (!await refreshPortalBound()) return false;
      if (_syncInFlight != null || _loading) return false;
      _nextSyncAuto = automatic;
      await syncFromJwxt();
      if (armOfflineRetry) {
        _offlineRetryPending =
            _syncStatus == TimetableSyncStatus.failure && _lastFailureOffline;
      }
      return true;
    } finally {
      _triggerBusy = false;
    }
  }

  /// App 冷启动：距上次成功 ≥10 分钟（或从未成功，即首次安装）才同步。
  Future<bool> onAppStart() => _trigger(
    due: () => _elapsedSinceSuccess(autoSyncInterval),
    automatic: true,
  );

  /// 登录成功后立即同步（不受节流限制）。
  /// 同时清除 [portalSessionExpired]（登录已成功，会话已更新；若随后的同步仍报
  /// 会话失效会重新置位）。
  Future<bool> onLoginSucceeded() async {
    _offlineRetryPending = false;
    await ensureStarted();
    await _setPortalSessionExpired(false);
    return _trigger(armOfflineRetry: false);
  }

  /// App 回到前台：距上次成功 >30 分钟才同步。
  Future<bool> onAppResumed() => _trigger(
    due: () => _elapsedSinceSuccess(resumeSyncInterval, strict: true),
    automatic: true,
  );

  /// 网络恢复（由 App 层的连接监听调用）：只有上一次自动同步因断网失败时，
  /// 立即重试一次（不等 10 分钟）；重试失败不再自动重试。其他情况忽略。
  Future<bool> onNetworkRestored() {
    if (!_offlineRetryPending || _triggerBusy || _syncInFlight != null) {
      return Future.value(false);
    }
    _offlineRetryPending = false;
    return _trigger(armOfflineRetry: false, automatic: true);
  }

  /// 右上角手动同步（不受节流限制）。未绑定返回 false（页面跳转登录）。
  Future<bool> manualSync() => _trigger(armOfflineRetry: false);

  Future<void> _setOverrides(
    List<SlotOverride> next,
    ScheduleChangeReason reason,
  ) async {
    _overrides = List.unmodifiable(next);
    await TimetableStore.saveOverrides(_overrides);
    _clampViewingWeek();
    notifyListeners();
    _fireScheduleChanged(reason);
  }

  /// 展示用时段 → 教务原时段。
  CourseSlot? _jwxtOriginal(String courseId, CourseSlot slot, int slotIndex) {
    final tagged = slotOriginOf(slot);
    if (tagged != null) {
      return tagged.courseId == courseId ? tagged.original : null;
    }
    for (final c in _snapshot.courses) {
      if (c.id != courseId) continue;
      final i = _indexOfEqualSlot(c.slots, slot, slotIndex);
      return i < 0 ? null : c.slots[i];
    }
    return null;
  }

  static bool _sameSlot(CourseSlot a, CourseSlot b) =>
      a.day == b.day &&
      a.startNode == b.startNode &&
      a.endNode == b.endNode &&
      a.weeks == b.weeks;

  static int _indexOfEqualSlot(List<CourseSlot> slots, CourseSlot s, int hint) {
    if (hint >= 0 && hint < slots.length && _sameSlot(slots[hint], s)) {
      return hint;
    }
    return slots.indexWhere((x) => _sameSlot(x, s));
  }

  /// 落点在 [weeks] 内与其他课程（不含自身、跳过隐藏）重叠的课名，去重排序。
  List<String> _conflictNames(
    String selfId,
    int day,
    int start,
    int end,
    List<int> weeks,
  ) {
    final names = <String>{};
    for (final c in combinedCourses) {
      if (c.hidden || c.id == selfId) continue;
      for (final s in c.slots) {
        if (!s.hasFixedTime || s.day != day) continue;
        if (s.startNode > end || start > s.endNode) continue;
        if (weeks.any(s.hasClassInWeek)) {
          names.add(c.name);
          break;
        }
      }
    }
    return names.toList()..sort();
  }

  // ---- 周视图列（设置 9）与首页明天（设置 13）----

  /// 第 [week] 周要显示的星期（显示顺序）。周日开头时周日（本教学周周日）放第一列；
  /// 周末列关闭但当周该天有课时自动显示。
  List<int> visibleDays(int week) => weekColumnDays(
    weekStartsSunday: settings.weekStartsSunday,
    showSaturday: settings.showSaturday,
    showSunday: settings.showSunday,
    saturdayHasClass: cellsForDay(week, 6).any((c) => c.activeThisWeek),
    sundayHasClass: cellsForDay(week, 7).any((c) => c.activeThisWeek),
  );

  /// 第 [week] 周第 [day] 列的日期（周日 = 本教学周周一 + 6）。
  DateTime dateOfColumn(int week, int day) =>
      weekColumnDate(weekStartDate(week), day);

  /// 月份列：第 [week] 周周一所在月份。
  int monthLabelOf(int week) => weekMonthLabel(weekStartDate(week));

  /// 首页「明天」区域数据（spec §13.4，用 actualWeek，不钳制；已套用调课）。
  HomeTomorrowInfo homeTomorrow({DateTime? now}) {
    final n = now ?? clock();
    final today = DateTime(n.year, n.month, n.day);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final start = settings.termStartDate;
    if (start == null) {
      return const HomeTomorrowInfo(kind: HomeTomorrowKind.unknown);
    }
    final todayWeek = actualWeek(today)!;
    final tomorrowWeek = actualWeek(tomorrow)!;
    final todayItems = todayCourses(now: n);
    final finished = todayItems.every(
      (i) => i.status == TodayCourseStatus.done,
    );
    if (todayWeek > totalWeeks) {
      return HomeTomorrowInfo(
        kind: HomeTomorrowKind.termEnded,
        message: '本学期已结束',
        tomorrowWeek: tomorrowWeek,
        todayFinished: finished,
      );
    }
    if (tomorrowWeek < 1) {
      final termDay = DateTime(start.year, start.month, start.day);
      final days = DateTime.utc(
        termDay.year,
        termDay.month,
        termDay.day,
      ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
      return HomeTomorrowInfo(
        kind: HomeTomorrowKind.beforeTerm,
        message: '距开学 $days 天',
        daysUntilTerm: days,
        tomorrowWeek: tomorrowWeek,
        todayFinished: finished,
      );
    }
    if (!settings.showTomorrowOnHome) {
      return HomeTomorrowInfo(
        kind: HomeTomorrowKind.disabled,
        tomorrowWeek: tomorrowWeek,
        todayFinished: finished,
      );
    }
    final items = coursesOnDate(tomorrow);
    final title = homeTomorrowTitle(tomorrow, tomorrowWeek, todayWeek);
    if (items.isEmpty) {
      return HomeTomorrowInfo(
        kind: HomeTomorrowKind.noClass,
        title: title,
        message: '明天没课',
        tomorrowWeek: tomorrowWeek,
        todayFinished: finished,
      );
    }
    return HomeTomorrowInfo(
      kind: HomeTomorrowKind.courses,
      title: title,
      courses: items,
      tomorrowWeek: tomorrowWeek,
      todayFinished: finished,
    );
  }

  /// 指定周、指定星期几的课程格（跨节已是完整 slot）。
  List<GridCell> cellsForDay(int week, int day) {
    final result = <GridCell>[];
    final candidates = <({Course course, CourseSlot slot, bool active})>[];

    for (final course in courses) {
      if (course.hidden) continue;
      final splitAway = settings.showNonCurrentWeek && course.isManual
          ? manualSplitAwayRefs(course, week)
          : const <SlotRef>{};
      for (final slot in course.slots) {
        if (!slot.hasFixedTime || slot.day != day) continue;
        final active = slot.hasClassInWeek(week);
        if (!active && !settings.showNonCurrentWeek) continue;
        // 本周这次已被拖走（拆出的时段本周有课）→ 原位置不画「[非本周]」虚影。
        if (!active && splitAway.contains(slot.ref)) continue;
        candidates.add((course: course, slot: slot, active: active));
      }
    }

    // 冲突：同日起止重叠
    for (final item in candidates) {
      var conflicts = 0;
      for (final other in candidates) {
        if (identical(item, other)) continue;
        if (!_overlap(item.slot, other.slot)) continue;
        if (item.active || other.active) conflicts++;
      }
      result.add(
        GridCell(
          course: item.course,
          slot: item.slot,
          conflictCount: conflicts,
          activeThisWeek: item.active,
        ),
      );
    }

    result.sort((a, b) {
      final byStart = a.slot.startNode.compareTo(b.slot.startNode);
      if (byStart != 0) return byStart;
      return a.course.name.compareTo(b.course.name);
    });
    return result;
  }

  /// 手动课第 [week] 周被拖走的原时段位置：本周有课、带 [CourseSlot.splitFrom] 的
  /// 时段沿 splitFrom 往上（经过课内仍存在的时段，防环）收集到的位置。
  /// [cellsForDay] 在这些位置不画本周的非本周灰格；其他周不受影响。
  @visibleForTesting
  static Set<SlotRef> manualSplitAwayRefs(Course course, int week) {
    final out = <SlotRef>{};
    for (final s in course.slots) {
      if (!s.hasClassInWeek(week)) continue;
      var ref = s.splitFrom;
      while (ref != null && out.add(ref)) {
        SlotRef? next;
        for (final p in course.slots) {
          if (ref.matches(p)) {
            next = p.splitFrom;
            break;
          }
        }
        ref = next;
      }
    }
    return out;
  }

  /// 无固定时间的「其他课程」。
  List<Course> otherCourses() => [
    for (final c in courses)
      if (!c.hidden && c.slots.every((s) => !s.hasFixedTime)) c,
  ];

  /// 首页点某一行：进周课表后弹出该课详情。
  void requestOpenCourse({
    required String courseId,
    required int day,
    required int startNode,
    required int endNode,
  }) {
    _pendingOpen = PendingCourseOpen(
      courseId: courseId,
      day: day,
      startNode: startNode,
      endNode: endNode,
    );
  }

  PendingCourseOpen? consumePendingOpen() {
    final pending = _pendingOpen;
    _pendingOpen = null;
    return pending;
  }

  GridCell? findCell({
    required String courseId,
    required int day,
    required int startNode,
    required int endNode,
    int? week,
  }) {
    final w = week ?? currentWeek;
    for (final cell in cellsForDay(w, day)) {
      if (cell.course.id == courseId &&
          cell.slot.day == day &&
          cell.slot.startNode == startNode &&
          cell.slot.endNode == endNode) {
        return cell;
      }
    }
    return null;
  }

  /// 指定日期的课程（用于明天预告）。
  List<TodayCourseItem> coursesOnDate(DateTime date) {
    if (settings.termStartDate == null) return const [];
    final cells = _activeCellsOn(date);
    return [
      for (final cell in cells)
        TodayCourseItem(
          course: cell.course,
          slot: cell.slot,
          status: TodayCourseStatus.upcoming,
        ),
    ];
  }

  /// 今日课程（按节次排序，最多取完）。
  List<TodayCourseItem> todayCourses({DateTime? now}) {
    final n = now ?? DateTime.now();
    // 用「今天」的真实周（不钳制），开学前/学期后无课、无提醒。
    final cells = _activeCellsOn(n).toList();
    final items = <TodayCourseItem>[];
    for (final cell in cells) {
      final start = _timeOf(n, periodStart(cell.slot.startNode));
      final end = _timeOf(n, periodEnd(cell.slot.endNode));
      if (start == null || end == null) {
        items.add(
          TodayCourseItem(
            course: cell.course,
            slot: cell.slot,
            status: TodayCourseStatus.upcoming,
          ),
        );
        continue;
      }
      if (n.isBefore(start)) {
        items.add(
          TodayCourseItem(
            course: cell.course,
            slot: cell.slot,
            status: TodayCourseStatus.upcoming,
            minutesUntilStart: start.difference(n).inMinutes,
          ),
        );
      } else if (n.isBefore(end) || n.isAtSameMomentAs(end)) {
        final total = end.difference(start).inMinutes;
        final done = n.difference(start).inMinutes;
        items.add(
          TodayCourseItem(
            course: cell.course,
            slot: cell.slot,
            status: TodayCourseStatus.ongoing,
            progress: total <= 0 ? 1 : (done / total).clamp(0.0, 1.0),
          ),
        );
      } else {
        items.add(
          TodayCourseItem(
            course: cell.course,
            slot: cell.slot,
            status: TodayCourseStatus.done,
          ),
        );
      }
    }
    return items;
  }

  String? periodStart(int node) {
    for (final p in periods) {
      if (p.node == node) return p.start;
    }
    return null;
  }

  String? periodEnd(int node) {
    for (final p in periods) {
      if (p.node == node) return p.end;
    }
    return null;
  }

  PeriodTime? periodAt(int node) {
    for (final p in periods) {
      if (p.node == node) return p;
    }
    return null;
  }

  /// 查看周的周一日期。周次待同步时以本周周一作为第 1 周。
  DateTime weekStartDate(int week) {
    final start = settings.termStartDate ?? _today;
    final monday = _mondayOf(start);
    return DateTime(monday.year, monday.month, monday.day + (week - 1) * 7);
  }

  /// 按优先级决议开学日：本次 dqzc > 可信缓存 > 内置配置 > 待同步(null)。
  static TimetableSettings _withResolvedTermStart(
    TimetableSettings s, {
    TimetableSettings? cached,
  }) {
    final r = resolveTermStart(
      termCode: s.termCode,
      fromDqzc: s.termStartFromJwxt ? s.termStartDate : null,
      cached: cached ?? s,
    );
    if (r.start == null) return s.copyWith(clearTermStart: true);
    return s.copyWith(
      termStartDate: r.start,
      termStartFromJwxt:
          r.source == TermStartSource.jwxt || r.source == TermStartSource.cache,
    );
  }

  List<DateTime> datesOfWeek(int week) {
    final start = weekStartDate(week);
    return [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
  }

  static List<PeriodTime> defaultPeriods() => const [
    PeriodTime(node: 1, start: '08:00', end: '08:45'),
    PeriodTime(node: 2, start: '08:55', end: '09:40'),
    PeriodTime(node: 3, start: '10:10', end: '10:55'),
    PeriodTime(node: 4, start: '11:05', end: '11:50'),
    PeriodTime(node: 5, start: '13:45', end: '14:30'),
    PeriodTime(node: 6, start: '14:40', end: '15:25'),
    PeriodTime(node: 7, start: '15:55', end: '16:40'),
    PeriodTime(node: 8, start: '16:50', end: '17:35'),
    PeriodTime(node: 9, start: '18:45', end: '19:30'),
    PeriodTime(node: 10, start: '19:40', end: '20:25'),
    PeriodTime(node: 11, start: '20:35', end: '21:20'),
  ];

  static bool _overlap(CourseSlot a, CourseSlot b) =>
      a.startNode <= b.endNode && b.startNode <= a.endNode;

  static DateTime _mondayOf(DateTime d) => mondayOfWeek(d);

  static DateTime? _timeOf(DateTime day, String? hhmm) {
    if (hhmm == null) return null;
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(day.year, day.month, day.day, h, m);
  }
}

class PendingCourseOpen {
  const PendingCourseOpen({
    required this.courseId,
    required this.day,
    required this.startNode,
    required this.endNode,
  });

  final String courseId;
  final int day;
  final int startNode;
  final int endNode;
}

/// 暴露色板长度给测试。
int get kTimetablePaletteLength => TimetableTheme.coursePalette.length;
