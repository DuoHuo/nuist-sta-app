import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/portal_exceptions.dart';

/// VPN 独立日志出口，不依赖门户初始化；仅接收不含凭据的状态描述。
void vpnLog(String message) {
  if (kDebugMode) debugPrint('[vpn] $message');
}

/// 只记录错误类别，不展开可能包含 URL、响应体或凭据的异常消息。
String vpnErrorKind(Object error) => switch (error) {
  PortalCredentialError() => '门户凭据不可用',
  PortalNetworkError() => '认证网络错误',
  PortalLoginError() => '认证流程失败',
  DioException() => 'HTTP ${error.type.name}',
  HandshakeException() => 'TLS 握手失败',
  SocketException() => '连接错误（系统码 ${error.osError?.errorCode ?? "无"}）',
  _ => '${error.runtimeType}',
};
