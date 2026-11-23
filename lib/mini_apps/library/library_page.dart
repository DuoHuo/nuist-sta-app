import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/ui/miuix_dialog.dart';
import 'library_api.dart';
import 'library_controller.dart';
import 'library_detail_page.dart';
import 'library_models.dart';
import 'library_widgets.dart';

/// 首页「图书馆」入口，馆藏可直接查询，借阅走统一门户。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.api});

  final LibraryApi? api;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final _controller = LibraryController(widget.api ?? LibraryApi());
  late final _tabs = TabController(length: 2, vsync: this);
  final _query = TextEditingController();
  final _catalogueScroll = ScrollController();
  var _field = LibrarySearchField.keyword;
  var _loansOpened = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_loadLoansWhenOpened);
  }

  void _loadLoansWhenOpened() {
    if (_tabs.index != 1 || _loansOpened) return;
    _loansOpened = true;
    unawaited(_controller.reloadLoans());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _query.dispose();
    _catalogueScroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    FocusScope.of(context).unfocus();
    if (_catalogueScroll.hasClients) _catalogueScroll.jumpTo(0);
    unawaited(_controller.search(_query.text, _field));
  }

  Future<void> _bindPortal() async {
    await context.push('/portal-bind');
    if (mounted) await _controller.reloadLoans();
  }

  void _openBook(String id) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) =>
            LibraryDetailPage(api: _controller.api, bookId: id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('图书馆'),
      bottom: TabBar(
        controller: _tabs,
        onTap: (_) => FocusScope.of(context).unfocus(),
        tabs: const [
          Tab(text: '馆藏查询'),
          Tab(text: '我的借阅'),
        ],
      ),
    ),
    backgroundColor: AppPalette.of(context).pageBg,
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, child) => TabBarView(
          controller: _tabs,
          children: [_buildCatalogue(context), _buildLoans(context)],
        ),
      ),
    ),
  );

  Widget _buildCatalogue(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Row(
          children: [
            Builder(
              builder: (buttonContext) => InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final field = await showMiuixOptionMenu<LibrarySearchField>(
                    buttonContext,
                    anchorBounds: miuixAnchorRect(buttonContext),
                    items: [
                      for (final field in LibrarySearchField.values)
                        MiuixOptionItem(
                          value: field,
                          label: field.label,
                          selected: field == _field,
                        ),
                    ],
                  );
                  if (field != null && mounted) {
                    setState(() => _field = field);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_field.label),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: '输入${_field.label}',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: _search,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
      ),
      Expanded(
        child: _LibraryResults(
          state: _controller.catalogue,
          scrollController: _catalogueScroll,
          idleMessage: '输入关键词查询馆藏',
          emptyMessage: '没有找到匹配的书目',
          totalLabel: (total) => '共 $total 条书目',
          itemBuilder: (context, book) {
            final title = book.title.isEmpty ? '未命名书目' : book.title;
            final publication = [
              book.author,
              book.publisher,
              book.publicationYear,
            ].where((value) => value.isNotEmpty).join(' · ');
            return _LibraryTile(
              title: title,
              description: publication,
              details: [
                if (book.callNumber.isNotEmpty) '索书号 ${book.callNumber}',
                if (book.copyCount case final total?) '馆藏 $total 册',
                if (book.availableCount case final count?) '可借 $count 册',
              ],
              onTap: book.id.isEmpty ? null : () => _openBook(book.id),
            );
          },
          loadMore: _controller.loadCataloguePage,
        ),
      ),
    ],
  );

  Widget _buildLoans(BuildContext context) {
    if (_controller.loansNeedBinding) {
      return LibraryMessage(
        icon: Icons.lock_outline,
        message: '请绑定统一门户通行密钥后查询个人借阅',
        action: '前往门户绑定',
        onPressed: _bindPortal,
      );
    }
    return _LibraryResults(
      state: _controller.loans,
      idleMessage: '正在准备查询借阅',
      emptyMessage: '当前没有借阅中的书目',
      totalLabel: (total) => '当前借阅 $total 册',
      loadMore: _controller.loadLoanPage,
      refresh: _controller.reloadLoans,
      itemBuilder: (context, loan) {
        final title = loan.title.isEmpty ? '未命名书目' : loan.title;
        final palette = AppPalette.of(context);
        return _LibraryTile(
          compact: true,
          title: title,
          description: loan.author,
          details: [
            if (loan.borrowedOn.isNotEmpty) '借出 ${loan.borrowedOn}',
            if (loan.dueOn.isNotEmpty) '应还 ${loan.dueOn}',
            if (loan.location.isNotEmpty) loan.location,
          ],
          status: loan.status,
          statusColor: loan.status == '已逾期' ? palette.danger : palette.warning,
          onTap: loan.bookId.isEmpty ? null : () => _openBook(loan.bookId),
        );
      },
    );
  }
}

