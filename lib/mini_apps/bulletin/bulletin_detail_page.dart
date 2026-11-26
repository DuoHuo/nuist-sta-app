import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import '../../core/navigation/app_page.dart';
import 'bulletin_api.dart';
import 'bulletin_attachment_preview_dialog.dart';
import 'bulletin_detail_repository.dart';
import 'bulletin_models.dart';

/// 在应用内优先以原生排版阅读学校官网的公告正文。
class BulletinDetailPage extends StatefulWidget {
  /// 创建指定公告的详情阅读页。
  const BulletinDetailPage({
    super.key,
    required this.bulletin,
    this.api,
    this.repository,
  }) : assert(api == null || repository == null);

  final Bulletin bulletin;
  final BulletinApi? api;

  /// 可注入缓存与请求入口；生产环境与列表共用默认实例。
  final BulletinDetailRepository? repository;

  @override
  State<BulletinDetailPage> createState() => _BulletinDetailPageState();
}

class _BulletinDetailPageState extends State<BulletinDetailPage> {
  static final _log = AppLog.logger('bulletin.detail');
  late final BulletinDetailRepository _repository;
  BulletinDetailDocument? _detail;
  final _bodyRows = <(BulletinDetailBlock, int?)>[];
  final _selectionKey = GlobalKey<SelectionAreaState>();
  bool _showingOldCache = false;
  bool _refreshing = false;
  WebViewController? _webViewController;
  final _progress = ValueNotifier<int>(0);
  bool _failed = false;
  bool _attachmentPreviewOpen = false;
  ContextMenuController? _documentSelectionMenu;

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    _repository =
        widget.repository ??
        (api == null
            ? BulletinDetailRepository.instance
            : BulletinDetailRepository(api: api));
    unawaited(_loadDetail());
  }

  Future<void> _loadDetail() => _log.startSpan().run(_loadDetailInSpan);

  Future<void> _loadDetailInSpan() async {
    final cached = await _repository.read(widget.bulletin);
    if (!mounted) return;
    if (cached != null) {
      final stale = !_repository.isFresh(cached);
      _showDocument(cached.document, showingOldCache: stale);
      if (!stale) return;
    }
    await _refreshDocumentInSpan();
  }

  Future<void> _refreshDocument() =>
      _log.startSpan().run(() => _refreshDocumentInSpan(manual: true));

  Future<void> _refreshDocumentInSpan({bool manual = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final latest = await _repository.refresh(widget.bulletin);
    if (!mounted) return;
    if (latest != null) {
      _showDocument(latest);
      return;
    }
    setState(() => _refreshing = false);
    if (_detail == null) {
      _log.warning(
        'detail.fallback',
        fields: {
          'stage': 'detail.load',
          'reason_code': 'document_unavailable',
          'outcome': 'degraded',
        },
      );
      _activateWebViewFallback();
    } else if (manual) {
      _message('刷新失败，仍显示缓存内容');
    }
  }

  void _showDocument(
    BulletinDetailDocument document, {
    bool showingOldCache = false,
  }) {
    if (_documentSelectionMenu != null) {
      _selectionKey.currentState?.selectableRegion.clearSelection();
      _documentSelectionMenu?.remove();
    }
    setState(() {
      _detail = document;
      _showingOldCache = showingOldCache;
      _refreshing = false;
      _bodyRows.clear();
      // 只展开行索引，长名单和表格仍按可见行渲染。
      for (final block in document.blocks) {
        switch (block.kind) {
          case BulletinDetailBlockKind.bulletList:
          case BulletinDetailBlockKind.numberedList:
          case BulletinDetailBlockKind.table:
            if (block.items.isEmpty) _bodyRows.add((block, null));
            for (var index = 0; index < block.items.length; index++) {
              _bodyRows.add((block, index));
            }
          default:
            _bodyRows.add((block, null));
        }
      }
    });
  }

  void _activateWebViewFallback() {
    if (!mounted || _webViewController != null) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) _progress.value = progress;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              _log.warning(
                'webview.load_failed',
                fields: {
                  'stage': 'webview.load',
                  'error_code': error.errorCode,
                  'reason_code': error.errorType?.name,
                  'outcome': 'failure',
                },
              );
              setState(() => _failed = true);
            }
          },
        ),
      );
    setState(() => _webViewController = controller);
    controller.loadRequest(Uri.parse(widget.bulletin.url));
  }

  Future<void> _retryWebView() async {
    final controller = _webViewController;
    if (controller == null) return;
    setState(() {
      _failed = false;
    });
    _progress.value = 0;
    await controller.loadRequest(Uri.parse(widget.bulletin.url));
  }

  Future<void> _openAttachment(BulletinAttachment attachment) async {
    if (_attachmentPreviewOpen) return;
    _attachmentPreviewOpen = true;
    try {
      await Navigator.of(context).push<void>(
        AppPageRoute<void>(
          fullscreenDialog:
              Theme.of(context).platform != TargetPlatform.android,
          builder: (_) => BulletinAttachmentPreviewDialog(
            attachment: attachment,
            api: _repository.api,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _log.warning(
        'attachment.open_failed',
        fields: {'stage': 'attachment.open'},
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _message('附件下载失败，可能需要连接校园网或 VPN');
    } finally {
      _attachmentPreviewOpen = false;
    }
  }

  void _message(String text, {AppSnackBarTone tone = AppSnackBarTone.error}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(AppSnackBar(tone: tone, content: Text(text)));
  }

  Future<void> _copyDocument(BulletinDetailDocument document) async {
    final sections = <String>[
      widget.bulletin.title,
      if (_metadata.isNotEmpty) _metadata,
    ];
    // 从完整文档取文字，未滚到的段落和表格也会被复制。
    for (final block in document.blocks) {
      final text = switch (block.kind) {
        BulletinDetailBlockKind.bulletList ||
        BulletinDetailBlockKind.numberedList => [
          for (final (index, item) in block.items.indexed)
            '${_listMarker(block.kind, index)} $item',
        ].join('\n'),
        BulletinDetailBlockKind.table => block.items.join('\n'),
        BulletinDetailBlockKind.image => '',
        _ => block.text,
      };
      if (text.trim().isNotEmpty) sections.add(text.trim());
    }
    try {
      await Clipboard.setData(ClipboardData(text: sections.join('\n\n')));
      if (mounted) _message('全文已复制', tone: AppSnackBarTone.success);
    } catch (_) {
      if (mounted) _message('复制失败，请重试');
    }
  }

  String _listMarker(BulletinDetailBlockKind kind, int index) =>
      kind == BulletinDetailBlockKind.bulletList ? '•' : '${index + 1}.';

  @override
  void dispose() {
    final menu = _documentSelectionMenu;
    _documentSelectionMenu = null;
    menu?.remove();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final detail = _detail;
    return Scaffold(
      backgroundColor: palette.pageBg,
      appBar: AppBar(
        title: const Text('公告详情'),
        actions: [
          if (detail != null) ...[
            IconButton(
              tooltip: '刷新正文',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshing ? null : _refreshDocument,
            ),
            IconButton(
              tooltip: '复制全文',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => _copyDocument(detail),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: ValueListenableBuilder<int>(
            valueListenable: _progress,
            builder: (context, progress, _) =>
                _webViewController != null && progress < 100
                ? LinearProgressIndicator(
                    minHeight: 2,
                    value: progress / 100,
                    color: palette.accent,
                    backgroundColor: palette.rowDivider,
                  )
                : const SizedBox(height: 2),
          ),
        ),
      ),
      body: detail != null
          ? _buildNativeDocument(detail, palette)
          : _webViewController != null
          ? _buildWebViewFallback(palette)
          : const Center(child: CircularProgressIndicator()),
    );
  }

  String get _metadata => [
    if (widget.bulletin.publisher.isNotEmpty) widget.bulletin.publisher,
    if (widget.bulletin.publishedAt.isNotEmpty) widget.bulletin.publishedAt,
  ].join(' · ');

  Widget _buildHeader(AppPalette palette) {
    final metadata = _metadata;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              widget.bulletin.title,
              style: TextStyle(
                color: palette.titleText,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          if (metadata.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              metadata,
              style: TextStyle(
                color: palette.labelText,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
          if (_showingOldCache) ...[
            const SizedBox(height: 6),
            Text(
              '当前显示缓存内容',
              style: TextStyle(color: palette.labelText, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  void _selectDocument(
    SelectableRegionState region,
    BulletinDetailDocument document,
    TextSelectionToolbarAnchors anchors,
  ) {
    region.selectAll();
    // 全选菜单跟随整篇正文，滚动卸载选区边界时仍可复制全文。
    final menu = ContextMenuController(
      onRemove: () {
        if (_documentSelectionMenu != null) {
          setState(() => _documentSelectionMenu = null);
        }
      },
    );
    setState(() => _documentSelectionMenu = menu);
    menu.show(
      context: context,
      contextMenuBuilder: (_) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: anchors,
        buttonItems: [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            label: '复制',
            onPressed: () {
              region.clearSelection();
              menu.remove();
              unawaited(_copyDocument(document));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionMenu(
    SelectableRegionState region,
    BulletinDetailDocument document,
  ) {
    final items = region.contextMenuButtonItems;
    if (!items.any((item) => item.type == ContextMenuButtonType.copy)) {
      return const SizedBox.shrink();
    }
    final anchors = region.contextMenuAnchors;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        for (final item in items)
          if (item.type == ContextMenuButtonType.copy)
            item.copyWith(label: '复制')
          else if (item.type == ContextMenuButtonType.selectAll)
            item.copyWith(
              label: '全选',
              onPressed: () => _selectDocument(region, document, anchors),
            ),
      ],
    );
  }

  Widget _buildNativeDocument(
    BulletinDetailDocument document,
    AppPalette palette,
  ) {
    // 全选时，滚动后才挂载的正文行也要显示选中状态。
    final documentSelected = _documentSelectionMenu != null;
    final highlight = TextStyle(
      backgroundColor: documentSelected
          ? palette.accent.withValues(alpha: 0.28)
          : null,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SelectionArea(
          key: _selectionKey,
          onSelectionChanged: (_) => _documentSelectionMenu?.remove(),
          contextMenuBuilder: (context, region) =>
              _buildSelectionMenu(region, document),
          child: DefaultSelectionStyle.merge(
            selectionColor: documentSelected ? Colors.transparent : null,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              itemCount:
                  1 +
                  _bodyRows.length +
                  (document.attachments.isEmpty
                      ? 0
                      : document.attachments.length + 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return DefaultTextStyle.merge(
                    style: highlight,
                    child: _buildHeader(palette),
                  );
                }
                final bodyIndex = index - 1;
                if (bodyIndex < _bodyRows.length) {
                  final (block, itemIndex) = _bodyRows[bodyIndex];
                  return DefaultTextStyle.merge(
                    style: highlight,
                    child: _buildBlock(block, palette, itemIndex: itemIndex),
                  );
                }
                final attachmentIndex = bodyIndex - _bodyRows.length - 1;
                // 附件仍由点按打开，复制正文时不选中操作文案。
                return SelectionContainer.disabled(
                  child: attachmentIndex < 0
                      ? Padding(
                          padding: const EdgeInsets.only(top: 16, bottom: 10),
                          child: Semantics(
                            header: true,
                            child: Text(
                              '附件',
                              style: TextStyle(
                                color: palette.titleText,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : _buildAttachment(
                          document.attachments[attachmentIndex],
                          palette,
                        ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlock(
    BulletinDetailBlock block,
    AppPalette palette, {
    int? itemIndex,
  }) {
    final alignment = block.centered ? TextAlign.center : TextAlign.left;
    switch (block.kind) {
      case BulletinDetailBlockKind.heading:
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              block.text,
              textAlign: alignment,
              style: TextStyle(
                color: palette.titleText,
                fontSize: block.level <= 2 ? 19 : 17,
                fontWeight: FontWeight.w700,
                height: 1.45,
              ),
            ),
          ),
        );
      case BulletinDetailBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            block.text,
            textAlign: alignment,
            style: TextStyle(
              color: palette.titleText,
              fontSize: 16,
              height: 1.7,
            ),
          ),
        );
      case BulletinDetailBlockKind.quote:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(left: BorderSide(color: palette.accent, width: 3)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            block.text,
            textAlign: alignment,
            style: TextStyle(
              color: palette.labelText,
              fontSize: 15,
              height: 1.65,
            ),
          ),
        );
      case BulletinDetailBlockKind.bulletList:
      case BulletinDetailBlockKind.numberedList:
        if (itemIndex == null) return const SizedBox(height: 10);
        return Padding(
          padding: EdgeInsets.only(
            bottom: itemIndex == block.items.length - 1 ? 15 : 5,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 24),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    _listMarker(block.kind, itemIndex),
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 16,
                      height: 1.7,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  block.items[itemIndex],
                  style: TextStyle(
                    color: palette.titleText,
                    fontSize: 16,
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        );
      case BulletinDetailBlockKind.table:
        if (itemIndex == null) return const SizedBox(height: 12);
        return Container(
          margin: EdgeInsets.only(
            bottom: itemIndex == block.items.length - 1 ? 12 : 0,
          ),
          decoration: BoxDecoration(
            color: itemIndex.isEven
                ? palette.surface
                : Color.alphaBlend(
                    palette.accent.withValues(alpha: 0.05),
                    palette.surface,
                  ),
            borderRadius: BorderRadius.vertical(
              top: itemIndex == 0 ? const Radius.circular(8) : Radius.zero,
              bottom: itemIndex == block.items.length - 1
                  ? const Radius.circular(8)
                  : Radius.zero,
            ),
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.rowDivider)),
            ),
            child: Text(
              block.items[itemIndex],
              style: TextStyle(color: palette.titleText, height: 1.5),
            ),
          ),
        );
      case BulletinDetailBlockKind.image:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LayoutBuilder(
              builder: (context, constraints) => Image(
                // 正文里的相机照片、扫描图按阅读宽度解码，避免每项保留原图位图。
                image: ResizeImage(
                  NetworkImage(block.url!),
                  width:
                      (constraints.maxWidth *
                              MediaQuery.devicePixelRatioOf(context))
                          .ceil()
                          .clamp(1, 2048),
                  height: 4096,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) =>
                    block.altText.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          block.altText,
                          textAlign: alignment,
                          style: TextStyle(color: palette.hint),
                        ),
                      ),
              ),
            ),
          ),
        );
    }
  }

  Widget _buildAttachment(BulletinAttachment attachment, AppPalette palette) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: palette.surface,
      child: ListTile(
        leading: Icon(Icons.attach_file, color: palette.accent),
        title: Text(
          attachment.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.titleText, fontSize: 14),
        ),
        subtitle: const Text('点击查看附件'),
        trailing: Icon(Icons.visibility_outlined, color: palette.accent),
        onTap: () => _openAttachment(attachment),
      ),
    );
  }

  Widget _buildWebViewFallback(AppPalette palette) {
    final controller = _webViewController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 只改错误态这层容器；网页正文是学校自己的页面，不注入任何样式。
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_failed)
          ColoredBox(
            color: palette.pageBg,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off, size: 38, color: palette.hint),
                  const SizedBox(height: 10),
                  Text(
                    '公告内容暂时无法加载',
                    style: TextStyle(color: palette.labelText),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _retryWebView,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
