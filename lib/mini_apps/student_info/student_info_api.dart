import 'dart:convert';
import 'dart:math';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import 'student_info_models.dart';

/// 信息门户的两个接口：
/// - `GET /getLoginUserAndGuest`：当前登录人。**未登录时也返回 errcode 0**，
///   只是给一个 userAccount 为 null 的游客对象，所以要按学号非空来判定；
/// - `POST /execTemplateMethod`（method=getXLInfo）：某个日期所在学期的校历。
///   未登录时 errcode 为 999。
///
/// 与 AcademicApi 同一套会话；两个请求并发，任一判定未登录就强制重登一次。
class StudentInfoApi {
  StudentInfoApi._();

  static final _base = 'https://${CampusHosts.iportal}';
  static final Uri _templateApi = Uri.parse('$_base/execTemplateMethod');

  static Future<StudentInfo> fetch() async {
    var info = await _send(force: false);
    if (info == null) {
      portalLog('信息门户会话失效，重新登录');
      info = await _send(force: true);
    }
    if (info == null) {
      throw const PortalLoginError('信息门户未返回登录人信息，请稍后再试');
    }
    return info;
  }

  /// 返回 null 表示未登录。
  static Future<StudentInfo?> _send({required bool force}) async {
    final http = await PortalSession.instance.clientFor(
      PortalServices.iportal,
      force: force,
    );
    final now = DateTime.now();
    try {
      final results = await Future.wait<Object?>([
        _fetchUser(http),
        _fetchSemester(http, now),
      ]);
      return StudentInfo(
        user: results[0] as PortalUser,
        semester: results[1] as SemesterInfo?,
        fetchedAt: now,
      );
    } on _NotLoggedIn {
      return null;
    }
  }

  static Future<PortalUser> _fetchUser(PortalHttp http) async {
    final response = await http.followRedirects(
      await http.get(
        Uri.parse('$_base/getLoginUserAndGuest?_t=${Random().nextDouble()}'),
        headers: {'Accept': 'application/json'},
      ),
    );
    final body = _decode(response.data);
    final data = body?['data'];
    if (body == null || data is! Map<String, dynamic>) {
      throw const _NotLoggedIn();
    }
    final user = PortalUser.fromJson(data);
    if (user.studentId.isEmpty) throw const _NotLoggedIn();
    return user;
  }

  /// 拿 [date] 所在学期；接口正常但没有学期数据时返回 null。
  static Future<SemesterInfo?> _fetchSemester(
    PortalHttp http,
    DateTime date,
  ) async {
    String two(int n) => n.toString().padLeft(2, '0');
    final response = await http.post(
      _templateApi,
      data: jsonEncode({
        'method': 'getXLInfo',
        'param': {
          'date': '${date.year}-${two(date.month)}-${two(date.day)}',
          '_t': date.millisecondsSinceEpoch,
        },
        // 门户前端带的随机数，只是防缓存。
        'n': '${Random().nextDouble()}',
      }),
      contentType: 'application/json;charset=UTF-8',
      headers: {
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    final body = _decode(response.data);
    if (body == null || '${body['errcode']}' != '0') throw const _NotLoggedIn();
    final data = body['data'];
    return SemesterInfo.tryFromJson(data is Map<String, dynamic> ? data : null);
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// 内部信号：响应表明当前没有登录态。
class _NotLoggedIn implements Exception {
  const _NotLoggedIn();
}
