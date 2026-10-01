import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../auth/aia_trust.dart';
import '../auth/nuist_login.dart';
import '../auth/passkey_store.dart';
import '../auth/portal_exceptions.dart';
import '../auth/portal_http.dart';
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

/// VPN 的独立认证会话；复用 NuistLogin，使用直连引导客户端避免循环依赖。
class VpnAuth {
  static const controller = 'https://client.vpn.nuist.edu.cn';
  static const service = '$controller/enlink/api/client/callback/cas';
  final CookieJar _jar = CookieJar();
  PortalHttp? _client;
  int _generation = 0;

  PortalHttp get _http {
    if (_client case final value?) return value;
    final trust = AiaTrust();
    // 这是建立 VPN 所必需的引导出口，不能使用 vpnDio。
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)))
      ..interceptors.add(CookieManager(_jar))
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: trust.createHttpClient,
      );
    return _client = PortalHttp(dio, trust: trust);
  }

  /// 获取新 token；Cookie 仅保留在内存，失效后重走 CAS。
  Future<VpnCredentials> obtain() async {
    vpnLog('读取本机绑定凭据');
    final bundle = await PasskeyStore.read();
    if (bundle == null) {
      throw const PortalCredentialError('使用校园 VPN 前请先绑定统一门户');
    }
    await NuistLogin(http: _http, bundle: bundle).login(service);
    vpnLog('VPN CAS 登录完成，检查身份信息');
    final cookies = await _jar.loadForRequest(Uri.parse('$controller/'));
    final infoCookie = cookies.where((cookie) => cookie.name == 'clientInfo');
    if (infoCookie.isEmpty) {
      throw const PortalLoginError('VPN 登录未返回身份信息');
    }
    final Map<String, dynamic> info;
    try {
      info = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(infoCookie.first.value))),
      ) as Map<String, dynamic>;
    } catch (_) {
      throw const PortalLoginError('VPN 身份信息格式不正确');
    }
    final uid = info['userId'];
    final user = bundle.studentId ?? info['username'];
    if (uid is! String ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(uid) ||
        user is! String ||
        user.isEmpty) {
      throw const PortalLoginError('VPN 身份信息缺少必要字段');
    }
    for (var attempt = 0; attempt < 6; attempt++) {
      vpnLog('向控制器获取隧道凭据，第 ${attempt + 1}/6 次');
      final response = await _http.get(
        Uri.parse('$controller/enlink/api/client/user/terminal/rules/$uid'),
      );
      if (response.statusCode == 401 ||
          PortalHttp.isRedirect(response.statusCode)) {
        await _jar.deleteAll();
        throw const PortalLoginError('VPN 控制器会话已失效，请重试');
      }
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
    try {
      final cookies = await _jar.loadForRequest(Uri.parse('$controller/'));
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
    await _jar.deleteAll();
  }
}
