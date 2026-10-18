import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import 'timetable_models.dart';
import '../../core/auth/safe_message.dart';
import 'timetable_exam_parser.dart';
import 'timetable_schedule_event.dart';

/// 教务 EMAP「我的课表」应用（**wdkb**）接口。
///
/// 接口确认（详见本目录 README.md）：
/// - 先 GET `*default/index.do` 建立应用会话
/// - 课表：`…/modules/xskcb/cxxszhxqkb.do`、`xswpkc.do`
/// - 学期/周次/节次：`…/modules/jshkcb/dqxnxq.do`、`dqzc.do`、`jc.do`
///   （注意前缀是 **jshkcb**，不是 xskcb）
class TimetableApi {
  TimetableApi._();

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

  /// 当前学期 / 周次 / 作息（jshkcb）
  /// 公共角色设置（网页端在 dqxnxq/dqzc 前调用）。默认不启用，见 [rolePreCallRoleId]。
  static final Uri _setRoleUrl = Uri.parse(
    '$_base/jwapp/sys/jwpubapp/pub/setJwCommonAppRole.do',
  );

  /// 预留：若端点更名后仍 403，再设置 ROLEID 以启用同步前的
  /// `setJwCommonAppRole`（非致命）。默认 null = 不调用；ROLEID 不写死，需另行确定来源。
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

