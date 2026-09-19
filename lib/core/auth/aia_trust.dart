import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'portal_http.dart';

/// 自动补全服务器漏发的中间证书（AIA chasing）。
///
/// 学校有些站点（如 icard）只下发叶子证书，浏览器和 Windows 会顺着证书里的
/// AIA「CA Issuers」地址把中间证书拉回来，Dart 的 BoringSSL 不会，握手直接失败。
/// 这里在握手失败后做同样的事：记下叶子证书 → 拉取签发者 → 加进
/// [context] → 由调用方重建 HttpClient 重试。
///
/// 安全性：只往 [context] 里加**非自签**的证书。dart:io 的校验不接受非自签
/// 证书作为信任锚点，链最终仍必须落到系统根证书上，所以明文拉来的中间证书
/// 只是「补链提示」，伪造的中间证书因为找不到系统根依旧通不过。
///
/// 拉到的中间证书会落盘到 [resolveCacheDir] 给的目录，下次冷启动 [preload] 直接预热，省掉
/// 首次握手失败 + 一次网络往返。缓存文件出于同样的理由不需要防篡改。
class AiaTrust {
  AiaTrust({bool withTrustedRoots = true, this.resolveCacheDir})
    : context = SecurityContext(withTrustedRoots: withTrustedRoots);

  final SecurityContext context;

  /// 取中间证书的磁盘缓存目录；不给或返回 null 表示不缓存。做成回调是因为
  /// 目录要问平台（path_provider），而本类要保持纯 Dart 可在桌面直接跑。
  final Future<Directory?> Function()? resolveCacheDir;
  Future<Directory?>? _cacheDir;

  Future<Directory?> _dir() =>
      _cacheDir ??= (resolveCacheDir?.call() ?? Future.value(null))
          .catchError((_) => null);

  /// 最近一次握手失败时各主机收到的叶子证书。
  final Map<String, Uint8List> _badLeaf = {};

  /// 已经尝试过补链的主机，避免同一主机反复拉取。
  final Set<String> _attempted = {};

  static const _fetchTimeout = Duration(seconds: 10);
  static const _maxDepth = 3;

  /// 把缓存目录里的中间证书全部加进 [context]。应在首个 TLS 请求前调用；
  /// 多次调用只生效一次。
  Future<void> preload() => _preloading ??= _preload();
  Future<void>? _preloading;

