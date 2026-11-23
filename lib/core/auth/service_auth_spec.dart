import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/campus_config.dart';
import '../logging/diagnostic_error.dart';
import 'campus_transport.dart';
import 'portal_exceptions.dart';
import 'portal_session.dart';
import 'safe_message.dart';

/// 子系统的会话建立、凭据注入与失效判定契约。
abstract class ServiceAuthSpec<TSession> {
  const ServiceAuthSpec();
  String get id;
  String get casServiceUrl;
  List<String> get cookieHosts;
  bool get treat403AsExpired => true;
  Future<TSession> establish(CampusTransport transport, Uri casLandingUri);
  Future<void> applyAuth(RequestOptions options, TSession session) async {}
  bool isSubsystemExpired(Response<dynamic> response) => false;
}

/// 不依赖子系统的明确鉴权失效信号；5xx 始终交给服务错误处理。
bool isGlobalAuthExpired(Response<dynamic> response, {bool treat403 = true}) =>
    CampusTransport.isGlobalAuthExpired(response, treat403: treat403);

/// 解析业务正文前校验 HTTP 成功状态，避免把服务器错误页当作有效数据。
void requireServiceSuccess(
  Response<dynamic> response, {
  required String endpoint,
  required String service,
}) {
  final status = response.statusCode ?? 0;
  if (status >= 200 && status < 300) return;
  throw DiagnosticException(
    '服务返回异常状态，请稍后重试',
    code: 'http_status_rejected',
    stage: 'response.validate',
    context: {
      'endpoint': endpoint,
      'service': service,
      'status_code': response.statusCode,
    },
  );
}

