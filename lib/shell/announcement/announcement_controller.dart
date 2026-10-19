import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'announcement_api.dart';
import 'announcement_models.dart';
import 'announcement_store.dart';

/// 拉取函数签名，与 [AnnouncementApi.fetch] 一致。
typedef AnnouncementFetch = Future<AnnouncementFetchResult> Function({
  String? etag,
  String? lastModified,
});

/// 公告状态：启动时静默检查，先用缓存，再带条件头请求；任何失败都静默保留缓存。
///
/// 只提供纯状态与已读标记，弹窗编排由 `AnnouncementOverlay` 负责。
class AnnouncementController extends ChangeNotifier {
  AnnouncementController._()
    : _fetcher = null,
      _readCache = AnnouncementStore.readCache,
      _saveCache = AnnouncementStore.saveCache,
      _readReadIds = AnnouncementStore.readReadIds,
      _saveReadIds = AnnouncementStore.saveReadIds,
      _now = DateTime.now,
      _appVersion = _platformVersion;

  /// 测试用构造：所有外部依赖均可注入，未注入的存储读写为空操作。
  @visibleForTesting
  AnnouncementController.test({
    required AnnouncementFetch fetch,
    Future<AnnouncementCache?> Function()? readCache,
    Future<void> Function(AnnouncementCache)? saveCache,
    Future<Set<String>> Function()? readReadIds,
    Future<void> Function(Set<String>)? saveReadIds,
    DateTime Function()? now,
    Future<String?> Function()? appVersion,
  }) : _fetcher = fetch,
       _readCache = readCache ?? (() async => null),
       _saveCache = saveCache ?? ((_) async {}),
       _readReadIds = readReadIds ?? (() async => <String>{}),
       _saveReadIds = saveReadIds ?? ((_) async {}),
       _now = now ?? DateTime.now,
       _appVersion = appVersion ?? (() async => null);

  /// 全局单例。
  static final AnnouncementController instance = AnnouncementController._();

  final AnnouncementFetch? _fetcher;
  final Future<AnnouncementCache?> Function() _readCache;
  final Future<void> Function(AnnouncementCache) _saveCache;
  final Future<Set<String>> Function() _readReadIds;
  final Future<void> Function(Set<String>) _saveReadIds;
  final DateTime Function() _now;
  final Future<String?> Function() _appVersion;

  Future<void>? _started;
  bool _disposed = false;
  AnnouncementCache? _cache;
  Set<String> _readIds = <String>{};
  String? _version;
  bool _bannerShown = false;

  static Future<String?> _platformVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
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
    final fetch = _fetcher ?? AnnouncementApi().fetch;
    try {
      _cache = await _readCache();
      _readIds = await _readReadIds();
    } catch (_) {}
    _notify();
    try {
      _version = await _appVersion();
    } catch (_) {
      _version = null;
    }
    _notify();
    try {
      final cache = _cache;
      final result = await fetch(
        etag: cache?.etag,
        lastModified: cache?.lastModified,
      );
      if (result.notModified) {
        if (cache != null) {
          _cache = AnnouncementCache(
            items: cache.items,
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
          etag: result.etag,
          lastModified: result.lastModified,
          fetchedAt: _now(),
        );
        await _saveCache(_cache!);
        final ids = items.map((a) => a.id).toSet();
        final pruned = _readIds.where(ids.contains).toSet();
        if (pruned.length != _readIds.length) {
          _readIds = pruned;
          await _saveReadIds(_readIds);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[announcement] 拉取失败，沿用缓存: $e');
    }
    _notify();
  }

  /// 当前可见公告（实时按 now 过滤过期，并按版本过滤、排序）。
  List<Announcement> get visible => visibleAnnouncements(
    _cache?.items ?? const [],
    now: _now(),
    appVersion: _version,
  );

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
