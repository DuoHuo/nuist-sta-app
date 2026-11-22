import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import 'bulletin_api.dart';
import 'bulletin_attachment_preview.dart';
import 'bulletin_models.dart';
import 'bulletin_office_engine_view.dart';
import 'bulletin_office_view.dart';
import 'bulletin_pdf_view.dart';

/// 附件预览窗口，支持在其他应用中打开下载的文件。
class BulletinAttachmentPreviewDialog extends StatefulWidget {
  /// 使用公告现有的下载通道，在同一窗口内复用文件。
  const BulletinAttachmentPreviewDialog({
    super.key,
    required this.attachment,
    required this.api,
  });

  final BulletinAttachment attachment;
  final BulletinApi api;

  @override
  State<BulletinAttachmentPreviewDialog> createState() =>
      _BulletinAttachmentPreviewDialogState();
}

typedef _DownloadedAttachment = ({
  File file,
  BulletinPreviewKind kind,
  String? mimeType,
});

class _BulletinAttachmentPreviewDialogState
    extends State<BulletinAttachmentPreviewDialog> {
  static final _log = AppLog.logger('bulletin.attachment');
  static const _actionsChannel = MethodChannel(
    'dev.duohuo.nuist_sta_app/attachment_actions',
  );
  static const _downloadError = '附件下载失败，请检查校园网或 VPN 后重试';

  Future<_DownloadedAttachment>? _download;
  Future<BulletinOfficeDocument?>? _officeRequest;
  File? _file;
  BulletinPreviewKind? _kind;
  BulletinPdfDocument? _pdf;

  /// 旧版 Word 转换出的 HTML；为空时离线阅读视图直接读取原附件。
  File? _engineFile;
  Uint8List? _firstPdfPage;
  BulletinOfficeDocument? _office;
  String? _engineMimeType;
  String? _text;
  String? _error;
  bool _loading = true;
  bool _opening = false;
  bool _useOfficeEngine = false;
  bool _officeEngineReady = false;
  bool _searchExpanded = false;

  File? get _searchFile => switch (_kind) {
    BulletinPreviewKind.pdf => _file,
    BulletinPreviewKind.office
        when isBulletinSearchableWorkbook(_office?.mimeType) =>
      _file,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<_DownloadedAttachment> _getAttachment() =>
      _download ??= _downloadAttachment();

  Future<BulletinOfficeDocument?> _openOffice(File file) async {
    try {
      return await BulletinOfficeDocument.open(file);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<_DownloadedAttachment> _downloadAttachment() async {
    final File file;
    try {
      file = await Future<File>.sync(
        () => widget.api.downloadAttachment(widget.attachment),
      );
    } catch (_) {
      _download = null;
      rethrow;
    }
    if (mounted) {
      try {
        final preview = await detectBulletinPreview(file);
        final mimeType = preview.kind == BulletinPreviewKind.office
            ? preview.mimeType ?? await detectBulletinOfficeMimeType(file)
            : preview.mimeType;
        return (file: file, kind: preview.kind, mimeType: mimeType);
      } on FileSystemException catch (error, stackTrace) {
        // 读取文件类型失败时，仍允许用户尝试用其他应用打开。
        _log.warning(
          'preview.failed',
          fields: {'stage': 'attachment.detect_type', 'outcome': 'degraded'},
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return (file: file, kind: BulletinPreviewKind.unsupported, mimeType: null);
  }

  Future<void> _load() => _log.startSpan().run(_loadInSpan);

  Future<void> _loadInSpan() async {
    var stage = 'attachment.download';
    void updateStage(String value) => stage = value;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (:file, :kind, :mimeType) = await _getAttachment();
      if (!mounted) return;
      _file = file;
      var displayKind = kind;
      switch (kind) {
        case BulletinPreviewKind.pdf:
          await _openPdf(file, updateStage);
        case BulletinPreviewKind.text:
          stage = 'attachment.read_text';
          _text = await readBulletinPreviewText(file);
        case BulletinPreviewKind.office:
          if (Platform.isAndroid && isBulletinLegacyWord(mimeType)) {
            // 转换失败时由外层改为提示用其他应用打开。
            stage = 'attachment.convert_word';
            _engineFile = await renderBulletinWordHtml(file);
            if (!mounted) return;
            _useOfficeEngine = true;
            break;
          }
          stage = 'attachment.open_office';
          if (!Platform.isAndroid ||
              preferBulletinOfficeGrid(mimeType) ||
              mimeType == null) {
            _office = await (_officeRequest ??= _openOffice(file));
          }
          if (!mounted) return;
          final searchableWorkbook = isBulletinSearchableWorkbook(
            _office?.mimeType,
          );
          if (!searchableWorkbook && _office?.sections.isNotEmpty != true) {
            if (!Platform.isAndroid || isBulletinLegacyExcel(mimeType)) {
              _fallback();
              return;
            }
            _useOfficeEngine = true;
          }
        case BulletinPreviewKind.image:
          break;
        case BulletinPreviewKind.unsupported:
          _fallback();
          return;
      }
      if (!mounted) return;
      setState(() {
        _kind = displayKind;
        _loading = false;
      });
    } catch (error, stackTrace) {
      _log.warning(
        'preview.failed',
        fields: {
          'stage': stage,
          'outcome': _file == null ? 'failure' : 'degraded',
        },
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      if (_file != null) {
        _fallback();
      } else {
        setState(() {
          _loading = false;
          _error = _downloadError;
        });
      }
    }
  }

  Future<void> _openPdf(File file, ValueChanged<String> updateStage) async {
    updateStage('attachment.open_pdf');
    final pdf = await BulletinPdfDocument.open(file);
    try {
      if (!mounted) {
        await pdf.close();
        return;
      }
      updateStage('attachment.render_pdf');
      final firstPage = await pdf.renderPage(0);
      if (!mounted) {
        await pdf.close();
        return;
      }
      _pdf = pdf;
      _firstPdfPage = firstPage;
    } catch (_) {
      await pdf.close();
      rethrow;
    }
  }

  Future<void> _officeEngineFailed() async {
    if (!mounted || !_useOfficeEngine) return;
    setState(() {
      _useOfficeEngine = false;
      _officeEngineReady = false;
      _loading = true;
    });
    final file = _file!;
    final office = await (_officeRequest ??= _openOffice(file));
    if (!mounted) return;
    if (office?.sections.isNotEmpty != true) {
      _fallback();
      return;
    }
    setState(() {
      _office = office;
      _loading = false;
    });
  }

  void _fallback() {
    if (!mounted || _kind == BulletinPreviewKind.unsupported) return;
    final pdf = _pdf;
    _pdf = null;
    _firstPdfPage = null;
    if (pdf != null) unawaited(pdf.close());
    setState(() {
      _kind = BulletinPreviewKind.unsupported;
      _loading = false;
    });
  }

  Future<void> _openExternally() => _log.startSpan().run(_openExternallyInSpan);

  Future<void> _openExternallyInSpan() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      if (!_loading && _download == null) unawaited(_load());
      final (:file, :mimeType, :kind) = await _getAttachment();
      var openMimeType = mimeType ?? _engineMimeType;
      if (mounted && kind == BulletinPreviewKind.office) {
        // 已知后缀时可立即打开；解析已完成时优先采用文件实际类型。
        openMimeType = _office?.mimeType ?? openMimeType;
      }
      if (mounted &&
          kind == BulletinPreviewKind.office &&
          openMimeType == null) {
        final office = await (_officeRequest ??= _openOffice(file));
        openMimeType = office?.mimeType;
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      try {
        await _actionsChannel.invokeMethod<void>('open', {
          'path': file.path,
          'mimeType': ?openMimeType,
        });
      } catch (error, stackTrace) {
        _log.warning(
          'open.failed',
          fields: {'stage': 'attachment.open_external'},
          error: error,
          stackTrace: stackTrace,
        );
        final message = switch (error) {
          PlatformException(code: 'no_app') => '本机没有可打开此附件的应用',
          MissingPluginException() => '当前平台无法打开此选项',
          _ => '无法用其他应用打开此附件，请重试',
        };
        if (mounted) setState(() => _error = message);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'open.failed',
        fields: {'stage': 'attachment.download'},
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = _downloadError);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _imageError(BuildContext context, Object error, StackTrace? stack) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fallback();
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
    final canPreview =
        !_loading &&
        _kind != null &&
        _kind != BulletinPreviewKind.unsupported &&
        (!_useOfficeEngine || _officeEngineReady);
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
          actions: [
            if (canPreview && (_searchFile != null || _useOfficeEngine))
              IconButton(
                tooltip: _searchExpanded ? '关闭查找' : '查找文字',
                onPressed: () =>
                    setState(() => _searchExpanded = !_searchExpanded),
                icon: Icon(_searchExpanded ? Icons.search_off : Icons.search),
              ),
            if (canPreview)
              IconButton(
                tooltip: '用其他应用打开',
                onPressed: _opening ? null : _openExternally,
                icon: const Icon(Icons.open_in_new),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _openButton() => FilledButton.icon(
    onPressed: _opening ? null : _openExternally,
    icon: const Icon(Icons.open_in_new),
    label: const Text('用其他应用打开'),
  );

  Widget _buildContent(AppPalette palette) {
    if (_loading) {
      return _previewMessage('正在加载附件…', progressColor: palette.accent);
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
        return BulletinPdfView(
          document: _pdf!,
          firstPage: _firstPdfPage!,
          searchFile: _searchFile,
          searchExpanded: _searchExpanded,
        );
      case BulletinPreviewKind.office:
        if (_useOfficeEngine) {
          return Stack(
            fit: StackFit.expand,
            children: [
              BulletinOfficeEngineView(
                file: _engineFile ?? _file!,
                onReady: (mime) {
                  if (mounted) {
                    setState(() {
                      _officeEngineReady = true;
                      _engineMimeType = mime;
                    });
                  }
                },
                onFailure: _officeEngineFailed,
                searchExpanded: _searchExpanded,
              ),
              if (!_officeEngineReady)
                ColoredBox(
                  color: palette.pageBg,
                  child: _previewMessage(
                    '正在加载附件…',
                    progressColor: palette.accent,
                  ),
                ),
            ],
          );
        }
        return BulletinOfficeView(
          document: _office!,
          searchFile: _searchFile,
          searchExpanded: _searchExpanded,
        );
      case BulletinPreviewKind.unsupported:
        return _previewMessage('无法预览此附件');
      case null:
        return Center(child: _openButton());
    }
  }

  Widget _previewMessage(String message, {Color? progressColor}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progressColor != null) ...[
              CircularProgressIndicator(color: progressColor),
              const SizedBox(height: 12),
            ],
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            _openButton(),
          ],
        ),
      ),
    );
  }
}
