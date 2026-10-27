import 'dart:async';
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
    final method = request['method'];
    final timeout = switch (method) {
      'start' => const Duration(seconds: 30),
      'open' => const Duration(seconds: 24),
      _ => const Duration(seconds: 3),
    };
    final label = switch (method) {
      'open' =>
        '${VpnConnectionLog.current?.label ?? "原生目标连接"} '
            'open，隧道 id=${request['id']}',
      'status' => '隧道 id=${request['id']} 原生 status',
      'start' ||
      'startStatus' ||
      'cancelStart' => '原生 $method，startId=${request['startId']}',
      _ => '原生 $method',
    };
    // 只输出操作名，绝不展开 request/result。
    return vpnStage(label, () async {
      var expired = false;
      final work = Isolate.run(() => _call(request, label));
      unawaited(
        work.then((result) async {
          // 即使 isolate 调度迟到，过期的启动结果也不能留下孤立隧道。
          if (expired && method == 'start' && result['id'] is int) {
            try {
              await call({'method': 'stop', 'id': result['id']});
            } catch (_) {}
          }
          if (expired && method == 'prepareStart' && result['startId'] is int) {
            try {
              await call({
                'method': 'cancelStart',
                'startId': result['startId'],
              });
            } catch (_) {}
          }
        }, onError: (Object _) {}),
      );
      return work.timeout(
        timeout,
        onTimeout: () {
          expired = true;
          throw SocketException('VPN 原生 $method 调用超时，请重试');
        },
      );
    });
  }

  static Map<String, dynamic> _call(
    Map<String, dynamic> request,
    String label,
  ) {
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
        final message = response['error'] as String? ?? '';
        final stage = RegExp(r'阶段="?(配置|DNS|TCP|TLS|协议鉴权)"?')
            .firstMatch(message)
            ?.group(1);
        final kind = RegExp(r'类别=(\w+)').firstMatch(message)?.group(1);
        if (stage != null) vpnLog('$label 失败：阶段=$stage，类别=${kind ?? "未知"}');
        for (final phase in ['DNS', 'TCP', '回环鉴权']) {
          if (message.contains('VPN 目标 $phase') ||
              message.contains('VPN $phase超时')) {
            vpnLog('$label 失败：阶段=$phase');
            break;
          }
        }
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
