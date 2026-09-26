import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cfb.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

import 'passkey_bundle.dart';
import 'webauthn_signer.dart';

/// 通行密钥在设备间搬运时的加密封装。
///
/// 导出物是一段 `nuistkey1:` 开头的 Base64URL 文本，剪贴板、`.nuistkey` 文件、
/// 二维码三种渠道装的都是同一个字符串。加密方案：
///
/// 1. APP 内置密钥的 16 字节，末六字节换成用户输入的六位 PIN（ASCII），直接
///    作为 AES-128 的密钥；
/// 2. AES-CFB（128 位反馈、NoPadding，等价于 Java 的 `AES/CFB/NoPadding`），
///    使用固定 IV，不把 IV 额外塞进二维码；
/// 3. 导入方拿同一个内置密钥、同一个 PIN 拼出密钥，用固定 IV 解密。CFB 不带
///    认证，PIN 错误只能靠明文解析失败来发现。
/// 4. 密文使用 Base45 编码：它的 45 个字符恰好是二维码 alphanumeric 模式的
///    字符集，导出页据此把二维码画小两个版本（见 `portal_export_page.dart`
///    的 `_exportQrCode`）。
///
/// 明文不是 JSON 而是 [_Payload] 的紧凑二进制（一百字节出头），为的是二维码能小
/// 到手机隔着屏幕一扫就中。
///
/// **安全边界必须说清楚**：内置密钥和 APP 一起打包，拆包就能拿到，所以它只挡
/// "顺手看一眼"，导出物的实际强度 = 六位 PIN 的 10^6 空间，没有任何拉伸，
/// 离线穷举是瞬间的事。导出物本身要当作门户登录凭据对待，UI 上要反复提醒用户。
class PasskeyTransfer {
  PasskeyTransfer._();

  static const prefix = 'nuistkey1:';

  /// APP 内置密钥（16 个 ASCII 字符 = 128 位），末六字节换成 PIN 后才是
  /// 真正的 AES 密钥。
  static const _appKey = 'HUWQs6XVvlrskAWz';

  static const _blockLength = 16;
  static final _iv = Uint8List(_blockLength);

  /// 把 [bundle] 加密成可传输的文本。私钥模板校验要做椭圆曲线点乘，放到独立 isolate。
  static Future<String> encrypt(PasskeyBundle bundle, String pin) {
    _checkPin(pin);
    return Isolate.run(() => _encryptSync(bundle, pin));
  }

  /// 解析并解密 [text]，PIN 错误与数据损坏都会抛 [PasskeyTransferError]。
  static Future<PasskeyBundle> decrypt(String text, String pin) async {
    _checkPin(pin);
    final bundle = await Isolate.run(() => _decryptSync(text, pin));
    // 解得出来不代表能用，顺手过一遍签名器的 PKCS#8 解析。
    try {
      Es256Key.fromPkcs8Pem(bundle.privateKeyPkcs8Pem);
    } on Exception catch (e) {
      throw PasskeyTransferError('导入的私钥无法解析：$e');
    }
    return bundle;
  }

  /// 粗判一段文本是不是导出物，用于剪贴板预填和扫码过滤。
  static bool looksLikeExport(String? text) =>
      text != null && text.trim().startsWith(prefix);

