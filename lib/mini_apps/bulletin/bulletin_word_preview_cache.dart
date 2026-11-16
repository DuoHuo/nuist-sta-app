import 'dart:io';

import 'bulletin_api.dart';
import 'bulletin_attachment_preview.dart';
import 'bulletin_models.dart';

/// 详情页预读和用户打开 Word 附件时共用原文件下载。
class BulletinWordPreviewCache {
  static const _lifetime = Duration(hours: 1);
  static const _limit = 6;
  static final _downloads = <String, ({DateTime started, Future<File> file})>{};
  static bool _warming = false;

  /// 在已打开的公告里后台准备首个可识别的官网 Word 附件。
  static Future<void> warm(
    Iterable<BulletinAttachment> attachments,
    BulletinApi api,
  ) async {
    if (!Platform.isAndroid || _warming) return;
    for (final attachment in attachments) {
      if (!_isOfficialWord(attachment)) continue;
      _warming = true;
      try {
        final file = await source(attachment, api);
        final preview = await detectBulletinPreview(file);
        if (preview.kind != BulletinPreviewKind.office) break;
        final mimeType =
            preview.mimeType ?? await detectBulletinOfficeMimeType(file);
        if (isBulletinSearchableWord(mimeType)) {
          await renderBulletinWordPdf(file);
        }
      } catch (_) {
        // 后台准备失败时，用户仍可主动打开附件。
      } finally {
        _warming = false;
      }
      break;
    }
  }

  /// 优先复用正在下载或刚下载的 Word 原文件。
  static Future<File> source(
    BulletinAttachment attachment,
    BulletinApi api,
  ) async {
    if (!Platform.isAndroid || !_isOfficialWord(attachment)) {
      return api.downloadAttachment(attachment);
    }
    final url = attachment.url;
    final now = DateTime.now();
    final existing = _downloads.remove(url);
    if (existing != null && now.difference(existing.started) < _lifetime) {
      _downloads[url] = existing;
      try {
        final file = await existing.file;
        if (await file.exists()) return file;
      } catch (_) {
        // 主动打开可重试后台下载。
      }
      if (_downloads[url] == existing) _downloads.remove(url);
      if (_downloads.containsKey(url)) return source(attachment, api);
    }
    final entry = (started: now, file: api.downloadAttachment(attachment));
    _downloads[url] = entry;
    if (_downloads.length > _limit) _downloads.remove(_downloads.keys.first);
    try {
      return await entry.file;
    } catch (_) {
      if (_downloads[url] == entry) _downloads.remove(url);
      rethrow;
    }
  }

  static bool _isOfficialWord(BulletinAttachment attachment) {
    final uri = Uri.tryParse(attachment.url);
    if (uri == null || !isOfficialBulletinUri(uri)) return false;
    final basename = uri.pathSegments.lastOrNull ?? '';
    const extensions = ['.doc', '.docx'];
    final name = attachment.name.trim().toLowerCase();
    return extensions.any(
      (extension) =>
          basename.toLowerCase().endsWith(extension) ||
          name.endsWith(extension),
    );
  }
}
