import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/portal_http.dart' show portalLog;
import '../../core/auth/session_executor.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import 'timetable_models.dart';
import 'timetable_multi_models.dart';
import '../../core/auth/safe_message.dart';
import 'timetable_exam_parser.dart';
import 'timetable_schedule_event.dart';

export '../../core/auth/service_auth_spec.dart' show JwxtUnexpectedHtmlError;

/// 教务 EMAP「我的课表」应用（**wdkb**）接口。
///
/// 接口确认（详见本目录 README.md）：
/// - 先 GET `*default/index.do` 建立应用会话
/// - 课表：`…/modules/xskcb/cxxszhxqkb.do`、`xswpkc.do`
/// - 学期/周次/节次：`…/modules/jshkcb/dqxnxq.do`、`dqzc.do`、`jc.do`
///   （注意前缀是 **jshkcb**，不是 xskcb）
class TimetableApi {
  TimetableApi._();
  static final _log = AppLog.logger('timetable.api');

  static final _base = 'https://${CampusHosts.jwxt}';
  static const _app = 'wdkb';

  static final Uri _indexUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/*default/index.do?EMAP_LANG=zh',
  );

  /// 抓包中 XHR 的 Referer（不带 query）。
  static final _referer = '$_base/jwapp/sys/$_app/*default/index.do';
  static final Uri _weekKbUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/cxxszhxqkb.do',
  );
  static final Uri _unscheduledUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/xswpkc.do',
  );

  /// 已确认角色时在应用建会话阶段设置；默认不指定角色。
  @visibleForTesting
  static String? rolePreCallRoleId;

  static final Uri _dqxnxqUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/jshkcb/dqxnxq.do',
  );
  static final Uri _dqzcUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/jshkcb/dqzc.do',
  );
  static final Uri _jcUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/jshkcb/jc.do',
  );
  static final Uri _xnxqcxUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/jshkcb/xnxqcx.do',
  );

  // 仍未核实方法/参数：cxjcs.do、cxxljc.do（可选）
  static final Uri _cxjcsUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/cxjcs.do',
  );
  static final Uri _cxxljcUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/cxxljc.do',
  );

  static JwxtAppSpec get _wdkb => JwxtAppSpec(
    appId: _app,
    indexUrl: _indexUrl.toString(),
    refererUrl: _referer,
    roleId: rolePreCallRoleId,
  );

  // ---- 我的考试安排（studentWdksapApp，第 11 条，见本目录 README.md）----

  static const _examAppName = 'studentWdksapApp';
  static final _examIndex = '$_base/jwapp/sys/$_examAppName/*default/index.do';

  /// 考试应用：先 GET 应用首页建立会话，XHR 的 Referer 为应用首页。
  static final _examApp = JwxtAppSpec(
    appId: _examAppName,
    indexUrl: _examIndex,
    refererUrl: _examIndex,
  );
  static final Uri _examListUrl = Uri.parse(
    '$_base/jwapp/sys/$_examAppName/WdksapController/cxxsksap.do',
  );

  /// cxxsksap 表单：只有 `requestParamStr`（JSON 字符串）。
  static Map<String, String> examForm(String termCode) => {
    'requestParamStr': jsonEncode({
      'XNXQDM': termCode,
      '*order': '-KSRQ,-KSSJMS',
    }),
  };

  /// 拉取 [termCode]（课表同步用的 XNXQDM）的考试安排，解析为 kind=exam、
  /// source=jwxt 的 [ScheduleEvent]。失败（非 2xx、code≠0、非 JSON、会话失效）抛错，
  /// 由调用方保留已有考试。成功且无考试 → 空列表。
  /// 日志只记跳过的条数，不记课程号、学号、教师或响应正文。
  static Future<List<ScheduleEvent>> fetchExams(String termCode) async {
    final decoded = await _post(
      _examListUrl,
      examForm(termCode),
      app: _examApp,
    );
    if (decoded == null) {
      throw const ExamResponseError('教务考试接口未返回 JSON');
    }
    final r = ExamParser.parse(decoded, expectedTermCode: termCode);
    if (r.skippedCourseCodes.isNotEmpty) {
      portalLog(
        'exams.records_skipped',
        fields: {
          'service': 'jwxt',
          'skipped_count': r.skippedCourseCodes.length,
        },
      );
    }
    return r.exams;
  }

  /// 拉取指定学期周课表行（已解析为 [Course]）。
  static Future<List<Course>> fetchSemesterCourses(String termCode) async {
    final rows = await _postRows(
      _weekKbUrl,
      sectionKey: 'cxxszhxqkb',
      form: {'XNXQDM': termCode},
    );
    return TimetableParser.parseKbRows(rows).courses;
  }

  /// 拉取未排课课程（`xswpkc`），解析为无固定时间 [Course]。
  static Future<List<Course>> fetchUnscheduledCourses(String termCode) async {
    final rows = await _postRows(
      _unscheduledUrl,
      sectionKey: 'xswpkc',
      form: {'XNXQDM': termCode},
    );
    return TimetableParser.parseKbRows(rows).courses;
  }

  /// 周课表 + 未排课（必需）+ 学期/周次/节次元数据（可选）快照。
  ///
  /// 元数据接口（jshkcb/dqxnxq、dqzc、jc）任一失败只记日志并跳过，
  /// 不影响课表；开学日缺失时由调用方用缓存值推算本周。
  static Future<TimetableSnapshot> fetchTermSnapshot(
    String termCode, {
    TimetableSettings? baseSettings,
    DateTime? now,
  }) async {
    var settings = baseSettings ?? const TimetableSettings();
    if (settings.termCode.isEmpty) {
      settings = settings.copyWith(termCode: termCode);
    }

    final datas = <String, dynamic>{};
    void merge(Map<String, dynamic>? raw) {
      final d = raw?['datas'];
      if (d is Map<String, dynamic>) datas.addAll(d);
    }

    // 必需：课表 + 未排课
    final weekRaw = await _post(_weekKbUrl, {'XNXQDM': termCode});
    if (weekRaw == null) {
      throw const DiagnosticException(
        '教务课表接口未返回数据',
        code: 'response_empty',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.cxxszhxqkb', 'service': 'jwxt'},
      );
    }
    final weekDatas = weekRaw['datas'];
    final weekSection = weekDatas is Map ? weekDatas['cxxszhxqkb'] : null;
    if (weekSection is! Map || weekSection['rows'] is! List) {
      throw const DiagnosticException(
        '教务课表响应缺少课程列表',
        code: 'response_rows_missing',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.cxxszhxqkb', 'service': 'jwxt'},
      );
    }
    merge(weekRaw);
    // 主课表请求已建立应用会话；其余只读请求互不依赖，避免逐个等待超时。
    // 未排课也是课程全集的一部分，失败不能发布只有周网格的部分快照。
    final unscheduled = _requiredSection(
      _post(_unscheduledUrl, {'XNXQDM': termCode}),
      section: 'xswpkc',
    );
    // 必需请求会在聚合等待前开始，提前消费错误以避免无人处理。
    unawaited(unscheduled.then<void>((_) {}, onError: (Object _) {}));

    // 可选：学期 / 节次 / 周次
    final parts = splitTermCode(termCode);
    final optionalSections = await Future.wait([
      unscheduled,
      _optional('dqxnxq', () => _post(_dqxnxqUrl, const {})),
      _optional('jc', () => _post(_jcUrl, const {})),
      if (parts != null)
        _optional('dqzc', () {
          final form = dqzcForm(parts, now ?? shanghaiToday());
          logDqzcForm(form);
          return _post(_dqzcUrl, form);
        }),
    ]);
    for (final section in optionalSections) {
      merge(section);
    }

    final snapshot = TimetableParser.parseImportJson({
      'code': '0',
      'datas': datas,
    }, baseSettings: settings.copyWith(termCode: termCode));
    return snapshot.copyWith(syncedAt: DateTime.now(), clearError: true);
  }

  /// 查询教务可选学年学期列表（`jshkcb/xnxqcx.do`），按学期降序返回。
  static Future<List<JwxtTermOption>> fetchAvailableTerms() async {
    final rows = await _postRows(
      _xnxqcxUrl,
      sectionKey: 'xnxqcx',
      form: const {'*order': '-DM'},
    );
    final out = <JwxtTermOption>[];
    final seen = <String>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final code = '${raw['DM'] ?? raw['XNXQDM'] ?? ''}'.trim();
      if (code.isEmpty || !seen.add(code)) continue;
      out.add(
        JwxtTermOption(
          termCode: code,
          displayName: '${raw['MC'] ?? ''}'.trim(),
        ),
      );
    }
    return out;
  }

  /// 拉取指定（往年/独立）学期快照：周课表 + 未排课 + `cxxljc`（开学日与周数）+ `jc`（节次）。
  /// 不调用 `dqxnxq` 与 `dqzc`，避免把历史学期代码或开学日覆盖为当前学期。
  static Future<TimetableSnapshot> fetchHistoricalTermSnapshot(
    String termCode, {
    TimetableSettings? baseSettings,
  }) async {
    final base = (baseSettings ?? const TimetableSettings()).copyWith(
      termCode: termCode,
      scheduleName: formatTermScheduleName(termCode),
    );
    final datas = <String, dynamic>{};
    void merge(Map<String, dynamic>? raw) {
      final d = raw?['datas'];
      if (d is Map<String, dynamic>) datas.addAll(d);
    }

    final weekRaw = await _post(_weekKbUrl, {'XNXQDM': termCode});
    if (weekRaw == null) {
      throw const DiagnosticException(
        '教务课表接口未返回数据',
        code: 'response_empty',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.cxxszhxqkb', 'service': 'jwxt'},
      );
    }
    final weekDatas = weekRaw['datas'];
    final weekSection = weekDatas is Map ? weekDatas['cxxszhxqkb'] : null;
    if (weekSection is! Map || weekSection['rows'] is! List) {
      throw const DiagnosticException(
        '教务课表响应缺少课程列表',
        code: 'response_rows_missing',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.cxxszhxqkb', 'service': 'jwxt'},
      );
    }
    merge(weekRaw);
    merge(
      await _optional(
        'xswpkc',
        () => _post(_unscheduledUrl, {'XNXQDM': termCode}),
      ),
    );
    merge(await _optional('jc', () => _post(_jcUrl, const {})));
    final parts = splitTermCode(termCode);
    if (parts != null) {
      merge(
        await _optional(
          'cxxljc',
          () => _post(_cxxljcUrl, {'XN': parts.year, 'XQ': parts.term}),
        ),
      );
    }

    final snapshot = TimetableParser.parseImportJson({
      'code': '0',
      'datas': datas,
    }, baseSettings: base);
    return snapshot.copyWith(
      settings: snapshot.settings.copyWith(
        termCode: termCode,
        scheduleName: base.scheduleName,
      ),
      syncedAt: DateTime.now(),
      clearError: true,
    );
  }

  static Future<Map<String, dynamic>?> _optional(
    String name,
    Future<Map<String, dynamic>?> Function() call,
  ) async {
    try {
      final r = await call();
      if (r == null) {
        AppLog.reportOutcome(
          'degraded',
          reason: 'optional_section_unavailable',
        );
        _log.warning(
          'optional.response_malformed',
          fields: {
            'service': 'jwxt',
            'endpoint': 'timetable.$name',
            'outcome': 'degraded',
            'reason_code': 'response_invalid_json',
          },
        );
      }
      return r;
    } catch (e, stackTrace) {
      AppLog.reportOutcome('degraded', reason: 'optional_section_unavailable');
      _log.warning(
        'optional.request_failed',
        fields: {
          'service': 'jwxt',
          'endpoint': 'timetable.$name',
          'outcome': 'degraded',
        },
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<Map<String, dynamic>> _requiredSection(
    Future<Map<String, dynamic>?> response, {
    required String section,
  }) async {
    final raw = await response;
    final datas = raw?['datas'];
    final rows = datas is Map ? datas[section] : null;
    if (rows is! Map || rows['rows'] is! List) {
      throw DiagnosticException(
        '教务课程响应缺少完整课程列表',
        code: raw == null ? 'response_empty' : 'response_rows_missing',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.$section', 'service': 'jwxt'},
      );
    }
    return raw!;
  }

  /// dqzc 表单参数（XN 学年 / XQ 学期 / RQ 日期）。
  static Map<String, String> dqzcForm(
    ({String year, String term}) parts,
    DateTime date,
  ) => {'XN': parts.year, 'XQ': parts.term, 'RQ': formatDate(date)};

  /// 仅 debug 构建打印 dqzc 表单参数。
  static void logDqzcForm(Map<String, String> form) {
    if (!kDebugMode) return;
    portalLog(
      'calendar.request_prepared',
      fields: {'service': 'jwxt', 'field_count': form.length},
    );
  }

  /// Asia/Shanghai (UTC+8) 当天日期，与设备时区无关。
  static DateTime shanghaiToday() {
    final t = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(t.year, t.month, t.day);
  }

  /// `yyyy-MM-dd`，不带时间。
  static String formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 当前学年学期代码（`POST jshkcb/dqxnxq.do`，空 body → `rows[0].DM`）。
  static Future<String> fetchCurrentTermCode() async {
    final rows = await _postRows(
      _dqxnxqUrl,
      sectionKey: 'dqxnxq',
      form: const {},
    );
    if (rows.isEmpty || rows.first is! Map) {
      throw const PortalLoginError('教务未返回当前学期（dqxnxq）');
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final code = '${row['DM'] ?? row['XNXQDM'] ?? ''}'.trim();
    if (code.isEmpty) {
      throw const PortalLoginError('教务 dqxnxq 缺少学期代码 DM');
    }
    return code;
  }

  /// 当前教学周次（`POST jshkcb/dqzc.do`，form `XN`/`XQ`/`RQ` → `ZC`）。
  ///
  /// [termCode] 缺省时先调 [fetchCurrentTermCode]；[date] 缺省为今天。
  static Future<int> fetchCurrentWeek({
    String? termCode,
    DateTime? date,
  }) async {
    final code = termCode ?? await fetchCurrentTermCode();
    final parts = splitTermCode(code);
    if (parts == null) {
      throw PortalLoginError('无法从学期代码解析学年/学期：$code');
    }
    final form = dqzcForm(parts, date ?? shanghaiToday());
    logDqzcForm(form);
    final rows = await _postRows(_dqzcUrl, sectionKey: 'dqzc', form: form);
    if (rows.isEmpty || rows.first is! Map) {
      throw const PortalLoginError('教务未返回当前周次（dqzc）');
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final zc = row['ZC'];
    final week = zc is int ? zc : int.tryParse('$zc');
    if (week == null || week < 1) {
      throw const PortalLoginError('教务 dqzc 缺少有效 ZC');
    }
    return week;
  }

  /// 节次作息（`POST jshkcb/jc.do`，空 body → `datas.jc.rows`）。
  static Future<List<PeriodTime>> fetchPeriods() async {
    final rows = await _postRows(_jcUrl, sectionKey: 'jc', form: const {});
    final periods = TimetableParser.parsePeriods(rows);
    if (periods.isEmpty) {
      throw const PortalLoginError('教务 jc 未返回可用节次');
    }
    return periods;
  }

  /// `2026-2027-1` → year=`2026-2027`, term=`1`。
  static ({String year, String term})? splitTermCode(String termCode) {
    final trimmed = termCode.trim();
    final dash = trimmed.lastIndexOf('-');
    if (dash <= 0 || dash >= trimmed.length - 1) return null;
    final year = trimmed.substring(0, dash);
    final term = trimmed.substring(dash + 1);
    if (year.isEmpty || term.isEmpty) return null;
    return (year: year, term: term);
  }

  // Exposed for docs / future use; still unverified.
  static Uri get cxjcsStubUrl => _cxjcsUrl;
  static Uri get cxxljcStubUrl => _cxxljcUrl;

  // --- internals -----------------------------------------------------------

  static Future<List<dynamic>> _postRows(
    Uri url, {
    required String sectionKey,
    required Map<String, String> form,
  }) async {
    final decoded = await _post(url, form);
    if (decoded == null) {
      throw DiagnosticException(
        '教务课表接口未返回数据',
        code: 'response_empty',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.$sectionKey', 'service': 'jwxt'},
      );
    }
    final datas = decoded['datas'];
    if (datas is! Map<String, dynamic>) {
      throw DiagnosticException(
        '教务响应缺少数据段',
        code: 'response_section_missing',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.$sectionKey', 'service': 'jwxt'},
      );
    }
    final section = datas[sectionKey] ?? _findRowsSection(datas);
    final rows = section is Map ? section['rows'] : null;
    if (rows is! List) {
      throw DiagnosticException(
        '教务响应缺少列表',
        code: 'response_rows_missing',
        stage: 'response.validate',
        context: {'endpoint': 'timetable.$sectionKey', 'service': 'jwxt'},
      );
    }
    return rows;
  }

  /// 测试钩子：替换实际 HTTP。返回 null 表示「非 JSON」，抛错模拟 HTTP 失败。
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(
    Uri url,
    Map<String, String> form,
  )?
  debugPost;

  /// 测试时替换统一鉴权执行器，保留实际建会话与请求流程。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static Future<Map<String, dynamic>?> _post(
    Uri url,
    Map<String, String> form, {
    JwxtAppSpec? app,
  }) async {
    final hook = debugPost;
    if (hook != null) return hook(url, form);
    final encoded = form.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          app ?? _wdkb,
          () => RequestOptions(
            path: url.toString(),
            method: 'POST',
            data: encoded,
            contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
            responseType: ResponseType.plain,
            headers: {
              'Accept': 'application/json, text/javascript, */*; q=0.01',
              'X-Requested-With': 'XMLHttpRequest',
              'Origin': _base,
            },
          ),
          idempotent: true,
        );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw JwxtHttpError(url.path.split('/').last, status);
    }
    final raw = response.data;
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map<String, dynamic>) return null;
      final code = '${decoded['code'] ?? ''}';
      if (code.isNotEmpty && code != '0') {
        // 只记 code：响应正文可能含学号等个人信息，不打印。
        portalLog(
          'response.rejected',
          fields: {'service': 'jwxt', 'response_code': code},
        );
        throw DiagnosticException(
          prefixedServerMessage(
            '教务课表接口返回错误：',
            decoded['msg'],
            fallback: '教务课表接口返回错误，请稍后重试',
          ),
          code: 'service_rejected',
          stage: 'response.validate',
          context: {
            'endpoint': 'timetable.${url.path.split('/').last}',
            'service': 'jwxt',
            'response_code': code,
          },
        );
      }
      return decoded;
    } on FormatException catch (error, stackTrace) {
      throw DiagnosticException(
        '教务响应不是有效 JSON',
        code: 'response_invalid_json',
        stage: 'response.decode',
        cause: error,
        causeStackTrace: stackTrace,
        context: {
          'endpoint': 'timetable.${url.path.split('/').last}',
          'service': 'jwxt',
        },
      );
    }
  }

  static Map<String, dynamic>? _findRowsSection(Map<String, dynamic> datas) {
    for (final value in datas.values) {
      if (value is Map<String, dynamic> && value['rows'] is List) {
        return value;
      }
    }
    return null;
  }
}

/// 教务会话失效且单次重登后仍失效。
class JwxtSessionExpiredError extends PortalLoginError {
  const JwxtSessionExpiredError(super.message);
}

/// 教务接口非 2xx（且不是会话失效）。
class JwxtHttpError implements Exception, DiagnosticError {
  const JwxtHttpError(this.endpoint, this.status);
  final String endpoint;
  final int status;
  @override
  Object? get cause => null;
  @override
  StackTrace? get causeStackTrace => null;
  @override
  Map<String, Object?> get diagnosticContext => {
    'endpoint': 'timetable.$endpoint',
    'service': 'jwxt',
    'status_code': status,
    'stage': 'request.complete',
    'reason_code': 'http_status_rejected',
  };
  @override
  String toString() => '教务 $endpoint 返回 HTTP $status';
}