  static void _checkPin(String pin) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const PasskeyTransferError('PIN 必须是六位数字');
    }
  }

  // ==================== 加密 ====================

  static String _encryptSync(PasskeyBundle bundle, String pin) {
    final plain = _Payload.encode(bundle, ECCurve_secp256r1());
    final sealed = _cfb(true, _deriveKey(pin), _iv, plain);

    return prefix + _base45Encode(sealed);
  }

  // ==================== 解密 ====================

  static PasskeyBundle _decryptSync(String text, String pin) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const PasskeyTransferError('这不是 NUIST++ 导出的通行密钥');
    }
    final Uint8List blob;
    try {
      blob = _base45Decode(trimmed.substring(prefix.length));
    } on FormatException {
      throw const PasskeyTransferError('数据不完整或被改动过');
    }
    if (blob.isEmpty) {
      throw const PasskeyTransferError('数据不完整或被改动过');
    }

    final plain = _cfb(false, _deriveKey(pin), _iv, blob);

    try {
      return _Payload.decode(plain, ECCurve_secp256r1());
    } catch (_) {
      throw const PasskeyTransferError('PIN 错误或数据已损坏');
    }
  }

  // ==================== 密码学原语 ====================

  static Uint8List _deriveKey(String pin) {
    final key = utf8.encode(_appKey);
    return Uint8List.fromList([
      ...key.sublist(0, key.length - pin.length),
      ...utf8.encode(pin),
    ]);
  }

  /// AES/CFB-128/NoPadding。pointycastle 的 CFB 只收整块，最后不满一块的部分
  /// 补零后过一遍再截断——CFB 的输出逐字节只取决于同位置的输入，补的零不影响结果。
  static Uint8List _cfb(
    bool forEncryption,
    Uint8List key,
    Uint8List iv,
    Uint8List input,
  ) {
    final cipher = CFBBlockCipher(AESEngine(), _blockLength)
      ..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
    final padded = Uint8List(
      (input.length + _blockLength - 1) ~/ _blockLength * _blockLength,
    )..setAll(0, input);
    final out = Uint8List(padded.length);
    for (var off = 0; off < padded.length; off += _blockLength) {
      cipher.processBlock(padded, off, out, off);
    }
    return Uint8List.sublistView(out, 0, input.length);
  }

  static Uint8List _hexToBytes(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// 明文的紧凑二进制编码。
///
/// 每个字段都尽量按"本来的字节"存：Base64URL 字符串解回原始字节、hex 解回
/// 字节、PKCS#8 只留 32 字节私钥标量（其余按 WebCrypto 导出的固定模板重建）。
/// 凭据字段是门户校验的原样字符串，所以还原后必须与原字符串逐字相同——比如
/// 非规范的 Base64URL 直接判定为无法导出，不做降级存储。
///
/// 布局（大端）：
/// ```
/// flags(1)                      仅 flagRpId 一个标志位，其余位必须为 0
/// [rpId: len(1)+utf8]           仅 flagRpId 置位时出现，否则用默认 rpId
/// credentialId: len(1)+bytes
/// key: len(1)+32                私钥标量
/// userId: len(1)+bytes
/// anonbiometricsd: len(1)+bytes
/// deviceName: len(1)+utf8
/// createdAt: 毫秒时间戳(8)
/// ```
class _Payload {
  _Payload._();

  static const defaultRpId = 'authserver.nuist.edu.cn';

  static const _flagRpId = 1 << 0;

  /// WebCrypto `exportKey("pkcs8")` 对 P-256 的固定输出：
  /// PrivateKeyInfo{ v0, {id-ecPublicKey, prime256v1}, OCTET STRING{
  ///   ECPrivateKey{ v1, d(32), [1] BIT STRING{ 0x04 ‖ x ‖ y } } } }
  static const _derPrefixHex =
      '308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420';
  static const _derPubPrefixHex = 'a144034200';

  static Uint8List encode(PasskeyBundle bundle, ECDomainParameters domain) {
    var flags = 0;
    final out = BytesBuilder();

    if (bundle.rpId != defaultRpId) {
      flags |= _flagRpId;
    }

    final credentialId = _packBase64Url(bundle.credentialId, '凭据 ID');

    final der = _pemToDer(bundle.privateKeyPkcs8Pem);
    final key = _scalarFromTemplateDer(der, domain);

    final userId = _packBase64Url(bundle.userId, '用户 ID');

    final anon = _packHex(bundle.anonbiometricsd);

    out.addByte(flags);
    if (flags & _flagRpId != 0) _putField(out, utf8.encode(bundle.rpId));
    _putField(out, credentialId);
    _putField(out, key);
    _putField(out, userId);
    _putField(out, anon);
    _putField(out, utf8.encode(bundle.deviceName));
    out.add(
      _bigIntToBytes(BigInt.from(bundle.createdAt.millisecondsSinceEpoch), 8),
    );
    return out.toBytes();
  }

  static PasskeyBundle decode(Uint8List bytes, ECDomainParameters domain) {
    final reader = _Reader(bytes);
    final flags = reader.byte();
    if (flags & ~_flagRpId != 0) {
      throw const PasskeyTransferError('解密结果不是有效的凭据');
    }

    final rpId = flags & _flagRpId != 0
        ? utf8.decode(reader.field())
        : defaultRpId;
    final credentialId = _unpackBase64Url(reader.field());
    final der = _templateDerFromScalar(reader.field(), domain);
    final userId = _unpackBase64Url(reader.field());
    final anon = _unpackHex(reader.field());
    final deviceName = utf8.decode(reader.field());
    final createdAt = _bytesToBigInt(reader.take(8)).toInt();
    if (!reader.done) {
      throw const PasskeyTransferError('解密结果不是有效的凭据');
    }

    return PasskeyBundle(
      rpId: rpId,
      credentialId: credentialId,
      privateKeyPkcs8Pem: _derToPem(der),
      userId: userId,
      anonbiometricsd: anon,
      deviceName: deviceName,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    );
  }

  // ---------- 字段编码 ----------

  static void _putField(BytesBuilder out, List<int> bytes) {
    if (bytes.length > 0xff) {
      throw const PasskeyTransferError('凭据字段过长，无法导出');
    }
    out.addByte(bytes.length);
    out.add(bytes);
  }

  /// [value] 解成字节；非规范值直接拒绝导出，[what] 用于拼错误文案。
  static Uint8List _packBase64Url(String value, String what) {
    try {
      final bytes = base64UrlDecode(value);
      if (base64UrlNoPad(bytes) == value) return bytes;
    } on FormatException {
      // 统一转换为面向用户的导出错误。
    }
    throw PasskeyTransferError('$what 不是规范的 Base64URL');
  }

  static String _unpackBase64Url(Uint8List bytes) => base64UrlNoPad(bytes);

  static Uint8List _packHex(String value) {
    if (value.length.isEven && RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
      return PasskeyTransfer._hexToBytes(value);
    }
    throw const PasskeyTransferError('匿名标识不是规范的十六进制字符串');
  }

  static String _unpackHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ---------- 私钥 ----------

  static Uint8List _pemToDer(String pem) => base64.decode(
    pem
        .replaceAll(RegExp(r'-----(BEGIN|END)[^-]*-----'), '')
        .replaceAll(RegExp(r'\s'), ''),
  );

  static String _derToPem(Uint8List der) {
    final text = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < text.length; i += 64) {
      lines.add(text.substring(i, min(i + 64, text.length)));
    }
    return '-----BEGIN PRIVATE KEY-----\n'
        '${lines.join('\n')}\n'
        '-----END PRIVATE KEY-----';
  }

  /// 校验 [der] 恰好是"模板 + 标量 + 由该标量算出的公钥"，返回其中的标量。
  /// 任何偏差都判定为无法导出——凭据私钥只可能是 WebCrypto 导出的形状，
  /// 出现别的说明数据本身有问题，不能猜着存。
  ///
  /// 公钥比对需要椭圆曲线点乘，所以 [encode] 整体跑在独立 isolate 里。
  static Uint8List _scalarFromTemplateDer(
    Uint8List der,
    ECDomainParameters domain,
  ) {
    const invalid = PasskeyTransferError(
      '本机私钥不是 WebCrypto 导出的 P-256 PKCS#8，无法导出',
    );
    final prefix = PasskeyTransfer._hexToBytes(_derPrefixHex);
    if (der.length != prefix.length + 32 + 5 + 65) throw invalid;
    for (var i = 0; i < prefix.length; i++) {
      if (der[i] != prefix[i]) throw invalid;
    }
    final scalar = Uint8List.sublistView(
      der,
      prefix.length,
      prefix.length + 32,
    );
    final d = _bytesToBigInt(scalar);
    if (d <= BigInt.zero || d >= domain.n) throw invalid;
    final publicKey = (domain.G * d)!.getEncoded(false);
    final storedKey = Uint8List.sublistView(der, prefix.length + 32 + 5);
    for (var i = 0; i < publicKey.length; i++) {
      if (storedKey[i] != publicKey[i]) throw invalid;
    }
    return Uint8List.fromList(scalar);
  }

  static Uint8List _templateDerFromScalar(
    Uint8List scalar,
    ECDomainParameters domain,
  ) {
    if (scalar.length != 32) {
      throw const PasskeyTransferError('解密结果不是有效的凭据');
    }
    final q = (domain.G * _bytesToBigInt(scalar))!;
    return Uint8List.fromList([
      ...PasskeyTransfer._hexToBytes(_derPrefixHex),
      ...scalar,
      ...PasskeyTransfer._hexToBytes(_derPubPrefixHex),
      ...q.getEncoded(false),
    ]);
  }
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  bool get done => _offset == _bytes.length;

  int byte() => take(1)[0];

  Uint8List field() => take(byte());

  Uint8List take(int length) {
    if (_offset + length > _bytes.length) {
      throw const PasskeyTransferError('解密结果不是有效的凭据');
    }
    final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }
}

