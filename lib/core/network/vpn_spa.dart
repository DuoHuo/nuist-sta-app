import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

/// 复用现有密码库构造 Enlink SPA 敲门包，不自行实现密码算法。
class VpnSpa {
  VpnSpa._();

  static String _base64(List<int> bytes) =>
      base64Encode(bytes).replaceAll('=', '');

  /// 可注入盐、时间和随机字符串，用于对拍 Python PoC 的脱敏向量。
  static Uint8List encode(
    String user, {
    Uint8List? salt,
    int? timestamp,
    String? randomValue,
    String access = 'tcp/443',
  }) {
    final random = Random.secure();
    salt ??= Uint8List.fromList(List.generate(8, (_) => random.nextInt(256)));
    if (salt.length != 8) throw ArgumentError('SPA 盐必须是 8 字节');
    randomValue ??= List.generate(16, (_) => random.nextInt(10)).join();
    timestamp ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 产品公开的默认 SPA 密钥；用户身份仍由 CAS 和隧道 token 校验。
    final key = MD5Digest().process(
      Uint8List.fromList(utf8.encode('Enlink@123')),
    );
    final material = BytesBuilder();
    var previous = Uint8List(0);
    while (material.length < 48) {
      previous = MD5Digest().process(
        Uint8List.fromList([...previous, ...key, ...salt]),
      );
      material.add(previous);
    }
    final kiv = material.takeBytes();
    final message =
        '$randomValue:${_base64(utf8.encode(user))}:$timestamp:3.0.0:1:${_base64(utf8.encode(access))}';
    final digest = SHA256Digest().process(
      Uint8List.fromList(utf8.encode(message)),
    );
    final plain = utf8.encode('$message:${_base64(digest)}');
    final padding = 16 - plain.length % 16;
    final padded = Uint8List.fromList([
      ...plain,
      ...List.filled(padding, padding),
    ]);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(KeyParameter(kiv.sublist(0, 32)), kiv.sublist(32, 48)),
      );
    final encrypted = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, encrypted, offset);
    }
    final full = _base64([...ascii.encode('Salted__'), ...salt, ...encrypted]);
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    final signature = mac.process(Uint8List.fromList(ascii.encode(full)));
    return Uint8List.fromList(
      ascii.encode('${full.substring(10)}${_base64(signature)}'),
    );
  }

  /// 仅在控制器声明启用 SPA 时发送，使用操作系统现有网络出口。
  static Future<void> knock(String host, int port, String user) async {
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty) throw const SocketException('VPN 敲门地址无法解析');
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      final packet = encode(user);
      if (socket.send(packet, addresses.first, port) != packet.length) {
        throw const SocketException('VPN 敲门包发送失败');
      }
    } finally {
      socket.close();
    }
  }
}
