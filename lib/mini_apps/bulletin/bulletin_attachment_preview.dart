import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 公告附件可以在本机预览的类型。
enum BulletinPreviewKind { image, text, pdf, unsupported }

/// 按文件内容识别附件，下载接口和文件名没有后缀也能识别 PDF、图片。
Future<BulletinPreviewKind> detectBulletinPreview(File file) async {
  final input = await file.open();
  final List<int> header;
  try {
    header = await input.read(1024);
  } finally {
    await input.close();
  }
  final ascii = latin1.decode(header);
  if (ascii.contains('%PDF-')) return BulletinPreviewKind.pdf;
  if (ascii.startsWith('\x89PNG\r\n\x1a\n') ||
      (header.length >= 3 &&
          header[0] == 0xff &&
          header[1] == 0xd8 &&
          header[2] == 0xff) ||
      ascii.startsWith('GIF87a') ||
      ascii.startsWith('GIF89a') ||
      ascii.startsWith('BM') ||
      (header.length >= 12 &&
          ascii.startsWith('RIFF') &&
          ascii.substring(8, 12) == 'WEBP')) {
    return BulletinPreviewKind.image;
  }
  final extension = file.path.toLowerCase().split('.').last;
  if ({'txt', 'csv', 'json', 'md', 'log', 'xml'}.contains(extension) &&
      await file.length() <= 1024 * 1024) {
    return BulletinPreviewKind.text;
  }
  return BulletinPreviewKind.unsupported;
}

/// 读取 UTF-8 / 带 BOM 的 UTF-16 文本；无法解码时由预览窗口降级下载。
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

/// Android 自带 PDF 渲染器的文档句柄，每次只渲染当前页。
class BulletinPdfDocument {
  BulletinPdfDocument._(this._id, this.pageCount);

  static const _channel = MethodChannel(
    'dev.duohuo.nuist_sta_app/attachment_pdf',
  );

  final int _id;
  bool _closed = false;

  /// 文档总页数。
  final int pageCount;

  /// 打开已通过校园网络下载到本机的 PDF，不需要外部预览服务。
  static Future<BulletinPdfDocument> open(File file) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('open', {
      'path': file.path,
    });
    if (result == null ||
        result['id'] is! int ||
        result['pageCount'] is! int ||
        (result['pageCount'] as int) < 1) {
      throw const FormatException('PDF 无法预览');
    }
    return BulletinPdfDocument._(
      result['id'] as int,
      result['pageCount'] as int,
    );
  }

  /// 将指定页渲染为 PNG，页码从零开始。
  Future<Uint8List> renderPage(int page) async {
    if (_closed || page < 0 || page >= pageCount) {
      throw StateError('PDF 页面不可用');
    }
    final bytes = await _channel.invokeMethod<Uint8List>('render', {
      'id': _id,
      'page': page,
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
      await _channel.invokeMethod<void>('close', {'id': _id});
    } catch (_) {
      // 引擎退出后可能已没有平台通道；原生插件也会释放残留句柄。
    }
  }
}
