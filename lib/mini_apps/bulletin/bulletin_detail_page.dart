import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import 'bulletin_api.dart';
import 'bulletin_attachment_preview_dialog.dart';
import 'bulletin_models.dart';

/// 在应用内优先以原生排版阅读学校官网的公告正文。
class BulletinDetailPage extends StatefulWidget {
  /// 创建指定公告的详情阅读页。
  const BulletinDetailPage({super.key, required this.bulletin, this.api});

  final Bulletin bulletin;
  final BulletinApi? api;

  @override
  State<BulletinDetailPage> createState() => _BulletinDetailPageState();
}

class _BulletinDetailPageState extends State<BulletinDetailPage> {
  static final _log = AppLog.logger('bulletin.detail');
  late final BulletinApi _api;
  late final Future<BulletinDetailDocument?> _detailFuture;
  final _bodyRows = <(BulletinDetailBlock, int?)>[];
  WebViewController? _webViewController;
  final _progress = ValueNotifier<int>(0);
  bool _failed = false;
  bool _attachmentPreviewOpen = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? BulletinApi();
    _detailFuture = _loadDetail();
    _detailFuture.then((detail) {
      if (detail == null) _activateWebViewFallback();
    });
  }

  Future<BulletinDetailDocument?> _loadDetail() =>
      _log.startSpan().run(_loadDetailInSpan);

  Future<BulletinDetailDocument?> _loadDetailInSpan() async {
    try {
      final detail = await _api.fetchDetail(widget.bulletin);
      if (detail == null) {
        _log.warning(
          'detail.fallback',
          fields: {
            'stage': 'response.parse',
            'reason_code': 'document_unrecognized',
            'outcome': 'degraded',
          },
        );
      }
      // 只展开行索引，不提前创建或布局正文组件；长名单与表格也按可见行渲染。
      for (final block in detail?.blocks ?? const <BulletinDetailBlock>[]) {
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
      return detail;
    } catch (error, stackTrace) {
      _log.warning(
        'detail.fallback',
        fields: {'stage': 'detail.load', 'outcome': 'degraded'},
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
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
      await showDialog<void>(
        context: context,
        builder: (_) => BulletinAttachmentPreviewDialog(
          attachment: attachment,
          api: _api,
          onDownload: (file) async {
            await SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)], subject: attachment.name),
            );
          },
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

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(tone: AppSnackBarTone.error, content: Text(text)),
      );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: palette.pageBg,
      appBar: AppBar(
        title: const Text('公告详情'),
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
      body: Column(
        children: [
          _buildHeader(palette),
          Expanded(
            child: FutureBuilder<BulletinDetailDocument?>(
              future: _detailFuture,
              builder: (context, snapshot) {
                final detail = snapshot.data;
                if (detail != null) {
                  return _buildNativeDocument(detail, palette);
                }
                if (_webViewController != null) {
                  return _buildWebViewFallback(palette);
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    final metadata = [
      if (widget.bulletin.publisher.isNotEmpty) widget.bulletin.publisher,
      if (widget.bulletin.publishedAt.isNotEmpty) widget.bulletin.publishedAt,
    ].join(' · ');
    return Container(
      width: double.infinity,
      color: palette.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.bulletin.title,
            style: TextStyle(
              color: palette.titleText,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (metadata.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(metadata, style: TextStyle(color: palette.hint, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _buildNativeDocument(
    BulletinDetailDocument document,
    AppPalette palette,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      itemCount:
          _bodyRows.length +
          (document.attachments.isEmpty ? 0 : document.attachments.length + 1),
      itemBuilder: (context, index) {
        if (index < _bodyRows.length) {
          final (block, itemIndex) = _bodyRows[index];
          return _buildBlock(block, palette, itemIndex: itemIndex);
        }
        final attachmentIndex = index - _bodyRows.length - 1;
        if (attachmentIndex < 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(
              '附件',
              style: TextStyle(
                color: palette.titleText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        }
        return _buildAttachment(document.attachments[attachmentIndex], palette);
      },
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
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Text(
            block.text,
            textAlign: alignment,
            style: TextStyle(
              color: palette.titleText,
              fontSize: block.level <= 2 ? 18 : 16,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
          ),
        );
      case BulletinDetailBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            block.text,
            textAlign: alignment,
            style: TextStyle(
              color: palette.titleText,
              fontSize: 15,
              height: 1.85,
            ),
          ),
        );
      case BulletinDetailBlockKind.quote:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border(left: BorderSide(color: palette.accent, width: 3)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            block.text,
            style: TextStyle(color: palette.labelText, height: 1.7),
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
              SizedBox(
                width: 24,
                child: Text(
                  block.kind == BulletinDetailBlockKind.bulletList
                      ? '•'
                      : '${itemIndex + 1}.',
                  style: TextStyle(
                    color: palette.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  block.items[itemIndex],
                  style: TextStyle(
                    color: palette.titleText,
                    fontSize: 15,
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
            color: palette.surface,
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
            child: Image.network(
              block.url!,
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
        subtitle: const Text('点击预览，无法预览时下载'),
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
