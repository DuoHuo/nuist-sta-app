import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'passkey_bundle.dart';
import 'portal_exceptions.dart';
import 'portal_http.dart';
import 'webauthn_signer.dart';

/// 统一身份认证的 CAS + WebAuthn 登录流程（由 NuistLogin.py 移植）。
///
/// 纯网络层，不启动 WebView：拿登录页取 execution → startAssertion 换
/// challenge → 用本机 Passkey 私钥离线签名 → 提交表单 → 跟随 302 落到目标
/// 服务。会话状态全在调用方传进来的 [PortalHttp] 所持的 dio 上（Cookie 由其
/// CookieManager 拦截器保管），本类自身无状态，可以反复调用。
class NuistLogin {
  NuistLogin({required this.http, required this.bundle, this.onStage});

  final PortalHttp http;
  final PasskeyBundle bundle;

  /// 阶段回调，用于给「测试登录」这类界面显示进度；不含任何凭据信息。
  final void Function(String stage)? onStage;

  static const authserverNormal = 'https://authserver.nuist.edu.cn';
  static const loginPath = '/authserver/login';
  static const startAssertionPath = '/authserver/startAssertion';

  /// clientDataJSON 里的 origin 必须固定为真实 authserver：即使将来经 webvpn
  /// 代理，填代理域名也会被服务端以 401 拒绝。
  static const webauthnOrigin = authserverNormal;

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:155.0) '
      'Gecko/20100101 Firefox/155.0';

  /// 在 [base] 上完成一次登录，返回跟随跳转后的落地 URL。
  ///
  /// [base] 是留给 VPN 模式的扩展位：webvpn 的代理前缀可以直接顶替 authserver
  /// 根地址，流程本身一个字都不用改（Python 版正是这么做的）。真要启用 VPN
  /// 还需补上 VPN Cookie 的获取与失效重试，那部分暂未移植。
  Future<String> login(String service, {String base = authserverNormal}) async {
    final loginUrl = _loginUrl(base, service);

    onStage?.call('opening');
    final (execution, landing) = await _openLoginPage(loginUrl);
    if (execution == null) {
      // SSO 票根还在，服务端直接把我们送到了目标服务，不必再签一次断言。
      onStage?.call('sso_reused');
      return landing;
    }

    onStage?.call('asserting');
    final request = await _startAssertion(base, loginUrl);
    final credential = _makeAssertion(request);

    onStage?.call('submitting');
    final response = await _submitLogin(
      base,
      loginUrl,
      request,
      credential,
      execution,
    );
    if (!PortalHttp.isRedirect(response.statusCode)) {
      throw PortalCredentialError(
        '登录未返回重定向（HTTP ${response.statusCode}），'
        '门户上的通行密钥可能已被删除或吊销',
      );
    }

    final location = response.headers.value('location');
    if (location == null || location.isEmpty) {
      throw const PortalLoginError('登录返回重定向但缺少 Location');
    }

    final landed = await http.followRedirects(
      await http.get(Uri.parse(loginUrl).resolve(location)),
    );
    final landedUrl = landed.realUri.toString();
    if (landedUrl.contains(loginPath)) {
      throw PortalLoginError('登录后又跳回认证页，service 可能不正确：$service');
    }
    onStage?.call('done');
    return landedUrl;
  }

  // ==================== CAS 流程 ====================

  /// 访问登录页，取得会话 Cookie 和 execution 令牌。
  ///
  /// 返回的 execution 为 null 表示 SSO 已登录、服务端直接跳走了。
  Future<(String?, String)> _openLoginPage(String loginUrl) async {
    final response = await http.followRedirects(
      await http.get(
        Uri.parse(loginUrl),
        headers: {'Accept': 'text/html,application/xhtml+xml'},
      ),
    );
    final landed = response.realUri.toString();
    if (!landed.contains(loginPath)) return (null, landed);

    // execution 藏在登录页的隐藏 input 里；抓包常见值 e1s1 作为后备。
    // 值可能含被 HTML 转义的 base64 字符（如 &#x2F;），得先反转义。
    final match = RegExp(
      r'''name=["']execution["'][^>]*value=["']([^"']+)''',
      caseSensitive: false,
    ).firstMatch(_unescapeHtml('${response.data}'));
    return (match?.group(1) ?? 'e1s1', landed);
  }

  /// 请求 WebAuthn 断言参数（challenge 等）。
  Future<Map<String, dynamic>> _startAssertion(
    String base,
    String loginUrl,
  ) async {
    final response = await http.post(
      Uri.parse('$base$startAssertionPath'),
      data: {'userId': bundle.userId, 'id': bundle.anonbiometricsd},
      headers: {
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'Origin': _httpOrigin(base),
        'Referer': loginUrl,
      },
      contentType: 'application/json;charset=utf-8',
      responseType: ResponseType.json,
    );

    final body = _asMap(response.data);
    if (body == null) {
      portalLog(
        'startAssertion 非 JSON 响应: HTTP ${response.statusCode} '
        '${_preview(response.data)}',
      );
      throw const PortalLoginError('startAssertion 返回的不是 JSON 对象');
    }
    portalLog('startAssertion 响应: ${_preview(body)}');
    if (body['success'] == false) {
      throw PortalCredentialError(
        'startAssertion 被拒绝：${body['message'] ?? body}',
      );
    }

    // 响应结构在不同版本里出现过 result 和 datas 两种外壳，都试一遍。
    final request =
        _asMap(_asMap(body['result'])?['request']) ??
        _asMap(_asMap(body['datas'])?['request']);
    if (request == null || request['requestId'] == null) {
      // 凭据在门户上被删除/吊销时，服务端不给 success 字段，只返回
      // HTTP 200 + {"message": "未查询到设备信息"}。这是最常见的失效形态，
      // 必须归到凭据错误，UI 才能提示重新绑定而不是让用户干等重试。
      final message = body['message'];
      if (message is String && message.isNotEmpty) {
        throw PortalCredentialError('$message，通行密钥可能已被删除或吊销');
      }
      throw PortalLoginError(
        'startAssertion 响应中没有有效的 request：${_preview(body)}',
      );
    }
    return request;
  }

  /// 用本机私钥离线完成 WebAuthn 断言签名。
  Map<String, dynamic> _makeAssertion(Map<String, dynamic> request) {
    final options = _asMap(request['publicKeyCredentialRequestOptions']) ?? {};
    final challenge = options['challenge'] as String?;
    final rpId = (options['rpId'] as String?) ?? bundle.rpId;
    if (challenge == null || challenge.isEmpty || rpId.isEmpty) {
      throw const PortalLoginError('startAssertion 缺少 challenge/rpId');
    }

    // 服务端列出了可用凭据却没有我们这张，说明它在门户侧已被删除。
    final allowed = options['allowCredentials'] as List?;
    if (allowed != null && allowed.isNotEmpty) {
      final ids = allowed.whereType<Map>().map((e) => e['id']).toSet();
      if (!ids.contains(bundle.credentialId)) {
        throw const PortalCredentialError('本机凭据不在服务端的可用列表中，该通行密钥已被吊销');
      }
    }

    final clientDataJson = utf8.encode(
      jsonEncode({
        'type': 'webauthn.get',
        'challenge': challenge,
        'origin': webauthnOrigin,
        'crossOrigin': false,
      }),
    );

    // 前端要求 userVerification，故 flags = UP(0x01) | UV(0x04)；计数器固定 0。
    final authenticatorData = Uint8List.fromList([
      ...sha256Bytes(utf8.encode(rpId)),
      0x05,
      0,
      0,
      0,
      0,
    ]);

    final signature = Es256Key.fromPkcs8Pem(bundle.privateKeyPkcs8Pem).sign(
      Uint8List.fromList([
        ...authenticatorData,
        ...sha256Bytes(clientDataJson),
      ]),
    );

    return {
      'type': 'public-key',
      'id': bundle.credentialId,
      'response': {
        'authenticatorData': base64UrlNoPad(authenticatorData),
        'clientDataJSON': base64UrlNoPad(clientDataJson),
        'signature': base64UrlNoPad(signature),
      },
      'clientExtensionResults': {'appid': false},
    };
  }

  /// 提交断言到 CAS 登录表单。
  Future<Response<dynamic>> _submitLogin(
    String base,
    String loginUrl,
    Map<String, dynamic> request,
    Map<String, dynamic> credential,
    String execution,
  ) {
    return http.post(
      Uri.parse(loginUrl),
      data: {
        '_eventId': 'submit',
        // 这里发的是 Base64URL 形式的 userId，不是明文学号；
        // 传明文学号会被服务端以 401 拒绝。
        'username': bundle.userId,
        'responseJson': jsonEncode({
          'requestId': request['requestId'],
          'credential': credential,
          'sessionToken': null,
        }),
        'cllt': 'fidoLogin',
        'dllt': 'generalLogin',
        'lt': '',
        'execution': execution,
      },
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Origin': _httpOrigin(base),
        'Referer': loginUrl,
        'Upgrade-Insecure-Requests': '1',
      },
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  // ==================== 工具 ====================

  static String _loginUrl(String base, String service) {
    if (service.isEmpty) return '$base$loginPath';
    // 复刻 Python 的 quote(service, safe=':/')：CAS 用字符串精确匹配校验
    // service，编码形式变了可能导致 ticket 验证失败。
    final encoded = Uri.encodeComponent(service)
        .replaceAll('%3A', ':')
        .replaceAll('%2F', '/');
    return '$base$loginPath?service=$encoded';
  }

  /// HTTP 请求头里的 Origin，与实际访问的主机一致。
  static String _httpOrigin(String base) {
    final uri = Uri.parse(base);
    return '${uri.scheme}://${uri.authority}';
  }

  static Map<String, dynamic>? _asMap(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : null;

  /// 日志用的响应摘要：截断到一屏，避免整页 HTML 刷屏。
  static String _preview(Object? data) {
    final text = data is Map || data is List ? jsonEncode(data) : '$data';
    final flat = text.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length > 300 ? '${flat.substring(0, 300)}…' : flat;
  }

  /// 反转义登录页里的 HTML 实体，只覆盖 execution 值可能出现的那几种。
  static String _unescapeHtml(String input) => input
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
