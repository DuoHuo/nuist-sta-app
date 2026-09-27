import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/colors.dart';
import 'announcement_api.dart';
import 'announcement_models.dart';

/// 在应用内优先以原生排版阅读学校官网的公告正文。
class AnnouncementDetailPage extends StatefulWidget {
  /// 创建指定公告的详情阅读页。
  const AnnouncementDetailPage({
    super.key,
    required this.announcement,
    this.api,
  });

  final Announcement announcement;
  final AnnouncementApi? api;

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  late final AnnouncementApi _api;
  late final Future<AnnouncementDetailDocument?> _detailFuture;
  WebViewController? _webViewController;
  int _progress = 0;
  bool _failed = false;
  String? _downloadingUrl;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? AnnouncementApi();
    _detailFuture = _loadDetail();
    _detailFuture.then((detail) {
      if (detail == null) _activateWebViewFallback();
    });
  }

  Future<AnnouncementDetailDocument?> _loadDetail() async {
    try {
      return await _api.fetchDetail(widget.announcement);
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
    controller.loadRequest(Uri.parse(widget.announcement.url));
  }

  Future<void> _retryWebView() async {
    final controller = _webViewController;
    if (controller == null) return;
    setState(() {
      _failed = false;
      _progress = 0;
    });
    await controller.loadRequest(Uri.parse(widget.announcement.url));
  }

  Future<void> _downloadAttachment(AnnouncementAttachment attachment) async {
    if (_downloadingUrl != null) return;
    setState(() => _downloadingUrl = attachment.url);
    try {
      final file = await _api.downloadAttachment(attachment);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: attachment.name),
      );
    } catch (_) {
      if (mounted) _message('附件下载失败，可能需要连接校园网或 VPN');
    } finally {
      if (mounted) setState(() => _downloadingUrl = null);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        title: const Text('公告详情'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _webViewController != null && _progress < 100
              ? LinearProgressIndicator(
                  minHeight: 2,
                  value: _progress / 100,
                  color: AppColors.accent,
                  backgroundColor: AppColors.rowDivider,
                )
              : const SizedBox(height: 2),
        ),
      ),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: FutureBuilder<AnnouncementDetailDocument?>(
              future: _detailFuture,
              builder: (context, snapshot) {
                final detail = snapshot.data;
                if (detail != null) return _buildNativeDocument(detail);
                if (_webViewController != null) return _buildWebViewFallback();
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final metadata = [
      if (widget.announcement.publisher.isNotEmpty)
        widget.announcement.publisher,
      if (widget.announcement.publishedAt.isNotEmpty)
        widget.announcement.publishedAt,
    ].join(' · ');
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.announcement.title,
            style: const TextStyle(
              color: AppColors.titleText,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (metadata.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              metadata,
              style: const TextStyle(color: AppColors.hint, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNativeDocument(AnnouncementDetailDocument document) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        for (final block in document.blocks) _buildBlock(block),
        if (document.attachments.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '附件',
            style: TextStyle(
              color: AppColors.titleText,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final attachment in document.attachments)
            _buildAttachment(attachment),
        ],
      ],
    );
  }

  Widget _buildBlock(AnnouncementDetailBlock block) {
    final alignment = block.centered ? TextAlign.center : TextAlign.left;
    switch (block.kind) {
      case AnnouncementDetailBlockKind.heading:
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Text(
            block.text,
            textAlign: alignment,
            style: TextStyle(
              color: AppColors.titleText,
              fontSize: block.level <= 2 ? 18 : 16,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
          ),
        );
      case AnnouncementDetailBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            block.text,
            textAlign: alignment,
            style: const TextStyle(
              color: AppColors.titleText,
              fontSize: 15,
              height: 1.85,
            ),
          ),
        );
      case AnnouncementDetailBlockKind.quote:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: const Border(
              left: BorderSide(color: AppColors.accent, width: 3),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            block.text,
            style: const TextStyle(color: AppColors.labelText, height: 1.7),
          ),
        );
      case AnnouncementDetailBlockKind.bulletList:
      case AnnouncementDetailBlockKind.numberedList:
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
                          block.kind == AnnouncementDetailBlockKind.bulletList
                              ? '•'
                              : '${index + 1}.',
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          block.items[index],
                          style: const TextStyle(
                            color: AppColors.titleText,
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
      case AnnouncementDetailBlockKind.table:
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
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
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.rowDivider),
                    ),
                  ),
                  child: Text(
                    row,
                    style: const TextStyle(
                      color: AppColors.titleText,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        );
      case AnnouncementDetailBlockKind.image:
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
                        style: const TextStyle(color: AppColors.hint),
                      ),
                    ),
            ),
          ),
        );
    }
  }

  Widget _buildAttachment(AnnouncementAttachment attachment) {
    final loading = _downloadingUrl == attachment.url;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Colors.white,
      child: ListTile(
        leading: const Icon(Icons.attach_file, color: AppColors.accent),
        title: Text(
          attachment.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.titleText, fontSize: 14),
        ),
        subtitle: const Text('点击下载并分享'),
        trailing: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.download_outlined, color: AppColors.accent),
        onTap: loading ? null : () => _downloadAttachment(attachment),
      ),
    );
  }

  Widget _buildWebViewFallback() {
    final controller = _webViewController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_failed)
          ColoredBox(
            color: AppColors.pageBg,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off, size: 38, color: AppColors.hint),
                  const SizedBox(height: 10),
                  const Text(
                    '公告内容暂时无法加载',
                    style: TextStyle(color: AppColors.labelText),
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