/// 大端无符号字节序列 ↔ BigInt。
BigInt _bytesToBigInt(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

const _base45Alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ '
    r'$%*+-./:';

String _base45Encode(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 2) {
    if (i + 1 == bytes.length) {
      final value = bytes[i];
      out
        ..write(_base45Alphabet[value % 45])
        ..write(_base45Alphabet[value ~/ 45]);
      continue;
    }
    var value = bytes[i] * 256 + bytes[i + 1];
    out
      ..write(_base45Alphabet[value % 45])
      ..write(_base45Alphabet[(value ~/ 45) % 45])
      ..write(_base45Alphabet[value ~/ 2025]);
  }
  return out.toString();
}

Uint8List _base45Decode(String text) {
  final values = [
    for (final character in text.codeUnits)
      _base45Alphabet.indexOf(String.fromCharCode(character)),
  ];
  if (values.any((value) => value < 0) || text.length % 3 == 1) {
    throw const FormatException('Invalid Base45 data');
  }

  final out = BytesBuilder();
  var i = 0;
  while (i < values.length) {
    final remaining = values.length - i;
    if (remaining == 2) {
      final value = values[i] + values[i + 1] * 45;
      if (value > 0xff) throw const FormatException('Invalid Base45 data');
      out.addByte(value);
      break;
    }
    final value = values[i] + values[i + 1] * 45 + values[i + 2] * 2025;
    if (value > 0xffff) throw const FormatException('Invalid Base45 data');
    out
      ..addByte(value ~/ 256)
      ..addByte(value % 256);
    i += 3;
  }
  return out.toBytes();
}

/// 导出 / 导入过程中面向用户的错误，[message] 可直接展示。
class PasskeyTransferError implements Exception {
  const PasskeyTransferError(this.message);

  final String message;

  @override
  String toString() => 'PasskeyTransferError: $message';
}
