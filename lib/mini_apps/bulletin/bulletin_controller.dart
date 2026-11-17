import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'bulletin_api.dart';
import 'bulletin_models.dart';
import 'bulletin_store.dart';

/// 公告浏览、缓存与订阅动态的共享状态。
class BulletinController extends ChangeNotifier {
  static final _log = AppLog.logger('bulletin.controller');
  static const _feedLimit = 2;
  static final _oldestPublicationDate = DateTime.utc(1);

  /// 创建公告状态，可注入接口与存储以隔离数据来源。
  BulletinController({
    BulletinApi? api,
    BulletinStore? store,
    DateTime Function()? now,
  }) : _api = api ?? BulletinApi(),
       _store = store ?? BulletinStore(),
       _now = now ?? DateTime.now;

  /// 首页卡片与公告阅读页共用的状态控制器。
  static final BulletinController instance = BulletinController();

  final BulletinApi _api;
  final BulletinStore _store;
  final DateTime Function() _now;
  DateTime? _lastAutomaticFeedAttempt;
  final _automaticCategoryAttempts = <String, DateTime>{};
  static const automaticRefreshInterval = Duration(minutes: 15);
  final Map<String, BulletinListPage> _pages = {};
  final Set<String> _loadingCategories = {};
  final Map<String, String> _categoryErrors = {};

  BulletinCategory _category = BulletinCategory.all.first;
  BulletinSubscription _subscription = const BulletinSubscription();
  List<Bulletin> _feed = [];
  bool _started = false;
  Future<void>? _starting;
  bool _feedLoading = false;
  bool _feedUnavailable = false;
  bool _disposed = false;
  int _subscriptionRevision = 0;

  BulletinCategory get category => _category;
  BulletinSubscription get subscription => _subscription;
  List<Bulletin> get feed => List.unmodifiable(_feed);
  bool get feedLoading => _feedLoading;

  /// 自动重试仍未成功时，首页暂时隐藏动态区域。
  bool get feedUnavailable => _feedUnavailable;
  bool get isLoadingCategory =>
      _loadingCategories.contains(_categoryKey(_category));
  String? get categoryError => _categoryErrors[_categoryKey(_category)];

  List<Bulletin> get items {
    final key = _categoryKey(_category);
    final pages =
        _pages.entries
            .where((entry) => entry.key.startsWith('$key|'))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    final seen = <String>{};
    return [
      for (final page in pages)
        for (final item in page.items)
          if (seen.add(item.id)) item,
    ];
  }

  bool get hasMore {
    final last = _lastPage(_category);
    return last?.nextUrl != null;
  }

