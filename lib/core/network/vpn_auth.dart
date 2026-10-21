import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../auth/aia_trust.dart';
import '../auth/cas_session.dart';
import '../auth/passkey_bundle.dart';
import '../auth/passkey_store.dart';
import '../auth/portal_cookie_manager.dart';
import '../auth/portal_exceptions.dart';
import '../auth/portal_http.dart';
import '../config/campus_config.dart';
import 'vpn_spa.dart';
import 'vpn_log.dart';

/// 控制器下发的短期隧道凭据，不包含门户私钥，不落盘。
class VpnCredentials {
  const VpnCredentials({
    required this.host,
    required this.port,
    required this.user,
    required this.token,
  });

  final String host;
  final int port;
  final String user;
  final String token;
}

/// VPN 控制器会话；与门户共用 CAS Cookie，控制器接口直连以便引导隧道。
class VpnAuth {
  VpnAuth({
    CasSession? cas,
    Future<PasskeyBundle?> Function()? readCredential,
    this.createHttp,
  }) : _cas = cas ?? CasSession.instance,
       _readCredential = readCredential ?? PasskeyStore.read;

  static final controller = 'https://${CampusHosts.vpnController}';
  static final service = '$controller/enlink/api/client/callback/cas';
  final CasSession _cas;
  final Future<PasskeyBundle?> Function() _readCredential;

  /// 测试用的控制器客户端工厂。
  final PortalHttp Function(CookieJar jar)? createHttp;
  late CookieJar _jar;
  PortalHttp? _client;
  int? _cookieGeneration;
  int _generation = 0;

