import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/colors.dart';
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
  late final BulletinApi _api;
  late final Future<BulletinDetailDocument?> _detailFuture;
  WebViewController? _webViewController;
  int _progress = 0;
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

  Future<BulletinDetailDocument?> _loadDetail() async {
    try {
      return await _api.fetchDetail(widget.bulletin);
    } catch (_) {
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
            if (mounted) setState(() => _progress = progress);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
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
      _progress = 0;
    });
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
    } catch (_) {
      if (mounted) _message('附件下载失败，可能需要连接校园网或 VPN');
    } finally {
      _attachmentPreviewOpen = false;
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
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
          child: _webViewController != null && _progress < 100
              ? LinearProgressIndicator(
                  minHeight: 2,
                  value: _progress / 100,
                  color: palette.accent,
                  backgroundColor: palette.rowDivider,
                )
              : const SizedBox(height: 2),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        for (final block in document.blocks) _buildBlock(block, palette),
        if (document.attachments.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '附件',
            style: TextStyle(
              color: palette.titleText,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final attachment in document.attachments)
            _buildAttachment(attachment, palette),
        ],
      ],
    );
  }

  Widget _buildBlock(BulletinDetailBlock block, AppPalette palette) {
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            children: [
              for (var index = 0; index < block.items.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          block.kind == BulletinDetailBlockKind.bulletList
                              ? '•'
                              : '${index + 1}.',
                          style: TextStyle(
                            color: palette.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          block.items[index],
                          style: TextStyle(
                            color: palette.titleText,
                            fontSize: 15,
                            height: 1.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case BulletinDetailBlockKind.table:
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              for (final row in block.items)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: palette.rowDivider),
                    ),
                  ),
                  child: Text(
                    row,
                    style: TextStyle(color: palette.titleText, height: 1.5),
                  ),
                ),
            ],
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
