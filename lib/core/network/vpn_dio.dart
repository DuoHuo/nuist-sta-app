import 'dart:io';

import 'package:dio/dio.dart';

import 'vpn_gateway.dart';
import 'vpn_http_adapter.dart';

export 'vpn_http_adapter.dart'
    show CampusNetworkDetector, CampusNetworkState, VpnConnector, forceVpnKey;

/// 创建显式使用校园网络的 Dio，不影响其他客户端或原生组件。
///
/// forceVpn 默认为 false：检测确认在校时直连，否则使用 VPN。
/// 单次请求可通过 Options(extra: {forceVpnKey: true}) 覆盖客户端默认值。
/// 未实现校园网检测前默认走 VPN；强制 VPN 失败不会降级直连。
Dio vpnDio({
  BaseOptions? options,
  bool forceVpn = false,
  VpnConnector? connector,
  CampusNetworkDetector? detectCampusNetwork,
  SecurityContext? securityContext,
  bool Function(X509Certificate, String, int)? onBadCertificate,
}) {
  final dio = Dio(options);
  dio.httpClientAdapter = VpnHttpClientAdapter(
    connector: connector ?? VpnGateway.instance,
    forceVpn: forceVpn,
    detectCampusNetwork:
        detectCampusNetwork ??
        () async =>
            await VpnGateway.campusNetworkDetector?.call() ??
            CampusNetworkState.unknown,
    securityContext: securityContext,
    onBadCertificate: onBadCertificate,
    createHttpClient: () =>
        HttpClient(context: securityContext)
          ..badCertificateCallback = onBadCertificate,
  );
  return dio;
}