Map<String, dynamic>? _json(Object? value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

void _validateLanding(Response<dynamic> response) {
  if (isGlobalAuthExpired(response) || (response.statusCode ?? 0) >= 400) {
    throw PortalLoginError(
      '业务登录未完成，请稍后再试',
      code: isGlobalAuthExpired(response)
          ? 'service_returned_to_login'
          : 'service_status_rejected',
      stage: 'service.establish',
      context: {'status_code': response.statusCode},
    );
  }
}

/// 教务查询返回普通 HTML 是协议异常，不能据此反复重登。
class JwxtUnexpectedHtmlError extends DiagnosticException {
  const JwxtUnexpectedHtmlError({super.context})
    : super(
        '教务接口返回了非登录 HTML 页面',
        code: 'jwxt_unexpected_html',
        stage: 'response.validate',
      );
}

/// 教务应用进入 index.do 后才能查询；角色初始化在全部业务 POST 之前完成。
class JwxtAppSpec extends ServiceAuthSpec<void> {
  const JwxtAppSpec({
    required this.appId,
    required this.indexUrl,
    required this.refererUrl,
    this.roleId,
  });
  final String appId;
  final String indexUrl;
  final String refererUrl;
  final String? roleId;
  @override
  String get id => 'jwxt.$appId';
  @override
  String get casServiceUrl => PortalServices.jwxt;
  @override
  List<String> get cookieHosts => [CampusHosts.jwxt];
  @override
  Future<void> establish(CampusTransport transport, Uri casLandingUri) async {
    _validateLanding(await transport.get(casLandingUri));
    _validateLanding(await transport.get(Uri.parse(indexUrl)));
    if (roleId case final role? when role.isNotEmpty) {
      _validateLanding(
        await transport.post(
          Uri.https(
            CampusHosts.jwxt,
            '/jwapp/sys/jwpubapp/pub/setJwCommonAppRole.do',
          ),
          data: {'ROLEID': role},
          headers: {'Referer': refererUrl},
          contentType: Headers.formUrlEncodedContentType,
          idempotent: false,
        ),
      );
    }
  }

  @override
  Future<void> applyAuth(RequestOptions options, void session) async {
    options.headers['Referer'] = refererUrl;
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) {
    if (isGlobalAuthExpired(response)) return true;
    final raw = response.data;
    if (response.statusCode == 200 &&
        raw is String &&
        RegExp(
          r'^\s*(?:<!doctype\s+html|<(?:html|head|body|form|script|div|table)\b)',
          caseSensitive: false,
        ).hasMatch(raw)) {
      throw JwxtUnexpectedHtmlError(
        context: {'status_code': response.statusCode, 'service': 'jwxt'},
      );
    }
    return false;
  }
}

/// 信息门户空响应、游客和 errcode 999 均需要重新建立会话。
class IportalSpec extends ServiceAuthSpec<void> {
  const IportalSpec();
  @override
  String get id => 'iportal';
  @override
  String get casServiceUrl => PortalServices.iportal;
  @override
  List<String> get cookieHosts => [CampusHosts.iportal];
  @override
  Future<void> establish(CampusTransport transport, Uri casLandingUri) async {
    _validateLanding(await transport.get(casLandingUri));
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) {
    final raw = response.data;
    if (raw == null || (raw is String && raw.trim().isEmpty)) return true;
    final body = _json(raw);
    if ('${body?['errcode']}' == '999') return true;
    if (response.requestOptions.uri.path.endsWith('/getLoginUserAndGuest')) {
      final data = body?['data'];
      if (data is Map) {
        final user = data['userAccount'] ?? data['studentId'];
        return user == null || '$user'.trim().isEmpty;
      }
    }
    return false;
  }
}

/// 一卡通 API 的非 Cookie 令牌。
class IcardSession {
  const IcardSession(this.token);
  final String token;
}

/// 从完整 CAS 落地地址读取一卡通令牌，不采信缺令牌的缓存。
class IcardSpec extends ServiceAuthSpec<IcardSession> {
  const IcardSpec();
  @override
  String get id => 'icard';
  @override
  String get casServiceUrl => PortalServices.icard;
  @override
  List<String> get cookieHosts => [CampusHosts.icard];
  @override
  Future<IcardSession> establish(
    CampusTransport transport,
    Uri casLandingUri,
  ) async {
    final response = await transport.get(casLandingUri);
    _validateLanding(response);
    final token = response.realUri.queryParameters['synjones-auth'];
    if (token == null || token.isEmpty) {
      throw const PortalLoginError(
        '一卡通登录未返回令牌，请重试',
        code: 'icard_token_missing',
        stage: 'icard.establish',
      );
    }
    return IcardSession(token);
  }

  @override
  Future<void> applyAuth(RequestOptions options, IcardSession session) async {
    options.headers['synjones-auth'] = 'bearer ${session.token}';
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) {
    final body = _json(response.data);
    final code = '${body?['code']}';
    if (code == '200') return false;
    final msg = '${body?['msg'] ?? body?['message'] ?? ''}'.toLowerCase();
    return code == '401' ||
        code == '403' ||
        ['token', '登录', 'unauthorized', '认证'].any(msg.contains);
  }
}

/// 图书馆读者接口的 CSRF 凭据。
class LibrarySession {
  const LibrarySession(this.csrfToken);
  final String? csrfToken;
}

/// 读者登录与 CSRF 只在图书馆的服务契约中处理。
class LibrarySpec extends ServiceAuthSpec<LibrarySession> {
  const LibrarySpec();
  @override
  String get id => 'library';
  @override
  String get casServiceUrl => PortalServices.library;
  @override
  List<String> get cookieHosts => [CampusHosts.library];
  @override
  Future<LibrarySession> establish(
    CampusTransport transport,
    Uri casLandingUri,
  ) async {
    _validateLanding(await transport.get(casLandingUri));
    final cookies = await transport.cookieStore!.openJar().loadForRequest(
      Uri.https(CampusHosts.library, '/mspace/'),
    );
    String? csrf;
    for (final cookie in cookies) {
      if (cookie.name == 'CSRF-TOKEN') {
        csrf = Uri.decodeComponent(cookie.value);
        break;
      }
    }
    return LibrarySession(csrf);
  }

  @override
  Future<void> applyAuth(RequestOptions options, LibrarySession session) async {
    if (session.csrfToken case final csrf?) {
      options.headers['X-CSRF-TOKEN'] = csrf;
    }
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) {
    final body = _json(response.data);
    final code = '${body?['code']}';
    if (code == '0') return false;
    final msg = '${body?['msg'] ?? body?['message'] ?? ''}'.toLowerCase();
    return code == '401' ||
        code == '403' ||
        msg.contains('未登录') ||
        msg.contains('not logged') ||
        msg.contains('unauthorized');
  }
}

bool _tableLoginExpired(Response<dynamic> response) {
  final raw = response.data;
  if (raw is! String) return false;
  final table = response.requestOptions.extra['authTableId'];
  if (table is String && raw.contains(table)) return false;
  final lower = raw.toLowerCase();
  return response.realUri.path.toLowerCase().contains('login') ||
      lower.contains('authserver/login') ||
      lower.contains('/authserver/login');
}

/// 双创平台三步换票；汇总与明细共享同一会话。
class InnovationSpec extends ServiceAuthSpec<void> {
  const InnovationSpec();
  @override
  String get id => 'innovation';
  @override
  String get casServiceUrl => PortalServices.cxcyjy;
  @override
  List<String> get cookieHosts => [CampusHosts.cxcyjy, CampusHosts.cxxf];
  @override
  Future<void> establish(CampusTransport transport, Uri casLandingUri) async {
    final platform = 'https://${CampusHosts.cxcyjy}/pt';
    final page = await transport.get(casLandingUri);
    _validateLanding(page);
    final token = RegExp(
      r'name="__RequestVerificationToken"[^>]*value="([^"]+)"',
    ).firstMatch('${page.data}')?.group(1);
    if (token == null) {
      throw const PortalLoginError(
        '创新创业平台登录页未返回验证令牌',
        code: 'service_returned_to_login',
        stage: 'innovation.complete_login',
      );
    }
    final done = await transport.post(
      Uri.parse('$platform/HomePage/UnifiedAuthenticationLogin'),
      data: FormData.fromMap({'__RequestVerificationToken': token}),
      headers: {
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': page.realUri.toString(),
      },
      idempotent: false,
    );
    _validateLanding(done);
    final result = _json(done.data);
    if (result?['Success'] != true) {
      throw PortalLoginError(
        prefixedServerMessage(
          '创新创业平台统一认证未完成：',
          result?['Message'],
          fallback: '创新创业平台登录失败，请稍后重试',
        ),
        code: 'authentication_incomplete',
        stage: 'innovation.complete_login',
      );
    }
    final redirect = '${(result?['Data'] as Map?)?['RedirectUrl'] ?? ''}';
    if (redirect.isNotEmpty) {
      final uri =
          redirect.startsWith('http://') || redirect.startsWith('https://')
          ? Uri.parse(redirect)
          : Uri.parse('$platform/${redirect.replaceFirst(RegExp(r'^/+'), '')}');
      _validateLanding(await transport.get(uri));
    }
    final referer = {'Referer': '$platform/'};
    final hop = await transport.get(
      Uri.parse(
        '$platform/System/Platform/AccessSubsystem/e8051115-0e26-47d1-963d-9a79992102ff',
      ),
      headers: referer,
      followRedirects: false,
    );
    final location = hop.headers.value('location');
    if (!CampusTransport.isRedirect(hop.statusCode) ||
        location == null ||
        location.isEmpty) {
      throw PortalLoginError(
        '双创平台未跳转到学分子系统',
        code: 'service_returned_to_login',
        stage: 'innovation.exchange_session',
        context: {'status_code': hop.statusCode},
      );
    }
    _validateLanding(
      await transport.get(hop.realUri.resolve(location), headers: referer),
    );
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) =>
      _tableLoginExpired(response);
}

/// 劳动平台 CAS 落地即建好会话，四个页面使用同一失效谓词。
class LaborSpec extends ServiceAuthSpec<void> {
  const LaborSpec();
  @override
  String get id => 'labor';
  @override
  String get casServiceUrl => PortalServices.labor;
  @override
  List<String> get cookieHosts => [CampusHosts.labor];
  @override
  Future<void> establish(CampusTransport transport, Uri casLandingUri) async {
    _validateLanding(await transport.get(casLandingUri));
  }

  @override
  bool isSubsystemExpired(Response<dynamic> response) =>
      _tableLoginExpired(response);
}
