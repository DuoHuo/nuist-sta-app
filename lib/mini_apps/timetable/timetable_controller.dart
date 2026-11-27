import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'timetable_api.dart';
import 'timetable_change_format.dart';
import 'timetable_colors.dart';
import 'timetable_date_edits.dart';
import 'timetable_exam_parser.dart';
import 'timetable_import_models.dart';
import 'timetable_multi_models.dart';
import 'timetable_remaining_weeks.dart';
import 'timetable_models.dart';
import 'timetable_next_day_reminder.dart';
import 'timetable_next_day_reminder_channel.dart';
import 'timetable_overrides.dart';
import 'timetable_schedule_event.dart';
import 'timetable_schedule_store.dart';
import 'timetable_store.dart';
import 'timetable_sync_diff.dart';
import 'timetable_theme.dart';
import 'timetable_timing.dart';
import 'timetable_week_layout.dart';
import 'timetable_week_format.dart';

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
  if (e is PortalLoginError) {
    final status = e.context['status_code'];
    if (status is int && status >= 500) return TimetableSyncFailure.server;
    if (status == 401 ||
        status == 403 ||
        const {
          'returned_to_login',
          'service_returned_to_login',
          'reauthentication_exhausted',
          'session_generation_changed',
          'service_cookie_revision_changed',
        }.contains(e.code)) {
      return TimetableSyncFailure.sessionExpired;
    }
  }
  if (e is TimeoutException || e is SocketException || e is HttpException) {
    return TimetableSyncFailure.network;
  }
  if (e is JwxtHttpError) {
    if (e.status == 401 || e.status == 403) {
      return TimetableSyncFailure.sessionExpired;
    }
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
        if (code == 401 || code == 403) {
          return TimetableSyncFailure.sessionExpired;
        }
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

  /// 是否自动触发（冷启动 / 网络恢复 / 打开课表页 / 回前台超 6 小时的静默补同步）。
  /// 手动同步图标、登录成功后的同步为 false；回前台的本地刷新本身不产生同步结果。
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

  /// 单日修改（第 1 条）。
  dateEdit,

  /// 整天调课（第 8 条）。
  daySwap,
}

/// 课表全局状态：首页卡片与周视图共用。
class TimetableController extends ChangeNotifier {
  TimetableController._([this._scopedId, this._manager]);

  TimetableController._forReminderCompute({
    required TimetableSnapshot snapshot,
    required List<Course> manualCourses,
    required List<SlotOverride> overrides,
    required Map<String, CourseEdit> courseEdits,
    required List<DaySwap> daySwaps,
    required List<CourseDateEdit> dateEdits,
  }) : _scopedId = null,
       _manager = null {
    _snapshot = snapshot;
    _manualCourses = manualCourses;
    _overrides = overrides;
    _courseEdits = courseEdits;
    _daySwaps = daySwaps;
    _dateEdits = dateEdits;
  }

  static final TimetableController instance = TimetableController._();
  static final _log = AppLog.logger('timetable.controller');

  final String? _scopedId;
  final TimetableController? _manager;

  /// 是否为主控制器单例（负责首页卡片、桌面小组件、通知提醒及多课表管理）。
  bool get _isPrimaryHost => _manager == null;

  /// 当前控制器读写磁盘时所处的课表作用域 id。
  String get activeStorageId =>
      _manager == null ? _primaryScheduleId : _scopedId!;

  Future<T> _inScope<T>(Future<T> Function() action) =>
      TimetableStore.withScheduleScope(activeStorageId, action);

  // ---- 多课表状态（仅主控制器维护，子控制器通过 _manager 访问）----
  SchedulesIndex _schedulesIndex = const SchedulesIndex();
  String _primaryScheduleId = kDefaultScheduleId;
  String _viewingScheduleId = kDefaultScheduleId;
  final Map<String, TimetableController> _scopedControllers = {};
  final Map<String, TimetableSnapshot> _probedHistoricalSnapshots = {};
  int _importSeq = 0;
  bool _historicalDiscoveryAttempted = false;
  Future<void>? _historicalDiscoveryInFlight;

  /// 是否已在本会话中触发过一次往年课表自动发现。
  bool get historicalDiscoveryAttempted =>
      (_manager ?? this)._historicalDiscoveryAttempted;

  SchedulesIndex get _rootIndex =>
      _manager == null ? _schedulesIndex : _manager._schedulesIndex;

  /// 全部已纳入多课表管理的课表元信息列表（始终至少包含当前默认课表）。
  List<ScheduleMetadata> get schedules {
    final idx = _rootIndex;
    if (idx.schedules.isNotEmpty) return idx.schedules;
    return [
      ScheduleMetadata(
        id: kDefaultScheduleId,
        name: _deriveDefaultScheduleName(),
        sourceKind: TimetableSourceKind.jwxt,
        termCode: _snapshot.settings.termCode,
        courseCount: _snapshot.courses.length,
      ),
    ];
  }

  /// 用户自己的教务课表（含当前学期与往年学期）。
  List<ScheduleMetadata> get ownSchedules => [
    for (final s in schedules)
      if (s.isOwnSchedule) s,
  ];

  /// 从 WakeUp 口令导入的他人课表。
  List<ScheduleMetadata> get importedSchedules => [
    for (final s in schedules)
      if (s.isImportedSchedule) s,
  ];

  /// 主课表 id（用于首页卡片、桌面小组件、上课/明日提醒与校园地图）。
  String get primaryScheduleId =>
      _manager == null ? _primaryScheduleId : _manager._primaryScheduleId;

  /// 课表页当前正在浏览的课表 id。
  String get viewingScheduleId =>
      _manager == null ? _viewingScheduleId : _manager._viewingScheduleId;

  /// 主课表是否为当前正在浏览的课表。
  bool get isViewingPrimary => viewingScheduleId == primaryScheduleId;

  /// 当前已确认的教务学期代码。
  String get currentTermCode {
    final fromIdx = _rootIndex.currentTermCode.trim();
    if (fromIdx.isNotEmpty) return fromIdx;
    final def = scheduleMetaOf(kDefaultScheduleId);
    if (def != null && def.termCode.isNotEmpty) return def.termCode;
    return settings.termCode;
  }

  ScheduleMetadata? scheduleMetaOf(String id) {
    for (final s in schedules) {
      if (s.id == id) return s;
    }
    return null;
  }

  ScheduleMetadata? get primaryScheduleMeta =>
      scheduleMetaOf(primaryScheduleId);

  ScheduleMetadata? get viewingScheduleMeta =>
      scheduleMetaOf(viewingScheduleId);

  /// 当前控制器所代表的课表元信息。
  ScheduleMetadata? get currentScheduleMeta => scheduleMetaOf(activeStorageId);

  /// 当前控制器是否为 WakeUp 导入的他人课表。
  bool get isImportedSchedule =>
      currentScheduleMeta?.isImportedSchedule == true;

  /// 判断指定课表是否属于「已过去的往年学期」（不再自动拉取更新）。
  bool isHistoricalSchedule(String id) {
    final meta = scheduleMetaOf(id);
    if (meta == null || !meta.isOwnSchedule) return false;
    if (id == kDefaultScheduleId) return false;
    final curr = currentTermCode;
    if (curr.isEmpty || meta.termCode.isEmpty) return true;
    return isHistoricalTerm(meta.termCode, currentTermCode: curr);
  }

  /// 当前课表页应绑定使用的控制器：看主课表时直接复用 [instance]，看其他课表时返回对应子控制器。
  TimetableController get viewingController {
    if (_manager != null) return _manager.viewingController;
    if (_viewingScheduleId == _primaryScheduleId) return this;
    return _scopedControllers[_viewingScheduleId] ??= TimetableController._(
      _viewingScheduleId,
      this,
    );
  }

  /// 获取指定课表对应的控制器（主课表返回主控制器，其余课表确保加载后返回子控制器）。
  Future<TimetableController> controllerForSchedule(String scheduleId) async {
    final host = _manager ?? this;
    await host.ensureStarted();
    if (scheduleId == host._primaryScheduleId) return host;
    return host._ensureScopedController(scheduleId);
  }

  String _deriveDefaultScheduleName() {
    final storedName = _snapshot.settings.scheduleName.trim();
    if (storedName.isNotEmpty && storedName != '我的课表') {
      return storedName;
    }
    final term = _snapshot.settings.termCode.trim();
    return term.isNotEmpty ? formatTermScheduleName(term) : '当前学期';
  }

  static Map<String, Object?> _savedResultFields(Object? result) => {
    'saved': result != null,
    'outcome': result == null ? 'rejected' : 'success',
  };

  bool _started = false;
  Future<void>? _starting;
  bool _initialized = false;

  /// 本地启动已成功完成，重复进入页面可直接构建现有课程。
  bool get isInitialized => _initialized;

  TimetableSnapshot _snapshot = const TimetableSnapshot();
  final _viewingWeekNotifier = _ViewingWeekNotifier(1);

  /// 上次 [followCurrentWeekIfChanged] 观察到的 [currentWeek]。
  /// 变了才把 [viewingWeek] 拉回本周；同周内手动翻周不打断。
  int? _lastSeenCurrentWeek;
  DateTime? _lastSeenDate;
  int _scheduleVersion = 0;

  /// 课表内容/影响排程设置的版本号（供通知与小组件去重）。
  int get scheduleVersion => _scheduleVersion;

  Map<String, dynamic>? _preloadedCourseColorsRaw;
  Map<String, dynamic>? _preloadedSyncChangesRaw;
  bool _loading = false;
  String? _statusMessage;
  bool _portalBound = false;
  PendingCourseOpen? _pendingOpen;
  TimetableSyncStatus _syncStatus = TimetableSyncStatus.idle;
  TimetableSyncFailure _syncFailure = TimetableSyncFailure.none;
  Future<void>? _syncInFlight;
  int _portalBindingRevision = 0;
  Future<void> _portalBindingChange = Future.value();

  /// 最近一次成功同步写入的变动结果（含待弹窗列表）；失败或无 diff 为 null。
  TimetableSyncDiffResult? lastSyncDiff;

  final _pendingChangeAlerts = <String, TimetableChangeRecord>{};
  int _changeAlertRevision = 0;
  bool _jwxtExamsBaselinePending = false;

  /// 变动提醒所属的课表生命周期，防止旧弹窗确认新课表的记录。
  int get changeAlertRevision => _changeAlertRevision;

  /// 累计尚未通知的记录，按检测时间升序，包含重启恢复与多轮后台同步。
  List<TimetableChangeRecord> get pendingChangeAlerts {
    final list = _pendingChangeAlerts.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return List.unmodifiable(list);
  }

  bool _matchesCurrentTerm(String recordTerm) {
    final rec = recordTerm.trim();
    final cur = settings.termCode.trim();
    if (rec.isEmpty || cur.isEmpty) return true;
    return rec == cur;
  }

  void _mergePendingChanges(Iterable<TimetableChangeRecord> records) {
    for (final record in records) {
      if (!record.notified && _matchesCurrentTerm(record.xnxqdm)) {
        _pendingChangeAlerts[record.fingerprint] = record;
      }
    }
  }

  bool get _hasStoredBaseline =>
      _snapshot.syncedAt != null ||
      _snapshot.courses.isNotEmpty ||
      _scheduleEvents.any((e) => e.isFromJwxt && e.isExam);

  Future<void> _reloadPendingChanges({
    Map<String, dynamic>? preloadedChanges,
    bool resetRevision = false,
    bool replace = false,
  }) async {
    if (resetRevision) {
      _changeAlertRevision++;
      _pendingChangeAlerts.clear();
      lastSyncDiff = null;
    } else if (replace) {
      _pendingChangeAlerts.clear();
    }
    if (!_hasStoredBaseline) return;
    if (TimetableChangeLogStore.hasDebugMemory) {
      _mergePendingChanges(TimetableChangeLogStore.readUnnotifiedDebugMemory());
    } else if (preloadedChanges != null) {
      _mergePendingChanges(
        TimetableChangeLogStore.unnotifiedFrom(
          TimetableChangeLogStore.parseRecords(preloadedChanges),
        ),
      );
    } else {
      _mergePendingChanges(
        await _inScope(() => TimetableChangeLogStore.readUnnotified()),
      );
    }
  }

  /// 读取当前课表作用域下的全部变动记录（时间倒序），供变动记录页使用。
  Future<List<TimetableChangeRecord>> readChangeHistoryNewestFirst() =>
      _inScope(() => TimetableChangeLogStore.readNewestFirst());

  /// 仅确认实际展示的记录，不清掉弹窗显示期间新到的变动。
  Future<void> acknowledgeChangeAlerts(
    Iterable<String> fingerprints, {
    required int revision,
  }) async {
    if (revision != _changeAlertRevision) return;
    final confirmed = fingerprints.toSet();
    await _inScope(() => TimetableChangeLogStore.markNotified(confirmed));
    if (revision != _changeAlertRevision) return;
    _pendingChangeAlerts.removeWhere((fp, _) => confirmed.contains(fp));
    final diff = lastSyncDiff;
    if (diff != null) {
      final remaining = [
        for (final record in diff.toNotify)
          if (!confirmed.contains(record.fingerprint)) record,
      ];
      lastSyncDiff = remaining.isEmpty
          ? null
          : TimetableSyncDiffResult(
              allWritten: diff.allWritten,
              toNotify: remaining,
            );
    }
    notifyListeners();
  }

  Future<void> _resetSyncChanges() async {
    _changeAlertRevision++;
    _pendingChangeAlerts.clear();
    lastSyncDiff = null;
    await _inScope(() => TimetableChangeLogStore.clear());
  }

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

  void _fireScheduleChanged(ScheduleChangeReason r) {
    _scheduleVersion++;
    _scheduleChanged.add(r);
    if (_isPrimaryHost) unawaited(updateNextDayReminder());
  }

  /// 测试开关：开启后即使在 flutter_test 中也把明日提醒计算放进真实 Isolate.run。
  @visibleForTesting
  static bool debugBuildNextDayReminderInBackground = false;

  Future<void>? _nextDayReminderWork;
  int _nextDayReminderGeneration = 0;
  Timer? _nextDayReminderYieldTimer;
  Completer<void>? _nextDayReminderYieldDone;
  Object? _nextDayReminderConfigurationInputs;
  Map<String, Object?>? _nextDayReminderConfiguration;
  Object? _sentNextDayReminderInputs;
  Object? _sendingNextDayReminderInputs;

  /// 导入的主课表没有门户绑定，也按已登录生成提醒内容。
  bool get _loggedInForReminder =>
      _portalBound || primaryScheduleMeta?.isImportedSchedule == true;

  /// 当前主课表是否有可用作课表提醒的数据源（已绑定门户，或主课表为导入课表）。
  bool get hasReminderScheduleSource => _loggedInForReminder;

  /// 当前控制器或其宿主是否为 [TimetableController.instance]。
  bool get isAttachedToPrimaryHost =>
      identical(_manager ?? this, TimetableController.instance);

  Object _nextDayReminderInputs() {
    final now = syncClock();
    return (
      _snapshot.courses,
      _snapshot.periods,
      _manualCourses,
      _overrides,
      _courseEdits,
      _daySwaps,
      _dateEdits,
      settings.termStartDate,
      settings.maxWeeks,
      _loggedInForReminder,
      settings.nextDayReminderEnabled,
      settings.nextDayReminderMinute,
      _snapshot.syncedAt != null,
      DateTime(now.year, now.month, now.day),
    );
  }

  /// 将套用调课、单日修改后的课程生成通知缓存，覆盖未来 400 个本机自然日。
  /// 只排明日提醒，不读取 reminderEnabled（课前提醒开关）。
  ///
  /// 合并并发调用；相同课程、提醒偏好和自然日不重复生成。每七天让出
  /// 一次事件循环，避免后台排程连续占用 UI；计算期间变化时重新取最新状态。
  Future<void> updateNextDayReminder() {
    if (!_isPrimaryHost) return Future.value();
    if (_nextDayReminderWork case final work?) return work;
    final generation = _nextDayReminderGeneration;
    return _nextDayReminderWork = _updateNextDayReminder(generation)
        .whenComplete(() {
          if (generation == _nextDayReminderGeneration) {
            _nextDayReminderWork = null;
          }
        });
  }

  Future<void> _updateNextDayReminder(int generation) async {
    // 先让同一批状态变更合并，再计算；不引入长期防抖定时器。
    await Future<void>.value();
    while (generation == _nextDayReminderGeneration) {
      final inputs = _nextDayReminderInputs();
      if (_sentNextDayReminderInputs == inputs ||
          _sendingNextDayReminderInputs == inputs) {
        return;
      }
      final configuration = _nextDayReminderConfigurationInputs == inputs
          ? _nextDayReminderConfiguration
          : await _buildNextDayReminderConfiguration(inputs, generation);
      if (generation != _nextDayReminderGeneration) return;
      if (configuration == null || inputs != _nextDayReminderInputs()) {
        continue;
      }
      // 已关闭的配置不需要持有旧课程，避免解绑后由缓存延长课程对象寿命。
      if (configuration['enabled'] == true) {
        _nextDayReminderConfigurationInputs = inputs;
        _nextDayReminderConfiguration = configuration;
      } else {
        _nextDayReminderConfigurationInputs = null;
        _nextDayReminderConfiguration = null;
      }
      _sendingNextDayReminderInputs = inputs;
      await NextDayReminderChannel.update(
        configuration,
        onCompleted: (saved) {
          if (generation != _nextDayReminderGeneration) return;
          if (_sendingNextDayReminderInputs == inputs) {
            _sendingNextDayReminderInputs = null;
          }
          if (saved && inputs == _nextDayReminderInputs()) {
            _sentNextDayReminderInputs = inputs;
          }
        },
      );
      if (inputs == _nextDayReminderInputs()) return;
    }
  }

  Future<Map<String, Object?>?> _buildNextDayReminderConfiguration(
    Object inputs,
    int generation,
  ) async {
    final enabled =
        settings.nextDayReminderEnabled &&
        _loggedInForReminder &&
        settings.termStartDate != null &&
        (_snapshot.syncedAt != null || hasCourses);
    var payloads = <String, Object?>{};
    if (enabled) {
      // 用 syncClock（测试可注入），覆盖未来 400 个本机自然日。
      final now = syncClock();
      final today = DateTime(now.year, now.month, now.day);
      final snapshotArg = TimetableSnapshot(
        courses: _snapshot.courses,
        periods: periods,
        settings: _snapshot.settings,
        syncedAt: _snapshot.syncedAt,
      );
      final manualArg = _manualCourses;
      final overridesArg = _overrides;
      final courseEditsArg = _courseEdits;
      final daySwapsArg = _daySwaps;
      final dateEditsArg = _dateEdits;
      final loggedIn = _loggedInForReminder;
      final total = totalWeeks;
      if (!Platform.environment.containsKey('FLUTTER_TEST') ||
          debugBuildNextDayReminderInBackground) {
        payloads = await Isolate.run(
          () => _computeNextDayReminderPayloads(
            today: today,
            totalWeeks: total,
            loggedIn: loggedIn,
            snapshot: snapshotArg,
            manualCourses: manualArg,
            overrides: overridesArg,
            courseEdits: courseEditsArg,
            daySwaps: daySwapsArg,
            dateEdits: dateEditsArg,
          ),
        );
        if (generation != _nextDayReminderGeneration ||
            inputs != _nextDayReminderInputs()) {
          return null;
        }
      } else {
        // FakeAsync 不推进 Isolate，保持让出一帧以合并同一轮事件里的连续变更，
        // 但只在临时独立实例中计算，不拷回/不覆盖主控制器的 _dayCells 缓存。
        final done = Completer<void>();
        _nextDayReminderYieldDone = done;
        _nextDayReminderYieldTimer = Timer(Duration.zero, done.complete);
        await done.future;
        if (identical(_nextDayReminderYieldDone, done)) {
          _nextDayReminderYieldDone = null;
          _nextDayReminderYieldTimer = null;
        }
        if (generation != _nextDayReminderGeneration ||
            inputs != _nextDayReminderInputs()) {
          return null;
        }
        payloads = _computeNextDayReminderPayloads(
          today: today,
          totalWeeks: total,
          loggedIn: loggedIn,
          snapshot: snapshotArg,
          manualCourses: manualArg,
          overrides: overridesArg,
          courseEdits: courseEditsArg,
          daySwaps: daySwapsArg,
          dateEdits: dateEditsArg,
        );
      }
    }
    return {
      'enabled': enabled,
      'minuteOfDay': TimetableSettings.sanitizeNextDayMinute(
        settings.nextDayReminderMinute,
      ),
      'payloads': payloads,
    };
  }

  static Map<String, Object?> _computeNextDayReminderPayloads({
    required DateTime today,
    required int totalWeeks,
    required bool loggedIn,
    required TimetableSnapshot snapshot,
    required List<Course> manualCourses,
    required List<SlotOverride> overrides,
    required Map<String, CourseEdit> courseEdits,
    required List<DaySwap> daySwaps,
    required List<CourseDateEdit> dateEdits,
  }) {
    final helper = TimetableController._forReminderCompute(
      snapshot: snapshot,
      manualCourses: manualCourses,
      overrides: overrides,
      courseEdits: courseEdits,
      daySwaps: daySwaps,
      dateEdits: dateEdits,
    );
    try {
      final payloads = <String, Object?>{};
      for (var offset = 0; offset < 400; offset++) {
        final eve = DateTime(today.year, today.month, today.day + offset);
        final tomorrow = DateTime(eve.year, eve.month, eve.day + 1);
        final week = helper.actualWeek(tomorrow);
        if (week == null) break;
        final outsideTerm = week < 1 || week > totalWeeks;
        final payload = buildNextDayReminder(
          tomorrow: tomorrow,
          courses: outsideTerm ? const [] : helper.coursesOnDate(tomorrow),
          periods: helper.periods,
          startTimeOf: (item) =>
              helper.timeForSlot(item.course, item.slot, date: tomorrow).start,
          loggedIn: loggedIn,
          hasCache: true,
          outsideTerm: outsideTerm,
        );
        if (payload != null) {
          payloads[nextDayReminderDateKey(eve)] = payload.toJson();
        }
      }
      return payloads;
    } finally {
      helper.dispose();
    }
  }

  final StreamController<TimetableSyncOutcome> _syncOutcomes =
      StreamController<TimetableSyncOutcome>.broadcast();

  /// 每次同步（任意来源）结束时触发一次：成功或失败（含失败分类、是否自动）。
  /// UI 用它决定是否弹「已同步」/「回到本周」或失败轻提示。
  Stream<TimetableSyncOutcome> get syncOutcomes => _syncOutcomes.stream;

  TimetableSyncOutcome? _lastSyncOutcome;

  /// 最近一次同步的结果（本次进程内；未同步过 / 解绑后为 null）。
  TimetableSyncOutcome? get lastSyncOutcome => _lastSyncOutcome;

  bool _lastAutoSyncFailed = false;

  /// 最近一次自动同步（冷启动 / 网络恢复 / 打开课表页）失败后为 true；
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

  /// 当前课表快照；导入课表的课程也保存在这里。
  TimetableSnapshot get snapshot => _snapshot;

  /// 教务同步课程（只读，不含本地导入）。
  List<Course> get jwxtCourses => isImportedSchedule
      ? const []
      : List.unmodifiable(
          _snapshot.courses.where(
            (course) => course.source == CourseSource.jwxt,
          ),
        );

  /// 用户手动课程（独立持久化，同步/退出登录不覆盖）。
  List<Course> get manualCourses => List.unmodifiable(_manualCourses);

  Map<String, int>? _colorMap;

  /// item 9：用户自选课程色（课程 id → 原始 ARGB），见 [TimetableStore.readUserCourseColors]。
  Map<String, int> _userColors = const {};
  Future<void> _appearanceWrites = Future.value();
  TimetableSettings? _pendingSettings;
  int _settingsWriteRevision = 0;
  final _settingsWriteKeyRevisions = <String, int>{};