  PortalHttp get _http {
    final generation = _cas.cookies.generation;
    if (_cookieGeneration == generation && _client != null) return _client!;
    _client?.dio.close(force: true);
    _cookieGeneration = generation;
    _jar = _cas.cookies.openJar();
    if (createHttp case final factory?) return _client = factory(_jar);
    final trust = AiaTrust();
    // 这是建立 VPN 所必需的引导出口，不能使用 vpnDio。
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)))
      ..interceptors.add(
        PortalCookieManager(
          _jar,
          checkSession: () => _cas.cookies.checkGeneration(generation),
        ),
      )
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: trust.createHttpClient,
      );
    return _client = PortalHttp(dio, trust: trust);
  }

  /// 先复用保存的控制器会话取得新 token，明确失效后才恢复 CAS 登录。
  Future<VpnCredentials> obtain() async {
    vpnLog('读取本机绑定凭据');
    final generation = _cas.cookies.generation;
    final bundle = await _readCredential();
    _cas.cookies.checkGeneration(generation);
    if (bundle == null) {
      throw const PortalCredentialError('使用校园 VPN 前请先绑定统一门户');
    }
    final http = _http;
    final jar = _jar;
    final reused = await _obtainWithSession(bundle, http, jar);
    _cas.cookies.checkGeneration(generation);
    if (reused != null) {
      vpnLog('复用控制器会话取得隧道凭据');
      return reused;
    }
    await _clearController();
    _cas.cookies.checkGeneration(generation);
    final target = await _cas.authenticate(
      service,
      onStage: (stage) => vpnLog('CAS 阶段: $stage'),
    );
    _cas.cookies.checkGeneration(generation);
    final response = await http.followRedirects(
      await http.get(Uri.parse(target)),
    );
    if (PortalHttp.isLoginResponse(response) ||
        (response.statusCode ?? 0) >= 400) {
      throw const PortalLoginError('VPN 登录未完成，请稍后再试');
    }
    vpnLog('VPN CAS 登录完成，检查身份信息');
    final fresh = await _obtainWithSession(bundle, http, jar);
    _cas.cookies.checkGeneration(generation);
    if (fresh == null) {
      throw const PortalLoginError('VPN 登录未返回有效控制器会话，请稍后再试');
    }
    return fresh;
  }

  Future<VpnCredentials?> _obtainWithSession(
    PasskeyBundle bundle,
    PortalHttp http,
    CookieJar jar,
  ) async {
    final cookies = await jar.loadForRequest(Uri.parse('$controller/'));
    final infoCookie = cookies.where((cookie) => cookie.name == 'clientInfo');
    if (infoCookie.isEmpty ||
        !cookies.any((cookie) => cookie.name == 'ENSSESSIONID')) {
      return null;
    }
    final Map<String, dynamic> info;
    try {
      info = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(infoCookie.first.value))),
      ) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final uid = info['userId'];
    final user = bundle.studentId ?? info['username'];
    if (uid is! String ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(uid) ||
        user is! String ||
        user.isEmpty) {
      return null;
    }
    if (bundle.studentId != null &&
        info['username'] is String &&
        info['username'] != bundle.studentId) {
      return null;
    }
    for (var attempt = 0; attempt < 6; attempt++) {
      vpnLog('向控制器获取隧道凭据，第 ${attempt + 1}/6 次');
      final response = await http.get(
        Uri.parse('$controller/enlink/api/client/user/terminal/rules/$uid'),
      );
      if (PortalHttp.isLoginResponse(response)) return null;
      final Map<String, dynamic> body;
      try {
        body =
            (response.data is String
                    ? jsonDecode(response.data as String)
                    : response.data)
                as Map<String, dynamic>;
      } catch (_) {
        throw const PortalLoginError('VPN 控制器返回格式不正确');
      }
      final data = body['data'];
      final code = '${body['code']}';
      if (code == '401' ||
          (code == '1000' && '${body['messages']}'.contains('请重新登录'))) {
        return null;
      }
      if ('${body['code']}' != '200') {
        throw const PortalLoginError('VPN 控制器未正常返回隧道凭据，请稍后再试');
      }
      if ('${body['code']}' == '200' &&
          data is Map &&
          data['token'] is String &&
          (data['token'] as String).isNotEmpty) {
        final endpoints = _endpoints(data['server']);
        if (endpoints.isEmpty) throw const PortalLoginError('VPN 控制器未返回可用网关');
        final endpoint = endpoints.first;
        if (data['spa_status'] == true ||
            '${data['spa_status']}' == 'true' ||
            '${data['spa_status']}' == '1') {
          final port = int.tryParse('${data['spa_port']}') ?? 62201;
          if (port < 1 || port > 65535) {
            throw const PortalLoginError('VPN 敲门端口不合法');
          }
          await VpnSpa.knock(
            endpoints.length > 1 ? endpoints[1].host : endpoint.host,
            port,
            user,
          );
          vpnLog('SPA 敲门包已发送');
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        vpnLog('控制器已下发有效隧道凭据');
        return VpnCredentials(
          host: endpoint.host,
          port: endpoint.port,
          user: user,
          token: data['token'] as String,
        );
      }
      if (attempt < 5) await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const PortalLoginError('无法取得 VPN token，账号可能正被其他会话占用');
  }

  Future<void> _clearController() => _cas.cookies.clearHost(
    Uri.parse(controller),
    names: const {'ENSSESSIONID', 'clientInfo'},
  );

  static List<Uri> _endpoints(Object? raw) {
    if (raw is! String) return const [];
    final result = <Uri>[];
    for (final part in raw.split('||')) {
      final value = part.trim();
      if (value.isEmpty) continue;
      final onlyPort = int.tryParse(value);
      if (onlyPort != null) {
        if (result.isNotEmpty && onlyPort > 0 && onlyPort <= 65535) {
          result.add(result.last.replace(port: onlyPort));
        }
        continue;
      }
      final uri = Uri.tryParse('https://$value');
      if (uri != null &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          uri.path.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.port > 0 &&
          uri.port <= 65535) {
        result.add(uri);
      }
    }
    return result;
  }

  /// 向控制器登记虚拟地址。此维护接口失败不代表数据隧道或 Passkey 失效。
  Future<void> register(String virtualIp, String gateway) async {
    final http = _client;
    final generation = _generation;
    if (http == null) return;
    final jar = _jar;
    try {
      final cookies = await jar.loadForRequest(Uri.parse('$controller/'));
      final sessions = cookies.where((cookie) => cookie.name == 'ENSSESSIONID');
      if (sessions.isEmpty || generation != _generation) return;
      await http.send(
        () => http.dio.put<dynamic>(
          '$controller/enlink/api/client/user/updateUserSession',
          data: {
            'sessionId': sessions.first.value,
            'virtualIp': virtualIp,
            'virtualIpV6': '',
            'gateway': gateway,
          },
          options: PortalHttp.options(contentType: Headers.jsonContentType),
        ),
      );
      vpnLog('虚拟地址登记请求完成');
    } catch (error) {
      vpnLog('虚拟地址登记失败（不影响隧道）：${vpnErrorKind(error)}');
      // 网关已经接受握手，不因非必需的维护接口失败中断用户请求。
    }
  }

  /// 换号或解绑时销毁 VPN Cookie 与引导连接池。
  Future<void> clear() async {
    _generation++;
    _client?.dio.close(force: true);
    _client = null;
    _cookieGeneration = null;
    await _clearController();
  }
}
