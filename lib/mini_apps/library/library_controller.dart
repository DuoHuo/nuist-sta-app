import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/portal_exceptions.dart';
import 'library_api.dart';
import 'library_models.dart';

/// 独立管理馆藏查询和个人借阅，页面退出后取消业务请求。
class LibraryController extends ChangeNotifier {
  LibraryController(this.api);

  final LibraryApi api;
  final catalogue = LibraryListState<LibraryBook>();
  final loans = LibraryListState<LibraryLoan>();
  bool loansNeedBinding = false;

  String _keyword = '';
  LibrarySearchField _field = LibrarySearchField.keyword;

  /// 提交新检索，取消上一组结果的请求。
  Future<void> search(String keyword, LibrarySearchField field) async {
    _keyword = keyword.trim();
    _field = field;
    catalogue.reset();
    if (_keyword.isEmpty) {
      notifyListeners();
      return;
    }
    await loadCataloguePage();
  }

  /// 加载或重试馆藏的下一页。
  Future<void> loadCataloguePage() => _load(
    catalogue,
    (page, token) => api.search(_keyword, _field, page, cancelToken: token),
    '暂时无法查询馆藏，请重试',
  );

  /// 首次进入借阅页、绑定返回或刷新时重新读取第一页。
  Future<void> reloadLoans() {
    loans.reset();
    loansNeedBinding = false;
    return loadLoanPage();
  }

  /// 加载或重试当前借阅的下一页。
  Future<void> loadLoanPage() => _load(
    loans,
    (page, token) async {
      final bound = await api.hasPortalBinding();
      if (token.isCancelled) return null;
      if (!bound) {
        loans.reset();
        loansNeedBinding = true;
        notifyListeners();
        return null;
      }
      return api.fetchLoans(page, cancelToken: token);
    },
    '暂时无法读取借阅记录，请重试',
    onCredentialError: () {
      loans.reset();
      loansNeedBinding = true;
      notifyListeners();
    },
  );

  Future<void> _load<T>(
    LibraryListState<T> state,
    Future<LibraryResultPage<T>?> Function(int page, CancelToken token) fetch,
    String errorMessage, {
    VoidCallback? onCredentialError,
  }) async {
    if (state.loading ||
        (state.started && state.error == null && !state.hasMore)) {
      return;
    }
    final token = CancelToken();
    state._request = token;
    state.started = true;
    state.loading = true;
    state.error = null;
    notifyListeners();
    try {
      final result = await fetch(state._page + 1, token);
      if (token.isCancelled || result == null) return;
      state._page++;
      state.items = List.unmodifiable([...state.items, ...result.items]);
      state.total = result.total;
      state.hasMore =
          result.items.isNotEmpty && state.items.length < result.total;
    } on PortalCredentialError {
      if (!token.isCancelled) onCredentialError?.call();
    } on PortalNetworkError catch (error) {
      if (!token.isCancelled) state.error = error.message;
    } catch (_) {
      if (!token.isCancelled) state.error = errorMessage;
    } finally {
      if (!token.isCancelled) {
        state._request = null;
        state.loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    catalogue.reset();
    loans.reset();
    super.dispose();
  }
}

/// 单个页签的分页状态，加载下一页失败时保留已读到的记录。
class LibraryListState<T> {
  List<T> items = const [];
  int total = 0;
  bool hasMore = false;
  bool started = false;
  bool loading = false;
  String? error;

  int _page = 0;
  CancelToken? _request;

  /// 清除结果和当前请求。
  void reset() {
    _request?.cancel();
    _request = null;
    _page = 0;
    items = const [];
    total = 0;
    hasMore = false;
    started = false;
    loading = false;
    error = null;
  }
}