  Future<void> _preload() async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.der')) continue;
        final der = await entry.readAsBytes();
        // 过期或根证书都是无效缓存，顺手清掉，免得越积越多。
        if (_isSelfSigned(der) || _isExpired(der)) {
          await entry.delete();
          continue;
        }
        try {
          context.setTrustedCertificatesBytes(_toPem(der));
          portalLog('AIA 缓存预热: ${_subjectCn(der) ?? entry.path}');
        } catch (_) {
          await entry.delete();
        }
      }
    } catch (e) {
      portalLog('AIA 缓存读取失败: $e');
    }
  }

  Future<void> _cache(Uint8List der) async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final name = _fingerprint(der);
      await File(
        '${dir.path}${Platform.pathSeparator}$name.der',
      ).writeAsBytes(der, flush: true);
    } catch (e) {
      portalLog('AIA 缓存写入失败: $e');
    }
  }

  /// 供 dio 的 IOHttpClientAdapter 使用：每次重建 HttpClient 都带上当前 context。
  HttpClient createHttpClient() {
    return HttpClient(context: context)
      ..badCertificateCallback = (cert, host, port) {
        _badLeaf[host] = Uint8List.fromList(cert.der);
        return false;
      };
  }

  static bool isHandshakeFailure(Object? error) => error is HandshakeException;

  /// 为 [host] 补链。返回 true 表示往 [context] 里加了新证书，值得重试。
  Future<bool> tryRepair(String host) async {
    if (!_attempted.add(host)) return false;
    final leaf = _badLeaf.remove(host);
    if (leaf == null) return false;

    var added = 0;
    var current = leaf;
    for (var depth = 0; depth < _maxDepth; depth++) {
      final url = _caIssuersUrl(current);
      if (url == null) break;
      final Uint8List issuer;
      try {
        issuer = await _fetch(url);
      } catch (e) {
        portalLog('AIA 拉取失败 $url: $e');
        break;
      }
      if (_isSelfSigned(issuer)) {
        // 根证书必须来自系统信任库，网上拉来的一律不加。
        break;
      }
      try {
        context.setTrustedCertificatesBytes(_toPem(issuer));
        added++;
        portalLog('AIA 补链: 已加入 ${_subjectCn(issuer) ?? url}');
      } catch (e) {
        portalLog('AIA 证书无法加入信任库: $e');
        break;
      }
      await _cache(issuer);
      current = issuer;
    }
    return added > 0;
  }

  // ==================== 证书解析 ====================

  /// OID 1.3.6.1.5.5.7.48.2（caIssuers）的 DER 编码，后面紧跟 [6] URI。
  static final _caIssuersOid = Uint8List.fromList(
    const [0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x02],
  );

  /// AIA 的结构固定（AccessDescription = SEQUENCE { OID, GeneralName }），
  /// 直接按字节找 OID 后面的 [6] IA5String 比完整走一遍扩展解析更省事、也更稳。
  static String? _caIssuersUrl(Uint8List der) {
    final oid = _caIssuersOid;
    for (var i = 0; i + oid.length + 2 <= der.length; i++) {
      var matched = true;
      for (var j = 0; j < oid.length; j++) {
        if (der[i + j] != oid[j]) {
          matched = false;
          break;
        }
      }
      if (!matched) continue;
      var p = i + oid.length;
      if (der[p] != 0x86) continue;
      var len = der[p + 1];
      p += 2;
      if (len & 0x80 != 0) {
        final n = len & 0x7F;
        len = 0;
        for (var k = 0; k < n; k++) {
          len = (len << 8) | der[p + k];
        }
        p += n;
      }
      if (p + len > der.length) continue;
      final url = ascii.decode(der.sublist(p, p + len), allowInvalid: true);
      if (url.startsWith('http://') || url.startsWith('https://')) return url;
    }
    return null;
  }

  /// TBSCertificate 的 issuer 与 subject 是否相同。
  static bool _isSelfSigned(Uint8List der) {
    final (issuer, subject) = _names(der);
    if (issuer == null || subject == null) return false;
    if (issuer.length != subject.length) return false;
    for (var i = 0; i < issuer.length; i++) {
      if (issuer[i] != subject[i]) return false;
    }
    return true;
  }

  static (Uint8List?, Uint8List?) _names(Uint8List der) {
    try {
      final tbs = _tbs(der);
      final offset = _tbsOffset(tbs);
      return (
        tbs.elements[offset + 2].encodedBytes,
        tbs.elements[offset + 4].encodedBytes,
      );
    } catch (_) {
      return (null, null);
    }
  }

  /// notAfter 已过则为 true；解析不了按未过期处理，交给 TLS 校验去拒绝。
  static bool _isExpired(Uint8List der) {
    try {
      final tbs = _tbs(der);
      final validity = tbs.elements[_tbsOffset(tbs) + 3] as ASN1Sequence;
      final notAfter = switch (validity.elements[1]) {
        ASN1UtcTime t => t.dateTimeValue,
        ASN1GeneralizedTime t => t.dateTimeValue,
        _ => null,
      };
      return notAfter != null && DateTime.now().isAfter(notAfter);
    } catch (_) {
      return false;
    }
  }

  static ASN1Sequence _tbs(Uint8List der) {
    final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
    return cert.elements.first as ASN1Sequence;
  }

  /// TBSCertificate: [0] version（可选）, serial, sigAlg, issuer, validity, subject
  static int _tbsOffset(ASN1Sequence tbs) =>
      tbs.elements.first.tag == 0xA0 ? 1 : 0;

  /// 缓存文件名：SHA-256 指纹的十六进制。
  static String _fingerprint(Uint8List der) {
    final digest = SHA256Digest().process(der);
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 仅用于日志。
  static String? _subjectCn(Uint8List der) {
    final (_, subject) = _names(der);
    if (subject == null) return null;
    try {
      final name = ASN1Parser(subject).nextObject() as ASN1Sequence;
      for (final rdn in name.elements) {
        final attr = (rdn as ASN1Set).elements.first as ASN1Sequence;
        final oid = attr.elements.first as ASN1ObjectIdentifier;
        if (oid.identifier == '2.5.4.3') {
          return utf8.decode(attr.elements[1].valueBytes(), allowMalformed: true);
        }
      }
    } catch (_) {}
    return null;
  }

  /// SecurityContext 只认 PEM/PKCS12，DER 要先包一层。
  static Uint8List _toPem(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 0x30) {
      final body = base64.encode(bytes);
      final buffer = StringBuffer('-----BEGIN CERTIFICATE-----\n');
      for (var i = 0; i < body.length; i += 64) {
        buffer.writeln(
          body.substring(i, i + 64 > body.length ? body.length : i + 64),
        );
      }
      buffer.write('-----END CERTIFICATE-----\n');
      return Uint8List.fromList(utf8.encode(buffer.toString()));
    }
    return bytes;
  }

  /// 拉取证书并统一成 DER（AIA 地址给的可能是 DER 也可能是 PEM）。
  static Future<Uint8List> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = _fetchTimeout
      ..maxConnectionsPerHost = 2;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      final response = await request.close().timeout(_fetchTimeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_fetchTimeout)) {
        builder.add(chunk);
      }
      return _toDer(builder.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  static Uint8List _toDer(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 0x30) return bytes;
    final text = ascii.decode(bytes, allowInvalid: true);
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
    ).firstMatch(text);
    if (match == null) throw const FormatException('不是 DER 也不是 PEM 证书');
    return Uint8List.fromList(
      base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
    );
  }
}