class _LibraryResults<T> extends StatelessWidget {
  const _LibraryResults({
    required this.state,
    required this.idleMessage,
    required this.emptyMessage,
    required this.totalLabel,
    required this.itemBuilder,
    required this.loadMore,
    this.refresh,
    this.scrollController,
  });

  final LibraryListState<T> state;
  final String idleMessage;
  final String emptyMessage;
  final String Function(int) totalLabel;
  final Widget Function(BuildContext, T) itemBuilder;
  final Future<void> Function() loadMore;
  final Future<void> Function()? refresh;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    if (state.items.isEmpty) {
      if (state.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (state.error case final error?) {
        return LibraryMessage(
          icon: Icons.cloud_off_outlined,
          message: error,
          action: '重试',
          onPressed: loadMore,
        );
      }
      return LibraryMessage(
        icon: state.started ? Icons.menu_book_outlined : Icons.search_outlined,
        message: state.started ? emptyMessage : idleMessage,
        action: state.started && refresh != null ? '刷新' : null,
        onPressed: refresh,
      );
    }
    final list = ListView.builder(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: state.items.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(totalLabel(state.total)),
            trailing: refresh == null
                ? null
                : IconButton(
                    tooltip: '刷新借阅',
                    onPressed: state.loading ? null : refresh,
                    icon: const Icon(Icons.refresh),
                  ),
          );
        }
        if (index <= state.items.length) {
          return itemBuilder(context, state.items[index - 1]);
        }
        if (state.loading) return const LibraryLoading();
        if (state.error case final error?) {
          return LibraryMessage(
            icon: Icons.cloud_off_outlined,
            message: error,
            action: '重试',
            onPressed: loadMore,
          );
        }
        if (!state.hasMore) return const SizedBox.shrink();
        return Center(
          child: TextButton(onPressed: loadMore, child: const Text('加载更多')),
        );
      },
    );
    final onRefresh = refresh;
    return onRefresh == null
        ? list
        : RefreshIndicator(onRefresh: onRefresh, child: list);
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({
    required this.title,
    required this.description,
    required this.details,
    required this.onTap,
    this.compact = false,
    this.status = '',
    this.statusColor,
  });

  final String title;
  final String description;
  final List<String> details;
  final VoidCallback? onTap;
  final bool compact;
  final String status;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.only(bottom: compact ? 6 : 8),
      color: palette.surface,
      child: ListTile(
        dense: compact ? true : null,
        minTileHeight: compact ? 48 : null,
        minVerticalPadding: compact ? 5 : null,
        contentPadding: compact
            ? const EdgeInsets.symmetric(horizontal: 12)
            : null,
        title: Text(
          title,
          style: compact
              ? theme.titleSmall?.copyWith(height: 1.3)
              : theme.titleMedium,
        ),
        subtitle: description.isEmpty && details.isEmpty && status.isEmpty
            ? null
            : Padding(
                padding: EdgeInsets.only(top: compact ? 2 : 4),
                child: DefaultTextStyle.merge(
                  style: compact
                      ? theme.bodySmall?.copyWith(
                          color: palette.labelText,
                          height: 1.3,
                        )
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (description.isNotEmpty) Text(description),
                      if (details.isNotEmpty || status.isNotEmpty)
                        Wrap(
                          spacing: compact ? 10 : 12,
                          runSpacing: compact ? 2 : 4,
                          children: [
                            for (final detail in details) Text(detail),
                            if (status.isNotEmpty)
                              Text(
                                status,
                                style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
        trailing: onTap == null
            ? null
            : Icon(Icons.chevron_right, color: palette.chevron),
        onTap: onTap,
      ),
    );
  }
}