  // 仍未核实方法/参数：cxjcs.do、cxxljc.do（可选）
  static final Uri _cxjcsUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/cxjcs.do',
  );
  static final Uri _cxxljcUrl = Uri.parse(
    '$_base/jwapp/sys/$_app/modules/xskcb/cxxljc.do',
  );

  /// 课表应用（wdkb）的首页与 Referer；`ready` = 本进程已进过应用首页。
  static final _wdkb = _JwxtApp(_indexUrl, _referer);

  // ---- 我的考试安排（studentWdksapApp，第 11 条，见本目录 README.md）----

  static const _examAppName = 'studentWdksapApp';
  static final _examIndex = '$_base/jwapp/sys/$_examAppName/*default/index.do';

  /// 考试应用：先 GET 应用首页建立会话，XHR 的 Referer 为应用首页。
  static final _examApp = _JwxtApp(Uri.parse(_examIndex), _examIndex);
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
  /// 日志只记跳过的条数与课程号，不记学号、教师或响应正文。
  static Future<List<ScheduleEvent>> fetchExams(String termCode) async {
    final decoded = await _post(
      _examListUrl,
      examForm(termCode),
      app: _examApp,
    );
    if (decoded == null) {
      throw const ExamResponseError('教务考试接口未返回 JSON');
    }
    final r = ExamParser.parse(decoded);
    if (r.skippedCourseCodes.isNotEmpty) {
      portalLog(
        () =>
            '教务考试 ${r.skippedCourseCodes.length} 条格式不对已跳过'
            '（KCH：${r.skippedCourseCodes.map((c) => c.isEmpty ? '缺' : c).join('、')}）',
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
    _reloginUsed = false;
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
      throw const PortalLoginError('教务课表接口未返回 JSON，请重新登录后再试');
    }
    merge(weekRaw);
    merge(
      await _optional(
        'xswpkc',
        () => _post(_unscheduledUrl, {'XNXQDM': termCode}),
      ),
    );

    // 可选（默认关闭）：角色预调用
    final roleId = rolePreCallRoleId;
    if (roleId != null && roleId.isNotEmpty) {
      await _optional(
        'setJwCommonAppRole',
        () => _post(_setRoleUrl, {'ROLEID': roleId}),
      );
    }

    // 可选：学期 / 节次 / 周次
    merge(await _optional('dqxnxq', () => _post(_dqxnxqUrl, const {})));
    merge(await _optional('jc', () => _post(_jcUrl, const {})));
    final parts = splitTermCode(termCode);
    if (parts != null) {
      merge(
        await _optional('dqzc', () {
          final form = dqzcForm(parts, now ?? shanghaiToday());
          logDqzcForm(form);
          return _post(_dqzcUrl, form);
        }),
      );
    }

    final snapshot = TimetableParser.parseImportJson({
      'code': '0',
      'datas': datas,
    }, baseSettings: settings.copyWith(termCode: termCode));
    return snapshot.copyWith(syncedAt: DateTime.now(), clearError: true);
  }

  static Future<Map<String, dynamic>?> _optional(
    String name,
    Future<Map<String, dynamic>?> Function() call,
  ) async {
    try {
      final r = await call();
      if (r == null) portalLog(() => '教务 $name 非 JSON 响应，跳过（非致命）');
      return r;
    } catch (e) {
      portalLog(() => '教务 $name 失败，跳过（非致命）：$e');
      return null;
    }
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
      () => '教务 dqzc 请求参数 XN=${form['XN']} XQ=${form['XQ']} RQ=${form['RQ']}',
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
      throw const PortalLoginError('教务课表接口未返回 JSON，请重新登录后再试');
    }
    final datas = decoded['datas'];
    if (datas is! Map<String, dynamic>) return const [];
    final section = datas[sectionKey] ?? _findRowsSection(datas);
    final rows = section is Map ? section['rows'] : null;
    if (rows is! List) return const [];
    return rows;
  }

  /// 测试钩子：替换实际 HTTP。返回 null 表示「非 JSON」，抛错模拟 HTTP 失败。
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(
    Uri url,
    Map<String, String> form,
  )?
  debugPost;

  /// 测试钩子：替换 [_postOnce] 内的原始 HTTP 响应（保留会话失效检测与单次重登逻辑）。
  @visibleForTesting
  static Future<Response<dynamic>> Function(
    Uri url,
    Map<String, String> form, {
    required bool force,
  })?
  debugPostResponse;

  /// 一次同步内最多强制重登一次。
  static bool _reloginUsed = false;

  static Future<Map<String, dynamic>?> _post(
    Uri url,
    Map<String, String> form, {
    _JwxtApp? app,
  }) async {
    final hook = debugPost;
    if (hook != null) return hook(url, form);

    var result = await _postOnce(url, form, force: false, app: app);
    if (result is _SessionExpired) {
      if (_reloginUsed) {
        throw const JwxtSessionExpiredError('教务会话失效且本次同步已重登过，请稍后再试');
      }
      _reloginUsed = true;
      portalLog(() => '教务 wdkb 会话失效，重新登录（本次同步仅一次）');
      result = await _postOnce(url, form, force: true, app: app);
      if (result is _SessionExpired) {
        throw const JwxtSessionExpiredError('重新登录后教务仍要求登录，请稍后再试');
      }
    }
    return (result as _Ok).json;
  }

  static Future<_PostResult> _postOnce(
    Uri url,
    Map<String, String> form, {
    required bool force,
    _JwxtApp? app,
  }) async {
    final a = app ?? _wdkb;
    final rawHook = debugPostResponse;
    final response = rawHook != null
        ? await rawHook(url, form, force: force)
        : await _postHttp(url, form, force: force, app: a);
    final status = response.statusCode ?? 0;
    // 分类顺序：
    // 1) 5xx → 服务器错误（即使返回 HTML），绝不重登；
    // 2) 401 / 跳到 authserver/login / 200 HTML 登录页 → 会话失效；
    // 3) 200 HTML 但不是登录页（如 WebVPN 维护页）→ 未知错误，不重登；
    // 4) 200 JSON code != "0" → 未知错误（见下方）。
    if (status >= 500) {
      throw JwxtHttpError(url.path.split('/').last, status);
    }
    if (status == 401 || _isSessionExpiredResponse(response)) {
      a.ready = false;
      return const _SessionExpired();
    }
    if (status < 200 || status >= 300) {
      throw JwxtHttpError(url.path.split('/').last, status);
    }
    if (_isHtmlResponse(response)) {
      throw JwxtUnexpectedHtmlError(url.path.split('/').last);
    }
    final raw = response.data;
    if (raw == null) return const _Ok(null);
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map<String, dynamic>) return const _Ok(null);
      final code = '${decoded['code'] ?? ''}';
      if (code.isNotEmpty && code != '0') {
        // 只记 code：响应正文可能含学号等个人信息，不打印。
        if (kDebugMode) portalLog(() => '教务接口返回错误 code=$code');
        throw PortalLoginError(
          prefixedServerMessage(
            '教务课表接口返回错误：',
            decoded['msg'],
            fallback: '教务课表接口返回错误，请稍后重试',
          ),
        );
      }
      return _Ok(decoded);
    } on FormatException {
      return const _Ok(null);
    }
  }

  static Future<Response<dynamic>> _postHttp(
    Uri url,
    Map<String, String> form, {
    required bool force,
    required _JwxtApp app,
  }) async {
    final http = await _client(force: force, app: app);
    // dqxnxq / jc 抓包为空 body（Content-Length 0）
    final encoded = form.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return http.followRedirects(
      await http.post(
        url,
        data: encoded,
        contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
        headers: {
          'Accept': 'application/json, text/javascript, */*; q=0.01',
          'X-Requested-With': 'XMLHttpRequest',
          'Origin': _base,
          'Referer': app.referer,
        },
      ),
    );
  }

  static Map<String, dynamic>? _findRowsSection(Map<String, dynamic> datas) {
    for (final value in datas.values) {
      if (value is Map<String, dynamic> && value['rows'] is List) {
        return value;
      }
    }
    return null;
  }

  static Future<PortalHttp> _client({
    required bool force,
    _JwxtApp? app,
  }) async {
    final a = app ?? _wdkb;
    final session = PortalSession.instance;
    final http = await session.clientFor(PortalServices.jwxt, force: force);
    if (a.ready && !force) return http;
    final response = await http.followRedirects(
      await http.get(
        a.indexUrl,
        headers: {'Accept': 'text/html,application/xhtml+xml'},
      ),
    );
    if (_looksLikeLoginPage(response)) {
      a.ready = false;
      if (!force) {
        final fresh = await session.clientFor(PortalServices.jwxt, force: true);
        final retry = await fresh.followRedirects(
          await fresh.get(
            a.indexUrl,
            headers: {'Accept': 'text/html,application/xhtml+xml'},
          ),
        );
        if (_looksLikeLoginPage(retry)) {
          throw const JwxtSessionExpiredError('重新登录后仍被教务拦回登录页，请稍后再试');
        }
        a.ready = true;
        return fresh;
      }
      throw const JwxtSessionExpiredError('重新登录后仍被教务拦回登录页，请稍后再试');
    }
    a.ready = true;
    return http;
  }

  /// Dio 跟随重定向后会话失效常以 200 到达：最终 URL 落在 authserver/login，
  /// 或返回 text/html（非 JSON）登录页。
  static bool _isSessionExpiredResponse(Response<dynamic> response) {
    if (response.realUri.toString().contains('authserver/login')) return true;
    for (final r in response.redirects) {
      if (r.location.toString().contains('authserver/login')) return true;
    }
    final status = response.statusCode ?? 0;
    if (status == 200 && _isHtmlResponse(response)) {
      final body = response.data as String;
      return body.contains('casLoginForm') || body.contains('authserver');
    }
    return false;
  }

  static bool _looksLikeLoginPage(Response<dynamic> response) {
    if (response.realUri.host.contains('authserver')) return true;
    final body = response.data;
    return body is String &&
        body.contains('authserver/login') &&
        (body.contains('name="execution"') || body.contains('casLoginForm'));
  }

  /// 响应体是 HTML（而不是 JSON）。按 content-type 或正文开头判断。
  static bool _isHtmlResponse(Response<dynamic> response) {
    final body = response.data;
    if (body is! String) return false;
    final t = body.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) return false;
    final ct = response.headers.value(Headers.contentTypeHeader) ?? '';
    return ct.contains('text/html') ||
        t.startsWith('<') ||
        t.toLowerCase().contains('<html');
  }
}