  Future<void> _serializeAppearance(Future<void> Function() action) {
    final result = _appearanceWrites.then((_) => action());
    _appearanceWrites = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// [c] 的用户自选色（原始 ARGB）；没选过为 null。
  int? userColorOf(Course c) {
    if (c.useDefaultColor) return null;
    if (c.occurrenceColor != null) return c.occurrenceColor;
    if (c.slots.length == 1) {
      final slot = c.slots.single;
      if (slot.useDefaultColor) return null;
      if (slot.color != null) return slot.color;
    }
    return _userColors[c.id];
  }

  /// 设 / 清（[color] 为 null，即「恢复默认」）某门课的自选色并落盘。不重算其他课的颜色。
  Future<void> setUserCourseColor(
    String courseId,
    int? color,
  ) => _serializeAppearance(() async {
    final next = Map<String, int>.of(_userColors);
    if (color == null) {
      next.remove(courseId);
    } else {
      next[courseId] = color | 0xFF000000;
    }
    List<Course>? nextManual;
    Map<String, CourseEdit>? nextCourseEdits;
    List<CourseDateEdit>? nextDateEdits;
    // 详情页选择“所有课程”颜色时，覆盖该课程各时段已有的局部颜色。
    final manual = manualCourseById(courseId);
    if (manual != null &&
        manual.slots.any((s) => s.color != null || s.useDefaultColor)) {
      nextManual = [
        for (final course in _manualCourses)
          if (course.id == courseId)
            course.copyWith(
              slots: [
                for (final slot in course.slots)
                  slot.copyWith(clearColor: true, useDefaultColor: false),
              ],
            )
          else
            course,
      ];
    }
    final courseEdit = _courseEdits[courseId];
    if (courseEdit != null &&
        courseEdit.slotEdits.any(
          (e) =>
              e.replacements.any((p) => p.color != null || p.useDefaultColor),
        )) {
      nextCourseEdits = {
        ..._courseEdits,
        courseId: courseEdit.copyWith(
          slotEdits: [
            for (final edit in courseEdit.slotEdits)
              CourseSlotEdit(
                original: edit.original,
                originalWeeks: edit.originalWeeks,
                replacements: [
                  for (final patch in edit.replacements)
                    CourseSlotPatch.tryParse({
                      ...patch.toJson(),
                      'color': null,
                      'useDefaultColor': false,
                    })!,
                ],
              ),
          ],
        ),
      };
    }
    // 应用到全局时清除这门课的局部颜色，保留备注、调课等其他修改。
    if (_dateEdits.any(
      (e) => e.courseId == courseId && (e.color != null || e.useDefaultColor),
    )) {
      nextDateEdits = [
        for (final e in _dateEdits)
          if (e.courseId != courseId || (e.color == null && !e.useDefaultColor))
            e
          else if (!e
              .copyWith(clearColor: true, useDefaultColor: false)
              .isEmpty)
            e.copyWith(clearColor: true, useDefaultColor: false),
      ];
    }
    // 全局色与被清除的局部颜色一起保存，任一文件失败都不提前改内存。
    await _inScope(
      () => TimetableStore.writeBatch(() async {
        await TimetableStore.saveUserCourseColors(next);
        if (nextManual != null) {
          await TimetableStore.saveManualCourses(nextManual);
        }
        if (nextCourseEdits != null) {
          await ScheduleStore.saveCourseEdits(nextCourseEdits);
        }
        if (nextDateEdits != null) {
          await ScheduleStore.saveCourseDateEdits(nextDateEdits);
        }
      }),
    );
    _userColors = next;
    if (nextManual != null) _manualCourses = List.unmodifiable(nextManual);
    if (nextCourseEdits != null) {
      _courseEdits = Map.unmodifiable(nextCourseEdits);
    }
    if (nextDateEdits != null) _dateEdits = List.unmodifiable(nextDateEdits);
    _scheduleVersion++;
    notifyListeners();
    _fireScheduleChanged(ScheduleChangeReason.courseEdit);
  });

  /// 自动配色跳过用户自选色的课（不占色号）。
  bool _autoColored(Course c) => !_userColors.containsKey(c.id);
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

  List<Course> _userOccupiedCourses() => [
    for (final c in _snapshot.courses)
      if (!_autoColored(c)) c,
    for (final c in _manualCourses)
      if (!_autoColored(c)) c,
  ];

  /// 无可用配色表时重建一次：教务课按原始位置（忽略调课记录）；手动课已存的
  /// [Course.assignedColorIndex] 当固定色参与、不重新顺延。手动课与教务课同名时
  /// 不拿手动课的 assignedColorIndex 去固定该课名（否则改名成教务课名的手动课
  /// 会抢走教务课的颜色），只参与相邻判断。
  Map<String, int> _buildFallbackColorMap(CoursePaletteScheme scheme) {
    final jwxtNames = {
      for (final c in _snapshot.courses) normalizeCourseName(c.name),
    };
    return assignCourseColors(
      [
        ..._snapshot.courses.where(_autoColored),
        for (final c in _manualCourses.where(_autoColored))
          c.colorIndex == null &&
                  c.assignedColorIndex != null &&
                  !jwxtNames.contains(normalizeCourseName(c.name))
              ? c.copyWith(colorIndex: c.assignedColorIndex)
              : c,
      ],
      scheme: scheme,
      userColors: _userColors,
      userOccupiedCourses: _userOccupiedCourses(),
    );
  }

  /// 全量重算配色（手动课只固定用户自选色号），把结果写回手动课的
  /// [Course.assignedColorIndex]（仅内存；调用方负责落盘 manual_courses.json），
  /// 并总是写 course_colors.json。返回手动课是否有变化。
  /// 只有四处调用：换配色方案、同步成功、增手动课、删手动课。
  Future<bool> _recomputeColors() async {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    final map = assignCourseColors(
      [
        // 教务原始位置，不套调课记录；用户自选色的课作为占用参考，不写进 map（item 9）。
        ..._snapshot.courses.where(_autoColored),
        for (final c in _manualCourses.where(_autoColored))
          c.copyWith(clearAssignedColor: true),
      ],
      scheme: scheme,
      userColors: _userColors,
      userOccupiedCourses: _userOccupiedCourses(),
    );
    _colorMap = map;
    _colorMapJwxt = _snapshot.courses;
    _colorMapScheme = scheme;
    final changed = _writeAssigned(map, onlyMissing: false);
    await _inScope(() => TimetableStore.saveCourseColors(scheme, map));
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
    final map = assignCourseColors(
      [
        for (final c in _snapshot.courses)
          if (_autoColored(c)) c.copyWith(colorIndex: colorIndexOf(c)),
        for (final c in _manualCourses)
          if (c.id != target.id && _autoColored(c))
            c.copyWith(
              colorIndex:
                  c.colorIndex ?? c.assignedColorIndex ?? colorIndexOf(c),
            ),
        target.copyWith(clearColor: true, clearAssignedColor: true),
      ],
      scheme: scheme,
      userColors: _userColors,
      userOccupiedCourses: [
        for (final c in _userOccupiedCourses())
          if (c.id != target.id) c,
      ],
    );
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

  /// 配色用课名：教务课总用教务原课名（改名 / 单日改名不换色），手动课用存储的课名。
  /// 配色用课名（教务用原课名，手动用存储名）。自动色哈希用此名。
  String colorNameOf(Course c) => _colorNameOf(c);

  String _colorNameOf(Course c) {
    if (c.isManual) return manualCourseById(c.id)?.name ?? c.name;
    return _jwxtCourseById(c.id)?.name ?? c.name;
  }

  /// 学期级冲突：与 [candidate] 同星期、节次重叠且周次相交的课程（教务+手动，跳过隐藏）。
  /// 编辑已有课程时传 [excludeId] 排除自身。
  List<Course> conflictsFor(CourseSlot candidate, {String? excludeId}) =>
      courseConflicts(combinedCourses, candidate, excludeId: excludeId);

  Object? _combinedCourseSources;
  List<Course> _combinedCourses = const [];

  /// 网格展示用合并列表：教务在前、手动在后；源数据变化时才重新合并。
  List<Course> get combinedCourses {
    final applied = _applied.courses;
    final sources = (applied, _manualCourses);
    if (_combinedCourseSources != sources) {
      _combinedCourseSources = sources;
      _combinedCourses = List.unmodifiable([...applied, ..._manualCourses]);
    }
    return _combinedCourses;
  }

  /// 同 [combinedCourses]（周视图/首页使用）。
  List<Course> get courses => combinedCourses;

  /// 周网格内容的变化标识，仅供界面比较，不包含临时浏览周或同步进度。
  /// 所有内容和配色集合均以新引用替换；布局尺寸、主题和系统日期由界面监听。
  Object get weekGridContentKey => (
    activeStorageId,
    _snapshot,
    _manualCourses,
    _overrides,
    _courseEdits,
    _daySwaps,
    _dateEdits,
    _scheduleEvents,
    _examOverrides,
    _userColors,
    _otherColors,
    courseColorMap,
  );

  /// 学期固定为 20 周，不随课程或考试安排变化，无课周也可浏览。
  int get totalWeeks => kDefaultTotalWeeks;

  /// 课程变动后把浏览周钳回 1..totalWeeks（页面无需自行处理）。
  void _clampViewingWeek() {
    _viewingWeekNotifier.value = _viewingWeekNotifier.value.clamp(
      1,
      totalWeeks,
    );
  }

  /// 每学期固定的总周数。
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

  /// 由学号前 4 位推导的入学年份（测试可替换；未绑定或解析失败返回 null）。
  @visibleForTesting
  static Future<int?> Function() enrollmentYearCheck =
      _defaultEnrollmentYearCheck;

  static Future<int?> _defaultEnrollmentYearCheck() async {
    final bundle = await PasskeyStore.read();
    return enrollmentYearFromStudentId(bundle?.studentId);
  }

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

  /// 测试用：替换教务可选学期列表查询。
  @visibleForTesting
  static Future<List<JwxtTermOption>> Function() fetchAvailableTerms =
      _defaultFetchAvailableTerms;

  static Future<List<JwxtTermOption>> _defaultFetchAvailableTerms() async {
    if (!identical(fetchSnapshot, _defaultFetch)) return const [];
    return TimetableApi.fetchAvailableTerms();
  }

  /// 测试用：替换往年教务课表拉取。
  @visibleForTesting
  static Future<TimetableSnapshot> Function(
    String term, {
    TimetableSettings? baseSettings,
  })
  fetchHistoricalSnapshot = _defaultFetchHistoricalSnapshot;

  static Future<TimetableSnapshot> _defaultFetchHistoricalSnapshot(
    String term, {
    TimetableSettings? baseSettings,
  }) => TimetableApi.fetchHistoricalTermSnapshot(
    term,
    baseSettings: baseSettings,
  );

  /// 作息表；快照为空时回退到校历默认作息，避免实验/体育连堂时刻算不出。
  List<PeriodTime> get periods =>
      _snapshot.periods.isEmpty ? defaultPeriods() : _snapshot.periods;
  TimetableSettings get settings => _snapshot.settings;

  /// 构造下一次设置编辑时使用的基线，包含排队中的选择。
  /// 展示、配色及提醒排程读取 [settings]，只使用已成功保存的状态。
  TimetableSettings get settingsForEditing => _pendingSettings ?? settings;

  /// 当前浏览周次的独立可监听对象；仅切换浏览周时通知，不唤醒监听整棵控制器的组件。
  ValueListenable<int> get viewingWeekListenable => _viewingWeekNotifier;

  int get viewingWeek => _viewingWeekNotifier.value;
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

  bool get isViewingCurrentWeek => _viewingWeekNotifier.value == currentWeek;

  /// 若 [currentWeek] 相对上次检查已变（改系统日期 / 跨周 / App 回前台），
  /// 把 [viewingWeek] 跳到 [_defaultViewingWeek]（本周，钳到 1..totalWeeks）。
  /// 同一本周内用户手动翻周不打断。返回是否改了 viewingWeek。
  ///
  /// 打开周课表、[onAppResumed] 时调用；PageView 由页面监听
  /// [viewingWeekListenable] 对齐页码。
  bool followCurrentWeekIfChanged() {
    final week = currentWeek;
    final prev = _lastSeenCurrentWeek;
    if (prev == week) return false;
    _lastSeenCurrentWeek = week;
    final target = _defaultViewingWeek;
    if (_viewingWeekNotifier.value == target) return false;
    setViewingWeek(target);
    return true;
  }

  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    final local = _localReady = Completer<void>();
    // 只有课表页等待本地阶段；其他调用方等待完整启动，失败不能成为未处理错误。
    local.future.ignore();
    return _starting = _start().catchError((Object error, StackTrace stack) {
      _started = false;
      _starting = null;
      _initialized = false;
      if (!local.isCompleted) local.completeError(error, stack);
      if (identical(_localReady, local)) _localReady = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// 本地课表、调课与配色已读入；门户绑定状态可能仍在读取。
  Completer<void>? _localReady;

  /// 启动并等待本地课表可展示。门户绑定读取依赖安全存储，冷启动可能需要
  /// 数百毫秒，有课时课表页不必等它；需要绑定状态的调用方仍用 [ensureStarted]。
  Future<void> ensureLocalReady() {
    final started = ensureStarted();
    final local = _localReady;
    return local == null || _initialized ? started : local.future;
  }

  /// 只读本地磁盘刷新：从 [TimetableStore] / [ScheduleStore] 重新载入快照、手动课程、
  /// 调课 / 编辑 / 日程等本地数据，并通知监听者刷新 UI。
  ///
  /// **不**调用 [fetchSnapshot]，**不**调用 [TimetableSyncDiff.applyAfterFetch]。
  /// 首页下拉、首页课表卡片刷新按钮只走这里；远程全量同步用
  /// [syncFromJwxt] / [manualSync]。
  ///
  /// 成功返回 `true`；读盘失败返回 `false`（供 UI toast「刷新失败」），不抛出。
  Future<bool> refreshLocal() async {
    try {
      await debugBeforeRefreshLocal?.call();
      await ensureStarted();
      final includeChangeLog = !TimetableChangeLogStore.hasDebugMemory;
      await _reloadFromDisk(includeChangeLog: includeChangeLog);
      final preloadedChanges = _preloadedSyncChangesRaw;
      _preloadedSyncChangesRaw = null;
      await _reloadPendingChanges(
        preloadedChanges: preloadedChanges,
        replace: true,
      );
      // 磁盘上的手动课 / 配色可能变了：清掉缓存后按当前数据重读配色表。
      _colorMap = null;
      await _loadColorMap();
      _clampViewingWeek();
      _lastSeenDate = _today;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _start() async {
    final includeChangeLog = !TimetableChangeLogStore.hasDebugMemory;
    await _reloadFromDisk(includeChangeLog: includeChangeLog);
    await _loadColorMap();
    if (_fillMissingAssignedColors()) {
      try {
        await _inScope(() => TimetableStore.saveManualCourses(_manualCourses));
      } on TimetablePersistenceException {
        // 旧数据色号可以再次推导；回填失败不阻断课表读取。
      }
    }
    // 旧数据：「其他」日程的名称还没有固定色号 → 补一次并落盘（只写 schedule_events.json）。
    if (_backfillOtherColors()) {
      try {
        await _inScope(
          () => ScheduleStore.saveEventsAndOtherColors(
            _scheduleEvents,
            _otherColors,
          ),
        );
      } on TimetablePersistenceException {
        // 保留内存中可用的固定色，下次启动仍可补写。
      }
    }
    _lastSeenCurrentWeek = currentWeek;
    _lastSeenDate = _today;
    _viewingWeekNotifier.value = _defaultViewingWeek;
    final preloadedChanges = _preloadedSyncChangesRaw;
    _preloadedSyncChangesRaw = null;
    await _reloadPendingChanges(preloadedChanges: preloadedChanges);
    final local = _localReady;
    if (local != null && !local.isCompleted) local.complete();
    if (_isPrimaryHost) {
      _portalBound = await bindingCheck();
    } else {
      _portalBound = _manager!._portalBound;
    }
    _initialized = true;
    notifyListeners();
    // 本地数据已可展示；400天通知排程是后台职责，不阻塞首页或小组件入口。
    unawaited(
      updateNextDayReminder().catchError((Object error, StackTrace stackTrace) {
        _log.warning(
          'next_day_reminder.startup_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  /// 从磁盘重载全部本地数据（快照、手动课程、调课 / 编辑 / 日程记录、同步状态）。
  /// [_start] 与 [refreshLocal] 共用；不读门户绑定状态，也不发网络请求。
  Future<void> _reloadFromDisk({bool includeChangeLog = false}) async {
    final bundle = await TimetableStore.readScopeBundle(
      initialScheduleId: activeStorageId,
      resolvePrimaryFromIndex: _isPrimaryHost,
      readSchedulesIndex: _isPrimaryHost,
      includeChangeLog: includeChangeLog,
    );
    if (_isPrimaryHost) {
      final storedIndex = TimetableStore.parseSchedulesIndex(
        bundle.schedulesIndex,
      );
      if (storedIndex != null) {
        final sorted = _sortedSchedules(storedIndex.schedules);
        _schedulesIndex = storedIndex.copyWith(
          schedules: List.unmodifiable(sorted),
        );
        final validPrimary =
            storedIndex.primaryScheduleId == kDefaultScheduleId ||
            storedIndex.byId(storedIndex.primaryScheduleId) != null;
        _primaryScheduleId = validPrimary
            ? storedIndex.primaryScheduleId
            : kDefaultScheduleId;
        if (_viewingScheduleId != kDefaultScheduleId &&
            storedIndex.byId(_viewingScheduleId) == null) {
          _viewingScheduleId = _primaryScheduleId;
        }
        // 启动初始加载尚未切到别的课表时，默认浏览主课表。
        if (!_started) {
          _viewingScheduleId = _primaryScheduleId;
        }
      }
    }
    _manualCourses = TimetableStore.parseManualCourses(bundle.manualCourses);
    _overrides = TimetableStore.parseOverrides(bundle.overrides);
    _scheduleEvents = List.unmodifiable(
      ScheduleStore.parseEvents(bundle.scheduleEvents),
    );
    _otherColors = Map.unmodifiable(
      ScheduleStore.parseOtherColors(bundle.scheduleEvents),
    );
    _courseEdits = Map.unmodifiable(
      ScheduleStore.parseCourseEdits(bundle.courseEdits),
    );
    _dateEdits = List.unmodifiable(
      ScheduleStore.parseCourseDateEdits(bundle.courseEdits),
    );
    _daySwaps = List.unmodifiable(ScheduleStore.parseDaySwaps(bundle.daySwaps));
    _examOverrides = Map.unmodifiable(
      ScheduleStore.parseExamOverrides(bundle.examOverrides),
    );
    _jwxtExamsBaselinePending = ScheduleStore.parseJwxtExamsBaselinePending(
      bundle.scheduleEvents,
    );
    _lastSyncSuccessAt = ScheduleStore.parseLastSyncSuccess(bundle.syncState);
    _lastAutomaticAttemptAt = ScheduleStore.parseLastAutomaticAttempt(
      bundle.syncState,
    );
    _portalSessionExpired = ScheduleStore.parsePortalSessionExpired(
      bundle.syncState,
    );
    _preloadedCourseColorsRaw = bundle.courseColors;
    _preloadedSyncChangesRaw = includeChangeLog ? bundle.syncChanges : null;

    final cached = TimetableStore.parseSnapshot(bundle.snapshot);
    final storedSettings = TimetableStore.parseSettings(bundle.settings);
    if (cached != null) {
      if (isImportedSchedule) {
        // 旧版曾把导入时间存入 syncedAt，不能当作教务同步时间。
        _snapshot = cached.copyWith(
          settings: cached.settings.withDisplayPrefsFrom(storedSettings),
          clearSyncedAt: true,
        );
      } else if (activeStorageId == kDefaultScheduleId) {
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
        _snapshot = cached.copyWith(
          settings: cached.settings.withDisplayPrefsFrom(storedSettings),
        );
      }
    } else {
      _snapshot = TimetableSnapshot(
        settings: activeStorageId == kDefaultScheduleId
            ? storedSettings
            : const TimetableSettings().withDisplayPrefsFrom(storedSettings),
      );
    }
    _snapshot = _snapshot.copyWith(
      settings: _withResolvedTermStart(
        !isImportedSchedule &&
                activeStorageId == kDefaultScheduleId &&
                _snapshot.settings.termCode.isEmpty
            ? _snapshot.settings.copyWith(termCode: '2026-2027-1')
            : _snapshot.settings,
      ),
    );
    if (_snapshot.periods.isEmpty) {
      _snapshot = _snapshot.copyWith(periods: defaultPeriods());
    }
    _scheduleVersion++;
    if (_isPrimaryHost) {
      final includeScopedChanges = !TimetableChangeLogStore.hasDebugMemory;
      for (final scoped in _scopedControllers.values.toList()) {
        if (scoped._started) {
          await scoped._reloadFromDisk(includeChangeLog: includeScopedChanges);
          final scopedChanges = scoped._preloadedSyncChangesRaw;
          scoped._preloadedSyncChangesRaw = null;
          await scoped._reloadPendingChanges(
            preloadedChanges: scopedChanges,
            replace: true,
          );
          scoped._colorMap = null;
          await scoped._loadColorMap();
          scoped._clampViewingWeek();
          scoped.notifyListeners();
        }
      }
    }
  }

  /// 启动时读 course_colors.json：方案与当前一致就直接用；缺失/损坏/方案不符/
  /// 类型不对 → 重建一次（[_buildFallbackColorMap]）并落盘。
  Future<void> _loadColorMap() async {
    final scheme = coursePaletteSchemeOf(settings.paletteScheme);
    final preloaded = _preloadedCourseColorsRaw;
    _preloadedCourseColorsRaw = null;
    StoredCourseColors? stored;
    await _inScope(() async {
      if (preloaded != null) {
        _userColors = TimetableStore.parseUserCourseColors(preloaded);
        stored = TimetableStore.parseCourseColors(preloaded);
      } else {
        try {
          _userColors = await TimetableStore.readUserCourseColors();
        } catch (_) {
          _userColors = const {};
        }
        try {
          stored = await TimetableStore.readCourseColors();
        } catch (_) {
          stored = null;
        }
      }
      _colorMapJwxt = _snapshot.courses;
      _colorMapScheme = scheme;
      if (stored case final loaded? when loaded.scheme == scheme) {
        _colorMap = loaded.map;
        return;
      }
      _colorMap = _buildFallbackColorMap(scheme);
      try {
        await TimetableStore.saveCourseColors(scheme, _colorMap!);
      } on TimetablePersistenceException {
        // 配色表是派生缓存；保存失败仍使用本次计算结果。
      }
    });
  }

  void setViewingWeek(int week) {
    final clamped = week.clamp(1, totalWeeks);
    if (clamped == _viewingWeekNotifier.value) return;
    _viewingWeekNotifier.value = clamped;
  }

  void goToCurrentWeek() => setViewingWeek(currentWeek);

  /// 课表页退出时清除临时浏览周，下一次进入从本周开始。
  /// 不通知正在退出或销毁的页面，避免退出动画跳周及卸载时重建。
  void clearViewingWeek() {
    _viewingWeekNotifier.setSilent(_defaultViewingWeek);
    _lastSeenCurrentWeek = currentWeek;
  }

  /// 「回到本周」（同 [goToCurrentWeek]；已在本周时不通知）。
  void jumpToCurrentWeek() => goToCurrentWeek();

  /// 纯显示/外观偏好键：只写 settings.json；仅当小组件的有效周末值变化时通知刷新。
  static const _pureAppearanceSettingKeys = <String>{
    'periodHeight',
    'cellRadius',
    'showSaturday',
    'showSunday',
    'showNonCurrentWeek',
    'showGridLines',
    'weekStartsOnMonday',
    'showLocation',
    'showTeacher',
    'fontScale',
    'cellOpacity',
    'showTomorrowOnHome',
    'cellTextColor',
    'homeMaxItems',
    'homeMaxExams',
    'headerTextSize',
    'showPeriodTimes',
  };

  /// 影响桌面小组件的显示偏好键：只写 settings.json（不重写 snapshot.json），仍需通知小组件同步。
  static const _widgetAffectingDisplayKeys = <String>{
    'examColor',
    'showExams',
    'widgetShowTeacher',
    'widgetShowLocation',
    'widgetShowCountdown',
    'widgetShowCount',
    'widgetShowPeriod',
    'widgetCourseCount',
    'widgetWeekCellHeight',
    'widgetWeekFontSize',
    'widgetWeekOpacity',
    'widgetWeekCompactRows',
    'widgetWeekShowWeekend',
  };

  /// 保存本次真正改动的设置；失败时恢复最后成功保存的状态。
  /// 等待保存期间保留待选值，连续调整不会互相覆盖或漏掉恢复原值的操作。
  Future<void> updateSettings(TimetableSettings next) {
    final before = settingsForEditing.toJson();
    final requested = next.toJson();
    final changedKeys = {
      for (final key in {...before.keys, ...requested.keys})
        if (before.containsKey(key) != requested.containsKey(key) ||
            before[key] != requested[key])
          key,
    };
    if (changedKeys.isEmpty) return Future.value();
    final revision = ++_settingsWriteRevision;
    for (final key in changedKeys) {
      _settingsWriteKeyRevisions[key] = revision;
    }
    _pendingSettings = next;
    return _serializeAppearance(() async {
      // 保存队列只写每个键最新请求；滑杆中间值被新值替代时不再落盘。
      final activeKeys = {
        for (final key in changedKeys)
          if (_settingsWriteKeyRevisions[key] == revision) key,
      };
      if (activeKeys.isEmpty) return;
      final isPureAppearance = activeKeys.every(
        _pureAppearanceSettingKeys.contains,
      );
      final shouldWriteSnapshot = !activeKeys.every(
        (k) =>
            _pureAppearanceSettingKeys.contains(k) ||
            _widgetAffectingDisplayKeys.contains(k),
      );
      late final bool shouldFireScheduleChanged;
      try {
        final previous = _snapshot.settings;
        final raw = previous.toJson();
        // 排队期间其他开关可能已保存，仅合并这次操作涉及的字段。
        for (final key in activeKeys) {
          if (requested.containsKey(key)) {
            raw[key] = requested[key];
          } else {
            raw.remove(key);
          }
        }
        final applied = TimetableSettings.fromJson(raw);
        // 未单独设置周末时，外观变化也可能改变桌面小组件的列。
        shouldFireScheduleChanged =
            !isPureAppearance ||
            previous.widgetWeekShowWeekend != applied.widgetWeekShowWeekend;
        final snapshot = _snapshot.copyWith(settings: applied);
        final scheme = coursePaletteSchemeOf(applied.paletteScheme);
        Map<String, int>? colors;
        List<Course>? manual;
        if (previous.paletteScheme != applied.paletteScheme) {
          colors = assignCourseColors([
            ...snapshot.courses.where(_autoColored),
            for (final course in _manualCourses.where(_autoColored))
              course.copyWith(clearAssignedColor: true),
          ], scheme: scheme);
          manual = [
            for (final course in _manualCourses)
              if (colors[normalizeCourseName(course.name)] case final index?
                  when course.colorIndex == null)
                course.copyWith(assignedColorIndex: index)
              else
                course,
          ];
        }
        await _inScope(
          () => TimetableStore.writeBatch(() async {
            if (colors != null) {
              await TimetableStore.saveCourseColors(scheme, colors);
            }
            if (manual != null) await TimetableStore.saveManualCourses(manual);
            // 未改动的原始值和未知键仍由 Store 保留；非默认课表只把外观偏好合入全局 settings.json。
            if (activeStorageId == kDefaultScheduleId) {
              await TimetableStore.mergeSettingsChanges(previous, applied);
            } else {
              await TimetableStore.mergeSettingsChanges(
                previous,
                previous.withDisplayPrefsFrom(applied),
              );
            }
            if (shouldWriteSnapshot) {
              await TimetableStore.saveSnapshot(snapshot);
            }
          }),
        );
        _snapshot = snapshot;
        if (manual != null) _manualCourses = manual;
        if (colors != null) {
          _colorMap = colors;
          _colorMapJwxt = snapshot.courses;
          _colorMapScheme = scheme;
        }
        _syncDisplayPrefsAcrossControllers(
          applied,
          fireScheduleChanged: shouldFireScheduleChanged,
        );
      } finally {
        if (revision == _settingsWriteRevision) _pendingSettings = null;
        notifyListeners();
      }
      if (shouldFireScheduleChanged) {
        _fireScheduleChanged(ScheduleChangeReason.settings);
      }
    });
  }

  void _syncDisplayPrefsAcrossControllers(
    TimetableSettings applied, {
    bool fireScheduleChanged = true,
  }) {
    final host = _manager ?? this;
    if (!identical(host, this)) {
      host._snapshot = host._snapshot.copyWith(
        settings: host._snapshot.settings.withDisplayPrefsFrom(applied),
      );
      if (host.settings.paletteScheme != applied.paletteScheme) {
        host._colorMap = null;
      }
      host.notifyListeners();
      if (fireScheduleChanged) {
        host._fireScheduleChanged(ScheduleChangeReason.settings);
      }
    }
    for (final scoped in host._scopedControllers.values) {
      if (identical(scoped, this)) continue;
      scoped._snapshot = scoped._snapshot.copyWith(
        settings: scoped._snapshot.settings.withDisplayPrefsFrom(applied),
      );
      scoped._colorMap = null;
      scoped.notifyListeners();
    }
  }

  /// 缓存为空、尚未建立教务考试基线或非今日同步 → 需要同步。
  bool get needsSync {
    if (!hasCourses) return true;
    if (_jwxtExamsBaselinePending) return true;
    final at = _snapshot.syncedAt;
    if (at == null) return true;
    final now = DateTime.now();
    return at.year != now.year || at.month != now.month || at.day != now.day;
  }

  /// 刷新门户登录状态。
  Future<bool> refreshPortalBound() async {
    _portalBound = await bindingCheck();
    notifyListeners();
    // 明日提醒重排不挡同步/SnackBar；未 mock 的 MethodChannel 在测试里会挂起。
    unawaited(updateNextDayReminder());
    return _portalBound;
  }

  /// 课表页打开时：已登录且缓存为空/过期则自动从教务全量同步。
  /// 同样受 90 分钟节流（距上次成功不足则不同步）。仍走远程。
  /// 往年学期与导入的他人课表不再主动拉取更新。
  Future<void> autoSyncIfNeeded() async {
    if (_isPrimaryHost && isHistoricalSchedule(_primaryScheduleId)) return;
    if (_isPrimaryHost && primaryScheduleMeta?.isImportedSchedule == true) {
      return;
    }
    if (_loading || !needsSync) return;
    if (!_elapsedSinceSuccess(autoSyncInterval)) return;
    if (!_automaticAttemptDue()) return;
    if (!await refreshPortalBound()) return;
    if (_loading || _syncInFlight != null) return;
    final bindingRevision = _portalBindingRevision;
    await _recordAutomaticAttempt();
    if (_loading ||
        _syncInFlight != null ||
        !_portalBound ||
        bindingRevision != _portalBindingRevision) {
      return;
    }
    _nextSyncAuto = true;
    await syncFromJwxt();
  }

  /// 远程手动「立即同步」入口（周课表顶栏用）：未绑定门户时不发请求、不报失败，
  /// 返回 false 由页面跳转登录；已绑定则从教务全量同步并返回 true。
  Future<bool> syncIfBound() async {
    if (isImportedSchedule) return true;
    if (!await refreshPortalBound()) return false;
    await syncFromJwxt();
    return true;
  }

  /// 从教务 wdkb 同步课表（复用门户会话）。失败保留缓存并在同步条提示。
  /// 进行中再次调用返回同一个 Future（不重复请求）。
  Future<void> syncFromJwxt() {
    if (_manager != null && activeStorageId != kDefaultScheduleId) {
      if (isImportedSchedule) {
        _statusMessage = '导入的课表不支持从教务同步';
        notifyListeners();
        return Future.value();
      }
      return _syncHistoricalScoped();
    }
    if (_isPrimaryHost && _primaryScheduleId != kDefaultScheduleId) {
      return _syncDefaultFromHost();
    }
    final inFlight = _syncInFlight;
    if (inFlight != null) return SilentRefresh.join(inFlight);
    if (_loading) {
      SilentRefresh.skipCurrent(reason: 'already_refreshing');
      return Future.value();
    }
    final automatic = _nextSyncAuto;
    _nextSyncAuto = false;
    late final Future<void> f;
    f = SilentRefresh.track(
      () => _doSync(automatic: automatic).whenComplete(() {
        if (identical(_syncInFlight, f)) _syncInFlight = null;
      }),
    );
    _syncInFlight = f;
    return SilentRefresh.join(f);
  }

  Future<void> _syncDefaultFromHost() async {
    final automatic = _nextSyncAuto;
    _nextSyncAuto = false;
    final scoped = await _ensureScopedController(kDefaultScheduleId);
    scoped._portalBound = _portalBound;
    scoped._nextSyncAuto = automatic;
    await scoped.syncFromJwxt();
    _syncStatus = scoped._syncStatus;
    _syncFailure = scoped._syncFailure;
    _lastAutoSyncFailed = scoped._lastAutoSyncFailed;
    _lastSyncOutcome = scoped._lastSyncOutcome;
    _portalSessionExpired = scoped._portalSessionExpired;
    if (_primaryScheduleId == kDefaultScheduleId) {
      await _reloadPendingChanges(replace: true);
    }
    notifyListeners();
    if (scoped._lastSyncOutcome case final outcome?) {
      _syncOutcomes.add(outcome);
    }
  }

  Future<void> _syncHistoricalScoped() {
    final inFlight = _syncInFlight;
    if (inFlight != null) return SilentRefresh.join(inFlight);
    if (_loading) return Future.value();
    final term = settings.termCode.trim();
    if (term.isEmpty) return Future.value();
    late final Future<void> f;
    f = _doSyncHistorical(term).whenComplete(() {
      if (identical(_syncInFlight, f)) _syncInFlight = null;
    });
    _syncInFlight = f;
    return f;
  }

  Future<void> _doSyncHistorical(String term) async {
    final host = _manager ?? this;
    final bindingRevision = host._portalBindingRevision;
    TimetableSyncOutcome? outcome;
    _loading = true;
    _statusMessage = '正在同步往年课表…';
    _syncStatus = TimetableSyncStatus.syncing;
    _syncFailure = TimetableSyncFailure.none;
    notifyListeners();
    try {
      final previous = settings;
      final previousJwxt = _snapshot.courses;
      final hadBaseline =
          _snapshot.syncedAt != null ||
          previousJwxt.isNotEmpty ||
          _scheduleEvents.any((e) => e.isFromJwxt && e.isExam);
      var snapshot = await fetchHistoricalSnapshot(
        term,
        baseSettings: previous.copyWith(clearTermStart: true),
      );
      if (bindingRevision != host._portalBindingRevision) return;
      if (snapshot.periods.isEmpty) {
        snapshot = snapshot.copyWith(
          periods: _snapshot.periods.isEmpty
              ? defaultPeriods()
              : _snapshot.periods,
        );
      }
      final existingMeta = scheduleMetaOf(activeStorageId);
      final resolvedName = existingMeta?.customName == true
          ? existingMeta!.name
          : formatTermScheduleName(term);
      snapshot = snapshot.copyWith(
        courses: [
          for (final c in snapshot.courses)
            if (c.source == CourseSource.jwxt) c,
        ],
        settings: snapshot.settings
            .withDisplayPrefsFrom(settings)
            .copyWith(termCode: term, scheduleName: resolvedName),
        syncedAt: DateTime.now(),
        clearError: true,
      );
      await _inScope(
        () => TimetableStore.writeBatch(
          () => TimetableStore.saveSnapshot(snapshot),
        ),
      );
      _snapshot = snapshot;
      lastSyncDiff = null;
      if (hadBaseline) {
        try {
          final courseDiff = await _inScope(
            () => TimetableSyncDiff.applyAfterFetch(
              previousJwxtCourses: previousJwxt,
              newJwxtCourses: snapshot.courses,
              allowWhenOldEmpty: true,
              termStartDate: snapshot.settings.termStartDate,
              xnxqdm: term,
              detectedAt: snapshot.syncedAt,
            ),
          );
          if (bindingRevision != host._portalBindingRevision) return;
          if (courseDiff.allWritten.isNotEmpty ||
              courseDiff.toNotify.isNotEmpty) {
            lastSyncDiff = courseDiff;
            _mergePendingChanges(courseDiff.toNotify);
          }
        } catch (error, stackTrace) {
          AppLog.reportOutcome(
            'degraded',
            reason: 'change_history_unavailable',
          );
          _log.warning(
            'changes.update_failed',
            fields: {'stage': 'sync.change_detection', 'outcome': 'degraded'},
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      await _serializeAppearance(() async {
        final colorsChanged = await _recomputeColors();
        if (colorsChanged) {
          await _inScope(
            () => TimetableStore.saveManualCourses(_manualCourses),
          );
        }
      });
      final hadExamBaseline = hadBaseline && !_jwxtExamsBaselinePending;
      final previousJwxtExams = [
        for (final e in _scheduleEvents)
          if (e.isFromJwxt && e.isExam) e,
      ];
      final syncedExams = await _syncExams(
        term,
        bindingRevision: bindingRevision,
      );
      if (bindingRevision != host._portalBindingRevision) return;
      if (syncedExams != null) {
        try {
          final examDiff = await _inScope(
            () => TimetableSyncDiff.applyExamsAfterFetch(
              previousJwxtExams: hadExamBaseline ? previousJwxtExams : const [],
              newJwxtExams: syncedExams,
              allowWhenOldEmpty: hadExamBaseline,
              xnxqdm: term,
              detectedAt: snapshot.syncedAt,
            ),
          );
          if (bindingRevision != host._portalBindingRevision) return;
          if (examDiff.allWritten.isNotEmpty || examDiff.toNotify.isNotEmpty) {
            lastSyncDiff = _mergeSyncDiff(lastSyncDiff, examDiff);
            _mergePendingChanges(examDiff.toNotify);
          }
        } catch (error, stackTrace) {
          AppLog.reportOutcome(
            'degraded',
            reason: 'change_history_unavailable',
          );
          _log.warning(
            'changes.exam_update_failed',
            fields: {
              'stage': 'sync.exam_change_detection',
              'outcome': 'degraded',
            },
            error: error,
            stackTrace: stackTrace,
          );
        }
      } else if (!hadExamBaseline) {
        await _markJwxtExamsBaselinePending();
      }
      await host._upsertScheduleMetadata(
        ScheduleMetadata(
          id: activeStorageId,
          name: resolvedName,
          customName: existingMeta?.customName ?? false,
          sourceKind: TimetableSourceKind.jwxt,
          termCode: term,
          createdAt: existingMeta?.createdAt ?? DateTime.now(),
          syncedAt: snapshot.syncedAt,
          courseCount: snapshot.courses.length,
        ),
        persist: true,
      );
      _clampViewingWeek();
      _statusMessage = '已同步 ${_snapshot.courses.length} 门课程';
      _syncStatus = TimetableSyncStatus.success;
      _syncFailure = TimetableSyncFailure.none;
      outcome = const TimetableSyncOutcome.success(automatic: false);
      _fireScheduleChanged(ScheduleChangeReason.sync);
    } catch (e) {
      if (bindingRevision != host._portalBindingRevision) return;
      _syncFailure = classifySyncError(e);
      outcome = TimetableSyncOutcome.failure(
        automatic: false,
        failure: _syncFailure,
        offline: _isOffline(e),
      );
      _statusMessage = '同步失败：$e';
      _syncStatus = TimetableSyncStatus.failure;
      if (_syncFailure == TimetableSyncFailure.sessionExpired) {
        await host._setPortalSessionExpired(true);
      }
    } finally {
      _loading = false;
      if (outcome != null) _lastSyncOutcome = outcome;
      notifyListeners();
      if (outcome case final completed?) _syncOutcomes.add(completed);
    }
  }

  /// [syncFromJwxt] 的别名：从教务远程拉取全量课表，行为与 [syncFromJwxt] 完全等同。
  Future<void> syncFromRemote() => syncFromJwxt();

  Future<void> _doSync({bool automatic = false}) async {
    final bindingRevision = _portalBindingRevision;
    TimetableSyncOutcome? outcome;
    _loading = true;
    _statusMessage = '正在同步教务课表…';
    _syncStatus = TimetableSyncStatus.syncing;
    _syncFailure = TimetableSyncFailure.none;
    notifyListeners();
    try {
      await _log.operation<void>(
        'sync',
        () async {
          final term = settings.termCode.isNotEmpty
              ? settings.termCode
              : '2026-2027-1';
          final previous = settings;
          // SW01：记下同步前浏览周与是否在看本周。
          final viewingWeekBeforeSync = viewingWeek;
          final wasOnCurrentWeek = isViewingCurrentWeek;
          var snapshot = await fetchSnapshot(
            term,
            // 清空开学日，以便区分「本次 dqzc 推算」与「缓存/默认值」。
            baseSettings: previous.copyWith(clearTermStart: true),
          );
          // 绑定已变更，旧请求不能继续套用或保存课程。
          if (bindingRevision != _portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          if (snapshot.periods.isEmpty) {
            snapshot = snapshot.copyWith(
              periods: _snapshot.periods.isEmpty
                  ? defaultPeriods()
                  : _snapshot.periods,
            );
          }
          snapshot = snapshot.copyWith(
            settings: _withResolvedTermStart(
              snapshot.settings,
              cached: previous,
            ),
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
          late final List<Course> previousJwxt;
          late final bool hasCourseSyncBaseline;
          late final bool hasExamSyncBaseline;
          late final String effectiveTerm;
          final host = _manager ?? this;
          // 与设置保存共用队列：落盘后立即发布快照，后续设置不能再写回旧课表。
          await _serializeAppearance(() async {
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
            previousJwxt = _snapshot.courses;
            final hadJwxtExams = _scheduleEvents.any(
              (e) => e.isFromJwxt && e.isExam,
            );
            final prevTerm = _snapshot.settings.termCode.trim();
            final nextTerm = snapshot.settings.termCode.trim();
            effectiveTerm = nextTerm.isNotEmpty ? nextTerm : term;
            final sameTerm =
                (prevTerm.isEmpty && nextTerm.isEmpty) ||
                prevTerm == nextTerm ||
                (prevTerm.isEmpty &&
                    (previousJwxt.isNotEmpty || hadJwxtExams)) ||
                nextTerm.isEmpty;
            hasCourseSyncBaseline =
                sameTerm &&
                (previousJwxt.isNotEmpty ||
                    (_snapshot.syncedAt != null && prevTerm.isNotEmpty));
            hasExamSyncBaseline =
                sameTerm &&
                !_jwxtExamsBaselinePending &&
                (hadJwxtExams ||
                    previousJwxt.isNotEmpty ||
                    (_snapshot.syncedAt != null && prevTerm.isNotEmpty));
            final termRolledOver =
                previous.termCode.isNotEmpty &&
                previous.termCode != effectiveTerm &&
                isHistoricalTerm(
                  previous.termCode,
                  currentTermCode: effectiveTerm,
                ) &&
                previousJwxt.isNotEmpty;
            if (termRolledOver && activeStorageId == kDefaultScheduleId) {
              final archiveId = 'jwxt_${sanitizeScheduleId(previous.termCode)}';
              await TimetableStore.archiveDefaultToSchedule(archiveId);
              final prevMeta = host.scheduleMetaOf(kDefaultScheduleId);
              await host._upsertScheduleMetadata(
                ScheduleMetadata(
                  id: archiveId,
                  name: prevMeta?.customName == true
                      ? prevMeta!.name
                      : formatTermScheduleName(previous.termCode),
                  customName: prevMeta?.customName ?? false,
                  sourceKind: TimetableSourceKind.jwxt,
                  termCode: previous.termCode,
                  createdAt: prevMeta?.createdAt ?? DateTime.now(),
                  syncedAt: _snapshot.syncedAt,
                  courseCount: previousJwxt.length,
                ),
                persist: true,
              );
            }
            snapshot = snapshot.copyWith(
              settings: snapshot.settings
                  .withDisplayPrefsFrom(settings)
                  .copyWith(scheduleName: settings.scheduleName),
            );
            // 快照与学期设置一起落盘，失败时保留原有内存和磁盘数据。
            await _inScope(
              () => TimetableStore.writeBatch(() async {
                await TimetableStore.saveSnapshot(snapshot);
                // 只合并学期四键，保留展示设置的原始值与未知键。
                await TimetableStore.mergeTermSettings(snapshot.settings);
                // 绑定变更时取消尚未提交的旧批次；外层按 revision 忽略本次同步。
                if (bindingRevision != host._portalBindingRevision) {
                  throw const TimetablePersistenceException();
                }
              }),
            );
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
            _snapshot = snapshot;
          });
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          // 变更日志沿用已捕获的旧教务源；I/O 等待不占设置队列，也不再次覆盖快照。
          if (!hasCourseSyncBaseline && !hasExamSyncBaseline) {
            await _resetSyncChanges();
            if (bindingRevision != host._portalBindingRevision) return;
          }
          TimetableSyncDiffResult? syncDiff;
          try {
            syncDiff = await _inScope(
              () => TimetableSyncDiff.applyAfterFetch(
                previousJwxtCourses: hasCourseSyncBaseline
                    ? previousJwxt
                    : const [],
                newJwxtCourses: snapshot.courses,
                allowWhenOldEmpty: hasCourseSyncBaseline,
                termStartDate: snapshot.settings.termStartDate,
                xnxqdm: effectiveTerm,
                detectedAt: snapshot.syncedAt,
              ),
            );
          } catch (error, stackTrace) {
            AppLog.reportOutcome(
              'degraded',
              reason: 'change_history_unavailable',
            );
            _log.warning(
              'changes.update_failed',
              fields: {'stage': 'sync.change_detection', 'outcome': 'degraded'},
              error: error,
              stackTrace: stackTrace,
            );
          }
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          lastSyncDiff = syncDiff;
          if (syncDiff != null) _mergePendingChanges(syncDiff.toNotify);
          // SW01（§13.10）：同步成功后停留在正在看的周（只钳到 1..totalWeeks）。
          // 同步期间未手动切周，且（同步前就在看本周 / 之前无开学日 / 从已知旧学期切到新学期）
          // 时才跟到新的本周；不再调用 followCurrentWeekIfChanged，避免把非当前周拉回本周。
          final switchedDuringSync = viewingWeek != viewingWeekBeforeSync;
          final termChanged =
              previous.termCode.isNotEmpty &&
              previous.termCode != _snapshot.settings.termCode;
          _lastSeenCurrentWeek = currentWeek;
          if (!switchedDuringSync &&
              (wasOnCurrentWeek ||
                  previous.termStartDate == null ||
                  termChanged)) {
            _viewingWeekNotifier.value =
                _defaultViewingWeek; // 已钳到 1..totalWeeks
          } else {
            _clampViewingWeek();
          }
          // 教务优先（jwxt §3.2）：原课被删、SKZC 与 origWeeks 不同（含缺 origWeeks
          // 的旧记录）、或原时段星期/节次变了 → 删掉记录，显示教务数据。其余保留。
          // 只在同步成功这里比较；解绑不删。
          final stale = staleOverrideIds(_snapshot.courses, _overrides);
          if (stale.isNotEmpty) {
            _overrides = List.unmodifiable([
              for (final o in _overrides)
                if (!stale.contains(o.id)) o,
            ]);
            await _inScope(() => TimetableStore.saveOverrides(_overrides));
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
          }
          // 编辑/删除记录同理：原课没了、SKZC 或时段变了 → 删除（解绑/失败不删）。
          final staleEdits = staleCourseEditIds(
            _snapshot.courses,
            _courseEdits,
          );
          if (staleEdits.isNotEmpty) {
            _courseEdits = Map.unmodifiable(
              {..._courseEdits}..removeWhere((k, _) => staleEdits.contains(k)),
            );
            await _inScope(() => ScheduleStore.saveCourseEdits(_courseEdits));
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
          }
          await _serializeAppearance(() async {
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
            final colorsChanged = await _recomputeColors();
            if (bindingRevision != host._portalBindingRevision) {
              AppLog.reportOutcome('skipped', reason: 'superseded');
              return;
            }
            if (colorsChanged) {
              await _inScope(
                () => TimetableStore.saveManualCourses(_manualCourses),
              );
            }
          });
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          // 第 11 条：课表成功后拉考试（不受 showExams 影响）。考试失败不影响本次课表
          // 同步结果、成功时间与离线补同步逻辑，已有考试保留。
          final previousJwxtExams = [
            for (final e in _scheduleEvents)
              if (e.isFromJwxt && e.isExam) e,
          ];
          final syncedExams = await _syncExams(
            effectiveTerm,
            bindingRevision: bindingRevision,
          );
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          if (syncedExams != null) {
            try {
              final examDiff = await _inScope(
                () => TimetableSyncDiff.applyExamsAfterFetch(
                  previousJwxtExams: hasExamSyncBaseline
                      ? previousJwxtExams
                      : const [],
                  newJwxtExams: syncedExams,
                  allowWhenOldEmpty: hasExamSyncBaseline,
                  xnxqdm: effectiveTerm,
                  detectedAt: snapshot.syncedAt,
                ),
              );
              if (bindingRevision != host._portalBindingRevision) {
                AppLog.reportOutcome('skipped', reason: 'superseded');
                return;
              }
              if (examDiff.allWritten.isNotEmpty ||
                  examDiff.toNotify.isNotEmpty) {
                lastSyncDiff = _mergeSyncDiff(lastSyncDiff, examDiff);
                _mergePendingChanges(examDiff.toNotify);
              }
            } catch (error, stackTrace) {
              AppLog.reportOutcome(
                'degraded',
                reason: 'change_history_unavailable',
              );
              _log.warning(
                'changes.exam_update_failed',
                fields: {
                  'stage': 'sync.exam_change_detection',
                  'outcome': 'degraded',
                },
                error: error,
                stackTrace: stackTrace,
              );
            }
          } else if (!hasExamSyncBaseline) {
            await _markJwxtExamsBaselinePending();
          }
          final existingDefault = host.scheduleMetaOf(kDefaultScheduleId);
          final defaultMetaName = existingDefault?.customName == true
              ? existingDefault!.name
              : (settings.scheduleName != '我的课表' &&
                        previous.termCode == effectiveTerm
                    ? settings.scheduleName
                    : formatTermScheduleName(effectiveTerm));
          await host._upsertScheduleMetadata(
            ScheduleMetadata(
              id: kDefaultScheduleId,
              name: defaultMetaName,
              customName: existingDefault?.customName ?? false,
              sourceKind: TimetableSourceKind.jwxt,
              termCode: effectiveTerm,
              createdAt: existingDefault?.createdAt ?? DateTime.now(),
              syncedAt: _snapshot.syncedAt,
              courseCount: _snapshot.courses.length,
            ),
            currentTermCode: effectiveTerm,
            persist:
                host._schedulesIndex.schedules.length > 1 ||
                await TimetableStore.readSchedulesIndex() != null,
          );
          // 只有成功才重置自动同步计时。
          final succeededAt = syncClock();
          await ScheduleStore.saveLastSyncSuccess(succeededAt);
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          await host._setPortalSessionExpired(false);
          if (bindingRevision != host._portalBindingRevision) {
            AppLog.reportOutcome('skipped', reason: 'superseded');
            return;
          }
          _lastSyncSuccessAt = succeededAt;
          _lastFailureOffline = false;
          _statusMessage = '已同步 ${_snapshot.courses.length} 门教务课程';
          _syncStatus = TimetableSyncStatus.success;
          _syncFailure = TimetableSyncFailure.none;
          _lastAutoSyncFailed = false;
          outcome = TimetableSyncOutcome.success(automatic: automatic);
          _fireScheduleChanged(ScheduleChangeReason.sync);
          if (_isPrimaryHost) {
            unawaited(
              _autoDiscoverHistoricalTerms(bindingRevision: bindingRevision),
            );
          }
        },
        fields: {'automatic': automatic, 'has_cache': hasCourses},
        resultFields: (_) => {'course_count': _snapshot.courses.length},
        errorFields: (error) => {
          'failure_kind': classifySyncError(error).name,
          'offline': _isOffline(error),
        },
      );
    } catch (e) {
      final host = _manager ?? this;
      if (bindingRevision != host._portalBindingRevision) return;
      SilentRefresh.failCurrent();
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
        await host._setPortalSessionExpired(true);
      }
    } finally {
      final host = _manager ?? this;
      _loading = false;
      // 等待存储期间也可能换绑，过时同步不能再发布成功或失败提示。
      if (bindingRevision != host._portalBindingRevision) outcome = null;
      if (outcome != null) _lastSyncOutcome = outcome;
      notifyListeners();
      if (outcome case final completed?) _syncOutcomes.add(completed);
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
    _initialized = true;
    _lastSeenCurrentWeek = currentWeek;
    _lastSeenDate = _today;
    _scheduleVersion++;
    _viewingWeekNotifier.value = viewingWeek ?? _defaultViewingWeek;
    notifyListeners();
  }

  /// 测试用：重置单例状态（下次 [ensureStarted] 重新读盘）。
  @visibleForTesting
  void debugReset() {
    lastSyncDiff = null;
    _pendingChangeAlerts.clear();
    _changeAlertRevision++;
    _jwxtExamsBaselinePending = false;
    _viewingWeekNotifier.setSilent(1);
    _lastSeenCurrentWeek = null;
    _lastSeenDate = null;
    _scheduleVersion++;
    _preloadedCourseColorsRaw = null;
    _preloadedSyncChangesRaw = null;
    _started = false;
    _starting = null;
    _localReady = null;
    _initialized = false;
    _snapshot = const TimetableSnapshot();
    _manualCourses = const [];
    _overrides = const [];
    _effJwxt = null;
    _combinedCourseSources = null;
    _combinedCourses = const [];
    _dayCellSources = null;
    _dayCells.clear();
    _effectiveEventSources = null;
    _effectiveEventCache = const [];
    _eventsByDate.clear();
    _scheduleEvents = const [];
    _otherColors = const {};
    _userColors = const {};
    _courseEdits = const {};
    _dateEdits = const [];
    _daySwaps = const [];
    _examOverrides = const {};
    _lastSyncSuccessAt = null;
    _lastAutomaticAttemptAt = null;
    debugBeforeRefreshLocal = null;
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
    _appearanceWrites = Future.value();
    _pendingSettings = null;
    _settingsWriteRevision = 0;
    _settingsWriteKeyRevisions.clear();
    _loading = false;
    _statusMessage = null;
    _syncStatus = TimetableSyncStatus.idle;
    _syncFailure = TimetableSyncFailure.none;
    _syncInFlight = null;
    _portalBindingRevision = 0;
    _portalBindingChange = Future.value();
    _portalBound = false;
    _pendingOpen = null;
    _schedulesIndex = const SchedulesIndex();
    _primaryScheduleId = kDefaultScheduleId;
    _viewingScheduleId = kDefaultScheduleId;
    _scopedControllers.clear();
    _probedHistoricalSnapshots.clear();
    _importSeq = 0;
    _historicalDiscoveryAttempted = false;
    _historicalDiscoveryInFlight = null;
    _nextDayReminderConfigurationInputs = null;
    _nextDayReminderConfiguration = null;
    _sentNextDayReminderInputs = null;
    _sendingNextDayReminderInputs = null;
    _nextDayReminderGeneration++;
    _nextDayReminderYieldTimer?.cancel();
    _nextDayReminderYieldTimer = null;
    final reminderYield = _nextDayReminderYieldDone;
    if (reminderYield != null && !reminderYield.isCompleted) {
      reminderYield.complete();
    }
    _nextDayReminderYieldDone = null;
    _nextDayReminderWork = null;
  }

  /// 清空教务课程与 snapshot 磁盘缓存，并清除教务写入的学期元数据；
  /// 手动课程与展示设置（周末/非本周/格子高度等）保留。
  Future<void> clearJwxtCourses() async {
    await _resetSyncChanges();
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
    // 教务考试一并清掉；手动日程、考试覆盖、课程编辑、调课记录、配色表都保留。
    final hadJwxtExams = _scheduleEvents.any((e) => e.isFromJwxt);
    if (hadJwxtExams) {
      _scheduleEvents = List.unmodifiable([
        for (final e in _scheduleEvents)
          if (!e.isFromJwxt) e,
      ]);
    }
    TimetablePersistenceException? firstFailure;
    Future<void> attemptCleanup(Future<void> Function() action) async {
      try {
        await action();
      } on TimetablePersistenceException catch (error) {
        firstFailure ??= error;
      }
    }

    try {
      // 每项清理独立尝试，磁盘失败不能让后面的数据继续残留。
      await attemptCleanup(() => _inScope(TimetableStore.clearJwxtSnapshot));
      if (hadJwxtExams) {
        await attemptCleanup(
          () => _inScope(
            () => ScheduleStore.saveEventsAndOtherColors(
              _scheduleEvents,
              _otherColors,
              clearJwxtExamsBaselinePending: _jwxtExamsBaselinePending,
            ),
          ),
        );
      } else if (_jwxtExamsBaselinePending) {
        await attemptCleanup(
          () =>
              _inScope(() => ScheduleStore.saveJwxtExamsBaselinePending(false)),
        );
      }
      _jwxtExamsBaselinePending = false;
      // 不序列化内存设置：只从原始 settings.json 中删除学期键。
      if (activeStorageId == kDefaultScheduleId) {
        await attemptCleanup(TimetableStore.removeTermSettingKeys);
      }
    } finally {
      _clampViewingWeek();
      try {
        await updateNextDayReminder();
      } finally {
        notifyListeners();
      }
    }
    if (firstFailure case final error?) throw error;
  }

  /// 兼容旧调用（页面 DEBUG 菜单）：仅清教务课程，手动课程保留。
  Future<void> clearCourses() => clearJwxtCourses();

  /// 退出登录/解绑门户：默认清掉教务课程、snapshot 磁盘缓存与教务学期元数据，
  /// 手动课程与展示设置保留；从 WakeUp 导入的他人课表保留。
  /// [clearJwxt] 为 false 时仅更新登录态，教务缓存与手动课程都保留。
  Future<void> handleLogout({bool clearJwxt = true}) async {
    _portalBound = false;
    // 解绑后不再残留上次同步失败的状态，免得打开课表又弹失败提示。
    _statusMessage = null;
    _syncStatus = TimetableSyncStatus.idle;
    _syncFailure = TimetableSyncFailure.none;
    _lastAutoSyncFailed = false;
    _lastSyncOutcome = null;
    try {
      await _setPortalSessionExpired(false);
      // 调课记录保留（jwxt §3.2 第 7 条），重新绑定同步后重新套用。
      if (clearJwxt) {
        if (activeStorageId == kDefaultScheduleId) {
          await clearJwxtCourses();
        } else {
          if (primaryScheduleMeta?.isOwnSchedule == true) {
            await clearJwxtCourses();
          }
          if (_isPrimaryHost) {
            final defScoped = _scopedControllers.remove(kDefaultScheduleId);
            if (defScoped != null) {
              await defScoped.clearJwxtCourses();
            } else {
              await TimetableStore.withScheduleScope(
                kDefaultScheduleId,
                () async {
                  await TimetableChangeLogStore.clear();
                  await TimetableStore.clearJwxtSnapshot();
                  final existingEvents = await ScheduleStore.readEvents();
                  final otherColors = await ScheduleStore.readOtherColors();
                  final keptEvents = [
                    for (final e in existingEvents)
                      if (!e.isFromJwxt) e,
                  ];
                  if (keptEvents.length != existingEvents.length) {
                    await ScheduleStore.saveEventsAndOtherColors(
                      keptEvents,
                      otherColors,
                      clearJwxtExamsBaselinePending: true,
                    );
                  } else {
                    await ScheduleStore.saveJwxtExamsBaselinePending(false);
                  }
                  await TimetableStore.removeTermSettingKeys();
                },
              );
            }
          }
        }
        if (_isPrimaryHost) {
          await _clearHistoricalJwxtOnLogout();
        }
      }
    } finally {
      notifyListeners();
      _fireScheduleChanged(ScheduleChangeReason.unbind);
    }
  }

  Future<void> _clearHistoricalJwxtOnLogout() async {
    _historicalDiscoveryAttempted = false;
    final historicalIds = [
      for (final s in _schedulesIndex.schedules)
        if (s.isOwnSchedule && s.id != kDefaultScheduleId) s.id,
    ];
    if (historicalIds.isEmpty &&
        _schedulesIndex.checkedEmptyTerms.isEmpty &&
        _schedulesIndex.currentTermCode.isEmpty) {
      return;
    }
    for (final id in historicalIds) {
      _scopedControllers.remove(id);
      try {
        await TimetableStore.deleteScheduleDirectory(id);
      } catch (_) {}
    }
    final primaryWasCleared = historicalIds.contains(_primaryScheduleId);
    if (primaryWasCleared) {
      _primaryScheduleId = kDefaultScheduleId;
    }
    if (historicalIds.contains(_viewingScheduleId)) {
      _viewingScheduleId = _primaryScheduleId;
    }
    final remaining = [
      for (final s in _schedulesIndex.schedules)
        if (!historicalIds.contains(s.id))
          if (s.id == kDefaultScheduleId)
            s.copyWith(
              termCode: '',
              name: s.customName ? s.name : '当前学期',
              clearSyncedAt: true,
              courseCount: 0,
            )
          else
            s,
    ];
    _schedulesIndex = SchedulesIndex(
      primaryScheduleId: _primaryScheduleId,
      currentTermCode: '',
      schedules: List.unmodifiable(remaining),
    );
    if (await TimetableStore.readSchedulesIndex() != null ||
        remaining.any((s) => s.isImportedSchedule)) {
      await TimetableStore.saveSchedulesIndex(_schedulesIndex);
    }
    if (primaryWasCleared) {
      await _reloadFromDisk();
      await _reloadPendingChanges(resetRevision: true);
      _colorMap = null;
      await _loadColorMap();
    }
  }

  // ---- 多课表管理：切换 / 主课表 / 命名 / 删除 / WakeUp 导入 / 往年学期 ----

  Future<TimetableController> _ensureScopedController(String id) async {
    final host = _manager ?? this;
    final ctrl = host._scopedControllers[id] ??= TimetableController._(
      id,
      host,
    );
    await ctrl.ensureStarted();
    return ctrl;
  }

  Future<void> _ensureIndexSeeded() async {
    if (_schedulesIndex.schedules.isNotEmpty) return;
    _schedulesIndex = SchedulesIndex(
      primaryScheduleId: _primaryScheduleId,
      currentTermCode: _snapshot.settings.termCode,
      schedules: [
        ScheduleMetadata(
          id: kDefaultScheduleId,
          name: _deriveDefaultScheduleName(),
          customName:
              _snapshot.settings.scheduleName.trim().isNotEmpty &&
              _snapshot.settings.scheduleName.trim() != '我的课表' &&
              _snapshot.settings.scheduleName.trim() !=
                  formatTermScheduleName(_snapshot.settings.termCode),
          sourceKind: TimetableSourceKind.jwxt,
          termCode: _snapshot.settings.termCode,
          createdAt: DateTime.now(),
          syncedAt: _snapshot.syncedAt,
          courseCount: _snapshot.courses.length,
        ),
      ],
    );
  }

  List<ScheduleMetadata> _sortedSchedules(List<ScheduleMetadata> raw) {
    final own = <ScheduleMetadata>[];
    final imported = <ScheduleMetadata>[];
    for (final s in raw) {
      if (s.isOwnSchedule) {
        own.add(s);
      } else {
        imported.add(s);
      }
    }
    own.sort((a, b) {
      final ta = a.termCode.trim();
      final tb = b.termCode.trim();
      if (ta.isNotEmpty && tb.isNotEmpty) {
        final byTerm = compareTermCodes(tb, ta);
        if (byTerm != 0) return byTerm;
      } else if (ta.isNotEmpty || tb.isNotEmpty) {
        return tb.isNotEmpty ? 1 : -1;
      }
      if (a.id == kDefaultScheduleId && b.id != kDefaultScheduleId) return -1;
      if (b.id == kDefaultScheduleId && a.id != kDefaultScheduleId) return 1;
      final ca = a.createdAt;
      final cb = b.createdAt;
      if (ca != null && cb != null) return cb.compareTo(ca);
      return a.id.compareTo(b.id);
    });
    return [...own, ...imported];
  }

  /// 按当前学期同步后或用户打开切换面板时，在后台静默自动发现并拉取往年有课学期（幂等且不阻断当前流程）。
  Future<void> triggerHistoricalDiscoveryIfNeeded() {
    final host = _manager ?? this;
    return host._autoDiscoverHistoricalTerms(
      bindingRevision: host._portalBindingRevision,
    );
  }

  Future<void> _autoDiscoverHistoricalTerms({
    required int bindingRevision,
  }) async {
    if (!_isPrimaryHost) return;
    if (_historicalDiscoveryInFlight != null) {
      return _historicalDiscoveryInFlight!;
    }
    if (_historicalDiscoveryAttempted) return;
    if (!_portalBound || currentTermCode.trim().isEmpty) return;
    late final Future<void> task;
    task = () async {
      _historicalDiscoveryAttempted = true;
      try {
        final added = await _discoverHistoricalTermsImpl();
        if (bindingRevision != _portalBindingRevision) return;
        if (added.isNotEmpty) notifyListeners();
      } catch (_) {
        // 自动发现失败时重置标记，以便下次同步或打开切换器时可再次尝试。
        if (bindingRevision == _portalBindingRevision) {
          _historicalDiscoveryAttempted = false;
        }
      } finally {
        if (identical(_historicalDiscoveryInFlight, task)) {
          _historicalDiscoveryInFlight = null;
        }
      }
    }();
    _historicalDiscoveryInFlight = task;
    return task;
  }

  Future<void> _upsertScheduleMetadata(
    ScheduleMetadata meta, {
    String? currentTermCode,
    bool persist = true,
  }) async {
    await _ensureIndexSeeded();
    final list = [..._schedulesIndex.schedules];
    final idx = list.indexWhere((s) => s.id == meta.id);
    if (idx >= 0) {
      list[idx] = meta;
    } else {
      list.add(meta);
    }
    final sorted = _sortedSchedules(list);
    _schedulesIndex = _schedulesIndex.copyWith(
      primaryScheduleId: _primaryScheduleId,
      currentTermCode: currentTermCode ?? _schedulesIndex.currentTermCode,
      schedules: List.unmodifiable(sorted),
    );
    if (persist) {
      await TimetableStore.saveSchedulesIndex(_schedulesIndex);
    }
    notifyListeners();
  }

  /// 切换课表页当前浏览的课表（不影响首页/小组件/提醒绑定的主课表）。
  Future<void> switchViewingSchedule(String scheduleId) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    if (scheduleId != kDefaultScheduleId &&
        host.scheduleMetaOf(scheduleId) == null) {
      return;
    }
    if (scheduleId != host._primaryScheduleId) {
      await host._ensureScopedController(scheduleId);
    }
    host._viewingScheduleId = scheduleId;
    host.notifyListeners();
  }

  /// 将指定课表设为主课表（驱动首页卡片、桌面小组件、上课提醒与校园地图），并切过去查看。
  Future<void> setPrimarySchedule(String scheduleId) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    if (scheduleId != kDefaultScheduleId &&
        host.scheduleMetaOf(scheduleId) == null) {
      return;
    }
    final primaryChanged = host._primaryScheduleId != scheduleId;
    if (primaryChanged) {
      host._primaryScheduleId = scheduleId;
      host._schedulesIndex = host._schedulesIndex.copyWith(
        primaryScheduleId: scheduleId,
      );
      await TimetableStore.saveSchedulesIndex(host._schedulesIndex);
      // 原主课表如果刚好被缓存为子控制器，释放后按新主课表重新加载 host。
      host._scopedControllers.remove(scheduleId);
      final includeChangeLog = !TimetableChangeLogStore.hasDebugMemory;
      await host._reloadFromDisk(includeChangeLog: includeChangeLog);
      final preloadedChanges = host._preloadedSyncChangesRaw;
      host._preloadedSyncChangesRaw = null;
      await host._reloadPendingChanges(
        preloadedChanges: preloadedChanges,
        resetRevision: true,
      );
      host._colorMap = null;
      await host._loadColorMap();
      host._lastSeenCurrentWeek = host.currentWeek;
    }
    host._viewingScheduleId = scheduleId;
    if (primaryChanged) {
      host._viewingWeekNotifier.value = host._defaultViewingWeek;
    }
    host.notifyListeners();
    host._fireScheduleChanged(ScheduleChangeReason.settings);
  }

  /// 重命名任意课表（自己的教务课表或导入课表），之后同步不覆盖自定义名称。
  Future<void> renameSchedule(String scheduleId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    final existing = host.scheduleMetaOf(scheduleId);
    if (existing == null) return;
    final updated = existing.copyWith(name: trimmed, customName: true);
    await host._upsertScheduleMetadata(updated, persist: true);

    if (scheduleId == host._primaryScheduleId) {
      final snap = host._snapshot.copyWith(
        settings: host._snapshot.settings.copyWith(scheduleName: trimmed),
      );
      await host._inScope(() => TimetableStore.saveSnapshot(snap));
      if (scheduleId == kDefaultScheduleId) {
        await TimetableStore.mergeSettingsChanges(
          host._snapshot.settings,
          snap.settings,
        );
      }
      host._snapshot = snap;
      host.notifyListeners();
    } else if (host._scopedControllers[scheduleId] case final scoped?) {
      final snap = scoped._snapshot.copyWith(
        settings: scoped._snapshot.settings.copyWith(scheduleName: trimmed),
      );
      await scoped._inScope(() => TimetableStore.saveSnapshot(snap));
      if (scheduleId == kDefaultScheduleId) {
        await TimetableStore.mergeSettingsChanges(
          scoped._snapshot.settings,
          snap.settings,
        );
      }
      scoped._snapshot = snap;
      scoped.notifyListeners();
    } else {
      await TimetableStore.withScheduleScope(scheduleId, () async {
        final snap = await TimetableStore.readSnapshot();
        if (snap != null) {
          final next = snap.copyWith(
            settings: snap.settings.copyWith(scheduleName: trimmed),
          );
          await TimetableStore.saveSnapshot(next);
        }
      });
    }
  }

  /// 删除非默认课表（如导入的他人课表或往年学期缓存）。
  /// 若删除的刚好是主课表或当前浏览课表，则回退到默认课表。
  Future<bool> deleteSchedule(String scheduleId) async {
    if (scheduleId == kDefaultScheduleId) return false;
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    if (host.scheduleMetaOf(scheduleId) == null) return false;

    final wasPrimary = host._primaryScheduleId == scheduleId;
    final wasViewing = host._viewingScheduleId == scheduleId;

    host._scopedControllers.remove(scheduleId);
    await TimetableStore.deleteScheduleDirectory(scheduleId);
    final nextList = [
      for (final s in host._schedulesIndex.schedules)
        if (s.id != scheduleId) s,
    ];
    if (wasPrimary) {
      host._primaryScheduleId = kDefaultScheduleId;
    }
    if (wasViewing) {
      host._viewingScheduleId = host._primaryScheduleId;
    }
    host._schedulesIndex = host._schedulesIndex.copyWith(
      primaryScheduleId: host._primaryScheduleId,
      schedules: List.unmodifiable(nextList),
    );
    await TimetableStore.saveSchedulesIndex(host._schedulesIndex);
    if (wasPrimary) {
      host._scopedControllers.remove(kDefaultScheduleId);
      final includeChangeLog = !TimetableChangeLogStore.hasDebugMemory;
      await host._reloadFromDisk(includeChangeLog: includeChangeLog);
      final preloadedChanges = host._preloadedSyncChangesRaw;
      host._preloadedSyncChangesRaw = null;
      await host._reloadPendingChanges(
        preloadedChanges: preloadedChanges,
        resetRevision: true,
      );
      host._colorMap = null;
      await host._loadColorMap();
      host._lastSeenCurrentWeek = host.currentWeek;
      host._viewingWeekNotifier.value = host._defaultViewingWeek;
      host._fireScheduleChanged(ScheduleChangeReason.settings);
    }
    host.notifyListeners();
    return true;
  }

  /// 将解析后的 WakeUp 课表保存为独立的「导入课表」，并切换到该课表查看。
  Future<ScheduleMetadata> importWakeupSchedule(
    WakeupImportResult result, {
    required String name,
    bool setAsPrimary = false,
  }) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    final trimmedName = name.trim().isEmpty ? result.defaultName : name.trim();
    String id;
    do {
      id = sanitizeScheduleId(
        'wakeup_${DateTime.now().millisecondsSinceEpoch}_${host._importSeq++}',
      );
    } while (host.scheduleMetaOf(id) != null);

    final periods = result.snapshot.periods.isEmpty
        ? defaultPeriods()
        : result.snapshot.periods;
    final snapSettings = result.snapshot.settings
        .withDisplayPrefsFrom(host.settings)
        .copyWith(scheduleName: trimmedName);
    final snapshot = result.snapshot.copyWith(
      periods: periods,
      settings: snapSettings,
      clearSyncedAt: true,
    );
    final scheme = coursePaletteSchemeOf(host.settings.paletteScheme);
    final adaptedCourses = <Course>[
      for (final c in snapshot.courses)
        if (result.userColors[c.id] case final rawArgb?)
          c.copyWith(
            colorIndex: adaptedPaletteIndexForArgb(rawArgb, scheme: scheme),
          )
        else
          c,
    ];
    final adaptedSnapshot = snapshot.copyWith(
      courses: List.unmodifiable(adaptedCourses),
    );
    final colorMap = assignCourseColors(adaptedCourses, scheme: scheme);

    await TimetableStore.withScheduleScope(id, () async {
      await TimetableStore.writeBatch(() async {
        await TimetableStore.saveSnapshot(adaptedSnapshot);
        await TimetableStore.saveCourseColors(scheme, colorMap);
        if (result.exams.isNotEmpty) {
          await ScheduleStore.saveEvents(result.exams);
        }
      });
    });

    final meta = ScheduleMetadata(
      id: id,
      name: trimmedName,
      customName: true,
      sourceKind: TimetableSourceKind.wakeupImport,
      createdAt: DateTime.now(),
      courseCount: snapshot.courses.length,
    );
    await host._upsertScheduleMetadata(meta, persist: true);
    if (setAsPrimary) {
      await host.setPrimarySchedule(id);
    } else {
      await host.switchViewingSchedule(id);
    }
    return meta;
  }

  /// 将考试裁剪到目标学期的合理日期窗内（仅在已知开学日且用于历史学期时启用，防止无 XNXQDM 的跨学期数据污染）。
  List<ScheduleEvent> _filterExamsToTermWindow(
    List<ScheduleEvent> exams,
    TimetableSettings termSettings,
  ) {
    final start = termSettings.termStartDate;
    if (start == null) return exams;
    final weeks = termSettings.maxWeeks > 0 ? termSettings.maxWeeks : 20;
    final minDate = start.subtract(const Duration(days: 30));
    final maxDate = start.add(Duration(days: (weeks + 8) * 7));
    return [
      for (final e in exams)
        if (!e.date.isBefore(minDate) && !e.date.isAfter(maxDate)) e,
    ];
  }

  /// 查询并筛选教务可选学年学期列表（按学号推导的入学年份过滤，且剔除拉取不到或无课的学期）。
  Future<List<JwxtTermOption>> fetchAvailableJwxtTerms({
    bool refresh = false,
  }) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    final rawOptions = await fetchAvailableTerms();
    final enrollmentYear = await enrollmentYearCheck();
    final curr = host.currentTermCode.trim();
    final candidates = [
      for (final opt in rawOptions)
        if (opt.termCode.trim().isNotEmpty &&
            isTermAtOrAfterEnrollment(
              opt.termCode,
              enrollmentYear: enrollmentYear,
            ) &&
            (curr.isEmpty || compareTermCodes(opt.termCode, curr) <= 0))
          opt,
    ]..sort((a, b) => compareTermCodes(b.termCode, a.termCode));

    final emptyTerms = refresh
        ? <String>[]
        : List<String>.of(host._schedulesIndex.checkedEmptyTerms);
    final available = <JwxtTermOption>[];
    for (final opt in candidates) {
      final term = opt.termCode.trim();
      if (curr.isNotEmpty && term == curr) {
        available.add(opt);
        continue;
      }
      final id = sanitizeScheduleId('jwxt_$term');
      final existing = host.scheduleMetaOf(id);
      if (existing != null && (existing.courseCount ?? 0) > 0) {
        available.add(opt);
        continue;
      }
      if (!refresh && emptyTerms.contains(term)) {
        continue;
      }
      try {
        final snap = await fetchHistoricalSnapshot(
          term,
          baseSettings: host.settings.copyWith(clearTermStart: true),
        );
        final jwxtCourses = [
          for (final c in snap.courses)
            if (c.source == CourseSource.jwxt) c,
        ];
        if (jwxtCourses.isEmpty) {
          if (!emptyTerms.contains(term)) emptyTerms.add(term);
          continue;
        }
        emptyTerms.remove(term);
        host._probedHistoricalSnapshots[term] = snap;
        available.add(opt);
      } catch (e) {
        final failure = classifySyncError(e);
        if (failure == TimetableSyncFailure.sessionExpired ||
            (failure == TimetableSyncFailure.network && _isOffline(e))) {
          rethrow;
        }
        if (!emptyTerms.contains(term)) emptyTerms.add(term);
      }
    }
    if (!listEquals(emptyTerms, host._schedulesIndex.checkedEmptyTerms)) {
      host._schedulesIndex = host._schedulesIndex.copyWith(
        checkedEmptyTerms: List.unmodifiable(emptyTerms),
      );
      if (host._schedulesIndex.schedules.length > 1 ||
          emptyTerms.isNotEmpty ||
          await TimetableStore.readSchedulesIndex() != null) {
        await TimetableStore.saveSchedulesIndex(host._schedulesIndex);
      }
    }
    return available;
  }

  /// 手动拉取并保存指定往年学期课表（不会设为自动更新目标，也不覆盖当前学期）。
  Future<ScheduleMetadata> syncHistoricalTerm(String termCode) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    final trimmed = termCode.trim();
    final curr = host.currentTermCode;
    if (trimmed == curr && curr.isNotEmpty) {
      await host.syncFromJwxt();
      return host.scheduleMetaOf(kDefaultScheduleId)!;
    }
    final id = sanitizeScheduleId('jwxt_$trimmed');
    final existing = host.scheduleMetaOf(id);
    List<Course> prevHistCourses = const [];
    List<ScheduleEvent> prevHistExams = const [];
    var prevHistHasCourseBaseline = false;
    var prevHistHasExamBaseline = false;
    if (existing != null) {
      await TimetableStore.withScheduleScope(id, () async {
        final snap = await TimetableStore.readSnapshot();
        final eventsFile = await TimetableStore.fileFor(
          ScheduleStore.scheduleEventsFile,
        );
        final eventsRaw = eventsFile != null
            ? TimetableStore.readJsonFile(eventsFile)
            : const <String, dynamic>{};
        final events = ScheduleStore.parseEvents(eventsRaw);
        final examPending = ScheduleStore.parseJwxtExamsBaselinePending(
          eventsRaw,
        );
        prevHistCourses = [
          for (final c in snap?.courses ?? const <Course>[])
            if (c.source == CourseSource.jwxt) c,
        ];
        prevHistExams = [
          for (final e in events)
            if (e.isFromJwxt && e.isExam) e,
        ];
        final hadBaseline =
            snap?.syncedAt != null ||
            prevHistCourses.isNotEmpty ||
            prevHistExams.isNotEmpty;
        prevHistHasCourseBaseline = hadBaseline;
        prevHistHasExamBaseline = hadBaseline && !examPending;
      });
    }
    final name = existing?.customName == true
        ? existing!.name
        : formatTermScheduleName(trimmed);
    final cachedProbe = existing == null
        ? host._probedHistoricalSnapshots.remove(trimmed)
        : null;
    var snapshot =
        cachedProbe ??
        await fetchHistoricalSnapshot(
          trimmed,
          baseSettings: host.settings.copyWith(clearTermStart: true),
        );
    if (snapshot.periods.isEmpty) {
      snapshot = snapshot.copyWith(periods: defaultPeriods());
    }
    snapshot = snapshot.copyWith(
      courses: [
        for (final c in snapshot.courses)
          if (c.source == CourseSource.jwxt) c,
      ],
      settings: snapshot.settings
          .withDisplayPrefsFrom(host.settings)
          .copyWith(termCode: trimmed, scheduleName: name),
      syncedAt: DateTime.now(),
      clearError: true,
    );
    final scheme = coursePaletteSchemeOf(host.settings.paletteScheme);
    final colorMap = assignCourseColors(snapshot.courses, scheme: scheme);
    await TimetableStore.withScheduleScope(id, () async {
      await TimetableStore.writeBatch(() async {
        await TimetableStore.saveSnapshot(snapshot);
        await TimetableStore.saveCourseColors(scheme, colorMap);
      });
    });
    if (prevHistHasCourseBaseline) {
      try {
        await TimetableStore.withScheduleScope(
          id,
          () => TimetableSyncDiff.applyAfterFetch(
            previousJwxtCourses: prevHistCourses,
            newJwxtCourses: snapshot.courses,
            allowWhenOldEmpty: true,
            termStartDate: snapshot.settings.termStartDate,
            xnxqdm: trimmed,
            detectedAt: snapshot.syncedAt,
          ),
        );
      } catch (_) {}
    }
    // 尽力拉取该学期考试，按学期与时间窗过滤后保存（保留该课表内的非教务日程），失败记录考试基线待补。
    var histExamsSucceeded = false;
    List<ScheduleEvent> cleanedHistExams = const [];
    try {
      final exams = await fetchExams(trimmed);
      if (exams != null) {
        cleanedHistExams = _filterExamsToTermWindow([
          for (final e in exams)
            ExamParser.cleanImportedExam(
              e.copyWith(source: ScheduleSource.jwxt, kind: ScheduleKind.exam),
            ),
        ], snapshot.settings);
        await TimetableStore.withScheduleScope(id, () async {
          final existingEvents = await ScheduleStore.readEvents();
          final otherColors = await ScheduleStore.readOtherColors();
          final merged = [
            for (final e in existingEvents)
              if (!e.isFromJwxt) e,
            ...cleanedHistExams,
          ];
          await ScheduleStore.saveEventsAndOtherColors(
            merged,
            otherColors,
            clearJwxtExamsBaselinePending: true,
          );
        });
        histExamsSucceeded = true;
      }
    } catch (_) {}
    if (histExamsSucceeded) {
      if (prevHistHasExamBaseline) {
        try {
          await TimetableStore.withScheduleScope(
            id,
            () => TimetableSyncDiff.applyExamsAfterFetch(
              previousJwxtExams: prevHistExams,
              newJwxtExams: cleanedHistExams,
              allowWhenOldEmpty: true,
              xnxqdm: trimmed,
              detectedAt: snapshot.syncedAt,
            ),
          );
        } catch (_) {}
      }
    } else if (!prevHistHasExamBaseline) {
      try {
        await TimetableStore.withScheduleScope(
          id,
          () => ScheduleStore.saveJwxtExamsBaselinePending(true),
        );
      } catch (_) {}
    }

    final meta = ScheduleMetadata(
      id: id,
      name: name,
      customName: existing?.customName ?? false,
      sourceKind: TimetableSourceKind.jwxt,
      termCode: trimmed,
      createdAt: existing?.createdAt ?? DateTime.now(),
      syncedAt: snapshot.syncedAt,
      courseCount: snapshot.courses.length,
    );
    await host._upsertScheduleMetadata(meta, persist: true);
    if (id == host._primaryScheduleId) {
      await host.refreshLocal();
    } else if (host._scopedControllers[id] case final scoped?) {
      await scoped.refreshLocal();
    }
    return meta;
  }

  /// 发现并自动纳入近几个有课的往年教务学期（[forceRescan] 为 true 时重新拉取并探测全部候选学期）。
  Future<List<ScheduleMetadata>> discoverHistoricalTerms({
    int maxAcademicYears = 4,
    bool forceRescan = false,
  }) async {
    final host = _manager ?? this;
    final inFlight = host._historicalDiscoveryInFlight;
    if (inFlight != null) await inFlight;
    return host._discoverHistoricalTermsImpl(
      maxAcademicYears: maxAcademicYears,
      forceRescan: forceRescan,
    );
  }

  Future<List<ScheduleMetadata>> _discoverHistoricalTermsImpl({
    int maxAcademicYears = 4,
    bool forceRescan = false,
  }) async {
    final host = _manager ?? this;
    await host._ensureIndexSeeded();
    final curr = host.currentTermCode;
    if (curr.isEmpty) return const [];
    final options = await fetchAvailableTerms();
    final enrollmentYear = await enrollmentYearCheck();
    final candidates = [
      for (final opt in options)
        if (opt.termCode.isNotEmpty &&
            isTermAtOrAfterEnrollment(
              opt.termCode,
              enrollmentYear: enrollmentYear,
            ) &&
            isHistoricalTerm(opt.termCode, currentTermCode: curr))
          opt.termCode,
    ]..sort((a, b) => compareTermCodes(b, a));

    final added = <ScheduleMetadata>[];
    final emptyTerms = forceRescan
        ? <String>[]
        : List<String>.of(host._schedulesIndex.checkedEmptyTerms);
    var consecutiveEmpty = 0;
    final limit = maxAcademicYears * 3;
    for (final term in candidates.take(limit)) {
      final id = sanitizeScheduleId('jwxt_$term');
      final existing = host.scheduleMetaOf(id);
      if (!forceRescan && (existing != null || emptyTerms.contains(term))) {
        continue;
      }
      if (forceRescan && existing != null) {
        try {
          await host.syncHistoricalTerm(term);
        } catch (_) {}
        continue;
      }
      try {
        final snap = await fetchHistoricalSnapshot(
          term,
          baseSettings: host.settings.copyWith(clearTermStart: true),
        );
        final jwxtCourses = [
          for (final c in snap.courses)
            if (c.source == CourseSource.jwxt) c,
        ];
        if (jwxtCourses.isEmpty) {
          if (!emptyTerms.contains(term)) emptyTerms.add(term);
          consecutiveEmpty++;
          if (consecutiveEmpty >= 3) break;
          continue;
        }
        consecutiveEmpty = 0;
        final name = formatTermScheduleName(term);
        final prepared = snap.copyWith(
          courses: jwxtCourses,
          periods: snap.periods.isEmpty ? defaultPeriods() : snap.periods,
          settings: snap.settings
              .withDisplayPrefsFrom(host.settings)
              .copyWith(termCode: term, scheduleName: name),
          syncedAt: DateTime.now(),
          clearError: true,
        );
        final scheme = coursePaletteSchemeOf(host.settings.paletteScheme);
        final colorMap = assignCourseColors(prepared.courses, scheme: scheme);
        await TimetableStore.withScheduleScope(id, () async {
          await TimetableStore.writeBatch(() async {
            await TimetableStore.saveSnapshot(prepared);
            await TimetableStore.saveCourseColors(scheme, colorMap);
            await ScheduleStore.saveJwxtExamsBaselinePending(true);
          });
        });
        final meta = ScheduleMetadata(
          id: id,
          name: name,
          sourceKind: TimetableSourceKind.jwxt,
          termCode: term,
          createdAt: DateTime.now(),
          syncedAt: prepared.syncedAt,
          courseCount: prepared.courses.length,
        );
        await host._upsertScheduleMetadata(meta, persist: true);
        added.add(meta);
      } catch (_) {
        // 单个历史学期失败不影响继续发现或当前课表使用。
      }
    }
    if (!listEquals(emptyTerms, host._schedulesIndex.checkedEmptyTerms)) {
      host._schedulesIndex = host._schedulesIndex.copyWith(
        checkedEmptyTerms: List.unmodifiable(emptyTerms),
      );
      await TimetableStore.saveSchedulesIndex(host._schedulesIndex);
    }
    return added;
  }

  // ---- 手动课程 CRUD（只作用于 isManual 课程）----

  Future<T> _mutateManual<T>(Future<T> Function() action) async {
    final previous = _manualCourses;
    try {
      return await action();
    } on TimetablePersistenceException {
      _manualCourses = previous;
      _colorMap = null;
      _colorMapJwxt = null;
      _colorMapScheme = null;
      notifyListeners();
      rethrow;
    }
  }

  /// 新增手动课程；id 为空时自动生成。强制 source=manual。返回保存后的课程。
  Future<Course> addManualCourse(Course course) => _mutateManual(() async {
    final id = course.id.isEmpty || _idTaken(course.id)
        ? _newManualId()
        : course.id;
    final saved = course.copyWith(id: id, source: CourseSource.manual);
    _manualCourses = [..._manualCourses, saved];
    await _recomputeColors();
    await _persistManual();
    return manualCourseById(saved.id) ?? saved;
  });

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
  Future<Course> updateManualCourse(Course course) => _mutateManual(() async {
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
  });

  /// 删除手动课程；返回是否删除。教务课程 id 不会被删除（返回 false）。
  Future<bool> deleteManualCourse(String id) => _mutateManual(() async {
    final next = [
      for (final c in _manualCourses)
        if (c.id != id) c,
    ];
    if (next.length == _manualCourses.length) return false;
    _manualCourses = next;
    await _recomputeColors();
    if (_dateEdits.any((e) => e.courseId == id)) {
      _dateEdits = List.unmodifiable([
        for (final e in _dateEdits)
          if (e.courseId != id) e,
      ]);
      await _inScope(() => ScheduleStore.saveCourseDateEdits(_dateEdits));
    }
    await _persistManual();
    return true;
  });

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
    try {
      await _inScope(() => TimetableStore.saveManualCourses(_manualCourses));
    } on TimetablePersistenceException {
      _manualCourses = await _inScope(TimetableStore.readManualCourses);
      _colorMap = null;
      notifyListeners();
      rethrow;
    }
    _clampViewingWeek();
    notifyListeners();
    _fireScheduleChanged(reason);
  }

  /// 统一保存课程表单；仅传播相对打开表单时真正改变的字段。
  ///
  /// [applyWeeks] 为 null 时编辑当前上课时段的全部安排，并用 [courseWeeks]
  /// 替换重复周次；非 null 时只修改选中周的这次课。名称、类型、颜色遵循同一范围，
  /// 同门课的其他时段不受影响。[colorChanged] 区分不改颜色与显式恢复默认色。
  Future<Course?> saveCourseForm({
    Course? initial,
    CourseSlot? initialSlot,
    GridCell? cell,
    required String name,
    required String teacher,
    required String location,
    required String note,
    required CourseKind kind,
    required int day,
    required int startNode,
    required int endNode,
    required List<int> courseWeeks,
    List<int>? applyWeeks,
    int? userArgb,
    bool colorChanged = false,
  }) => _log.operation<Course?>('course.save', () async {
    final weeks = courseWeeks.where((w) => w >= 1 && w <= 104).toSet();
    if (kind == CourseKind.exam ||
        name.trim().isEmpty ||
        weeks.isEmpty ||
        day < 1 ||
        day > 7 ||
        startNode < 1 ||
        endNode < startNode ||
        endNode > lastPeriod ||
        (applyWeeks != null && applyWeeks.isEmpty)) {
      return null;
    }
    name = name.trim();
    teacher = teacher.trim();
    location = location.trim();
    note = note.trim();
    final openingCourse = cell?.course ?? initial;
    final openingSlot = cell?.slot ?? initialSlot ?? initial?.slots.firstOrNull;
    if (openingCourse == null) {
      return addManualCourse(
        Course(
          id: '',
          name: name,
          slots: [
            CourseSlot(
              day: day,
              startNode: startNode,
              endNode: endNode,
              weeks: weeksToBits(weeks, totalWeeks),
              teacher: teacher,
              location: location,
              note: note,
              kind: kind,
              color: userArgb == null ? null : userArgb | 0xFF000000,
            ),
          ],
        ),
      );
    }
    if (openingSlot == null) return null;
    final base = cell == null ? null : baseOccurrenceOf(cell);
    final current =
        base?.course ??
        courses.where((course) => course.id == openingCourse.id).firstOrNull;
    if (current == null) return null;
    final index =
        base?.slotIndex ?? _indexOfEqualSlot(current.slots, openingSlot, -1);
    if (index < 0 || index >= current.slots.length) return null;
    final original = current.slots[index];
    final nameChanged =
        name != (openingSlot.nameOverride ?? openingCourse.name).trim();
    final teacherChanged = teacher != openingSlot.teacher.trim();
    final locationChanged = location != openingSlot.location.trim();
    final noteChanged = note != openingSlot.note.trim();
    final kindChanged =
        kind != courseKindOf(course: openingCourse, slot: openingSlot);
    final dayChanged = day != openingSlot.day;
    final startChanged = startNode != openingSlot.startNode;
    final endChanged = endNode != openingSlot.endNode;
    final timeChanged = dayChanged || startChanged || endChanged;
    final repeatChanged = !setEquals(weeks, weeksOf(original).toSet());
    // 改名时将进入表单时确认的类型固定下来，避免“体育”等名称触发自动识别改变。
    final selectedKind = kindChanged || nameChanged ? kind : null;
    if (!nameChanged &&
        !teacherChanged &&
        !locationChanged &&
        !noteChanged &&
        !kindChanged &&
        !timeChanged &&
        !colorChanged &&
        !(applyWeeks == null && repeatChanged)) {
      return current.forSlot(original);
    }
    if (applyWeeks != null) {
      if (cell?.date == null || !cell!.activeThisWeek) return null;
      final selected = applyWeeks.where(original.hasClassInWeek).toSet();
      if (selected.isEmpty) return null;
      final next = [..._dateEdits];
      for (final week in selected) {
        final sourceDate = dateOfColumn(week, original.day);
        final date = swapPartnerIn(_daySwaps, sourceDate) ?? sourceDate;
        final displayWeek = _weekOfDate(date);
        CourseDateEdit? old;
        CourseDateEdit? inherited;
        for (final edit in next) {
          if (edit.scope == DateEditScope.oneDay &&
              edit.matches(
                current.id,
                date,
                original.startNode,
                original.endNode,
              )) {
            old = edit;
          } else if (edit.matchesWeek(
            current.id,
            displayWeek,
            date.weekday,
            original.startNode,
            original.endNode,
          )) {
            inherited = edit;
          }
        }
        final previous = old ?? inherited;
        if (previous?.isDelete == true) continue;
        var record =
            old ??
            CourseDateEdit(
              id: 'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
              courseId: current.id,
              date: date,
              origStart: original.startNode,
              origEnd: original.endNode,
              name: inherited?.name,
              teacher: inherited?.teacher,
              location: inherited?.location,
              note: inherited?.note,
              courseKind: inherited?.courseKind,
              color: inherited?.color,
              useDefaultColor: inherited?.useDefaultColor ?? false,
              toDate: inherited?.toDate == null
                  ? null
                  : mondayOfWeek(date)
                        .add(Duration(days: inherited!.toDate!.weekday - 1)),
              toStart: inherited?.toStart,
              toEnd: inherited?.toEnd,
              createdAt: DateTime.now().toIso8601String(),
            );
        record = record.copyWith(
          name: nameChanged ? name : null,
          teacher: teacherChanged ? teacher : null,
          location: locationChanged ? location : null,
          note: noteChanged ? note : null,
          courseKind: selectedKind,
          color: colorChanged && userArgb != null
              ? userArgb | 0xFF000000
              : null,
          clearColor: colorChanged && userArgb == null,
          useDefaultColor: colorChanged ? userArgb == null : null,
        );
        if (timeChanged) {
          final targetDate = dayChanged
              ? mondayOfWeek(date).add(Duration(days: day - 1))
              : record.toDate ?? date;
          final targetStart = startChanged
              ? startNode
              : record.toStart ?? original.startNode;
          final targetEnd = endChanged
              ? endNode
              : record.toEnd ?? original.endNode;
          if (targetStart > targetEnd) return null;
          record = record.copyWith(
            toDate: targetDate,
            toStart: targetStart,
            toEnd: targetEnd,
          );
          if (!record.movesTime) record = record.copyWith(clearMove: true);
        }
        if (old != null) next.removeWhere((edit) => edit.id == old!.id);
        if (!record.isEmpty) next.add(record);
      }
      await _setDateEdits(next);
      return current.forSlot(original);
    }
    final replacement = original.copyWith(
      day: dayChanged ? day : null,
      startNode: startChanged ? startNode : null,
      endNode: endChanged ? endNode : null,
      weeks: repeatChanged ? weeksToBits(weeks, original.weeks.length) : null,
      weeksLabel: repeatChanged ? '' : null,
      nameOverride: nameChanged ? name : null,
      teacher: teacherChanged ? teacher : null,
      location: locationChanged ? location : null,
      note: noteChanged ? note : null,
      kind: selectedKind,
      color: colorChanged && userArgb != null ? userArgb | 0xFF000000 : null,
      clearColor: colorChanged && userArgb == null,
      useDefaultColor: colorChanged ? userArgb == null : null,
      clearSplitFrom: timeChanged,
    );
    if (replacement.endNode < replacement.startNode) return null;
    final saved = await _replaceFormSlot(current, index, replacement);
    if (saved == null) return null;
    // 全部周的字段编辑只让同一时段内对应局部字段让位；其他备注、颜色和调课保留。
    final next = <CourseDateEdit>[];
    var touched = false;
    for (final edit in _dateEdits) {
      if (edit.courseId != current.id ||
          edit.isWeekdayMatch ||
          edit.origStart != original.startNode ||
          edit.origEnd != original.endNode) {
        next.add(edit);
        continue;
      }
      final sourceDate = swapPartnerIn(_daySwaps, edit.date) ?? edit.date;
      final matchingDay = edit.isWeeksScoped
          ? edit.date.weekday == original.day
          : sourceDate.weekday == original.day &&
                original.hasClassInWeek(_weekOfDate(sourceDate));
      if (!matchingDay) {
        next.add(edit);
        continue;
      }
      var scopedEdit = edit;
      if (edit.isWeeksScoped) {
        final affected = edit.weeks.where(original.hasClassInWeek).toList();
        if (affected.isEmpty) {
          next.add(edit);
          continue;
        }
        final untouched = edit.weeks
            .where((week) => !original.hasClassInWeek(week))
            .toList();
        if (untouched.isNotEmpty) {
          next.add(edit.copyWith(weeks: untouched));
          scopedEdit = CourseDateEdit.tryParse({
            ...edit.toJson(),
            'id':
                'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
            'weeks': affected,
          })!;
        }
      }
      touched = true;
      var updated = scopedEdit.copyWith(
        clearName: nameChanged,
        clearTeacher: teacherChanged,
        clearLocation: locationChanged,
        clearNote: noteChanged,
        clearCourseKind: selectedKind != null,
        clearColor: colorChanged,
        useDefaultColor: colorChanged ? false : null,
        clearMove: timeChanged,
      );
      if (repeatChanged) {
        if (edit.isWeeksScoped) {
          final remaining = scopedEdit.weeks.where(weeks.contains).toList();
          if (remaining.isEmpty) continue;
          updated = updated.copyWith(weeks: remaining);
        } else if (!weeks.contains(_weekOfDate(sourceDate))) {
          continue;
        }
      }
      if (timeChanged) {
        final newSource = dateOfColumn(
          _weekOfDate(sourceDate),
          replacement.day,
        );
        final newDate = swapPartnerIn(_daySwaps, newSource) ?? newSource;
        updated = CourseDateEdit.tryParse({
          ...updated.toJson(),
          'date': dateKeyOf(newDate),
          'origStart': replacement.startNode,
          'origEnd': replacement.endNode,
        })!;
      }
      if (!updated.isEmpty) next.add(updated);
    }
    if (touched) await _setDateEdits(next);
    return saved.forSlot(replacement);
  }, resultFields: _savedResultFields);

  /// 将当前单周的一次课程安排移为独立考试，连续节次仍算同一次安排。
  /// 原课程仅删除这一次；考试之后的编辑、删除不再关联原课程。
  /// 从底层时段移除这一周，撤销整天调课也不会重新出现原课程。
  /// 全部相关文件批量保存成功后才发布内存变更；保存失败时保留原课程与日程。
  Future<ScheduleEvent?> convertCourseOccurrenceToExam({
    required GridCell cell,
    required String title,
    required String location,
    required String note,
    required int day,
    required int startNode,
    required int endNode,
  }) => _log.operation<ScheduleEvent?>('course.convert_to_exam', () async {
    final key = _occurrenceKey(cell);
    final base = baseOccurrenceOf(cell);
    if (key == null ||
        base == null ||
        title.trim().isEmpty ||
        day < 1 ||
        day > 7 ||
        startNode < 1 ||
        endNode < startNode ||
        endNode > lastPeriod) {
      return null;
    }
    // 表单保存前该次课可能已经删除或挪走，不能用旧格子重复生成考试。
    final stillPresent =
        cellsForDay(_weekOfDate(cell.date!), cell.date!.weekday).any(
          (current) => current.activeThisWeek && _occurrenceKey(current) == key,
        );
    final start = TimeOfDayMinutes.tryParse(periodStart(startNode));
    final end = TimeOfDayMinutes.tryParse(periodEnd(endNode));
    if (!stillPresent ||
        start == null ||
        end == null ||
        end.compareTo(start) <= 0) {
      return null;
    }
    final original = base.course.slots[base.slotIndex];
    final replacement = original.copyWith(
      weeks: weeksToBits(
        weeksOf(original).where((week) => week != base.week),
        original.weeks.length,
      ),
      weeksLabel: '',
    );
    List<Course>? nextManual;
    Map<String, CourseEdit>? nextCourseEdits;
    if (base.course.isManual) {
      final stored = manualCourseById(base.course.id);
      if (stored == null) return null;
      final index = _indexOfEqualSlot(stored.slots, original, base.slotIndex);
      if (index < 0) return null;
      final slots = [...stored.slots]..[index] = replacement;
      nextManual = List.unmodifiable([
        for (final course in _manualCourses)
          if (course.id == stored.id) stored.copyWith(slots: slots) else course,
      ]);
    } else {
      final raw = _jwxtOriginal(base.course.id, original, base.slotIndex);
      final edit = _editBase(base.course.id);
      if (raw == null || edit == null) return null;
      final replacements = <CourseSlot>[];
      for (var index = 0; index < base.course.slots.length; index++) {
        final slot = base.course.slots[index];
        final origin = _jwxtOriginal(base.course.id, slot, index);
        if (origin == null || !_sameSlot(origin, raw)) continue;
        replacements.add(index == base.slotIndex ? replacement : slot);
      }
      nextCourseEdits = Map.unmodifiable({
        ..._courseEdits,
        base.course.id: _withJwxtSlotReplacements(raw, replacements, edit),
      });
    }
    final exam = ScheduleEvent(
      id: 'event-${DateTime.now().microsecondsSinceEpoch}-${_eventSeq++}',
      kind: ScheduleKind.exam,
      source: ScheduleSource.manual,
      title: title.trim(),
      date: mondayOfWeek(cell.date!).add(Duration(days: day - 1)),
      start: start,
      end: end,
      location: location.trim(),
      note: note.trim(),
      courseCode: cell.course.code.isEmpty ? null : cell.course.code,
    );
    final previousDateEdits = _dateEdits;
    final previousEvents = _scheduleEvents;
    final previousManual = _manualCourses;
    final previousCourseEdits = _courseEdits;
    final previousSnapshot = _snapshot;
    final previousOverrides = _overrides;
    final previousDaySwaps = _daySwaps;
    final nextDateEdits = List<CourseDateEdit>.unmodifiable([
      for (final edit in previousDateEdits)
        if (edit.scope != DateEditScope.oneDay ||
            !edit.matches(key.courseId, key.date, key.start, key.end))
          edit,
    ]);
    final nextEvents = List<ScheduleEvent>.unmodifiable([
      ...previousEvents,
      exam,
    ]);
    await _inScope(
      () => TimetableStore.writeBatch(() async {
        if (nextManual != null) {
          await TimetableStore.saveManualCourses(nextManual);
        }
        if (nextCourseEdits != null) {
          await ScheduleStore.saveCourseEdits(nextCourseEdits);
        }
        if (nextDateEdits.length != previousDateEdits.length) {
          await ScheduleStore.saveCourseDateEdits(nextDateEdits);
        }
        await ScheduleStore.saveEvents(nextEvents);
        if (!identical(_dateEdits, previousDateEdits) ||
            !identical(_scheduleEvents, previousEvents) ||
            !identical(_manualCourses, previousManual) ||
            !identical(_courseEdits, previousCourseEdits) ||
            !identical(_snapshot, previousSnapshot) ||
            !identical(_overrides, previousOverrides) ||
            !identical(_daySwaps, previousDaySwaps)) {
          throw const TimetablePersistenceException();
        }
      }),
    );
    if (nextManual != null) _manualCourses = nextManual;
    if (nextCourseEdits != null) _courseEdits = nextCourseEdits;
    _dateEdits = nextDateEdits;
    _scheduleEvents = nextEvents;
    _clampViewingWeek();
    _notifyEvents();
    return exam;
  }, resultFields: _savedResultFields);

  /// 替换一个显示时段，手动课更新本地课程，教务课保存原时段的差异覆盖。
  Future<Course?> _replaceFormSlot(
    Course course,
    int index,
    CourseSlot replacement,
  ) async {
    final original = course.slots[index];
    if (course.isManual) {
      final stored = manualCourseById(course.id);
      if (stored == null) return null;
      final target = _indexOfEqualSlot(stored.slots, original, index);
      if (target < 0) return null;
      final slots = [...stored.slots]..[target] = replacement;
      return updateManualCourse(stored.copyWith(slots: _mergeFormSlots(slots)));
    }
    final raw = _jwxtOriginal(course.id, original, index);
    final edit = _editBase(course.id);
    if (raw == null || edit == null) return null;
    final replacements = <CourseSlot>[];
    for (var i = 0; i < course.slots.length; i++) {
      final slot = course.slots[i];
      final origin = _jwxtOriginal(course.id, slot, i);
      if (origin == null || !_sameSlot(origin, raw)) continue;
      replacements.add(i == index ? replacement : slot);
    }
    await _saveJwxtSlotReplacements(course.id, raw, replacements, edit);
    return courses.where((value) => value.id == course.id).firstOrNull;
  }

  Future<void> _saveJwxtSlotReplacements(
    String courseId,
    CourseSlot raw,
    List<CourseSlot> replacements,
    CourseEdit edit,
  ) => _setCourseEdit(_withJwxtSlotReplacements(raw, replacements, edit));

  /// 仅构造时段覆盖，供普通编辑与课程转考试的批量保存复用。
  static CourseEdit _withJwxtSlotReplacements(
    CourseSlot raw,
    List<CourseSlot> replacements,
    CourseEdit edit,
  ) {
    final base = raw.copyWith(
      teacher: edit.teacher,
      location: edit.location,
      note: edit.note,
      kind: edit.courseKind,
    );
    final record = CourseSlotEdit(
      original: raw.ref,
      originalWeeks: raw.weeks,
      replacements: [
        for (final value in _mergeFormSlots(replacements))
          CourseSlotPatch.between(base, value),
      ],
    );
    return edit.copyWith(
      slotEdits: [
        for (final previous in edit.slotEdits)
          if (!previous.matches(raw)) previous,
        record,
      ],
      updatedAt: DateTime.now().toIso8601String(),
    );
  }

  /// 恢复位置或合并安排时，仅合并位置和字段完全相同的时段。
  static List<CourseSlot> _mergeFormSlots(List<CourseSlot> slots) {
    final result = <CourseSlot>[];
    for (final slot in slots) {
      final index = result.indexWhere(
        (other) =>
            other.ref == slot.ref &&
            other.teacher == slot.teacher &&
            other.location == slot.location &&
            other.note == slot.note &&
            other.kind == slot.kind &&
            other.isLab == slot.isLab &&
            other.nameOverride == slot.nameOverride &&
            other.color == slot.color &&
            other.useDefaultColor == slot.useDefaultColor &&
            other.splitFrom == slot.splitFrom,
      );
      if (index < 0) {
        result.add(slot);
      } else {
        final old = result[index];
        result[index] = old.copyWith(
          weeks: weeksToBits(
            {...weeksOf(old), ...weeksOf(slot)},
            old.weeks.length > slot.weeks.length
                ? old.weeks.length
                : slot.weeks.length,
          ),
          weeksLabel: '',
        );
      }
    }
    return result;
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
    final affected = switch (scope) {
      MoveScope.thisWeek => [week],
      MoveScope.fromThisWeek => [
        for (final w in weeksOf(slot))
          if (w >= week) w,
      ],
      MoveScope.allWeeks => weeksOf(slot),
    };

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
      final edit = _courseEdits[course.id];
      if (edit != null &&
          edit.slotEdits.any((value) => value.matches(origin))) {
        final peers = <CourseSlot>[];
        var movingIndex = -1;
        for (var i = 0; i < course.slots.length; i++) {
          final candidate = course.slots[i];
          final raw = _jwxtOriginal(course.id, candidate, i);
          if (raw == null || !_sameSlot(raw, origin)) continue;
          if (i == slotIndex) movingIndex = peers.length;
          peers.add(candidate);
        }
        if (movingIndex < 0) {
          return const MoveResult.error(MoveError.invalidSlot);
        }
        await _saveJwxtSlotReplacements(
          course.id,
          origin,
          moveManualSlots(
            peers,
            movingIndex,
            affected,
            toDay: toDay,
            toStart: toStartPeriod,
            toEnd: toEnd,
          ),
          edit,
        );
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
    final edit = _courseEdits[course.id];
    var restoredSlots = false;
    if (edit != null && edit.slotEdits.any((value) => value.matches(origin))) {
      final replacements = <CourseSlot>[];
      for (var i = 0; i < course.slots.length; i++) {
        final slot = course.slots[i];
        final raw = _jwxtOriginal(course.id, slot, i);
        if (raw == null || !_sameSlot(raw, origin)) continue;
        if (slot.ref != origin.ref) restoredSlots = true;
        replacements.add(
          slot.copyWith(
            day: origin.day,
            startNode: origin.startNode,
            endNode: origin.endNode,
            clearSplitFrom: true,
          ),
        );
      }
      if (restoredSlots) {
        await _saveJwxtSlotReplacements(course.id, origin, replacements, edit);
      }
    }
    final next = [
      for (final o in _overrides)
        if (!(o.matchesKey(course.id, origin) && o.origWeeks == origin.weeks))
          o,
    ];
    if (next.length == _overrides.length) return restoredSlots;
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

  static TimetableSyncDiffResult _mergeSyncDiff(
    TimetableSyncDiffResult? a,
    TimetableSyncDiffResult b,
  ) {
    if (a == null) return b;
    return TimetableSyncDiffResult(
      allWritten: [...a.allWritten, ...b.allWritten],
      toNotify: [...a.toNotify, ...b.toNotify],
    );
  }

  /// 课表同步成功后拉教务考试并整批替换（覆盖层由 [replaceJwxtExams] 按 examKey
  /// 保留 / 清理）。任何失败只记一条通用日志，已有考试不动。
  Future<List<ScheduleEvent>?> _syncExams(
    String term, {
    required int bindingRevision,
  }) async {
    final host = _manager ?? this;
    final List<ScheduleEvent>? exams;
    try {
      exams = await fetchExams(term);
    } catch (error, stackTrace) {
      if (bindingRevision != host._portalBindingRevision) return null;
      AppLog.reportOutcome('degraded', reason: 'exams_fetch_failed');
      _log.warning(
        'exams.fetch_failed_using_existing',
        fields: {'stage': 'sync.exams.fetch', 'outcome': 'cache_fallback'},
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
    if (bindingRevision != host._portalBindingRevision || exams == null) {
      return null;
    }
    final scopedExams =
        activeStorageId != kDefaultScheduleId &&
            isHistoricalSchedule(activeStorageId)
        ? _filterExamsToTermWindow(exams, settings)
        : exams;
    try {
      await replaceJwxtExams(scopedExams);
      return [
        for (final e in _scheduleEvents)
          if (e.isFromJwxt && e.isExam) e,
      ];
    } catch (error, stackTrace) {
      if (bindingRevision != host._portalBindingRevision) return null;
      AppLog.reportOutcome('degraded', reason: 'exams_save_failed');
      _log.warning(
        'exams.save_failed_using_existing',
        fields: {'stage': 'sync.exams.save', 'outcome': 'cache_fallback'},
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Object? _effectiveEventSources;
  List<ScheduleEvent> _effectiveEventCache = const [];
  final _eventsByDate = <DateTime, List<ScheduleEvent>>{};

  /// 套用考试覆盖后的日程（删除的教务考试不在其中），id 不变。
  /// 日程与覆盖记录都按新集合替换，翻周等界面通知不重复套用和排序。
  List<ScheduleEvent> get _effectiveEvents {
    final sources = (_scheduleEvents, _examOverrides);
    if (_effectiveEventSources != sources) {
      _effectiveEventSources = sources;
      _effectiveEventCache = List.unmodifiable([
        for (final e in _scheduleEvents)
          if (!e.isFromJwxt)
            e
          else if (_examOverrides[e.jwxtKey] case final o?)
            ?o.applyTo(e)
          else
            e,
      ]);
      _eventsByDate.clear();
      for (final event in _effectiveEventCache) {
        final date = event.date;
        (_eventsByDate[DateTime(date.year, date.month, date.day)] ??= []).add(
          event,
        );
      }
      for (final events in _eventsByDate.values) {
        events.sort((a, b) => a.start.compareTo(b.start));
      }
    }
    return _effectiveEventCache;
  }

  /// 全部日程（考试 + 其他，含教务与手动；已套用教务考试的编辑/删除），
  /// 未按 showExams 开关过滤。
  List<ScheduleEvent> get scheduleEvents => _effectiveEvents;

  /// 某天要显示的日程：考试受 [TimetableSettings.showExams] 控制，「其他」不受。
  /// 按开始时间排序。
  List<ScheduleEvent> scheduleEventsOn(DateTime date) {
    _effectiveEvents;
    return [
      for (final e
          in _eventsByDate[DateTime(date.year, date.month, date.day)] ??
              const <ScheduleEvent>[])
        if (!e.isExam || settings.showExams) e,
    ];
  }

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
        take(
          TimeOfDayMinutes.tryParse(
            timeForSlot(cell.course, cell.slot, date: today).end,
          ),
        );
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
      final next = Map<String, ExamOverride>.unmodifiable({
        ..._examOverrides,
        key: ExamOverride.diff(raw, event),
      });
      await _inScope(() => ScheduleStore.saveExamOverrides(next));
      _examOverrides = next;
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
      final next = Map<String, ExamOverride>.unmodifiable({
        ..._examOverrides,
        key: ExamOverride(key: key, deleted: true),
      });
      await _inScope(() => ScheduleStore.saveExamOverrides(next));
      _examOverrides = next;
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
        ExamParser.cleanImportedExam(
          e.copyWith(source: ScheduleSource.jwxt, kind: ScheduleKind.exam),
        ),
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
      await _inScope(() => ScheduleStore.saveExamOverrides(keptOverrides));
      _examOverrides = Map.unmodifiable(keptOverrides);
    }
    await _inScope(
      () => ScheduleStore.saveEventsAndOtherColors(
        _scheduleEvents,
        _otherColors,
        clearJwxtExamsBaselinePending: _jwxtExamsBaselinePending,
      ),
    );
    _jwxtExamsBaselinePending = false;
    _notifyEvents(ScheduleChangeReason.sync);
  }

  Future<void> _markJwxtExamsBaselinePending() async {
    _jwxtExamsBaselinePending = true;
    try {
      await _inScope(() => ScheduleStore.saveJwxtExamsBaselinePending(true));
    } on TimetablePersistenceException {
      // 存储不可用时保留内存标记即可。
    }
  }

  Future<void> _persistEvents() async {
    try {
      await _inScope(
        () => ScheduleStore.saveEventsAndOtherColors(
          _scheduleEvents,
          _otherColors,
        ),
      );
    } on TimetablePersistenceException {
      await _inScope(() async {
        _scheduleEvents = List.unmodifiable(await ScheduleStore.readEvents());
        _otherColors = Map.unmodifiable(await ScheduleStore.readOtherColors());
      });
      notifyListeners();
      rethrow;
    }
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
    await _inScope(() => ScheduleStore.saveCourseEdits(next));
    _courseEdits = Map.unmodifiable(next);
    _clampViewingWeek();
    notifyListeners();
  }

  /// 这门教务课当前的编辑/删除记录（没有返回 null）。编辑页预填用。
  CourseEdit? courseEditOf(String courseId) => _courseEdits[courseId];

  /// 按恢复范围生成课程详情的本地差异；只读取当前状态，不写入修改记录。
  List<CourseDetailChangeGroup> courseDetailChanges(GridCell cell) {
    final groups = <CourseDetailChangeGroup>[];
    final base = baseOccurrenceOf(cell);
    final dateEdit = cell.dateEdit;
    if (dateEdit != null && base != null) {
      final beforeDate = dateEdit.isWeeksScoped && cell.date != null
          ? mondayOfWeek(cell.date!)
                .add(Duration(days: dateEdit.date.weekday - 1))
          : dateEdit.date;
      var beforeSlot = base.course.slots[base.slotIndex].copyWith(
        day: beforeDate.weekday,
      );
      var beforeCourse = base.course;
      // 恢复单日记录后，匹配的按周记录仍会生效；从真实候选中排除当前记录
      // 预览恢复值，避免将继承字段误当成本次修改，也不临时改动控制器状态。
      for (final candidate in _applyDateEdits(
        beforeDate,
        beforeDate.weekday,
        _swapCandidates(
          _weekOfDate(beforeDate),
          beforeDate.weekday,
          beforeDate,
        ),
        excludedEditId: dateEdit.id,
      )) {
        if (!candidate.active || candidate.course.id != dateEdit.courseId) {
          continue;
        }
        final edit = candidate.dateEdit;
        final matches = edit == null
            ? candidate.slot.startNode == dateEdit.origStart &&
                  candidate.slot.endNode == dateEdit.origEnd
            : edit.matches(
                    dateEdit.courseId,
                    beforeDate,
                    dateEdit.origStart,
                    dateEdit.origEnd,
                  ) ||
                  edit.matchesWeek(
                    dateEdit.courseId,
                    _weekOfDate(beforeDate),
                    beforeDate.weekday,
                    dateEdit.origStart,
                    dateEdit.origEnd,
                  );
        if (!matches) continue;
        beforeCourse = candidate.course;
        beforeSlot = candidate.slot;
        break;
      }
      groups.add(
        CourseDetailChangeGroup(
          scope: CourseDetailChangeScope.occurrence,
          title: dateEdit.isWeeksScoped ? '已按周修改' : '这一天已单独修改',
          affectedScope: _detailDateScope(dateEdit),
          changes: _detailSlotChanges(
            beforeCourse,
            beforeSlot,
            cell.course,
            cell.slot,
            beforeDate: dateEdit.isWeeksScoped ? null : beforeDate,
            afterDate: dateEdit.isWeeksScoped ? null : cell.date,
          ),
        ),
      );
    }
    if (base != null) {
      final slot = base.course.slots[base.slotIndex];
      final info = overrideInfoFor(base.course, base.slotIndex);
      if (info != null) {
        final origin = slotOriginOf(slot)!.original;
        final moved = [
          for (final peer in base.course.slots)
            if (_sameSlot(slotOriginOf(peer)?.original ?? peer, origin) &&
                peer.ref != origin.ref)
              peer,
        ];
        final range = info.originalStart == info.originalEnd
            ? '第 ${info.originalStart} 节'
            : '第 ${info.originalStart}–${info.originalEnd} 节';
        groups.add(
          CourseDetailChangeGroup(
            scope: CourseDetailChangeScope.position,
            title: '已调课：原 ${_detailWeekday(info.originalDay)} $range',
            affectedScope: formatWeeks(
              moved.expand(weeksOf),
              maxSegments: null,
            ),
            changes: [
              for (final peer in moved)
                CourseDetailChange(
                  field: moved.length == 1
                      ? '上课时间'
                      : '上课时间（${formatWeeks(weeksOf(peer), maxSegments: null)}）',
                  before: _detailTime(
                    info.originalDay,
                    info.originalStart,
                    info.originalEnd,
                  ),
                  after: _detailTime(peer.day, peer.startNode, peer.endNode),
                ),
            ],
          ),
        );
      }
    }
    final original = _jwxtCourseById(cell.course.id);
    if (original != null && isJwxtOverridden(courseId: original.id)) {
      Course? current;
      for (final course in courses) {
        if (course.id == original.id) current = course;
      }
      final changes = <CourseDetailChange>[];
      for (final raw in original.slots) {
        final replacements = <CourseSlot>[
          if (current != null)
            for (final slot in current.slots)
              if (_sameSlot(slotOriginOf(slot)?.original ?? slot, raw)) slot,
        ];
        final retained = <int>{};
        for (final slot in replacements) {
          retained.addAll(weeksOf(slot));
          final added = weeksOf(slot).toSet().difference(weeksOf(raw).toSet());
          if (added.isNotEmpty) {
            changes.add(
              CourseDetailChange(
                field: '上课安排',
                before: '未安排',
                after:
                    '${formatWeeks(added, maxSegments: null)} · '
                    '${_detailTime(slot.day, slot.startNode, slot.endNode)}',
              ),
            );
          }
          final context =
              '${formatWeeks(weeksOf(slot), maxSegments: null)} · '
              '${_detailTime(raw.day, raw.startNode, raw.endNode)}';
          changes.addAll(
            _detailSlotChanges(
              original,
              raw.copyWith(weeks: slot.weeks),
              current!,
              slot,
              context: context,
            ),
          );
        }
        final removed = weeksOf(raw).toSet().difference(retained);
        if (removed.isNotEmpty) {
          changes.add(
            CourseDetailChange(
              field: '上课安排',
              before:
                  '${formatWeeks(removed, maxSegments: null)} · '
                  '${_detailTime(raw.day, raw.startNode, raw.endNode)}',
              after: '已删除',
            ),
          );
        }
      }
      // 整门恢复也清除单日记录，因此其他日期的修改同样需要可见。
      for (final edit in dateEditsOf(original.id)) {
        final candidate = _activeCandidateFor(edit);
        if (candidate == null) continue;
        final context = _detailDateScope(edit);
        if (edit.isDelete) {
          changes.add(
            CourseDetailChange(
              field: '上课安排（$context）',
              before: _detailTime(
                candidate.slot.day,
                candidate.slot.startNode,
                candidate.slot.endNode,
              ),
              after: '已删除',
            ),
          );
        } else {
          final after = _withDateEdit(candidate, edit, edit.targetDate.weekday);
          changes.addAll(
            _detailSlotChanges(
              candidate.course,
              candidate.slot,
              after.course,
              after.slot,
              beforeDate: edit.isWeeksScoped ? null : edit.date,
              afterDate: edit.isWeeksScoped ? null : edit.targetDate,
              context: context,
            ),
          );
        }
      }
      groups.add(
        CourseDetailChangeGroup(
          scope: CourseDetailChangeScope.course,
          title: '课程已修改',
          affectedScope: '整门课程的编辑、调课和单日修改',
          changes: changes,
        ),
      );
    }
    return groups;
  }

  List<CourseDetailChange> _detailSlotChanges(
    Course beforeCourse,
    CourseSlot beforeSlot,
    Course afterCourse,
    CourseSlot afterSlot, {
    DateTime? beforeDate,
    DateTime? afterDate,
    String context = '',
  }) {
    final changes = <CourseDetailChange>[];
    String field(String value) => context.isEmpty ? value : '$value（$context）';
    void add(String label, String before, String after) {
      if (before == after) return;
      changes.add(
        CourseDetailChange(
          field: field(label),
          before: before.isEmpty ? '未填写' : before,
          after: after.isEmpty ? '未填写' : after,
        ),
      );
    }

    add(
      '课程名称',
      courseDisplayName(course: beforeCourse, slot: beforeSlot),
      courseDisplayName(course: afterCourse, slot: afterSlot),
    );
    add(
      '上课时间',
      _detailTime(
        beforeSlot.day,
        beforeSlot.startNode,
        beforeSlot.endNode,
        date: beforeDate,
      ),
      _detailTime(
        afterSlot.day,
        afterSlot.startNode,
        afterSlot.endNode,
        date: afterDate,
      ),
    );
    add('教师', beforeSlot.teacher, afterSlot.teacher);
    add('地点', beforeSlot.location, afterSlot.location);
    add('备注', beforeSlot.note, afterSlot.note);
    add(
      '课程类型',
      _detailKind(courseKindOf(course: beforeCourse, slot: beforeSlot)),
      _detailKind(courseKindOf(course: afterCourse, slot: afterSlot)),
    );
    final beforeColor = userColorOf(beforeCourse.forSlot(beforeSlot));
    final afterColor = userColorOf(afterCourse.forSlot(afterSlot));
    if (beforeColor != afterColor) {
      changes.add(
        CourseDetailChange(
          field: field('颜色'),
          before: beforeColor == null ? '默认配色' : '自选颜色',
          after: afterColor == null ? '默认配色' : '自选颜色',
          beforeColor: beforeColor,
          afterColor: afterColor,
        ),
      );
    }
    return changes;
  }

  static String _detailWeekday(int day) => day >= 1 && day <= 7
      ? '周${const ['一', '二', '三', '四', '五', '六', '日'][day - 1]}'
      : '时间未填写';

  static String _detailTime(int day, int start, int end, {DateTime? date}) {
    final prefix = date == null ? '' : '${date.month}月${date.day}日 ';
    final range = start == end ? '第 $start 节' : '第 $start–$end 节';
    return '$prefix${_detailWeekday(day)} $range';
  }

  static String _detailKind(CourseKind kind) => switch (kind) {
    CourseKind.standard => '普通课',
    CourseKind.lab => '实验课',
    CourseKind.pe => '体育课',
    CourseKind.exam => '考试',
  };

  static String _detailDateScope(CourseDateEdit edit) => edit.isWeeksScoped
      ? '${formatWeeks(edit.weeks, maxSegments: null)} · ${_detailWeekday(edit.date.weekday)}'
      : edit.isWeekdayMatch
      ? '全部${_detailWeekday(edit.weekday ?? edit.date.weekday)}的匹配课程'
      : '${edit.date.month}月${edit.date.day}日 ${_detailWeekday(edit.date.weekday)}';

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
  /// 这门课的单日修改（第 1 条）一并清掉；整天调课记录不动。
  Future<bool> restoreJwxtCourse(String courseId) async {
    var hadEdit = _courseEdits.containsKey(courseId);
    if (hadEdit) {
      await _setCourseEdits({..._courseEdits}..remove(courseId));
    }
    if (_dateEdits.any((e) => e.courseId == courseId)) {
      hadEdit = true;
      await _setDateEdits([
        for (final e in _dateEdits)
          if (e.courseId != courseId) e,
      ], fire: false);
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
    final next = Map<String, ExamOverride>.unmodifiable(
      {..._examOverrides}..remove(examKey),
    );
    await _inScope(() => ScheduleStore.saveExamOverrides(next));
    _examOverrides = next;
    _notifyEvents(ScheduleChangeReason.restore);
    return true;
  }

  /// 设置「恢复教务课程」：清掉全部调课记录、教务课编辑/删除和教务考试覆盖。
  /// 什么都没有时返回 false。
  /// 教务课的单日修改（第 1 条）一并清掉；手动课的单日修改与整天调课记录不动。
  Future<bool> restoreAllJwxt() async {
    final jwxtDateEdits = _dateEdits.where(
      (e) => manualCourseById(e.courseId) == null,
    );
    if (_overrides.isEmpty &&
        _courseEdits.isEmpty &&
        _examOverrides.isEmpty &&
        jwxtDateEdits.isEmpty) {
      return false;
    }
    if (jwxtDateEdits.isNotEmpty) {
      await _setDateEdits([
        for (final e in _dateEdits)
          if (manualCourseById(e.courseId) != null) e,
      ], fire: false);
    }
    if (_examOverrides.isNotEmpty) {
      await _inScope(() => ScheduleStore.saveExamOverrides(const {}));
      _examOverrides = const {};
    }
    if (_courseEdits.isNotEmpty) await _setCourseEdits(const {});
    await _setOverrides(const [], ScheduleChangeReason.restore);
    return true;
  }

  // ===== 第 7 条：自动同步与节流 =====

  /// 自动同步最短间隔（成功或失败尝试后均限流）。冷启动 / 打开课表共用；
  /// 手动同步、重新绑定和一次离线恢复重试绕过限制。
  static const autoSyncInterval = Duration(minutes: 90);

  /// 回前台静默补拉教务的阈值：距上次**成功**远程同步超过此时长才补一次。
  /// 首页切回 / 下拉仍只走 [refreshLocal]，不受此常量影响。
  static const resumeRemoteSyncInterval = Duration(hours: 6);

  /// 节流用的「现在」（带时分秒），测试可替换。
  @visibleForTesting
  static DateTime Function() syncClock = DateTime.now;

  /// 测试用：在 [refreshLocal] 读盘前调用；抛错则 [refreshLocal] 返回 false。
  @visibleForTesting
  static Future<void> Function()? debugBeforeRefreshLocal;

  DateTime? _lastSyncSuccessAt;
  // 自动失败仍有持久化尝试间隔；手动/重新绑定和一次离线恢复不受此限制。
  DateTime? _lastAutomaticAttemptAt;
  bool _lastFailureOffline = false;
  bool _offlineRetryPending = false;
  bool _triggerBusy = false;

  /// 最近一次同步成功时间（持久化在 `sync_state.json`，重启后仍在）。
  DateTime? get lastSyncSuccessAt => _lastSyncSuccessAt;

  bool _elapsedSinceSuccess(Duration d) {
    final last = _lastSyncSuccessAt;
    if (last == null) return true;
    return syncClock().difference(last) >= d;
  }

  bool _automaticAttemptDue() {
    final last = _lastAutomaticAttemptAt;
    return last == null || syncClock().difference(last) >= autoSyncInterval;
  }

  Future<void> _recordAutomaticAttempt() async {
    final at = syncClock();
    _lastAutomaticAttemptAt = at;
    try {
      await ScheduleStore.saveLastAutomaticAttempt(at);
    } on TimetablePersistenceException catch (error, stackTrace) {
      // 本机记录失败仍允许拉取，本进程中的间隔继续有效。
      _log.warning(
        'sync.attempt_timestamp_save_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
    bool automaticBackoff = true,
  }) async {
    if (_triggerBusy || _syncInFlight != null || _loading) return false;
    _triggerBusy = true;
    try {
      await ensureStarted();
      if (_syncInFlight != null || _loading) return false;
      if (due != null && !due()) return false;
      if (automatic && automaticBackoff && !_automaticAttemptDue()) {
        return false;
      }
      if (!await refreshPortalBound()) return false;
      if (_syncInFlight != null || _loading) return false;
      final bindingRevision = _portalBindingRevision;
      if (automatic) await _recordAutomaticAttempt();
      if (_syncInFlight != null ||
          _loading ||
          !_portalBound ||
          bindingRevision != _portalBindingRevision) {
        return false;
      }
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

  /// App 冷启动：距上次成功 ≥90 分钟（或从未成功，即首次安装）才同步。
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

  /// 注册表分发的绑定变更：等待旧同步收尾，再立即同步或清理教务数据。
  /// 连续变更只处理最新状态；考试卡片共享本次处理结果。
  Future<void> onPortalBindingChanged(bool bound) {
    final revision = ++_portalBindingRevision;
    _portalBound = bound;
    notifyListeners();
    final change = _portalBindingChange.then((_) async {
      await ensureStarted();
      if (revision != _portalBindingRevision) return;
      await _syncInFlight;
      if (revision != _portalBindingRevision) return;
      _portalBound = bound;
      if (bound) {
        _offlineRetryPending = false;
        await _setPortalSessionExpired(false);
        if (revision != _portalBindingRevision) return;
        final stillBound = await bindingCheck();
        if (revision != _portalBindingRevision) return;
        _portalBound = stillBound;
        notifyListeners();
        unawaited(updateNextDayReminder());
        // 旧自动触发可能还在退栈；直接进入同步合流，不受 _triggerBusy 或节流影响。
        if (stillBound) await syncFromJwxt();
      } else {
        await handleLogout(clearJwxt: true);
      }
    });
    // 一次清理失败由注册表反馈，不阻断后续绑定变更。
    _portalBindingChange = change.then<void>((_) {}, onError: (Object _) {});
    return change;
  }

  /// App 回到前台：仅检查初始化、跨天/跨周（[followCurrentWeekIfChanged]）
  /// 与 6 小时远端同步冷却，不再无条件全量重读本地磁盘。
  /// 切回首页 tab、首页下拉仍走显式 [refreshLocal]。
  Future<bool> onAppResumed() async {
    try {
      await ensureStarted();
    } catch (_) {
      return false;
    }
    final today = _today;
    final dateChanged = _lastSeenDate != null && _lastSeenDate != today;
    _lastSeenDate = today;
    final weekChanged = followCurrentWeekIfChanged();
    if (dateChanged) {
      notifyListeners();
    }
    if (dateChanged || weekChanged) {
      unawaited(updateNextDayReminder());
    }
    if (_elapsedSinceSuccess(resumeRemoteSyncInterval)) {
      // 与冷启动一样走 _trigger（90 分钟节流不再套用；此处用 6h due）。
      // 不 await：本地刷新结果立刻返回，远程在后台跑。
      unawaited(
        _trigger(
          due: () => _elapsedSinceSuccess(resumeRemoteSyncInterval),
          automatic: true,
        ).catchError((Object _) => false),
      );
    }
    return true;
  }

  /// 网络恢复（由 App 层的连接监听调用）：只有上一次自动同步因断网失败时，
  /// 立即重试一次（不等 90 分钟）；重试失败不再自动重试。其他情况忽略。
  Future<bool> onNetworkRestored() {
    if (!_offlineRetryPending || _triggerBusy || _syncInFlight != null) {
      return Future.value(false);
    }
    _offlineRetryPending = false;
    return _trigger(
      armOfflineRetry: false,
      automatic: true,
      automaticBackoff: false,
    );
  }

  /// 远程手动同步（周课表顶栏用，不受节流限制）。未绑定返回 false（页面跳转登录）。
  Future<bool> manualSync() => _trigger(armOfflineRetry: false);

  Future<void> _setOverrides(
    List<SlotOverride> next,
    ScheduleChangeReason reason,
  ) async {
    await _inScope(() => TimetableStore.saveOverrides(next));
    _overrides = List.unmodifiable(next);
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
  /// 周末列关闭但当周该天有课或可见日程时自动显示。
  List<int> visibleDays(int week) => weekColumnDays(
    weekStartsSunday: settings.weekStartsSunday,
    showSaturday: settings.showSaturday,
    showSunday: settings.showSunday,
    saturdayHasClass:
        cellsForDay(week, 6).any((c) => c.activeThisWeek) ||
        scheduleEventsOn(dateOfColumn(week, 6)).isNotEmpty,
    sundayHasClass:
        cellsForDay(week, 7).any((c) => c.activeThisWeek) ||
        scheduleEventsOn(dateOfColumn(week, 7)).isNotEmpty,
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
  ///
  /// 展示优先级（第 1/8 条）：单日修改 > 整天调课 > 拖动调课 > 教务原始。
  /// - 整天调课：这一天本周有课的格子换成对调日期那天本周有课的格子（时段改成本列
  ///   星期，[GridCell.swappedFrom] = 对调日期）；非本周灰格仍按本列自己的。
  /// - 单日修改：按「课程 + 本列日期 + 显示节次」匹配（已套用整天调课后的显示）；
  ///   对不上的记录忽略（不删）。挪到别的日期的记录在目标日期显示。
  /// 每格带 [GridCell.date]（本列日期）。
  List<GridCell> cellsForDay(int week, int day) {
    // 只保留最近三周规模的列，翻周/拖动重建和首页读取可复用；导出整学期
    // 或生成长期提醒时不会无限积累。课程、覆盖、调课集合均以新引用替换。
    final sources = (
      combinedCourses,
      _daySwaps,
      _dateEdits,
      settings.showNonCurrentWeek,
      weekStartDate(1),
    );
    if (_dayCellSources != sources) {
      _dayCellSources = sources;
      _dayCells.clear();
    }
    final key = (week, day);
    final cached = _dayCells.remove(key);
    if (cached != null) {
      _dayCells[key] = cached;
      return cached;
    }
    final cells = List<GridCell>.unmodifiable(_buildCellsForDay(week, day));
    if (_dayCells.length >= 21) _dayCells.remove(_dayCells.keys.first);
    _dayCells[key] = cells;
    return cells;
  }

  Object? _dayCellSources;
  final _dayCells = <(int, int), List<GridCell>>{};

  List<GridCell> _buildCellsForDay(int week, int day) {
    final date = dateOfColumn(week, day);
    final candidates = (_daySwaps.isEmpty && _dateEdits.isEmpty)
        ? _baseCandidates(week, day)
        : _applyDateEdits(date, day, _swapCandidates(week, day, date));

    final result = <GridCell>[];
    // 冲突：同日起止重叠
    for (var i = 0; i < candidates.length; i++) {
      final item = candidates[i];
      var conflicts = 0;
      for (var j = 0; j < candidates.length; j++) {
        if (i == j) continue;
        final other = candidates[j];
        if (!_overlap(item.slot, other.slot)) continue;
        if (item.active || other.active) conflicts++;
      }
      result.add(
        GridCell(
          course: item.course,
          slot: item.slot,
          conflictCount: conflicts,
          activeThisWeek: item.active,
          date: date,
          dateEdit: item.dateEdit,
          swappedFrom: item.swappedFrom,
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

  /// 拖动调课 + 教务编辑后（[courses]）第 [week] 周第 [day] 列的候选格。
  List<_Cand> _baseCandidates(int week, int day) {
    final candidates = <_Cand>[];
    for (final course in courses) {
      if (course.hidden) continue;
      final splitAway = settings.showNonCurrentWeek && course.isManual
          ? manualSplitAwayRefs(course, week)
          : const <SlotRef>{};
      for (final slot in course.slots) {
        if (!slot.hasFixedTime || slot.day != day) continue;
        final active = slot.hasClassInWeek(week);
        if (!active && !settings.showNonCurrentWeek) continue;
        // 第 15 条：非本周灰格只在之后还有安排时显示，否则隐藏。
        if (!active && !slotHasRemainingWeeks(slot, week)) continue;
        // 本周这次已被拖走（拆出的时段本周有课）→ 原位置不画「[非本周]」虚影。
        if (!active && splitAway.contains(slot.ref)) continue;
        candidates.add(_Cand(course.forSlot(slot), slot, active));
      }
    }
    return candidates;
  }

  /// 套用整天调课（第 8 条）后的候选格。
  List<_Cand> _swapCandidates(int week, int day, DateTime date) {
    final base = _baseCandidates(week, day);
    final partner = swapPartnerIn(_daySwaps, date);
    if (partner == null) return base;
    final pw = _weekOfDate(partner);
    return [
      for (final c in base)
        if (!c.active) c,
      if (pw >= 1)
        for (final c in _baseCandidates(pw, partner.weekday))
          if (c.active)
            _Cand(
              c.course,
              _redaySlot(c.course.id, c.slot, day),
              true,
              swappedFrom: partner,
            ),
    ];
  }

  /// 套用单日 / 多周修改后的候选格。
  List<_Cand> _applyDateEdits(
    DateTime date,
    int day,
    List<_Cand> cands, {
    String? excludedEditId,
  }) {
    final week = _weekOfDate(date);
    final edits = excludedEditId == null
        ? _dateEdits
        : _dateEdits.where((edit) => edit.id != excludedEditId);
    final here = [
      for (final e in edits)
        if (e.scope == DateEditScope.oneDay && isSameDate(e.date, date)) e,
    ];
    final weekScoped = [
      for (final e in edits)
        if (e.isWeeksScoped) e,
    ];
    final weekdayDels = [
      for (final e in edits)
        if (e.isWeekdayMatch && e.isDelete) e,
    ];
    final incoming = [
      for (final e in edits)
        if (!e.isDelete &&
            e.scope == DateEditScope.oneDay &&
            e.movesToOtherDate &&
            isSameDate(e.toDate!, date))
          e,
    ];
    if (here.isEmpty &&
        weekScoped.isEmpty &&
        weekdayDels.isEmpty &&
        incoming.isEmpty) {
      return cands;
    }
    final out = <_Cand>[];
    for (final c in cands) {
      if (!c.active) {
        out.add(c);
        continue;
      }
      // weekdayMatch 删除优先按匹配隐藏。
      var killed = false;
      for (final e in weekdayDels) {
        if (e.matchesWeekdaySlot(
          courseId: c.course.id,
          courseName: c.course.name,
          weekday: day,
          teacher: c.slot.teacher,
          location: c.slot.location,
        )) {
          killed = true;
          break;
        }
      }
      if (killed) continue;

      CourseDateEdit? rec;
      for (final e in here) {
        if (e.matches(c.course.id, date, c.slot.startNode, c.slot.endNode)) {
          rec = e;
        }
      }
      if (rec == null) {
        for (final e in weekScoped) {
          if (e.matchesWeek(
            c.course.id,
            week,
            day,
            c.slot.startNode,
            c.slot.endNode,
          )) {
            rec = e;
          }
        }
      }
      if (rec == null) {
        out.add(c);
      } else if (!rec.isDelete && !rec.movesToOtherDate) {
        out.add(_withDateEdit(c, rec, day));
      }
      // delete / 挪走：不加入 out
    }
    for (final rec in incoming) {
      final src = _activeCandidateFor(rec);
      if (src != null) out.add(_withDateEdit(src, rec, day));
    }
    return out;
  }

  /// 单日修改记录指向的那次课（记录日期那天、整天调课后、单日修改前）；没有 → null。
  _Cand? _activeCandidateFor(CourseDateEdit rec) {
    final w = _weekOfDate(rec.date);
    if (w < 1) return null;
    for (final c in _swapCandidates(w, rec.date.weekday, rec.date)) {
      if (c.active &&
          rec.matches(
            c.course.id,
            rec.date,
            c.slot.startNode,
            c.slot.endNode,
          )) {
        return c;
      }
    }
    return null;
  }

  _Cand _withDateEdit(_Cand c, CourseDateEdit rec, int day) {
    final s = c.slot;
    final slot = CourseSlot(
      day: day,
      startNode: rec.toStart ?? s.startNode,
      endNode: rec.toEnd ?? s.endNode,
      weeks: s.weeks,
      weeksLabel: s.weeksLabel,
      teacher: rec.teacher ?? s.teacher,
      location: rec.location ?? s.location,
      note: rec.note ?? s.note,
      isLab: s.isLab,
      kind: rec.courseKind ?? s.kind,
      nameOverride: rec.name ?? s.nameOverride,
      color: rec.useDefaultColor ? null : rec.color ?? s.color,
      useDefaultColor:
          rec.useDefaultColor || (rec.color == null && s.useDefaultColor),
      splitFrom: s.splitFrom,
    );
    tagSlotOrigin(
      slot,
      slotOriginOf(s) ??
          SlotOrigin(courseId: c.course.id, original: s, moved: false),
    );
    return _Cand(
      c.course.forSlot(slot),
      slot,
      true,
      swappedFrom: c.swappedFrom,
      dateEdit: rec,
    );
  }

  /// 换到第 [day] 列显示的时段（保留来源标，单双周仍按原时段判断）。
  static CourseSlot _redaySlot(String courseId, CourseSlot s, int day) {
    if (s.day == day) return s;
    final n = CourseSlot(
      day: day,
      startNode: s.startNode,
      endNode: s.endNode,
      weeks: s.weeks,
      weeksLabel: s.weeksLabel,
      teacher: s.teacher,
      location: s.location,
      note: s.note,
      isLab: s.isLab,
      kind: s.kind,
      nameOverride: s.nameOverride,
      color: s.color,
      useDefaultColor: s.useDefaultColor,
      splitFrom: s.splitFrom,
    );
    tagSlotOrigin(
      n,
      slotOriginOf(s) ??
          SlotOrigin(courseId: courseId, original: s, moved: false),
    );
    return n;
  }

  /// [date] 所在的教学周（周次待同步时以本周为第 1 周，与 [weekStartDate] 一致）。
  int _weekOfDate(DateTime date) => teachingWeekOf(
    settings.termStartDate ?? _mondayOf(_today),
    DateTime(date.year, date.month, date.day),
  );

  /// [date] 所在教学周（不钳制）；周次待同步时以本周为第 1 周。
  int weekOfDate(DateTime date) => _weekOfDate(date);

  // ===== 第 8 条：整天调课 =====

  List<DaySwap> _daySwaps = const [];
  int _swapSeq = 0;

  /// 全部整天调课记录（设置「调课记录」列表；按添加顺序）。
  List<DaySwap> get daySwaps => List.unmodifiable(_daySwaps);

  /// [date] 是否参与了整天调课（表头「调」胶囊）。
  bool isSwappedDate(DateTime date) => _daySwaps.any((s) => s.involves(date));

  /// [date] 的对调日期；没调返回 null。
  DateTime? swapPartnerOf(DateTime date) => swapPartnerIn(_daySwaps, date);

  /// [date] 所在的调课记录；没有返回 null。
  DaySwap? daySwapOn(DateTime date) {
    for (final s in _daySwaps) {
      if (s.involves(date)) return s;
    }
    return null;
  }

  /// 两天课程互换（考试 / 日程留在原日期）。同一天、或任一天已在别的调课记录里
  /// → 返回 null 不写（请先恢复那条）。单日修改记录不受影响：调课前在这两天做的
  /// 单日修改，这门课不在那天显示时暂不生效，恢复调课后自动重新生效。
  Future<DaySwap?> addDaySwap(DateTime a, DateTime b) async {
    if (isSameDate(a, b) || isSwappedDate(a) || isSwappedDate(b)) return null;
    final swap = DaySwap(
      id: 'swap-${DateTime.now().microsecondsSinceEpoch}-${_swapSeq++}',
      dateA: DateTime(a.year, a.month, a.day),
      dateB: DateTime(b.year, b.month, b.day),
      createdAt: DateTime.now().toIso8601String(),
    );
    await _setDaySwaps([..._daySwaps, swap]);
    return swap;
  }

  /// 恢复一条整天调课记录。id 不存在返回 false。不删任何单日修改。
  Future<bool> removeDaySwap(String id) async {
    final next = [
      for (final s in _daySwaps)
        if (s.id != id) s,
    ];
    if (next.length == _daySwaps.length) return false;
    await _setDaySwaps(next);
    return true;
  }

  Future<void> _setDaySwaps(List<DaySwap> next) async {
    await _inScope(() => ScheduleStore.saveDaySwaps(next));
    _daySwaps = List.unmodifiable(next);
    notifyListeners();
    _fireScheduleChanged(ScheduleChangeReason.daySwap);
  }

  // ===== 第 1 条：单日修改（只改这一天）=====

  List<CourseDateEdit> _dateEdits = const [];
  int _dateEditSeq = 0;

  /// 全部单日修改记录（含暂不生效的）。
  List<CourseDateEdit> get courseDateEdits => List.unmodifiable(_dateEdits);

  /// 某门课的单日修改记录。
  List<CourseDateEdit> dateEditsOf(String courseId) => [
    for (final e in _dateEdits)
      if (e.courseId == courseId) e,
  ];

  /// 第 15 条：非本周格 / 考试是否在 [viewedWeek] 之后还有安排。
  bool hasRemainingWeeks(Object item, int viewedWeek) => switch (item) {
    Course c => courseHasRemainingWeeks(c, viewedWeek),
    CourseSlot s => slotHasRemainingWeeks(s, viewedWeek),
    GridCell g => slotHasRemainingWeeks(g.slot, viewedWeek),
    ScheduleEvent e => examHasRemainingWeeks(_weekOfDate(e.date), viewedWeek),
    _ => false,
  };

  /// 一格对应「这次课」的识别键（单日修改按它存）。非本周格 / 没有日期 → null。
  ({String courseId, DateTime date, int start, int end})? _occurrenceKey(
    GridCell cell,
  ) {
    final d = cell.date;
    if (d == null || !cell.activeThisWeek) return null;
    final e = cell.dateEdit;
    if (e != null) {
      return (
        courseId: e.courseId,
        date: e.isWeeksScoped
            ? mondayOfWeek(d).add(Duration(days: e.date.weekday - 1))
            : e.date,
        start: e.origStart,
        end: e.origEnd,
      );
    }
    return (
      courseId: cell.course.id,
      date: DateTime(d.year, d.month, d.day),
      start: cell.slot.startNode,
      end: cell.slot.endNode,
    );
  }

  /// [cell] 底层的课程（[courses] 里的那门，未套单日修改）、时段下标与所在周：
  /// 「所有周」保存 / 拖动用它改课程本身。整天调课换来的格子指回原日期那次课。
  /// 手工构造、没有 [GridCell.date] 的格子按时段原样找，周取 [week]（默认浏览周）。
  ({Course course, int slotIndex, int week})? baseOccurrenceOf(
    GridCell cell, {
    int? week,
  }) {
    final key = _occurrenceKey(cell);
    final id = key?.courseId ?? cell.course.id;
    Course? course;
    for (final c in courses) {
      if (c.id == id) course = c;
    }
    if (course == null) return null;
    if (key == null) {
      final i = _indexOfEqualSlot(course.slots, cell.slot, -1);
      return i < 0
          ? null
          : (course: course, slotIndex: i, week: week ?? viewingWeek);
    }
    final baseDate = swapPartnerIn(_daySwaps, key.date) ?? key.date;
    final w = _weekOfDate(baseDate);
    for (var i = 0; i < course.slots.length; i++) {
      final s = course.slots[i];
      if (s.hasFixedTime &&
          s.day == baseDate.weekday &&
          s.startNode == key.start &&
          s.endNode == key.end &&
          s.hasClassInWeek(w)) {
        return (course: course, slotIndex: i, week: w);
      }
    }
    return null;
  }

  CourseDateEdit? _findDateEdit(
    ({String courseId, DateTime date, int start, int end}) k,
  ) {
    CourseDateEdit? hit;
    for (final e in _dateEdits) {
      if (e.scope == DateEditScope.oneDay &&
          e.matches(k.courseId, k.date, k.start, k.end)) {
        hit = e;
      }
    }
    return hit;
  }

  /// 设置这周这一节的颜色；null 恢复为课程全局颜色，不影响同门课的其他时段。
  /// 已有按周修改时为当前周建立独立记录，保留这次课的其他修改。
  Future<bool> setOccurrenceColor(
    GridCell cell,
    int? color, {
    bool useDefaultColor = false,
  }) async {
    final key = _occurrenceKey(cell);
    if (key == null || baseOccurrenceOf(cell) == null) return false;
    final inherited = cell.dateEdit;
    final date = inherited?.isWeeksScoped == true
        ? mondayOfWeek(cell.date!)
              .add(Duration(days: inherited!.date.weekday - 1))
        : key.date;
    CourseDateEdit? old;
    for (final e in _dateEdits) {
      if (e.scope == DateEditScope.oneDay &&
          e.matches(key.courseId, date, key.start, key.end)) {
        old = e;
      }
    }
    if (old == null && color == null && !useDefaultColor) return true;
    final rec =
        (old ??
                CourseDateEdit(
                  id: 'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
                  courseId: key.courseId,
                  date: date,
                  origStart: key.start,
                  origEnd: key.end,
                  name: inherited?.name,
                  teacher: inherited?.teacher,
                  location: inherited?.location,
                  note: inherited?.note,
                  courseKind: inherited?.courseKind,
                  useDefaultColor: inherited?.useDefaultColor ?? false,
                  toDate: inherited?.movesTime == true ? cell.date : null,
                  toStart: inherited?.toStart,
                  toEnd: inherited?.toEnd,
                  createdAt: DateTime.now().toIso8601String(),
                ))
            .copyWith(
              color: color == null ? null : color | 0xFF000000,
              clearColor: color == null,
              useDefaultColor: useDefaultColor && color == null,
            );
    await _upsertDateEdit(old, rec);
    return true;
  }

  /// 只改这一天：改这次课的课名 / 老师 / 地点 / 备注，或挪到同一周的 [toDay]
  /// 第 [toStart]–[toEnd] 节（只给 [toStart] 时保持时长）。传 null 的项保持之前的单日
  /// 修改（或课程原值）。手动课与教务课规则相同；同步不清这些记录。
  /// 格子没有日期 / 不是本周有课的格 / 找不到底层课程 → null（不写）。
  Future<CourseDateEdit?> editOccurrence(
    GridCell cell, {
    String? name,
    String? teacher,
    String? location,
    String? note,
    int? toDay,
    int? toStart,
    int? toEnd,
  }) async {
    final key = _occurrenceKey(cell);
    if (key == null || baseOccurrenceOf(cell) == null) return null;
    if (toDay != null && (toDay < 1 || toDay > 7)) return null;
    final old = _findDateEdit(key);
    final inherited = cell.dateEdit?.isWeeksScoped == true
        ? cell.dateEdit
        : null;
    var rec =
        old ??
        CourseDateEdit(
          id: 'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
          courseId: key.courseId,
          date: key.date,
          origStart: key.start,
          origEnd: key.end,
          name: inherited?.name,
          teacher: inherited?.teacher,
          location: inherited?.location,
          note: inherited?.note,
          courseKind: inherited?.courseKind,
          color: inherited?.color,
          useDefaultColor: inherited?.useDefaultColor ?? false,
          toDate: inherited?.toDate == null
              ? null
              : mondayOfWeek(key.date)
                    .add(Duration(days: inherited!.toDate!.weekday - 1)),
          toStart: inherited?.toStart,
          toEnd: inherited?.toEnd,
          createdAt: DateTime.now().toIso8601String(),
        );
    rec = rec.copyWith(
      kind: DateEditKind.edit,
      scope: DateEditScope.oneDay,
      clearWeeks: true,
      name: name,
      teacher: teacher,
      location: location,
      note: note,
    );
    if (toDay != null || toStart != null || toEnd != null) {
      final monday = mondayOfWeek(cell.date!);
      final toDate = toDay == null
          ? rec.toDate ?? key.date
          : DateTime(monday.year, monday.month, monday.day + toDay - 1);
      final curStart = rec.toStart ?? key.start;
      final curEnd = rec.toEnd ?? key.end;
      final s = toStart ?? curStart;
      final e = toEnd ?? (toStart == null ? curEnd : s + (curEnd - curStart));
      if (s < 1 || e < s || e > lastPeriod) return null;
      rec = rec.copyWith(toDate: toDate, toStart: s, toEnd: e);
      if (!rec.movesTime) rec = rec.copyWith(clearMove: true);
    }
    await _upsertDateEdit(old, rec);
    return rec.isEmpty ? null : rec;
  }

  /// 只删这一天的这次课（其他周 / 其他天不变）。scope=oneDay。
  Future<CourseDateEdit?> deleteOccurrence(GridCell cell) async {
    final key = _occurrenceKey(cell);
    if (key == null || baseOccurrenceOf(cell) == null) return null;
    final old = _findDateEdit(key);
    final rec =
        (old ??
                CourseDateEdit(
                  id: 'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
                  courseId: key.courseId,
                  date: key.date,
                  origStart: key.start,
                  origEnd: key.end,
                  createdAt: DateTime.now().toIso8601String(),
                ))
            .copyWith(
              kind: DateEditKind.delete,
              scope: DateEditScope.oneDay,
              clearWeeks: true,
            );
    await _upsertDateEdit(old, rec);
    return rec;
  }

  /// 编辑页「应用周数」：对勾选周写入一条 scope=weeks 的修改。
  /// [weeks] 空 → null（调用方应拦截）。单周且等于格子所在周 → 退回 [editOccurrence]
  /// （oneDay，不写 weeks）。
  Future<CourseDateEdit?> editOccurrenceWeeks(
    GridCell cell, {
    required List<int> weeks,
    String? name,
    String? teacher,
    String? location,
    String? note,
    int? toDay,
    int? toStart,
    int? toEnd,
  }) async {
    final sorted = {...weeks}.where((w) => w >= 1).toList()..sort();
    if (sorted.isEmpty) return null;
    final key = _occurrenceKey(cell);
    if (key == null || baseOccurrenceOf(cell) == null) return null;
    final cellWeek = _weekOfDate(key.date);
    if (sorted.length == 1 && sorted.single == cellWeek) {
      return editOccurrence(
        cell,
        name: name,
        teacher: teacher,
        location: location,
        note: note,
        toDay: toDay,
        toStart: toStart,
        toEnd: toEnd,
      );
    }
    // 替换同课程同节次的旧 weeks 记录。
    CourseDateEdit? old;
    for (final e in _dateEdits) {
      if (e.isWeeksScoped &&
          e.courseId == key.courseId &&
          e.date.weekday == key.date.weekday &&
          e.origStart == key.start &&
          e.origEnd == key.end) {
        old = e;
      }
    }
    var rec =
        old ??
        CourseDateEdit(
          id: 'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
          courseId: key.courseId,
          date: key.date,
          origStart: key.start,
          origEnd: key.end,
          createdAt: DateTime.now().toIso8601String(),
        );
    rec = rec.copyWith(
      kind: DateEditKind.edit,
      scope: DateEditScope.weeks,
      weeks: sorted,
      name: name,
      teacher: teacher,
      location: location,
      note: note,
    );
    if (toDay != null || toStart != null || toEnd != null) {
      final monday = mondayOfWeek(cell.date!);
      final toDate = toDay == null
          ? rec.toDate ?? key.date
          : DateTime(monday.year, monday.month, monday.day + toDay - 1);
      final curStart = rec.toStart ?? key.start;
      final curEnd = rec.toEnd ?? key.end;
      final s = toStart ?? curStart;
      final e = toEnd ?? (toStart == null ? curEnd : s + (curEnd - curStart));
      if (s < 1 || e < s || e > lastPeriod) return null;
      rec = rec.copyWith(toDate: toDate, toStart: s, toEnd: e);
      if (!rec.movesTime) rec = rec.copyWith(clearMove: true);
    }
    await _upsertDateEdit(old, rec);
    return rec.isEmpty ? null : rec;
  }

  /// 删除菜单第 2 档：全部同星期 + 同老师同地点（空则同名课）。
  Future<CourseDateEdit?> deleteWeekdayMatch(GridCell cell) async {
    final key = _occurrenceKey(cell);
    if (key == null || baseOccurrenceOf(cell) == null) return null;
    final teacher = cell.slot.teacher;
    final location = cell.slot.location;
    final empty = teacher.isEmpty || location.isEmpty;
    // 替换同课程同 weekday 的旧 weekdayMatch 删除。
    CourseDateEdit? old;
    for (final e in _dateEdits) {
      if (e.isWeekdayMatch &&
          e.isDelete &&
          e.courseId == key.courseId &&
          e.weekday == key.date.weekday) {
        old = e;
      }
    }
    final rec = CourseDateEdit(
      id:
          old?.id ??
          'dedit-${DateTime.now().microsecondsSinceEpoch}-${_dateEditSeq++}',
      courseId: key.courseId,
      date: key.date,
      origStart: key.start,
      origEnd: key.end,
      kind: DateEditKind.delete,
      scope: DateEditScope.weekdayMatch,
      weekday: key.date.weekday,
      matchEmptyTeacherLocation: empty,
      // 空放宽时 name 存课名快照；否则 teacher/location 为匹配快照。
      name: empty ? cell.course.name : null,
      teacher: empty ? null : teacher,
      location: empty ? null : location,
      createdAt: old?.createdAt ?? DateTime.now().toIso8601String(),
    );
    await _upsertDateEdit(old, rec);
    return rec;
  }

  /// 详情「已修改·恢复」：删掉一条单日修改。id 不存在返回 false。
  Future<bool> restoreDateEdit(String id) async {
    final next = [
      for (final e in _dateEdits)
        if (e.id != id) e,
    ];
    if (next.length == _dateEdits.length) return false;
    await _setDateEdits(next);
    return true;
  }

  /// 「所有周」保存后去掉这条单日修改里同名的字段（让课程本身的新值在这天也生效）；
  /// 变空就删。id 不存在返回 false。
  Future<bool> clearDateEditFields(
    String id, {
    bool name = false,
    bool teacher = false,
    bool location = false,
    bool note = false,
    bool courseKind = false,
    bool color = false,
    bool move = false,
  }) async {
    final i = _dateEdits.indexWhere((e) => e.id == id);
    if (i < 0) return false;
    final rec = _dateEdits[i].copyWith(
      clearName: name,
      clearTeacher: teacher,
      clearLocation: location,
      clearNote: note,
      clearCourseKind: courseKind,
      clearColor: color,
      useDefaultColor: color ? false : null,
      clearMove: move,
    );
    await _upsertDateEdit(_dateEdits[i], rec);
    return true;
  }

  Future<void> _upsertDateEdit(CourseDateEdit? old, CourseDateEdit rec) async {
    final next = [
      for (final e in _dateEdits)
        if (old == null || e.id != old.id) e,
      if (!rec.isEmpty) rec,
    ];
    await _setDateEdits(next);
  }

  Future<void> _setDateEdits(
    List<CourseDateEdit> next, {
    bool fire = true,
  }) async {
    await _inScope(() => ScheduleStore.saveCourseDateEdits(next));
    _dateEdits = List.unmodifiable(next);
    notifyListeners();
    if (fire) _fireScheduleChanged(ScheduleChangeReason.dateEdit);
  }

  /// 拖动保存「只改这一天」：普通格走拖动调课（[moveSlot] 只改本周，与以前一致）；
  /// 整天调课换来的格、已有单日修改的格、或落到调课日期时写单日修改记录。
  Future<MoveResult> moveOccurrenceThisDay(
    GridCell cell, {
    required int toDay,
    required int toStartPeriod,
    int? week,
  }) async {
    final base = baseOccurrenceOf(cell, week: week);
    if (base == null) return const MoveResult.error(MoveError.invalidSlot);
    if (toDay < 1 || toDay > 7 || toStartPeriod < 1) {
      return const MoveResult.error(MoveError.invalidTarget);
    }
    final key = _occurrenceKey(cell);
    final d = cell.date;
    if (key == null || d == null) {
      return moveSlot(
        base.course,
        base.slotIndex,
        toDay: toDay,
        toStartPeriod: toStartPeriod,
        week: base.week,
        scope: MoveScope.thisWeek,
      );
    }
    final monday = mondayOfWeek(d);
    final toDate = DateTime(monday.year, monday.month, monday.day + toDay - 1);
    final perDate =
        cell.swappedFrom != null ||
        cell.dateEdit != null ||
        isSwappedDate(toDate) ||
        isSwappedDate(key.date);
    if (!perDate) {
      return moveSlot(
        base.course,
        base.slotIndex,
        toDay: toDay,
        toStartPeriod: toStartPeriod,
        week: base.week,
        scope: MoveScope.thisWeek,
      );
    }
    final span = cell.slot.span;
    final toEnd = toStartPeriod + span - 1;
    if (toEnd > lastPeriod) {
      return const MoveResult.error(MoveError.pastLastPeriod);
    }
    if (toDay == cell.slot.day && toStartPeriod == cell.slot.startNode) {
      return const MoveResult.noChange();
    }
    // 拖回这次课的原位置时记录里的挪动被清掉（记录变空就删）。
    await editOccurrence(
      cell,
      toDay: toDay,
      toStart: toStartPeriod,
      toEnd: toEnd,
    );
    final w = _weekOfDate(toDate);
    return MoveResult.moved(
      affectedWeeks: [w],
      conflictNames: _conflictNames(key.courseId, toDay, toStartPeriod, toEnd, [
        w,
      ]),
    );
  }

  /// 拖动保存「所有周」：改课程本身（该时段所有有课的周，[MoveScope.allWeeks]）。
  /// 整天调课换来的格指回原日期那次课的时段。
  Future<MoveResult> moveOccurrenceAllWeeks(
    GridCell cell, {
    required int toDay,
    required int toStartPeriod,
    int? week,
  }) async {
    final base = baseOccurrenceOf(cell, week: week);
    if (base == null) return const MoveResult.error(MoveError.invalidSlot);
    return moveSlot(
      base.course,
      base.slotIndex,
      toDay: toDay,
      toStartPeriod: toStartPeriod,
      week: base.week,
      scope: MoveScope.allWeeks,
    );
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
          cell.slot.startNode <= startNode &&
          cell.slot.endNode >= startNode) {
        return cell;
      }
    }
    return null;
  }

  /// 指定日期的课程（用于明天预告）。
  /// [allowPendingWeek] 允许开学日未设定时沿用网格的第 1 周。
  List<TodayCourseItem> coursesOnDate(
    DateTime date, {
    bool allowPendingWeek = false,
  }) {
    if (weekPending && !allowPendingWeek) return const [];
    final cells = _timedCellsOn(date);
    return [
      for (final cell in cells)
        TodayCourseItem(
          course: cell.course,
          slot: cell.slot,
          status: TodayCourseStatus.upcoming,
        ),
    ];
  }

  // 今日/明日及原生导出使用合并后的连堂；周视图保留逐条记录供编辑寻址。
  List<GridCell> _timedCellsOn(DateTime date) {
    final cells = _activeCellsOn(date).toList();
    final out = <GridCell>[];
    for (final course in courses) {
      final group = cells.where((c) => c.course.id == course.id).toList();
      final runs = mergeTimingSlots(course, [for (final c in group) c.slot]);
      for (final slot in runs) {
        final displayCourse = course.forSlot(slot);
        final first = group.firstWhere(
          (c) => c.slot.startNode == slot.startNode,
        );
        final segments = resolveTimingSegments(
          periods: periods,
          startNode: slot.startNode,
          endNode: slot.endNode,
          kind: timingKindOf(course: displayCourse, slot: slot),
        );
        final displaySlots = [
          if (segments.isEmpty) slot, // 缺作息时保留课程，不能让首课查询丢数据。
          for (final segment in segments)
            segment.startNode == slot.startNode &&
                    segment.endNode == slot.endNode
                ? slot
                : CourseSlot(
                    day: slot.day,
                    startNode: segment.startNode,
                    endNode: segment.endNode,
                    weeks: slot.weeks,
                    weeksLabel: slot.weeksLabel,
                    teacher: slot.teacher,
                    location: slot.location,
                    note: slot.note,
                    istk: slot.istk,
                    isLab: slot.isLab,
                    kind: slot.kind,
                    nameOverride: slot.nameOverride,
                    color: slot.color,
                    useDefaultColor: slot.useDefaultColor,
                  ),
        ];
        for (final displaySlot in displaySlots) {
          out.add(
            GridCell(
              course: displayCourse,
              slot: displaySlot,
              conflictCount: first.conflictCount,
              activeThisWeek: true,
              date: first.date,
              swappedFrom: first.swappedFrom,
              dateEdit: first.dateEdit,
            ),
          );
        }
      }
    }
    out.sort((a, b) => a.slot.startNode.compareTo(b.slot.startNode));
    return out;
  }

  /// 明天第一节课，供小组件「之后」行等调用；先调用 [ensureStarted] 载入本机课表。
  ///
  /// 按本机自然日计算，使用套用改课、调课后的实际课程与节次，不受首页明天开关影响。
  /// 无课、无开学日或不在学期内返回 null。显示名统一读取返回值的 `course.displayName`，
  /// 实际起止时刻可交给 [effectiveSlotTime] 换算（含实验/体育课时刻规则）。
  TodayCourseItem? firstCourseTomorrow({DateTime? now}) {
    final today = now ?? DateTime.now();
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final week = actualWeek(tomorrow);
    if (week == null || week < 1 || week > totalWeeks) return null;
    return coursesOnDate(tomorrow).firstOrNull;
  }

  /// 今日课程（按节次排序，最多取完）。
  List<TodayCourseItem> todayCourses({DateTime? now}) {
    final n = now ?? DateTime.now();
    // 用「今天」的真实周（不钳制），开学前/学期后无课、无提醒。
    final cells = _timedCellsOn(n);
    final items = <TodayCourseItem>[];
    for (final cell in cells) {
      final time = timeForSlot(cell.course, cell.slot, date: n);
      final start = _timeOf(n, time.start);
      final end = _timeOf(n, time.end);
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

  /// 时段在给定课程类型下的实际起止（实验/体育会取消小课间）。
  ///
  /// 见 `timetable_timing.dart` 的 [effectiveSlotBounds] / [resolveTimingSegments]。
  ({String? start, String? end}) effectiveSlotTime(
    int startNode,
    int endNode, {
    CourseTimingKind kind = CourseTimingKind.standard,
  }) => effectiveSlotBounds(
    periods: periods,
    startNode: startNode,
    endNode: endNode,
    kind: kind,
  );

  /// 课程各显示面共用的实际时刻入口；逐条记录先按当日连堂合并再取本记录的边界。
  ({String? start, String? end}) timeForSlot(
    Course course,
    CourseSlot slot, {
    DateTime? date,
  }) {
    final kind = timingKindOf(course: course, slot: slot);
    if (kind == CourseTimingKind.standard) {
      return effectiveSlotTime(slot.startNode, slot.endNode, kind: kind);
    }
    final day = date ?? dateOfColumn(currentWeek, slot.day);
    final peers = cellsForDay(actualWeek(day) ?? currentWeek, day.weekday)
        .where((c) => c.activeThisWeek && c.course.id == course.id)
        .map((c) => c.slot)
        .toList();
    final run = mergeTimingSlots(course, peers)
        .where(
          (s) => s.startNode <= slot.startNode && s.endNode >= slot.endNode,
        )
        .firstOrNull;
    if (run == null) {
      return effectiveSlotTime(slot.startNode, slot.endNode, kind: kind);
    }
    final segments = resolveTimingSegments(
      periods: periods,
      startNode: run.startNode,
      endNode: run.endNode,
      kind: kind,
    );
    String? shifted(int node, bool start) {
      final segment = segments
          .where((s) => s.startNode <= node && s.endNode >= node)
          .firstOrNull;
      final raw = start ? periodStart(node) : periodEnd(node);
      final value = TimeOfDayMinutes.tryParse(raw);
      if (segment == null || value == null) return raw;
      // 仍由 effectiveSlotTime 决定累计压缩量，各显示面不另写时刻规则。
      final adjustedEnd = TimeOfDayMinutes.tryParse(
        effectiveSlotTime(segment.startNode, node, kind: kind).end,
      );
      final standardEnd = TimeOfDayMinutes.tryParse(periodEnd(node));
      if (adjustedEnd == null || standardEnd == null) return raw;
      final minutes =
          value.totalMinutes +
          adjustedEnd.totalMinutes -
          standardEnd.totalMinutes;
      return '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
    }

    return (
      start: shifted(slot.startNode, true),
      end: shifted(slot.endNode, false),
    );
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

  @override
  void dispose() {
    _viewingWeekNotifier.dispose();
    super.dispose();
  }
}

/// 浏览周次独立通知器：写入 [value] 仅通知周次监听方，[setSilent] 供退出清理与测试重置静默写回。
class _ViewingWeekNotifier extends ValueNotifier<int> {
  _ViewingWeekNotifier(super.value) : _current = value;

  int _current;

  @override
  int get value => _current;

  @override
  set value(int newValue) {
    if (_current == newValue) return;
    _current = newValue;
    notifyListeners();
  }

  void setSilent(int newValue) {
    _current = newValue;
  }
}

/// [TimetableController.cellsForDay] 的候选格。
class _Cand {
  _Cand(this.course, this.slot, this.active, {this.swappedFrom, this.dateEdit});
  final Course course;
  final CourseSlot slot;
  final bool active;
  final DateTime? swappedFrom;
  final CourseDateEdit? dateEdit;
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
