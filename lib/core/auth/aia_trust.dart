import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../logging/app_log.dart';
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
  /// CAS、VPN 引导与校园业务共用同一证书缓存和信任上下文。
  static final shared = AiaTrust(resolveCacheDir: _sharedCacheDir);
  static Future<Directory?> _sharedCacheDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}aia_certs');
  }

  static final _log = AppLog.logger('core.auth.certificate');
  AiaTrust({
    bool withTrustedRoots = true,
    this.resolveCacheDir,
    DateTime Function()? now,
  }) : _withTrustedRoots = withTrustedRoots,
       _now = now ?? DateTime.now,
       context = SecurityContext(withTrustedRoots: withTrustedRoots);

  SecurityContext context;
  final bool _withTrustedRoots;
  final DateTime Function() _now;

  /// 取中间证书的磁盘缓存目录；不给或返回 null 表示不缓存。做成回调是因为
  /// 目录要问平台（path_provider），而本类要保持纯 Dart 可在桌面直接跑。
  final Future<Directory?> Function()? resolveCacheDir;
  Future<Directory?>? _cacheDir;

  Future<Directory?> _dir() =>
      _cacheDir ??= (resolveCacheDir?.call() ?? Future.value(null)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _log.warning(
          'cache.directory_failed',
          error: error,
          stackTrace: stackTrace,
          fields: {'outcome': 'memory_fallback', 'stage': 'certificate.cache'},
        );
        return null;
      });

  /// 最近一次握手失败时各主机收到的叶子证书。
  final Map<String, Uint8List> _badLeaf = {};

  final Map<String, String> _lastLeafFingerprint = {};
  final Map<String, Future<bool>> _repairs = {};
  final Map<String, Uint8List> _memoryIssuers = {};
  DateTime? _cacheValidUntil;
  final Map<String, Uint8List> _issuersByUrl = {};
  final Map<String, DateTime> _preparedHosts = {};
  final Map<String, Future<bool>> _preparations = {};

  /// 一卡通请求前只探测 TLS 叶子，不发送业务 HTTP、Cookie，也不放行坏证书。
  Future<bool> prepareHost(
    Uri uri, {
    FutureOr<HttpClient> Function()? createProbeClient,
    FutureOr<HttpClient> Function()? createFetchClient,
  }) {
    final key = '${uri.host}:${uri.port}';
    final until = _preparedHosts[key];
    if (until != null && until.isAfter(_now())) return Future.value(false);
    return _preparations[key] ??=
        _prepareHost(
          uri,
          createProbeClient: createProbeClient,
          createFetchClient: createFetchClient,
        ).whenComplete(() {
          _preparations.remove(key);
        });
  }

  Future<bool> _prepareHost(
    Uri uri, {
    FutureOr<HttpClient> Function()? createProbeClient,
    FutureOr<HttpClient> Function()? createFetchClient,
  }) async {
    await preload();
    final HttpClient client;
    try {
      client = await (createProbeClient?.call() ?? createHttpClient());
    } catch (_) {
      // 选路/原生准备失败仍由真实业务请求报告，预补不能取代业务诊断。
      return false;
    }
    client.badCertificateCallback = onBadCertificate;
    client.connectionTimeout = _fetchTimeout;
    var repaired = false;
    var verified = false;
    try {
      // getUrl 只建立连接；不 close/send，不发业务 HTTP 或认证信息。
      final request = await client.getUrl(uri).timeout(_fetchTimeout);
      verified = true;
      request.abort();
    } catch (_) {
      if (_badLeaf.containsKey(uri.host)) {
        repaired = await tryRepair(
          uri.host,
          createFetchClient: createFetchClient,
        );
      }
    } finally {
      client.close(force: true);
    }
    if (verified) {
      _preparedHosts['${uri.host}:${uri.port}'] =
          _cacheValidUntil ?? _now().add(const Duration(minutes: 5));
    }
    return repaired;
  }

  static const _fetchTimeout = Duration(seconds: 10);
  static const _maxDepth = 3;

  /// 把缓存目录里的中间证书全部加进 [context]。应在首个 TLS 请求前调用；
  /// 多次调用只生效一次。
  Future<void> preload() {
    if (_cacheValidUntil case final until? when !until.isAfter(_now())) {
      _memoryIssuers.removeWhere((_, der) => !_isCurrentlyValid(der));
      _issuersByUrl.removeWhere((_, der) => !_isCurrentlyValid(der));
      context = SecurityContext(withTrustedRoots: _withTrustedRoots);
      _cacheValidUntil = null;
      for (final der in _memoryIssuers.values.toList()) {
        context.setTrustedCertificatesBytes(_toPem(der));
        _rememberIssuer(der);
      }
      _preloading = null;
    }
    return _preloading ??= _preload().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _log.warning(
          'certificate.preload_timeout',
          fields: {
            'stage': 'certificate.preload',
            'timeout_ms': 5000,
            'outcome': 'cache_fallback',
          },
        );
      },
    );
  }

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
        if (_isSelfSigned(der) || !_isCurrentlyValid(der)) {
          await entry.delete();
          continue;
        }
        try {
          context.setTrustedCertificatesBytes(_toPem(der));
          _rememberIssuer(der);
          portalLog('certificate.cache_loaded');
        } catch (error, stackTrace) {
          _log.warning(
            'cache.certificate_invalid',
            error: error,
            stackTrace: stackTrace,
            fields: {
              'stage': 'certificate.preload',
              'outcome': 'cache_fallback',
            },
          );
          await entry.delete();
        }
      }
    } catch (error, stackTrace) {
      _log.warning(
        'certificate.cache_read_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'outcome': 'cache_fallback'},
      );
    }
  }

  Future<void> _cache(Uint8List der) async {
    _rememberIssuer(der);
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final name = _fingerprint(der);
      await File('${dir.path}${Platform.pathSeparator}$name.der')
          .writeAsBytes(der, flush: true);
    } catch (error, stackTrace) {
      _log.warning(
        'certificate.cache_write_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'outcome': 'memory_fallback'},
      );
    }
  }

  /// 供 dio 的 IOHttpClientAdapter 使用：每次重建 HttpClient 都带上当前 context。
  HttpClient createHttpClient() {
    return HttpClient(context: context)
      ..badCertificateCallback = onBadCertificate;
  }

  /// 记录需要补链的证书，始终拒绝本次握手；也供 VPN 内层 TLS 使用。
  bool onBadCertificate(X509Certificate cert, String host, int port) {
    final fingerprint = _fingerprint(cert.der);
    if (_lastLeafFingerprint[host] == fingerprint &&
        !_repairs.containsKey(host)) {
      // 有效缓存仍未能补完整链：本次新失败允许失效重取，不能终身跳过主机。
      final issuer = _caIssuersUrl(cert.der);
      if (issuer != null) _issuersByUrl.remove(issuer);
    }
    _preparedHosts.removeWhere((key, _) => key.startsWith('$host:'));
    _lastLeafFingerprint[host] = fingerprint;
    _badLeaf[host] = Uint8List.fromList(cert.der);
    return false;
  }

  static bool isHandshakeFailure(Object? error) => error is HandshakeException;

  /// 为 [host] 补链。返回 true 表示往 [context] 里加了新证书，值得重试。
  Future<bool> tryRepair(
    String host, {
    FutureOr<HttpClient> Function()? createFetchClient,
  }) => _repairs[host] ??= _repair(host, createFetchClient: createFetchClient)
      .whenComplete(() {
        _repairs.remove(host);
      });

  Future<bool> _repair(
    String host, {
    FutureOr<HttpClient> Function()? createFetchClient,
  }) async {
    final leaf = _badLeaf.remove(host);
    if (leaf == null) {
      _log.debug(
        'repair.skipped',
        fields: {'host': host, 'reason_code': 'certificate_leaf_unavailable'},
      );
      return false;
    }

    var added = 0;
    await preload();
    var current = leaf;
    final visited = <String>{};
    for (var depth = 0; depth < _maxDepth; depth++) {
      final url = _caIssuersUrl(current);
      if (url == null || !visited.add(url)) break;
      final Uint8List issuer;
      try {
        final cached = _issuersByUrl[url];
        issuer = cached != null && _isCurrentlyValid(cached)
            ? cached
            : await _fetch(url, createFetchClient: createFetchClient);
      } catch (error, stackTrace) {
        _log.warning(
          'certificate.fetch_failed',
          error: error,
          stackTrace: stackTrace,
          fields: {
            'host': host,
            'stage': 'certificate.fetch',
            'details': {'depth': depth},
          },
        );
        break;
      }
      if (_isSelfSigned(issuer) || !_isCurrentlyValid(issuer)) {
        // 根证书必须来自系统信任库，网上拉来的一律不加。
        break;
      }
      try {
        context.setTrustedCertificatesBytes(_toPem(issuer));
        _issuersByUrl[url] = issuer;
        added++;
        portalLog('certificate.chain_extended');
      } catch (error, stackTrace) {
        _log.warning(
          'certificate.trust_failed',
          error: error,
          stackTrace: stackTrace,
          fields: {
            'host': host,
            'stage': 'certificate.trust',
            'details': {'depth': depth},
          },
        );
        break;
      }
      await _cache(issuer);
      current = issuer;
    }
    return added > 0;
  }

  // ==================== 证书解析 ====================

  /// OID 1.3.6.1.5.5.7.48.2（caIssuers）的 DER 编码，后面紧跟 [6] URI。
  static final _caIssuersOid = Uint8List.fromList(const [
    0x06,
    0x08,
    0x2B,
    0x06,
    0x01,
    0x05,
    0x05,
    0x07,
    0x30,
    0x02,
  ]);

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
        if (n == 0 || n > 4 || p + n > der.length) continue;
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

  bool _isCurrentlyValid(Uint8List der) {
    final validity = _validity(der);
    return validity != null &&
        !validity.start.isAfter(_now()) &&
        validity.end.isAfter(_now());
  }

  void _rememberIssuer(Uint8List der) {
    _memoryIssuers[_fingerprint(der)] = der;
    final expires = _expiresAt(der);
    if (expires != null &&
        (_cacheValidUntil == null || expires.isBefore(_cacheValidUntil!))) {
      _cacheValidUntil = expires;
    }
  }

  static ({DateTime start, DateTime end})? _validity(Uint8List der) {
    try {
      final tbs = _tbs(der);
      final validity = tbs.elements[_tbsOffset(tbs) + 3] as ASN1Sequence;
      DateTime? time(ASN1Object element) => switch (element) {
        ASN1UtcTime t => t.dateTimeValue,
        ASN1GeneralizedTime t => t.dateTimeValue,
        _ => null,
      };
      final start = time(validity.elements[0]);
      final end = time(validity.elements[1]);
      return start == null || end == null ? null : (start: start, end: end);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _expiresAt(Uint8List der) => _validity(der)?.end;

  @visibleForTesting
  static String? caIssuersUrlForTesting(Uint8List der) => _caIssuersUrl(der);

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
  static Future<Uint8List> _fetch(
    String url, {
    FutureOr<HttpClient> Function()? createFetchClient,
  }) async {
    final client = (await (createFetchClient?.call() ?? HttpClient()))
      ..connectionTimeout = _fetchTimeout
      ..maxConnectionsPerHost = 2;
    final watch = Stopwatch()..start();
    final requestHeaders = <String, Object?>{};
    final responseHeaders = <String, Object?>{};
    HttpClientResponse? response;
    Uint8List? bytes;
    final builder = BytesBuilder(copy: false);
    Object? failure;
    StackTrace? failureStack;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      request.headers.forEach((name, values) => requestHeaders[name] = values);
      response = await request.close().timeout(_fetchTimeout);
      response.headers.forEach(
        (name, values) => responseHeaders[name] = values,
      );
      final httpFailure = response.statusCode == 200
          ? null
          : HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      try {
        final remaining = _fetchTimeout - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('证书响应读取超过请求时限', _fetchTimeout);
        }
        await response.forEach(builder.add).timeout(remaining);
        bytes = builder.takeBytes();
      } catch (error, stackTrace) {
        if (httpFailure == null) rethrow;
        _log.warning(
          'certificate.error_body_incomplete',
          error: error,
          stackTrace: stackTrace,
          fields: {
            'status_code': response.statusCode,
            'stage': 'certificate.fetch_body',
            'timeout_ms': _fetchTimeout.inMilliseconds,
          },
        );
        throw httpFailure;
      }
      if (httpFailure != null) throw httpFailure;
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
      rethrow;
    } finally {
      final captured = bytes ?? builder.takeBytes();
      try {
        await AppLog.recordHttpExchangeAsync(
          'core.auth.certificate',
          {
            'method': 'GET',
            'service': AppLog.serviceForHost(Uri.tryParse(url)?.host ?? ''),
            'status_code': response?.statusCode,
            'duration_ms': watch.elapsedMilliseconds,
            'capture_source': 'dart_http_client',
            'request': {
              'url': url,
              'headers': requestHeaders,
              'body': '',
              'complete': true,
            },
            'response': {
              'status': response?.statusCode,
              'headers': responseHeaders,
              'body_base64': base64Encode(captured),
              'encoding': 'base64',
              'captured_bytes': captured.length,
              'complete': bytes != null,
              if (bytes == null)
                'incomplete_reason': response == null
                    ? 'response_unavailable'
                    : 'response_not_fully_consumed',
              'redirects': [
                for (final redirect in response?.redirects ?? <RedirectInfo>[])
                  {
                    'status': redirect.statusCode,
                    'method': redirect.method,
                    'url': redirect.location.toString(),
                  },
              ],
            },
          },
          error: failure,
          stackTrace: failureStack,
        );
      } finally {
        client.close(force: true);
      }
    }
    return _toDer(bytes);
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
