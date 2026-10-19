import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bulletin_api.dart';
import 'bulletin_models.dart';
import 'bulletin_store.dart';

/// 公告浏览、缓存与订阅动态的共享状态。
class BulletinController extends ChangeNotifier {
  /// 创建公告状态，可注入接口与存储以隔离数据来源。
  BulletinController({BulletinApi? api, BulletinStore? store})
    : _api = api ?? BulletinApi(),
      _store = store ?? BulletinStore();

  /// 首页卡片与公告阅读页共用的状态控制器。
  static final BulletinController instance = BulletinController();

  final BulletinApi _api;
  final BulletinStore _store;
  final Map<String, BulletinListPage> _pages = {};
  final Set<String> _loadingCategories = {};
  final Map<String, String> _categoryErrors = {};

  BulletinCategory _category = BulletinCategory.all.first;
  BulletinSubscription _subscription = const BulletinSubscription();
  List<Bulletin> _feed = [];
  Set<String> _knownIds = {};
  bool _baselineReady = false;
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
    // 空缓存和持久化快照可能不可修改，运行时始终使用可写副本。
    _feed = List.of(local.feed);
    _knownIds = Set.of(local.knownIds);
    _baselineReady = local.baselineReady;
    notifyListeners();
    if (_subscription.enabled) unawaited(refreshFeed());
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
  }) async {
    await ensureStarted();
    final key = _categoryKey(category);
    final cacheKey = _pageKey(category, 1);
    if (!forceRefresh && _pages.containsKey(cacheKey)) return;
    if (!_loadingCategories.add(key)) return;
    _categoryErrors.remove(key);
    notifyListeners();
    try {
      final page = await _api.fetchPage(category.uri, pageNumber: 1);
      _pages.removeWhere((entryKey, _) => entryKey.startsWith('$key|'));
      _pages[cacheKey] = page;
      await _save();
    } catch (error) {
      _categoryErrors[key] = '公告加载失败：$error';
    } finally {
      _loadingCategories.remove(key);
      notifyListeners();
    }
  }

  /// 刷新当前分类的首屏。
  Future<void> refreshCurrentCategory() =>
      loadCategory(_category, forceRefresh: true);

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
      final page = await _api.fetchPage(
        Uri.parse(nextUrl),
        pageNumber: (previous?.pageNumber ?? 0) + 1,
      );
      _pages[_pageKey(category, page.pageNumber)] = page;
      await _save();
    } catch (error) {
      _categoryErrors[key] = '加载更多失败：$error';
    } finally {
      _loadingCategories.remove(key);
      notifyListeners();
    }
  }

  /// 更新订阅设置；首次开启会记录最新公告作为基线。
  Future<void> configureSubscription({
    required bool enabled,
    required Set<BulletinTopic> topics,
  }) async {
    await ensureStarted();
    final wasEnabled = _subscription.enabled;
    _subscriptionRevision++;
    _feedUnavailable = false;
    _subscription = BulletinSubscription(
      enabled: enabled,
      topics: Set.unmodifiable(topics),
    );
    _feed = _feed.where(_subscription.matches).toList();
    if (enabled && !wasEnabled) _baselineReady = false;
    await _save();
    notifyListeners();
    if (enabled && !_baselineReady) unawaited(refreshFeed());
  }

  /// 检查最新公告，失败后最多尝试三次，持续失败时静默隐藏动态。
  Future<void> refreshFeed() async {
    await ensureStarted();
    if (_disposed || !_subscription.enabled || _feedLoading) return;
    final revision = _subscriptionRevision;
    _feedLoading = true;
    notifyListeners();
    try {
      final latest = await _fetchFeedWithRetry(revision);
      if (latest == null) return;
      final newItems = _baselineReady
          ? latest.items.where((item) => !_knownIds.contains(item.id)).toList()
          : <Bulletin>[];
      _knownIds.addAll(latest.items.map((item) => item.id));
      _baselineReady = true;
      final matches = newItems.where(_subscription.matches).toList();
      if (matches.isNotEmpty) _feed = [...matches, ..._feed];
      if (_knownIds.length > 3000) {
        _knownIds = _knownIds.skip(_knownIds.length - 2000).toSet();
      }
      if (_feed.length > 100) _feed = _feed.take(100).toList();
      _pages[_pageKey(BulletinCategory.all.first, 1)] = latest;
      _feedUnavailable = false;
      await _save();
    } catch (_) {
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

  Future<BulletinListPage?> _fetchFeedWithRetry(int revision) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
      if (!_feedRequestIsCurrent(revision)) return null;
      try {
        final latest = await _api.fetchPage(
          BulletinCategory.all.first.uri,
          pageNumber: 1,
        );
        return _feedRequestIsCurrent(revision) ? latest : null;
      } catch (_) {
        if (!_feedRequestIsCurrent(revision)) return null;
        if (attempt == 2) rethrow;
      }
    }
    return null;
  }

  bool _feedRequestIsCurrent(int revision) =>
      !_disposed && _subscription.enabled && revision == _subscriptionRevision;

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
      knownIds: Set.unmodifiable(_knownIds),
      baselineReady: _baselineReady,
    ),
  );
}
