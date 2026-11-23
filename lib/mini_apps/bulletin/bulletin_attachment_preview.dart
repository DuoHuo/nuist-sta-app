import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 公告附件可以在本机预览的类型。
enum BulletinPreviewKind { image, text, pdf, office, unsupported }

const _officeMimeTypes = {
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'docm': 'application/vnd.ms-word.document.macroEnabled.12',
  'xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
  'pptm': 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
  'rtf': 'application/rtf',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'odp': 'application/vnd.oasis.opendocument.presentation',
};

const _legacyOfficeMimeTypes = {
  'doc': 'application/msword',
  'xls': 'application/vnd.ms-excel',
  'ppt': 'application/vnd.ms-powerpoint',
};

const _previewChannel = MethodChannel(
  'dev.duohuo.nuist_sta_app/attachment_pdf',
);

/// 按文件内容识别预览类型，兼容没有后缀的 PDF、图片和 Office 附件。
Future<({BulletinPreviewKind kind, String? mimeType})> detectBulletinPreview(
  File file,
) async {
  final input = await file.open();
  final List<int> header;
  try {
    header = await input.read(1024);
  } finally {
    await input.close();
  }
  final ascii = latin1.decode(header);
  if (ascii.contains('%PDF-')) {
    return (kind: BulletinPreviewKind.pdf, mimeType: 'application/pdf');
  }
  if (ascii.startsWith('\x89PNG\r\n\x1a\n')) {
    return (kind: BulletinPreviewKind.image, mimeType: 'image/png');
  }
  if (ascii.startsWith('\xff\xd8\xff')) {
    return (kind: BulletinPreviewKind.image, mimeType: 'image/jpeg');
  }
  if (ascii.startsWith('GIF87a') || ascii.startsWith('GIF89a')) {
    return (kind: BulletinPreviewKind.image, mimeType: 'image/gif');
  }
  if (ascii.startsWith('BM')) {
    return (kind: BulletinPreviewKind.image, mimeType: 'image/bmp');
  }
  if (header.length >= 12 &&
      ascii.startsWith('RIFF') &&
      ascii.startsWith('WEBP', 8)) {
    return (kind: BulletinPreviewKind.image, mimeType: 'image/webp');
  }
  final name = file.uri.pathSegments.last.toLowerCase();
  final extension = name.contains('.') ? name.split('.').last : '';
  final officeMimeType = _officeMimeTypes[extension];
  if (ascii.startsWith('PK\x03\x04') &&
      !{'zip', 'jar', 'apk'}.contains(extension)) {
    return (kind: BulletinPreviewKind.office, mimeType: officeMimeType);
  }
  if (ascii.startsWith('\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1')) {
    return (
      kind: BulletinPreviewKind.office,
      mimeType: _legacyOfficeMimeTypes[extension] ?? officeMimeType,
    );
  }
  if (ascii.startsWith(r'{\rtf')) {
    return (kind: BulletinPreviewKind.office, mimeType: 'application/rtf');
  }
  if ({'txt', 'csv', 'json', 'md', 'log', 'xml'}.contains(extension) &&
      await file.length() <= 1024 * 1024) {
    return (kind: BulletinPreviewKind.text, mimeType: null);
  }
  return (
    kind: BulletinPreviewKind.unsupported,
    mimeType: officeMimeType ?? _legacyOfficeMimeTypes[extension],
  );
}

/// 优先用 Flutter 的表格阅读界面显示 Excel 工作簿。
bool preferBulletinOfficeGrid(String? mimeType) =>
    mimeType == _officeMimeTypes['xlsx'] ||
    mimeType == _officeMimeTypes['xlsm'] ||
    isBulletinLegacyExcel(mimeType);

/// 旧版 Excel 工作簿沿用应用内的表格阅读界面。
bool isBulletinLegacyExcel(String? mimeType) =>
    mimeType == _legacyOfficeMimeTypes['xls'];

/// 现有表格阅读器支持全文查找的 Excel 格式。
bool isBulletinSearchableWorkbook(String? mimeType) =>
    isBulletinLegacyExcel(mimeType) || mimeType == _officeMimeTypes['xlsx'];

/// 旧版 Word 附件先在后台转成 HTML，再交给离线阅读视图。
bool isBulletinLegacyWord(String? mimeType) =>
    mimeType == _legacyOfficeMimeTypes['doc'];

/// 文件名无法识别时，通过 Office 包内的元数据识别类型。
Future<String?> detectBulletinOfficeMimeType(File file) async {
  try {
    final result = await _previewChannel.invokeMethod<Object?>(
      'officeMimeType',
      {'path': file.path},
    );
    return result is String ? result : null;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 把旧版 Word 转成静态 HTML，供离线阅读视图打开。
Future<File> renderBulletinWordHtml(File source) async {
  final path = await _previewChannel
      .invokeMethod<String>('convertWord', {'path': source.path})
      .timeout(const Duration(seconds: 60));
  if (path == null || path.isEmpty) throw const FormatException('Word 转换失败');
  return File(path);
}

/// 读取 UTF-8 或带 BOM 的 UTF-16 文本。
Future<String> readBulletinPreviewText(File file) async {
  final bytes = await file.readAsBytes();
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) throw const FormatException('文本编码不完整');
    final data = ByteData.sublistView(bytes);
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    return String.fromCharCodes([
      for (var offset = 2; offset < bytes.length; offset += 2)
        data.getUint16(offset, endian),
    ]);
  }
  return utf8.decode(bytes);
}