/// 教务接口返回 200 HTML 但不是登录页（如 WebVPN 维护页），归为未知错误。
class JwxtUnexpectedHtmlError implements Exception {
  const JwxtUnexpectedHtmlError(this.endpoint);

  final String endpoint;

  @override
  String toString() => '教务接口 $endpoint 返回了非预期的 HTML 页面';
}

/// 教务会话失效且单次重登后仍失效。
class JwxtSessionExpiredError extends PortalLoginError {
  const JwxtSessionExpiredError(super.message);
}

/// 教务接口非 2xx（且不是会话失效）。
class JwxtHttpError implements Exception {
  const JwxtHttpError(this.endpoint, this.status);
  final String endpoint;
  final int status;
  @override
  String toString() => '教务 $endpoint 返回 HTTP $status';
}

sealed class _PostResult {
  const _PostResult();
}

class _Ok extends _PostResult {
  const _Ok(this.json);
  final Map<String, dynamic>? json;
}

class _SessionExpired extends _PostResult {
  const _SessionExpired();
}

/// 一个教务 EMAP 应用：首页（进一次建立应用会话）与 XHR Referer。
class _JwxtApp {
  _JwxtApp(this.indexUrl, this.referer);

  final Uri indexUrl;
  final String referer;

  /// 本进程已进过应用首页（会话失效时置回 false）。
  bool ready = false;
}
