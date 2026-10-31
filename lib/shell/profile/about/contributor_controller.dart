import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log.dart';
import 'contributor_api.dart';
import 'contributor_models.dart';
import 'contributor_store.dart';

/// 关于页贡献者名单的状态：先展示缓存，无缓存或缓存满 24h 才去拉。
/// 没有显式刷新；拉取失败但有缓存时静默保留缓存。
class ContributorController extends ChangeNotifier {
  static final _log = AppLog.logger('shell.profile.contributors.controller');

  ContributorController({
    Future<List<Contributor>> Function()? fetch,
    ContributorStore? store,
    DateTime Function()? now,
  }) : _fetch = fetch ?? ContributorApi().fetch,
       _store = store ?? const ContributorStore(),
       _now = now ?? DateTime.now;

  final Future<List<Contributor>> Function() _fetch;
  final ContributorStore _store;
  final DateTime Function() _now;

  List<Contributor>? _items;
  bool _loading = false;
  bool _failed = false;
  bool _disposed = false;

  /// null = 还没有任何数据（无缓存且未拉到）。
  List<Contributor>? get items => _items;

  /// 仅在无缓存、正在请求时为 true。
  bool get loading => _loading;

  /// 无缓存且拉取失败。
  bool get failed => _failed;

  Future<void> load() async {
    final cache = await _store.read();
    if (cache != null) {
      _items = cache.items;
      _notify();
      if (!cache.isStale(_now())) return;
    }
    await _request();
  }

  /// 仅供无缓存且失败时的重试按钮调用。
  Future<void> retry() => _request();

  Future<void> _request() async {
    final hasData = _items != null;
    if (!hasData) {
      _loading = true;
      _failed = false;
      _notify();
    }
    try {
      await _log.operation(
        'refresh',
        () async {
          final items = await _fetch();
          _items = items;
          _failed = false;
          await _store.save(ContributorCache(items: items, fetchedAt: _now()));
        },
        failureEvent: 'refresh.failed_using_cache',
        errorFields: (_) => {'has_cache': hasData, 'outcome': 'cache_fallback'},
      );
    } catch (_) {
      if (!hasData) _failed = true;
    } finally {
      _loading = false;
      _notify();
    }
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
