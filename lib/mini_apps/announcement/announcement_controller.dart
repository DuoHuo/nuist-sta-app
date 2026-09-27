import 'dart:async';

import 'package:flutter/foundation.dart';

import 'announcement_api.dart';
import 'announcement_models.dart';
import 'announcement_store.dart';

/// 公告浏览、缓存与订阅动态的共享状态。
class AnnouncementController extends ChangeNotifier {
  AnnouncementController._();

  /// 首页卡片与公告阅读页共用的状态控制器。
  static final AnnouncementController instance = AnnouncementController._();

  final AnnouncementApi _api = AnnouncementApi();
  final AnnouncementStore _store = AnnouncementStore();
  final Map<String, AnnouncementListPage> _pages = {};
  final Set<String> _loadingCategories = {};
  final Map<String, String> _categoryErrors = {};

  AnnouncementCategory _category = AnnouncementCategory.all.first;
  AnnouncementSubscription _subscription = const AnnouncementSubscription();
  List<Announcement> _feed = [];
  Set<String> _knownIds = {};
  bool _baselineReady = false;
  bool _started = false;
  Future<void>? _starting;
  bool _feedLoading = false;
  String? _feedError;

  AnnouncementCategory get category => _category;
  AnnouncementSubscription get subscription => _subscription;
  List<Announcement> get feed => List.unmodifiable(_feed);
  bool get feedLoading => _feedLoading;
  String? get feedError => _feedError;
  bool get isLoadingCategory =>
      _loadingCategories.contains(_categoryKey(_category));
  String? get categoryError => _categoryErrors[_categoryKey(_category)];

  List<Announcement> get items {
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
    _pages
      ..clear()
      ..addAll(local.pages);
    _subscription = local.subscription;
    _feed = local.feed;
    _knownIds = local.knownIds;
    _baselineReady = local.baselineReady;
    notifyListeners();
    if (_subscription.enabled) unawaited(refreshFeed());
  }

  /// 切换当前公告分类并加载首屏内容。
  Future<void> selectCategory(AnnouncementCategory category) async {
    _category = category;
    notifyListeners();
    await loadCategory(category);
  }

  /// 加载分类首屏，或在 [forceRefresh] 为真时重新请求官网。
  Future<void> loadCategory(
    AnnouncementCategory category, {
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
    required Set<AnnouncementTopic> topics,
  }) async {
    await ensureStarted();
    final wasEnabled = _subscription.enabled;
    _subscription = AnnouncementSubscription(
      enabled: enabled,
      topics: Set.unmodifiable(topics),
    );
    _feed = _feed.where(_subscription.matches).toList();
    if (enabled && !wasEnabled) _baselineReady = false;
    await _save();
    notifyListeners();
    if (enabled && !_baselineReady) unawaited(_primeBaseline());
  }

  /// 检查最新公告并加入符合订阅主题的新动态。
  Future<void> refreshFeed() async {
    await ensureStarted();
    if (!_subscription.enabled || _feedLoading) return;
    if (!_baselineReady) {
      await _primeBaseline();
      return;
    }
    _feedLoading = true;
    _feedError = null;
    notifyListeners();
    try {
      final latest = await _api.fetchPage(
        AnnouncementCategory.all.first.uri,
        pageNumber: 1,
      );
      final newItems = latest.items
          .where((item) => !_knownIds.contains(item.id))
          .toList();
      _knownIds.addAll(latest.items.map((item) => item.id));
      final matches = newItems.where(_subscription.matches).toList();
      if (matches.isNotEmpty) _feed = [...matches, ..._feed];
      if (_knownIds.length > 3000) {
        _knownIds = _knownIds.skip(_knownIds.length - 2000).toSet();
      }
      if (_feed.length > 100) _feed = _feed.take(100).toList();
      _pages[_pageKey(AnnouncementCategory.all.first, 1)] = latest;
      await _save();
    } catch (error) {
      _feedError = '订阅动态刷新失败：$error';
    } finally {
      _feedLoading = false;
      notifyListeners();
    }
  }

  Future<void> _primeBaseline() async {
    if (_feedLoading) return;
    _feedLoading = true;
    _feedError = null;
    notifyListeners();
    try {
      final latest = await _api.fetchPage(
        AnnouncementCategory.all.first.uri,
        pageNumber: 1,
      );
      _knownIds.addAll(latest.items.map((item) => item.id));
      _baselineReady = true;
      _pages[_pageKey(AnnouncementCategory.all.first, 1)] = latest;
      _feed = _feed.where(_subscription.matches).toList();
      await _save();
    } catch (error) {
      _feedError = '订阅初始化失败：$error';
    } finally {
      _feedLoading = false;
      notifyListeners();
    }
  }

  AnnouncementListPage? _lastPage(AnnouncementCategory category) {
    final key = _categoryKey(category);
    final pages =
        _pages.entries
            .where((entry) => entry.key.startsWith('$key|'))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return pages.isEmpty ? null : pages.last;
  }

  String _pageKey(AnnouncementCategory category, int page) =>
      '${_categoryKey(category)}|$page';

  String _categoryKey(AnnouncementCategory category) =>
      category.path.isEmpty ? 'all' : category.path;

  Future<void> _save() => _store.save(
    AnnouncementLocalData(
      subscription: _subscription,
      pages: Map.unmodifiable(_pages),
      feed: List.unmodifiable(_feed),
      knownIds: Set.unmodifiable(_knownIds),
      baselineReady: _baselineReady,
    ),
  );
}
