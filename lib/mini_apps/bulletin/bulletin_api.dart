import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_directories.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import '../../core/auth/campus_transport.dart';
import '../../core/auth/portal_exceptions.dart';
import 'bulletin_detail_parser.dart';
import 'bulletin_models.dart';
import 'bulletin_tagger.dart';

const _nonAttachmentExtensions = {'jsp', 'aspx', 'php', 'cgi'};

final _invalidFileNameCharsPattern = RegExp(r'''[\\/:*?"<>|\x00-\x1f]''');
final _fileExtensionPattern = RegExp(
  r'\.([a-z0-9]{1,10})$',
  caseSensitive: false,
);
final _utf8FileNamePattern = RegExp(
  r"^utf-8'[^']*'(.*)$",
  caseSensitive: false,
);
final _pathSeparatorPattern = RegExp(r'[/\\]');
final _newsRowPattern = RegExp(
  r'''<li\b[^>]*class=["'][^"']*\bnews\b[^"']*["'][^>]*>([\s\S]*?)</li>''',
  caseSensitive: false,
);
final _anchorPattern = RegExp(
  r'<a\b([^>]*)>([\s\S]*?)</a>',
  caseSensitive: false,
);
final _articlePathPattern = RegExp(r'/info/[^/]+/(\d+)\.htm');
final _pagingDivPattern = RegExp(
  r'''<div\b[^>]*class=["'][^"']*\bwp_paging\b[^"']*["'][^>]*>([\s\S]*?)</div>''',
  caseSensitive: false,
);
final _totalCountPattern = RegExp(r'总共\s*(?:&nbsp;\s*)?(\d+)');
final _spanPatterns = <String, RegExp>{
  'wjj': _buildSpanPattern('wjj'),
  'news_org': _buildSpanPattern('news_org'),
  'news_date': _buildSpanPattern('news_date'),
};
final _attributePattern = RegExp(
  r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);
final _brTagPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final _htmlTagPattern = RegExp(r'<[^>]*>');
final _whitespacePattern = RegExp(r'\s+');
final _numericEntityPattern = RegExp(
  r'&#(x[0-9a-f]+|\d+);',
  caseSensitive: false,
);

RegExp _buildSpanPattern(String className) => RegExp(
  """<span\\b[^>]*class=["'][^"']*\\b$className\\b[^"']*["'][^>]*>([\\s\\S]*?)</span>""",
  caseSensitive: false,
);

/// 信息公告栏官网首页地址（主机名由 `campus_config.dart` 的校园根域派生）。
final bulletinHomeUri = 'https://${CampusHosts.bulletin}/';

/// 可在后台预读和落盘的官网 HTTPS 地址。
bool isOfficialBulletinUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == CampusHosts.bulletin &&
    uri.port == 443 &&
    uri.userInfo.isEmpty;

/// 从学校官网读取公告列表。
class BulletinApi {
  static final _log = AppLog.logger('bulletin.api');

