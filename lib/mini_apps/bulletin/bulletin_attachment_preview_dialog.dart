import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/colors.dart';
import 'bulletin_api.dart';
import 'bulletin_attachment_preview.dart';
import 'bulletin_models.dart';

/// 附件预览窗口：本机预览 PDF、图片和文本，不能预览时自动转入下载保存。
class BulletinAttachmentPreviewDialog extends StatefulWidget {
  /// 使用公告现有的下载通道，并复用下载文件进行预览和保存。
  const BulletinAttachmentPreviewDialog({
    super.key,
    required this.attachment,
    required this.api,
    required this.onDownload,
  });

  final BulletinAttachment attachment;
  final BulletinApi api;

  /// 将已经下载的文件交给保存 / 分享面板，不再次发起网络请求。
  final Future<void> Function(File file) onDownload;

  @override
  State<BulletinAttachmentPreviewDialog> createState() =>
      _BulletinAttachmentPreviewDialogState();
}

class _BulletinAttachmentPreviewDialogState
    extends State<BulletinAttachmentPreviewDialog> {
  File? _file;
  BulletinPreviewKind? _kind;
  BulletinPdfDocument? _pdf;
  Uint8List? _pageImage;
  String? _text;
  String? _error;
  int _page = 0;
  bool _loading = true;
  bool _pageLoading = false;
  bool _sharing = false;
  bool _fallbackStarted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await widget.api.downloadAttachment(widget.attachment);
      if (!mounted) return;
      _file = file;
      final kind = await detectBulletinPreview(file);
      if (!mounted) return;
      switch (kind) {
        case BulletinPreviewKind.pdf:
          final pdf = await BulletinPdfDocument.open(file);
          if (!mounted) {
            await pdf.close();
            return;
          }
          _pdf = pdf;
          _pageImage = await pdf.renderPage(0);
        case BulletinPreviewKind.text:
          _text = await readBulletinPreviewText(file);
        case BulletinPreviewKind.image:
          break;
        case BulletinPreviewKind.unsupported:
          await _fallback();
          return;
      }
      if (!mounted) return;
      setState(() {
        _kind = kind;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (_file != null) {
        await _fallback();
      } else {
        setState(() {
          _loading = false;
          _error = '附件下载失败，请检查校园网或 VPN 后重试';
        });
      }
    }
  }

  Future<void> _fallback() async {
    if (!mounted || _fallbackStarted) return;
    _fallbackStarted = true;
    final pdf = _pdf;
    _pdf = null;
    if (pdf != null) unawaited(pdf.close());
    setState(() {
      _kind = BulletinPreviewKind.unsupported;
      _loading = false;
      _pageLoading = false;
    });
    // 先显示不能预览的提示，再打开保存 / 分享面板。
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await _download();
  }

  Future<void> _download() async {
    final file = _file;
    if (file == null || _sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      await widget.onDownload(file);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开保存面板，请重试');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _showPage(int page) async {
    final pdf = _pdf;
    if (pdf == null || _pageLoading || page < 0 || page >= pdf.pageCount) {
      return;
    }
    setState(() {
      _page = page;
      _pageLoading = true;
    });
    try {
      final image = await pdf.renderPage(page);
      if (!mounted) return;
      setState(() {
        _pageImage = image;
        _pageLoading = false;
      });
    } catch (_) {
      await _fallback();
    }
  }

  Widget _imageError(BuildContext context, Object error, StackTrace? stack) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_fallback());
    });
    return const Center(child: Text('无法预览此附件'));
  }

  @override
  void dispose() {
    final pdf = _pdf;
    if (pdf != null) unawaited(pdf.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: palette.pageBg,
        appBar: AppBar(
          title: const Text('附件预览'),
          leading: IconButton(
            tooltip: '关闭预览',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                widget.attachment.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.titleText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(child: _buildContent(palette)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: palette.danger)),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                  ),
                  onPressed: _file == null || _loading || _sharing
                      ? null
                      : _download,
                  icon: _sharing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text('下载并分享'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(AppPalette palette) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: palette.accent),
            const SizedBox(height: 12),
            const Text('正在加载附件…'),
          ],
        ),
      );
    }
    switch (_kind) {
      case BulletinPreviewKind.text:
        return SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: Text(
                _text!,
                style: const TextStyle(fontSize: 15, height: 1.7),
              ),
            ),
          ),
        );
      case BulletinPreviewKind.image:
        return InteractiveViewer(
          maxScale: 5,
          child: Center(
            child: Image.file(
              _file!,
              cacheWidth: 1600,
              fit: BoxFit.contain,
              errorBuilder: _imageError,
            ),
          ),
        );
      case BulletinPreviewKind.pdf:
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一页',
                  onPressed: _pageLoading || _page == 0
                      ? null
                      : () => _showPage(_page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('第 ${_page + 1} 页 / 共 ${_pdf!.pageCount} 页'),
                IconButton(
                  tooltip: '下一页',
                  onPressed: _pageLoading || _page + 1 >= _pdf!.pageCount
                      ? null
                      : () => _showPage(_page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            Expanded(
              child: _pageLoading
                  ? const Center(child: CircularProgressIndicator())
                  : InteractiveViewer(
                      key: ValueKey(_page),
                      maxScale: 5,
                      child: Center(
                        child: Image.memory(
                          _pageImage!,
                          fit: BoxFit.contain,
                          errorBuilder: _imageError,
                        ),
                      ),
                    ),
            ),
          ],
        );
      case BulletinPreviewKind.unsupported:
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '无法预览此附件，已为你下载\n请在保存面板中保存或分享',
              textAlign: TextAlign.center,
            ),
          ),
        );
      case null:
        return Center(
          child: OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重新下载'),
          ),
        );
    }
  }
}