/// Android 自带 PDF 渲染器的文档句柄，支持按页渲染。
class BulletinPdfDocument {
  BulletinPdfDocument._(this._id, this.pageAspectRatios, this.probedPageCount);

  final int _id;
  bool _closed = false;

  /// 按文档顺序保存每页宽高比，用于在渲染前计算滚动布局。
  final List<double> pageAspectRatios;

  /// 打开时已预先探测宽高比的页数；后续页在渲染后按实际图像尺寸修正。
  final int probedPageCount;

  /// 打开已通过校园网络下载到本机的 PDF，不需要外部预览服务。
  static Future<BulletinPdfDocument> open(File file) async {
    final result = await _previewChannel.invokeMapMethod<String, dynamic>(
      'open',
      {'path': file.path},
    );
    final id = result?['id'];
    final ratios = result?['pageAspectRatios'];
    if (id is! int || ratios is! List || ratios.isEmpty) {
      throw const FormatException('PDF 无法预览');
    }
    final pageAspectRatios = List<double>.unmodifiable(ratios.cast<double>());
    final rawProbed = result?['probedPageCount'];
    final probedPageCount = rawProbed is int
        ? rawProbed.clamp(0, pageAspectRatios.length)
        : pageAspectRatios.length;
    return BulletinPdfDocument._(id, pageAspectRatios, probedPageCount);
  }

  /// 将指定页按目标像素宽度渲染为位图字节，页码从零开始。
  Future<Uint8List> renderPage(int page, {int? targetWidth}) async {
    if (_closed || page < 0 || page >= pageAspectRatios.length) {
      throw StateError('PDF 页面不可用');
    }
    final bytes = await _previewChannel.invokeMethod<Uint8List>('render', {
      'id': _id,
      'page': page,
      'width': ?targetWidth,
    });
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('PDF 页面无法预览');
    }
    return bytes;
  }

  /// 关闭文档，页面退出或平台通道被销毁时均可安全调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _previewChannel.invokeMethod<void>('close', {'id': _id});
    } catch (_) {
      // 引擎退出后可能已没有平台通道；原生插件也会释放残留句柄。
    }
  }
}

/// Office 内容预览中可阅读的文本与表格。
class BulletinOfficeDocument {
  BulletinOfficeDocument._(this.mimeType, this.sections, this.limited);

  final String mimeType;
  final List<BulletinOfficeSection> sections;
  final bool limited;

  /// 在 Android 后台读取附件，需要时返回无法预览。
  static Future<BulletinOfficeDocument?> open(File file) async {
    final data = await _previewChannel.invokeMapMethod<String, dynamic>(
      'office',
      {'path': file.path},
    );
    if (data == null) return null;
    final sections = [
      for (final section in data['sections'] as List)
        BulletinOfficeSection.fromData(section as Map),
    ];
    return BulletinOfficeDocument._(
      data['mimeType'] as String,
      sections,
      data['limited'] == true,
    );
  }
}

/// Word 正文、Excel 工作表或单张 PowerPoint 幻灯片。
class BulletinOfficeSection {
  BulletinOfficeSection.fromData(Map data)
    : title = data['title'] as String?,
      slide = data['slide'] as int?,
      lines = (data['lines'] as List?)?.cast<String>() ?? const [],
      blocks = [
        for (final block in data['blocks'] as List? ?? const [])
          BulletinOfficeBlock._(block as Map),
      ],
      columns = data['columns'] as int? ?? 0,
      rows = [
        for (final row in data['rows'] as List? ?? const [])
          (
            number: row['number'] as int,
            cells: _workbookCells(row['cells']),
            highlights:
                (row['highlights'] as Map?)?.map(
                  (column, ranges) =>
                      MapEntry(column as int, (ranges as List).cast<int>()),
                ) ??
                const <int, List<int>>{},
          ),
      ];

  final String? title;
  final int? slide;
  final List<String> lines;
  final List<BulletinOfficeBlock> blocks;
  final int columns;
  final List<
    ({int number, Map<int, String> cells, Map<int, List<int>> highlights})
  >
  rows;
}

Map<int, String> _workbookCells(Object? cells) {
  if (cells is Map) return cells.cast<int, String>();
  return {
    for (final (index, value) in (cells as List).indexed)
      index: value as String,
  };
}

/// 保留阅读顺序的预览段落、表格或图片。文字仍可选择和复制。
class BulletinOfficeBlock {
  BulletinOfficeBlock._(Map data)
    : text = data['text'] as String?,
      alignment = data['align'] as String?,
      heading = data['heading'] as int?,
      image = data['image'] as Uint8List?,
      table = [
        for (final row in data['table'] as List? ?? const [])
          (row as List).cast<String>(),
      ];

  final String? text;
  final String? alignment;
  final int? heading;
  final Uint8List? image;
  final List<List<String>> table;
}
