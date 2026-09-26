import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

import 'portal_exceptions.dart';

/// WebAuthn 断言所需的 ES256（P-256 + SHA-256）签名。
///
/// 私钥来自 [PasskeyBundle.privateKeyPkcs8Pem]，即 portal_passkey.js 里
/// `crypto.subtle.exportKey("pkcs8", ...)` 导出后 PEM 封装的结果，对应
/// Python 版的 `serialization.load_pem_private_key`。
class Es256Key {
  Es256Key._(this._key);

  final ECPrivateKey _key;

  /// 解析 PKCS#8 PEM 私钥，并校验它确实是 P-256。
  ///
  /// PKCS#8 的结构是两层：外层 PrivateKeyInfo 的第 3 个元素是一个 OCTET
  /// STRING，里面裹着一份 DER 编码的 RFC 5915 ECPrivateKey，私钥标量 d 是
  /// 后者的第 2 个元素。
  factory Es256Key.fromPkcs8Pem(String pem) {
    final Uint8List der;
    try {
      der = base64.decode(_stripPemArmor(pem));
    } on FormatException catch (e) {
      throw PortalCredentialError('私钥 PEM 解码失败：${e.message}');
    }

    try {
      final info = ASN1Parser(der).nextObject();
      if (info is! ASN1Sequence || info.elements.length < 3) {
        throw const PortalCredentialError('私钥不是合法的 PKCS#8 结构');
      }
      final wrapped = info.elements[2];
      if (wrapped is! ASN1OctetString) {
        throw const PortalCredentialError('PKCS#8 缺少 privateKey 字段');
      }

      final ecKey = ASN1Parser(wrapped.octets).nextObject();
      if (ecKey is! ASN1Sequence || ecKey.elements.length < 2) {
        throw const PortalCredentialError('私钥内层不是合法的 ECPrivateKey');
      }
      final scalar = ecKey.elements[1];
      if (scalar is! ASN1OctetString) {
        throw const PortalCredentialError('ECPrivateKey 缺少私钥标量');
      }

      // P-256 的标量固定 32 字节；长度对不上说明这压根不是 ES256 凭据。
      if (scalar.octets.length != 32) {
        throw PortalCredentialError(
          '私钥不是 P-256（标量长度 ${scalar.octets.length} 字节，应为 32）',
        );
      }

      final d = _bytesToBigInt(scalar.octets);
      final domain = ECCurve_secp256r1();
      if (d <= BigInt.zero || d >= domain.n) {
        throw const PortalCredentialError('私钥标量超出 P-256 有效范围');
      }
      return Es256Key._(ECPrivateKey(d, domain));
    } on PortalException {
      rethrow;
    } catch (e) {
      throw PortalCredentialError('私钥解析失败：$e');
    }
  }

  /// 对 [message] 做 SHA-256 后 ECDSA 签名，返回 WebAuthn 要求的 DER 编码。
  ///
  /// k 走 RFC 6979 确定性算法（构造函数第二个参数传 HMAC-SHA256 即启用），
  /// 这样不依赖需要播种的 SecureRandom —— 移动端上少一个能悄悄出错的环节。
  Uint8List sign(Uint8List message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(_key));
    final signature = signer.generateSignature(message) as ECSignature;
    return (ASN1Sequence()
          ..add(ASN1Integer(signature.r))
          ..add(ASN1Integer(signature.s)))
        .encodedBytes;
  }

  static String _stripPemArmor(String pem) => pem
      .replaceAll(RegExp(r'-----(BEGIN|END)[^-]*-----'), '')
      .replaceAll(RegExp(r'\s'), '');

  /// 大端无符号字节序列转 BigInt（不是补码，字节全部按正数解读）。
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }
}

/// SHA-256 摘要。复用 pointycastle，省掉一个只为算哈希而引入的依赖。
Uint8List sha256Bytes(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

/// Base64URL 编码，去掉结尾的 `=` 填充（WebAuthn 的通用表示）。
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Base64URL 解码，自动补回 `=` 填充。
Uint8List base64UrlDecode(String value) {
  final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  return base64.decode(
    normalized.padRight(
      normalized.length + (4 - normalized.length % 4) % 4,
      '=',
    ),
  );
}
