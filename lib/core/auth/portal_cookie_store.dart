import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';

import '../logging/app_log.dart';
import 'portal_exceptions.dart';
import 'secure_cookie_storage.dart';

/// 门户、业务系统和 VPN 共用的安全 Cookie 存储。
///
/// 读写串行化，避免冷启动恢复与并发响应相互覆盖；清空时作废旧客户端，
/// 旧请求即使随后收到响应，也不能把已解绑的会话写回来。
class PortalCookieStore {
  static final _log = AppLog.logger('core.auth.cookie_store');

  PortalCookieStore({Storage? storage})
    : _jar = PersistCookieJar(
        persistSession: true,
        ignoreExpires: false,
        storage: storage ?? const SecureCookieStorage(),
      );

  static final instance = PortalCookieStore();

  final PersistCookieJar _jar;
  Future<void> _queue = Future.value();
  int _generation = 0;
  final Map<String, int> _hostRevisions = {};

  /// 当前账号会话的代次，清空后递增。
  int get generation => _generation;

  /// 指定子系统 Cookie 的代次，与账号解绑代次互相独立。
  int hostRevision(String host) => _hostRevisions[host] ?? 0;

  /// 在存储队列内校验响应代次，旧响应不能污染新会话。
  Future<void> saveForRevision(
    Uri uri,
    List<Cookie> cookies, {
    required int generation,
    required int hostRevision,
  }) => _forGeneration(generation, () async {
    if (this.hostRevision(uri.host) != hostRevision) return;
    await _jar.saveFromResponse(uri, cookies);
  });

  /// 为一个客户端取得当前账号的 Cookie 视图。
  CookieJar openJar() => _SessionCookieJar(this, _generation);

  /// 检查请求是否仍属于当前账号。
  void checkGeneration(int generation) {
    if (generation != _generation) {
      throw const PortalLoginError(
        '登录状态已清除，请重新发起请求',
        code: 'session_generation_changed',
        stage: 'session.validate',
      );
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _forGeneration<T>(int generation, Future<T> Function() action) =>
      _serialize(() async {
        checkGeneration(generation);
        final result = await action();
        checkGeneration(generation);
        return result;
      });

  Map<String, Object?> _snapshotPaths(Map paths) => {
    for (final path in paths.cast<String, dynamic>().entries)
      path.key: {
        for (final cookie
            in (path.value as Map).cast<String, SerializableCookie>().entries)
          cookie.key: cookie.value.toJson(),
      },
  };

  Map<String, Object?> _snapshotDomains() => {
    for (final domain in _jar.domainCookies.entries)
      domain.key: _snapshotPaths(domain.value),
  };

  Future<Set<Cookie>> _removeExpired() async {
    final expired = <Cookie>{};
    for (final domains in [_jar.hostCookies, _jar.domainCookies]) {
      var changed = false;
      for (final entry in domains.entries) {
        var hostChanged = false;
        final paths = entry.value;
        // PersistCookieJar 恢复的内层 Map 仍是 dynamic，取用前逐层转换。
        for (final raw in paths.cast<String, dynamic>().values) {
          final cookies = (raw as Map).cast<String, SerializableCookie>();
          cookies.removeWhere((_, cookie) {
            if (!cookie.isExpired()) return false;
            expired.add(cookie.cookie);
            hostChanged = true;
            return true;
          });
        }
        changed |= hostChanged;
        if (hostChanged && identical(domains, _jar.hostCookies)) {
          await _jar.storage.write(
            entry.key,
            jsonEncode(_snapshotPaths(paths)),
          );
        }
      }
      if (changed && identical(domains, _jar.domainCookies)) {
        await _jar.storage.write('.domains', jsonEncode(_snapshotDomains()));
      }
    }
    return expired;
  }

  Future<List<Cookie>> _load(int generation, Uri uri) =>
      _forGeneration(generation, () async {
        try {
          final cookies = await _jar.loadForRequest(uri);
          // cookie_jar 的 HTTPS 快路径会放行过期的 Secure Cookie。
          final expired = await _removeExpired();
          return cookies
              .where(
                (cookie) =>
                    !expired.contains(cookie) &&
                    (!cookie.secure || uri.scheme == 'https'),
              )
              .toList();
        } catch (error, stackTrace) {
          _log.warning(
            'persisted_cookie.read_failed',
            error: error,
            stackTrace: stackTrace,
          );
          // 损坏的持久化条目按没有存储处理，后续请求可重新建立会话。
          _jar.hostCookies.remove(uri.host);
          await _jar.storage.delete(uri.host);
          return const [];
        }
      });

  /// 仅清理指定服务器自己的 Cookie，保留父域共享的其他业务会话。
  ///
  /// [names] 用于清理明确属于该系统、但被下发到父域的 Cookie。
  Future<void> clearHost(Uri uri, {Set<String> names = const {}}) =>
      _clearHost(_generation, uri, names);

  /// 清理服务声明的 Cookie 域，并作废这些域正在返回的旧响应。
  Future<void> clearHosts(Iterable<String> hosts) async {
    for (final host in hosts.toSet()) {
      await clearHost(Uri(scheme: 'https', host: host));
    }
  }

  Future<void> _clearHost(int generation, Uri uri, Set<String> names) =>
      _forGeneration(generation, () async {
        _hostRevisions.update(
          uri.host,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        await _jar.delete(uri);
        _jar.domainCookies.remove(uri.host);
        for (final entry in _jar.domainCookies.entries) {
          if (uri.host != entry.key && !uri.host.endsWith('.${entry.key}')) {
            continue;
          }
          for (final raw in entry.value.cast<String, dynamic>().values) {
            final cookies = (raw as Map).cast<String, SerializableCookie>();
            cookies.removeWhere((name, _) => names.contains(name));
          }
        }
        await _removeExpired();
        if (_jar.domainCookies.isEmpty) {
          await _jar.storage.delete('.domains');
        } else {
          await _jar.storage.write('.domains', jsonEncode(_snapshotDomains()));
        }
      });

  /// 作废旧客户端，并在其已经开始的存储操作结束后清空所有 Cookie。
  Future<void> clearAll() {
    _generation++;
    _hostRevisions.clear();
    return _serialize(_jar.deleteAll);
  }

  /// 解绑开始时立即阻止旧账号请求，存储清理由调用方在停止隧道后执行。
  void invalidateAccount() {
    _generation++;
    _hostRevisions.clear();
  }

  /// 清理已作废账号的存储，不再次改变账号代次。
  Future<void> deleteAll() => _serialize(_jar.deleteAll);
}

class _SessionCookieJar implements CookieJar {
  _SessionCookieJar(this.store, this.generation);

  final PortalCookieStore store;
  final int generation;

  @override
  bool get ignoreExpires => false;

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) => store._load(generation, uri);

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) =>
      store._forGeneration(
        generation,
        () => store._jar.saveFromResponse(uri, cookies),
      );

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) =>
      store._clearHost(generation, uri, const {});

  @override
  Future<void> deleteAll() async {
    store.checkGeneration(generation);
    await store.clearAll();
  }
}