  /// 创建公告接口客户端，可注入 Dio 实例。
  BulletinApi({Dio? dio})
    : _transport = CampusTransport.stateless(
        dio: dio,
        options: BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 18),
          headers: const {'Accept-Language': 'zh-CN,zh;q=0.9'},
        ),
      );

  final CampusTransport _transport;
  Dio get _dio => _transport.dio;

  /// 请求并解析指定分类或分页的公告列表。
  Future<BulletinListPage> fetchPage(Uri uri, {required int pageNumber}) async {
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final html = response.data;
    if (html == null || html.isEmpty) {
      throw const FormatException('公告栏没有返回列表内容');
    }
    final page = await compute(_parsePage, (
      html: html,
      uri: uri,
      pageNumber: pageNumber,
    ), debugLabel: 'bulletin.parse_page');
    if (page.items.isEmpty && (page.totalCount ?? 0) > 0) {
      throw const DiagnosticException(
        '公告列表存在但未解析出任何记录',
        code: 'response_list_unrecognized',
        stage: 'response.parse',
        context: {'endpoint': 'bulletin.list', 'service': 'bulletin'},
      );
    }
    _log.debug(
      'list.parsed',
      fields: {
        'endpoint': 'bulletin.list',
        'count': page.items.length,
        'has_next_page': page.nextUrl != null,
      },
    );
    return page;
  }

  /// 请求并解析单条公告正文；无法识别正文时返回 null 交给 WebView 兜底。
  Future<BulletinDetailDocument?> fetchDetail(Bulletin bulletin) async {
    final uri = Uri.parse(bulletin.url);
    final official = isOfficialBulletinUri(uri);
    final Response<String> response;
    try {
      response = await _dio.getUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          extra: {'maxRedirects': official ? 5 : 10, 'sameHostOnly': official},
        ),
      );
    } on PortalLoginError catch (error) {
      if (official &&
          const {
            'redirect_host_rejected',
            'redirect_limit_exceeded',
            'redirect_location_missing',
            'redirect_location_invalid',
          }.contains(error.code)) {
        return null;
      }
      rethrow;
    } on DioException catch (error) {
      final cause = error.error;
      if (official &&
          cause is PortalLoginError &&
          const {
            'redirect_host_rejected',
            'redirect_limit_exceeded',
            'redirect_location_missing',
            'redirect_location_invalid',
          }.contains(cause.code)) {
        return null;
      }
      rethrow;
    }
    final html = response.data;
    if (html == null || html.isEmpty) return null;
    return compute(_parseDetail, (
      html: html,
      uri: response.realUri,
    ), debugLabel: 'bulletin.parse_detail');
  }

  /// 下载公告附件到独立的临时目录，供预览、外部打开和分享复用。
  Future<File> downloadAttachment(BulletinAttachment attachment) async {
    final paths = Uri.tryParse(attachment.url)?.pathSegments ?? const [];
    final sourceName = paths.isEmpty ? '' : paths.last;
    final cache = await AppDirectories.temporary();
    final separator = Platform.pathSeparator;
    final directory = Directory(
      '${cache.path}${separator}bulletin_attachments',
    );
    await directory.create(recursive: true);
    final target = await directory.createTemp('attachment-');
    late File file;
    try {
      await _dio.download(attachment.url, (Headers headers) {
        var name = _attachmentFileName(headers) ?? attachment.name.trim();
        if (name.isEmpty) name = '公告附件';
        final extension = _fileExtension(sourceName);
        if (extension != null && _fileExtension(name) == null) {
          name += '.$extension';
        }
        name = name.replaceAll(_invalidFileNameCharsPattern, '_');
        file = File('${target.path}${separator}nuist-announcement-$name');
        return file.path;
      }, deleteOnError: true);
    } catch (_) {
      try {
        await target.delete();
      } on FileSystemException {
        // 清理失败时保留原始下载错误。
      }
      rethrow;
    }
    await trimAttachmentCache(directory, preserve: target);
    return file;
  }

  /// 清理过期的或超出容量上限的公告附件缓存目录。
  @visibleForTesting
  static Future<void> trimAttachmentCache(
    Directory directory, {
    FileSystemEntity? preserve,
    Duration maxAge = const Duration(days: 7),
    int maxBytes = 128 * 1024 * 1024,
    DateTime? now,
  }) async {
    try {
      if (!await directory.exists()) return;
      final cutoff = (now ?? DateTime.now()).subtract(maxAge);
      final preservePath = preserve?.path;
      var keptBytes = 0;
      if (preserve != null) {
        final preserved = await _inspectCacheEntry(preserve);
        if (preserved != null) {
          keptBytes = preserved.bytes;
        }
      }
      final entries =
          <({FileSystemEntity entity, int bytes, DateTime modified})>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (preservePath != null && entity.path == preservePath) continue;
        final info = await _inspectCacheEntry(entity);
        if (info == null) continue;
        entries.add((
          entity: entity,
          bytes: info.bytes,
          modified: info.modified,
        ));
      }
      entries.sort((a, b) => b.modified.compareTo(a.modified));
      for (final entry in entries) {
        final expired = entry.modified.isBefore(cutoff);
        final overBudget = keptBytes + entry.bytes > maxBytes;
        if (expired || overBudget) {
          try {
            await entry.entity.delete(recursive: true);
          } on FileSystemException {
            // 单个缓存目录清理失败不影响其余附件。
          }
        } else {
          keptBytes += entry.bytes;
        }
      }
    } on FileSystemException {
      // 缓存清理失败不影响当前附件下载结果。
    }
  }

  static Future<({int bytes, DateTime modified})?> _inspectCacheEntry(
    FileSystemEntity entity,
  ) async {
    try {
      if (entity is File) {
        final stat = await entity.stat();
        return (bytes: stat.size, modified: stat.modified);
      }
      if (entity is Directory) {
        var bytes = 0;
        DateTime? newestFileModified;
        await for (final child in entity.list(
          recursive: true,
          followLinks: false,
        )) {
          if (child is! File) continue;
          final stat = await child.stat();
          bytes += stat.size;
          final modified = stat.modified;
          if (newestFileModified == null ||
              modified.isAfter(newestFileModified)) {
            newestFileModified = modified;
          }
        }
        final modified = newestFileModified ?? (await entity.stat()).modified;
        return (bytes: bytes, modified: modified);
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}

String? _fileExtension(String name) {
  final extension = _fileExtensionPattern
      .firstMatch(name)
      ?.group(1)
      ?.toLowerCase();
  // CMS 下载接口的后缀属于网页，并不代表附件格式。
  return _nonAttachmentExtensions.contains(extension) ? null : extension;
}

String? _attachmentFileName(Headers headers) {
  final values = headers['content-disposition'];
  if (values == null || values.isEmpty) return null;
  try {
    final parameters = HeaderValue.parse(
      values.first,
      preserveBackslash: true,
    ).parameters;
    var fileName = parameters['filename'];
    final parts = _utf8FileNamePattern.firstMatch(
      parameters['filename*'] ?? '',
    );
    if (parts != null) {
      try {
        fileName = Uri.decodeComponent(parts.group(1)!);
      } on FormatException {
        // 扩展参数编码无效时保留普通 filename。
      } on ArgumentError {
        // 不完整的百分号编码也会被拒绝。
      }
    }
    final name = fileName?.split(_pathSeparatorPattern).last.trim();
    return name == null || name.isEmpty || name == '.' || name == '..'
        ? null
        : name;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

// 后台只接收正文与解析参数，不捕获 Dio、门户会话或平台通道。
BulletinListPage _parsePage(({String html, Uri uri, int pageNumber}) input) =>
    parseBulletinPage(
      input.html,
      currentUri: input.uri,
      pageNumber: input.pageNumber,
    );

BulletinDetailDocument? _parseDetail(({String html, Uri uri}) input) =>
    parseBulletinDetail(input.html, currentUri: input.uri);

/// 解析官网返回的列表 HTML 和分页链接。
BulletinListPage parseBulletinPage(
  String html, {
  required Uri currentUri,
  required int pageNumber,
}) {
  final items = <Bulletin>[];
  final seenIds = <String>{};
  final rows = _newsRowPattern.allMatches(html);

  for (final rowMatch in rows) {
    final row = rowMatch.group(1) ?? '';
    final anchors = _anchorPattern.allMatches(row);
    RegExpMatch? articleAnchor;
    for (final anchor in anchors) {
      final attributes = _attributes(anchor.group(1) ?? '');
      final href = _decodeHtml(attributes['href'] ?? '');
      if (href.contains('wbnewsid=') || _articlePathPattern.hasMatch(href)) {
        articleAnchor = anchor;
        break;
      }
    }
    if (articleAnchor == null) continue;

    final attributes = _attributes(articleAnchor.group(1) ?? '');
    final href = _decodeHtml(attributes['href'] ?? '');
    final url = currentUri.resolve(href);
    final id = _articleId(url);
    if (id.isEmpty || !seenIds.add(id)) continue;

    final title = _decodeHtml(
      attributes['title'] ?? _plainText(articleAnchor.group(2) ?? ''),
    ).trim();
    if (title.isEmpty) continue;
    final category = _spanText(
      row,
      'wjj',
    ).replaceAll('[', '').replaceAll(']', '');
    final bulletin = Bulletin(
      id: id,
      title: title,
      url: url.toString(),
      officialCategory: category,
      publisher: _spanText(row, 'news_org'),
      publishedAt: _spanText(row, 'news_date'),
    );
    items.add(tagBulletin(bulletin));
  }

  final paging = _pagingDivPattern.firstMatch(html)?.group(1) ?? '';
  String? nextUrl;
  for (final anchor in _anchorPattern.allMatches(paging)) {
    final label = _plainText(anchor.group(2) ?? '').trim();
    final href = _attributes(anchor.group(1) ?? '')['href'] ?? '';
    if (label.contains('下页') &&
        href.isNotEmpty &&
        !href.startsWith('javascript:')) {
      nextUrl = currentUri.resolve(_decodeHtml(href)).toString();
      break;
    }
  }
  final totalText = _totalCountPattern.firstMatch(paging)?.group(1);

  return BulletinListPage(
    items: items,
    pageNumber: pageNumber,
    nextUrl: nextUrl,
    totalCount: int.tryParse(totalText ?? ''),
  );
}

String _articleId(Uri uri) {
  final queryId = uri.queryParameters['wbnewsid'];
  if (queryId != null && queryId.isNotEmpty) return queryId;
  return _articlePathPattern.firstMatch(uri.path)?.group(1) ?? uri.toString();
}

String _spanText(String html, String className) {
  final pattern = _spanPatterns.putIfAbsent(
    className,
    () => _buildSpanPattern(className),
  );
  final match = pattern.firstMatch(html);
  return _plainText(match?.group(1) ?? '').trim();
}

Map<String, String> _attributes(String source) {
  final attributes = <String, String>{};
  for (final match in _attributePattern.allMatches(source)) {
    attributes[match.group(1)!.toLowerCase()] =
        match.group(2) ?? match.group(3) ?? '';
  }
  return attributes;
}

String _plainText(String html) => _decodeHtml(
  html.replaceAll(_brTagPattern, ' ').replaceAll(_htmlTagPattern, ' '),
).replaceAll(_whitespacePattern, ' ');

String _decodeHtml(String text) {
  var value = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  value = value.replaceAllMapped(_numericEntityPattern, (match) {
    final code = match.group(1)!;
    final value = code.toLowerCase().startsWith('x')
        ? int.tryParse(code.substring(1), radix: 16)
        : int.tryParse(code);
    return value == null ? match.group(0)! : String.fromCharCode(value);
  });
  return value.replaceAll('&amp;', '&');
}
