import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'vpn_log.dart';

/// Rust 控制接口。阻塞的握手、DNS 和建连在后台 isolate 中执行。
class VpnNative {
  const VpnNative();

  /// 执行一条控制命令，业务流量不经过此接口。
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    try {
      return await Isolate.run(() => _call(request));
    } catch (error) {
      // 不输出 request/result：其中可能包含 token 和回环鉴权密钥。
      vpnLog('原生控制调用失败：${vpnErrorKind(error)}');
      rethrow;
    }
  }

  static Map<String, dynamic> _call(Map<String, dynamic> request) {
    const configured = String.fromEnvironment('VPN_NATIVE_LIBRARY');
    final name = configured.isNotEmpty
        ? configured
        : switch (Platform.operatingSystem) {
            'android' || 'linux' => 'libnuist_vpn.so',
            'windows' => 'nuist_vpn.dll',
            'macos' => 'libnuist_vpn.dylib',
            _ => throw const SocketException('当前平台尚未接入校园 VPN 原生库'),
          };
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(name);
    } catch (_) {
      vpnLog('原生动态库加载失败');
      throw const SocketException('未找到校园 VPN 原生库，请使用包含 Rust 核心的构建');
    }
    final allocate = library
        .lookupFunction<
          Pointer<Uint8> Function(UintPtr),
          Pointer<Uint8> Function(int)
        >('nuist_vpn_alloc');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Uint8>, UintPtr),
          void Function(Pointer<Uint8>, int)
        >('nuist_vpn_free');
    final call = library
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Uint8>, UintPtr),
          Pointer<Uint8> Function(Pointer<Uint8>, int)
        >('nuist_vpn_call');
    final freeResult = library
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('nuist_vpn_result_free');
    final bytes = utf8.encode(jsonEncode(request));
    final input = allocate(bytes.length);
    if (input == nullptr) throw const SocketException('VPN 控制消息过大');
    Pointer<Uint8> result = nullptr;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      result = call(input, bytes.length);
      if (result == nullptr) throw const SocketException('VPN 原生接口未返回结果');
      var length = 0;
      while (length < 1024 * 1024 && (result + length).value != 0) {
        length++;
      }
      if (length == 1024 * 1024) throw const SocketException('VPN 响应长度异常');
      final response = jsonDecode(
        utf8.decode(result.asTypedList(length)),
      ) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw SocketException(response['error'] as String? ?? 'VPN 操作失败');
      }
      return response['data'] as Map<String, dynamic>;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      free(input, bytes.length);
      if (result != nullptr) freeResult(result);
    }
  }
}