  /// 读取本地状态并启动订阅动态刷新；重复调用只初始化一次。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    final local = await _store.read();
    if (_disposed) return;
    _pages
      ..clear()
      ..addAll(local.pages);
    _subscription = local.subscription;
    _feed = _recentMatches([...?_cachedFirstPage?.items, ...local.feed]);
    notifyListeners();
    if (_subscription.enabled) unawaited(refreshFeed(automatic: true));
  }

  /// 切换当前公告分类并加载首屏内容。
  Future<void> selectCategory(BulletinCategory category) async {
    _category = category;
    notifyListeners();
    await loadCategory(category);
  }

  /// 加载分类首屏，或在 [forceRefresh] 为真时重新请求官网。
  Future<void> loadCategory(
    BulletinCategory category, {
    bool forceRefresh = false,
    bool automatic = false,
  }) async {
    await ensureStarted();
    final key = _categoryKey(category);
    final cacheKey = _pageKey(category, 1);
    if (!forceRefresh && _pages.containsKey(cacheKey)) return;
    final now = _now();
    final last = _automaticCategoryAttempts[key];
    if (automatic &&
        last != null &&
        !last.isAfter(now) &&
        now.difference(last) < automaticRefreshInterval) {
      return;
    }
    if (!_loadingCategories.add(key)) return;
    if (automatic) _automaticCategoryAttempts[key] = now;
    _categoryErrors.remove(key);
    notifyListeners();
    try {
      await _log.operation(
        'category.load',
        () async {
          final page = await _api.fetchPage(category.uri, pageNumber: 1);
          _pages.removeWhere((entryKey, _) => entryKey.startsWith('$key|'));
          _pages[cacheKey] = page;
          await _save();
        },
        fields: {'force_refresh': forceRefresh},
        successLevel: forceRefresh ? AppLogLevel.info : AppLogLevel.debug,
        failureEvent: 'category.load_failed',
      );
    } catch (_) {
      SilentRefresh.failCurrent();
      _categoryErrors[key] = '公告加载失败，请稍后重试';
    } finally {
      _loadingCategories.remove(key);
      notifyListeners();
    }
  }

  /// 刷新当前分类的首屏。
  Future<void> refreshCurrentCategory({bool automatic = false}) =>
      loadCategory(_category, forceRefresh: true, automatic: automatic);

  /// 加载当前分类的下一页。
  Future<void> loadMore() async {
    await ensureStarted();
    final category = _category;
    final key = _categoryKey(category);
    final previous = _lastPage(category);
    final nextUrl = previous?.nextUrl;
    if (nextUrl == null || !_loadingCategories.add(key)) return;
    _categoryErrors.remove(key);
    notifyListeners();
    try {
      await _log.operation(
        'category.load_more',
        () async {
          final page = await _api.fetchPage(
            Uri.parse(nextUrl),
            pageNumber: (previous?.pageNumber ?? 0) + 1,
          );
          _pages[_pageKey(category, page.pageNumber)] = page;
          await _save();
        },
        successLevel: AppLogLevel.debug,
        failureEvent: 'category.load_more_failed',
      );
    } catch (_) {
      SilentRefresh.failCurrent();
      _categoryErrors[key] = '加载更多失败，请稍后重试';
    } finally {
      _loadingCategories.remove(key);
      notifyListeners();
    }
  }

  /// 更新订阅设置，并按当前主题刷新首页公告。
  Future<void> configureSubscription({
    required bool enabled,
    required Set<BulletinTopic> topics,
  }) async {
    await ensureStarted();
    _subscriptionRevision++;
    _lastAutomaticFeedAttempt = null;
    _feedUnavailable = false;
    _subscription = BulletinSubscription(
      enabled: enabled,
      topics: Set.unmodifiable(topics),
    );
    _feed = _recentMatches([...?_cachedFirstPage?.items, ..._feed]);
    await _save();
    _log.info(
      'subscription.updated',
      fields: {'enabled': enabled, 'topic_count': topics.length},
    );
    notifyListeners();
    if (enabled) unawaited(refreshFeed());
  }

  /// 检查最新公告，失败后最多尝试三次，持续失败时静默隐藏动态。
  Future<void> refreshFeed({bool automatic = false}) async {
    await ensureStarted();
    final revision = _subscriptionRevision;
    if (!_feedRequestIsCurrent(revision) || _feedLoading) {
      SilentRefresh.skipCurrent(
        reason: _feedLoading ? 'already_refreshing' : 'subscription_inactive',
      );
      return;
    }
    final now = _now();
    final last = _lastAutomaticFeedAttempt;
    if (automatic &&
        last != null &&
        !last.isAfter(now) &&
        now.difference(last) < automaticRefreshInterval) {
      SilentRefresh.skipCurrent(reason: 'automatic_refresh_cooldown');
      return;
    }
    // 失败也从本次尝试起冷却，回前台不能反复触发整轮重试。
    if (automatic) _lastAutomaticFeedAttempt = now;
    _feedLoading = true;
    notifyListeners();
    try {
      await _log.operation(
        'feed.refresh',
        () async {
          final latest = await _fetchFeedWithRetry(revision);
          if (latest == null || !_feedRequestIsCurrent(revision)) {
            SilentRefresh.skipCurrent();
            return false;
          }
          _feed = latest.feed;
          _pages[_pageKey(BulletinCategory.all.first, 1)] = latest.firstPage;
          _feedUnavailable = false;
          await _save();
          return true;
        },
        successLevel: AppLogLevel.debug,
        failureEvent: 'feed.refresh_failed',
        outcomeForResult: (applied) => applied ? 'success' : 'skipped',
      );
    } catch (_) {
      SilentRefresh.failCurrent();
      if (_feedRequestIsCurrent(revision)) _feedUnavailable = true;
    } finally {
      _feedLoading = false;
      if (!_disposed) {
        notifyListeners();
        if (_subscription.enabled && revision != _subscriptionRevision) {
          unawaited(refreshFeed());
        }
      }
    }
  }

  Future<({BulletinListPage firstPage, List<Bulletin> feed})?>
  _fetchFeedWithRetry(int revision) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
      if (!_feedRequestIsCurrent(revision)) return null;
      try {
        return await _fetchRecentFeed(revision);
      } catch (error, stackTrace) {
        _log.debug(
          'feed.retry_failed',
          fields: {
            'attempt': attempt + 1,
            'wait_ms': attempt < 2 ? (attempt + 1) * 2000 : 0,
            'retryable': attempt < 2,
          },
          error: error,
          stackTrace: stackTrace,
        );
        if (!_feedRequestIsCurrent(revision)) return null;
        if (attempt == 2) rethrow;
      }
    }
    return null;
  }

  Future<({BulletinListPage firstPage, List<Bulletin> feed})?> _fetchRecentFeed(
    int revision,
  ) async {
    final firstUri = BulletinCategory.all.first.uri;
    final firstPage = await _api.fetchPage(firstUri, pageNumber: 1);
    final visited = {firstUri};
    var page = firstPage;
    var feed = <Bulletin>[];
    while (_feedRequestIsCurrent(revision)) {
      feed = _recentMatches([...feed, ...page.items]);
      final next = Uri.tryParse(page.nextUrl ?? '');
      if (next == null || !isOfficialBulletinUri(next) || !visited.add(next)) {
        break;
      }
      if (feed.length == _feedLimit && page.items.isNotEmpty) {
        // 用当前页尾的日期判断是否还需翻页，避免较早的置顶公告占满名额。
        final cutoff = _publicationDate(feed.last);
        final pageEnd = _publicationDate(page.items.last);
        if (cutoff != null && pageEnd != null && !pageEnd.isAfter(cutoff)) {
          break;
        }
      }
      page = await _api.fetchPage(next, pageNumber: page.pageNumber + 1);
    }
    return _feedRequestIsCurrent(revision)
        ? (firstPage: firstPage, feed: feed)
        : null;
  }

  List<Bulletin> _recentMatches(Iterable<Bulletin> items) {
    final seen = <String>{};
    final ranked =
        [
          for (final (index, item) in items.indexed)
            if (seen.add(item.id) && _subscription.matches(item))
              (
                index: index,
                item: item,
                date: _publicationDate(item) ?? _oldestPublicationDate,
              ),
        ]..sort((first, second) {
          final order = second.date.compareTo(first.date);
          return order == 0 ? first.index.compareTo(second.index) : order;
        });
    return [for (final match in ranked.take(_feedLimit)) match.item];
  }

  DateTime? _publicationDate(Bulletin item) =>
      DateTime.tryParse(item.publishedAt.trim());

  BulletinListPage? get _cachedFirstPage =>
      _pages[_pageKey(BulletinCategory.all.first, 1)];

  bool _feedRequestIsCurrent(int revision) =>
      !_disposed &&
      _subscription.enabled &&
      _subscription.topics.isNotEmpty &&
      revision == _subscriptionRevision;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  BulletinListPage? _lastPage(BulletinCategory category) {
    final key = _categoryKey(category);
    final pages =
        _pages.entries
            .where((entry) => entry.key.startsWith('$key|'))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return pages.isEmpty ? null : pages.last;
  }

  String _pageKey(BulletinCategory category, int page) =>
      '${_categoryKey(category)}|$page';

  String _categoryKey(BulletinCategory category) =>
      category.path.isEmpty ? 'all' : category.path;

  Future<void> _save() => _store.save(
    BulletinLocalData(
      subscription: _subscription,
      pages: Map.unmodifiable(_pages),
      feed: List.unmodifiable(_feed),
    ),
  );
}
