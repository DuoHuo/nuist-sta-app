import 'dart:convert';

/// 统一门户软件通行密钥（Passkey）凭据包。
///
/// JSON 字段名与 `authserver_login/passkey.local.json` 保持一致，
/// 可直接交给 NuistLogin.py / login_passkey.py 使用：
/// `rpId / credentialId / privateKeyPkcs8Pem / userId / anonbiometricsd`。
/// `userId` 与 `anonbiometricsd` 分别是 startAssertion 的 userId 与 id，
/// 必须与私钥一起保存。
class PasskeyBundle {
  const PasskeyBundle({
    required this.rpId,
    required this.credentialId,
    required this.privateKeyPkcs8Pem,
    required this.userId,
    required this.anonbiometricsd,
    required this.deviceName,
    required this.createdAt,
  });

  final String rpId;
  final String credentialId;
  final String privateKeyPkcs8Pem;
  final String userId;
  final String anonbiometricsd;

  /// 注册时报给门户的设备名，门户「通行密钥」列表里显示的就是它。
  final String deviceName;
  final DateTime createdAt;

  factory PasskeyBundle.fromJson(Map<String, dynamic> json) => PasskeyBundle(
    rpId: json['rpId'] as String,
    credentialId: json['credentialId'] as String,
    privateKeyPkcs8Pem: json['privateKeyPkcs8Pem'] as String,
    userId: json['userId'] as String,
    anonbiometricsd: json['anonbiometricsd'] as String,
    deviceName: json['deviceName'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  Map<String, dynamic> toJson() => {
    'rpId': rpId,
    'credentialId': credentialId,
    'privateKeyPkcs8Pem': privateKeyPkcs8Pem,
    'userId': userId,
    'anonbiometricsd': anonbiometricsd,
    'deviceName': deviceName,
    'createdAt': createdAt.toIso8601String(),
  };

  /// 绑定的学号，解不出来时返回 null。
  ///
  /// [userId] 是学号的 Base64URL 形式——门户 finishRegister 返回的就是它，
  /// Python 版在缺 userId 时也正是拿学号 Base64URL 编码补上的。纯本地解码，
  /// 不需要联网。
  String? get studentId {
    try {
      final normalized = userId.replaceAll('-', '+').replaceAll('_', '/');
      final decoded = utf8.decode(
        base64.decode(
          normalized.padRight(
            normalized.length + (4 - normalized.length % 4) % 4,
            '=',
          ),
        ),
      );
      return RegExp(r'^\d{6,20}$').hasMatch(decoded) ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
