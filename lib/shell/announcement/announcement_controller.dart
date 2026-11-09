import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/network/client_metadata.dart';
import 'announcement_api.dart';
import 'announcement_models.dart';
import 'announcement_store.dart';

/// 拉取函数签名，与 [AnnouncementApi.fetch] 一致。
typedef AnnouncementFetch = Future<AnnouncementFetchResult> Function({
  String? etag,
  String? lastModified,
});

/// 公告状态：先确认客户端上下文，再展示匹配缓存并发起条件请求。
/// 请求失败时只保留与当前版本、包名及渠道匹配的缓存。
///
/// 只提供纯状态与已读标记，弹窗编排由 `AnnouncementOverlay` 负责。
class AnnouncementController extends ChangeNotifier {
  static final _log = AppLog.logger('shell.announcement.controller');

  AnnouncementController._()
    : _fetcher = null,
      _readCache = AnnouncementStore.readCache,
      _saveCache = AnnouncementStore.saveCache,
      _readReadIds = AnnouncementStore.readReadIds,
      _saveReadIds = AnnouncementStore.saveReadIds,
      _now = DateTime.now,
      _metadataProvider = ClientMetadataProvider.instance.get;

  /// 测试用构造：所有外部依赖均可注入，未注入的存储读写为空操作。
  @visibleForTesting
  AnnouncementController.test({
    required AnnouncementFetch fetch,
    Future<AnnouncementCache?> Function()? readCache,
    Future<void> Function(AnnouncementCache)? saveCache,
    Future<Set<String>> Function()? readReadIds,
    Future<void> Function(Set<String>)? saveReadIds,
    DateTime Function()? now,
    Future<ClientMetadata> Function()? metadataProvider,
  }) : _fetcher = fetch,
       _readCache = readCache ?? (() async => null),
       _saveCache = saveCache ?? ((_) async {}),
       _readReadIds = readReadIds ?? (() async => <String>{}),
       _saveReadIds = saveReadIds ?? ((_) async {}),
       _now = now ?? DateTime.now,
       _metadataProvider =
           metadataProvider ?? (() async => const ClientMetadata());

  /// 全局单例。
  static final AnnouncementController instance = AnnouncementController._();

  final AnnouncementFetch? _fetcher;
  final Future<AnnouncementCache?> Function() _readCache;
  final Future<void> Function(AnnouncementCache) _saveCache;
  final Future<Set<String>> Function() _readReadIds;
  final Future<void> Function(Set<String>) _saveReadIds;
  final DateTime Function() _now;
  final Future<ClientMetadata> Function() _metadataProvider;

  Future<void>? _started;
  bool _disposed = false;
  AnnouncementCache? _cache;
  Set<String> _readIds = <String>{};
  bool _bannerShown = false;

  static String? _cacheContext(ClientMetadata metadata) {
    final headers = metadata.headers;
    if (!const [
      'X-Client-Platform',
      'X-App-Package',
      'X-App-Channel',
      'X-App-Version-Code',
    ].every(headers.containsKey)) {
      return null;
    }
    return metadata.cacheKey;
  }

  static bool get _inFlutterTest {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  /// 幂等启动，多次调用返回同一个 Future。测试环境下的单例不发请求。
  Future<void> ensureStarted() => _started ??= _start();

  Future<void> _start() async {
    if (_fetcher == null && _inFlutterTest) return;
    String? cacheKey;
    try {
      cacheKey = _cacheContext(await _metadataProvider());
    } catch (_) {}
    try {
      final stored = await _readCache();
      if (stored != null && stored.matches(cacheKey)) _cache = stored;
    } catch (_) {}
    // 缓存迁移不能丢掉已读状态；服务端筛选后缺少的条目也不代表已经删除。
    try {
      _readIds = await _readReadIds();
    } catch (_) {}
    _notify();
    final api = _fetcher == null ? AnnouncementApi() : null;
    final fetch = _fetcher ?? api!.fetch;
    try {
      await _log.operation(
        'refresh',
        () async {
          final cache = _cache;
          var result = await fetch(
            etag: cache?.etag,
            lastModified: cache?.lastModified,
          );
          if (result.notModified && cache == null) {
            // 不能把没有响应正文的 304 当成更新成功；最多补一次无条件请求。
            result = await fetch();
            if (result.notModified) {
              throw const FormatException('没有可复用的公告缓存');
            }
          }
          if (result.notModified) {
            if (cache != null) {
              _cache = AnnouncementCache(
                items: cache.items,
                cacheKey: cacheKey,
                etag: cache.etag,
                lastModified: cache.lastModified,
                fetchedAt: _now(),
              );
              await _saveCache(_cache!);
            }
          } else {
            // 整体替换：服务端已删除的条目（含不可关闭的）随之从缓存消失。
            final items = (result.items ?? const <Announcement>[])
                .take(kMaxAnnouncements)
                .toList();
            _cache = AnnouncementCache(
              items: items,
              cacheKey: cacheKey,
              etag: result.etag,
              lastModified: result.lastModified,
              fetchedAt: _now(),
            );
            if (cacheKey != null) await _saveCache(_cache!);
          }
        },
        failureEvent: 'refresh.failed_using_cache',
        errorFields: (_) => {'outcome': 'cache_fallback'},
      );
    } catch (_) {
      // 原 Trace 中已记录失败；继续使用已有缓存。
    } finally {
      api?.close();
    }
    _notify();
  }

  /// 当前可见公告（实时按 now 过滤过期并排序，版本范围由服务端筛选）。
  List<Announcement> get visible =>
      visibleAnnouncements(_cache?.items ?? const [], now: _now());

  /// 当前时间（可注入），供 UI 计算过期定时。
  DateTime get now => _now();

  bool _unread(Announcement a) => !_readIds.contains(a.id);

  /// 是否存在未读的可见公告（所有提醒级别）。
  bool get hasUnread => visible.any(_unread);

  /// 未读且需悬浮条提醒的公告（不含不可关闭的）。
  List<Announcement> get unreadBadge => visible
      .where((a) => a.remind == AnnouncementRemind.badge && !a.blocking)
      .where(_unread)
      .toList();

  /// 未读且需自动弹出的公告（不含不可关闭的）。
  List<Announcement> get unreadPopup => visible
      .where((a) => a.remind == AnnouncementRemind.popup && !a.blocking)
      .where(_unread)
      .toList();

  /// 不可关闭的公告，不受已读影响，过期即释放。
  List<Announcement> get blocking => visible.where((a) => a.blocking).toList();

  /// 本次进程是否已弹过悬浮条。
  bool get bannerShownThisLaunch => _bannerShown;

  /// 记录本次进程已弹过悬浮条。
  void markBannerShown() => _bannerShown = true;

  /// 把给定 id 标为已读。
  Future<void> markRead(Iterable<String> ids) async {
    final before = _readIds.length;
    _readIds = {..._readIds, ...ids};
    if (_readIds.length == before) return;
    _notify();
    await _saveReadIds(_readIds);
  }

  /// 把当前所有可见公告标为已读。
  Future<void> markAllVisibleRead() => markRead(visible.map((a) => a.id));

  /// 最近一个不可关闭公告的剩余时长，供 UI 定时重检过期。
  Duration? get nextExpiry {
    final now = _now();
    Duration? best;
    for (final a in blocking) {
      final d = a.expiresAt!.difference(now);
      if (best == null || d < best) best = d;
    }
    return best;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
