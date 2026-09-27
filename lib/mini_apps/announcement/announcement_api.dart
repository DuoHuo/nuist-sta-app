import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'announcement_detail_parser.dart';
import 'announcement_models.dart';
import 'announcement_tagger.dart';

/// 信息公告栏官网首页地址。
const announcementHomeUri = 'https://bulletin.nuist.edu.cn/';

/// 从学校官网读取公告列表。
class AnnouncementApi {
  /// 创建公告接口客户端，可注入 Dio 实例。
  AnnouncementApi({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 18),
              headers: const {'Accept-Language': 'zh-CN,zh;q=0.9'},
            ),
          );

  final Dio _dio;

  /// 请求并解析指定分类或分页的公告列表。
  Future<AnnouncementListPage> fetchPage(
    Uri uri, {
    required int pageNumber,
  }) async {
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final html = response.data;
    if (html == null || html.isEmpty) {
      throw const FormatException('公告栏没有返回列表内容');
    }
    return parseAnnouncementPage(html, currentUri: uri, pageNumber: pageNumber);
  }

  /// 请求并解析单条公告正文；无法识别正文时返回 null 交给 WebView 兜底。
  Future<AnnouncementDetailDocument?> fetchDetail(
    Announcement announcement,
  ) async {
    final uri = Uri.parse(announcement.url);
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    final html = response.data;
    if (html == null || html.isEmpty) return null;
    return parseAnnouncementDetail(html, currentUri: uri);
  }

  /// 下载公告附件到临时目录，供系统分享面板保存或打开。
  Future<File> downloadAttachment(AnnouncementAttachment attachment) async {
    final directory = await getTemporaryDirectory();
    final sourceName = Uri.tryParse(attachment.url)?.pathSegments.last ?? '';
    final extension = sourceName.contains('.')
        ? '.${sourceName.split('.').last}'
        : '';
    var name = attachment.name.trim();
    if (name.isEmpty) name = '公告附件';
    name = name.replaceAll(RegExp(r'''[\\/:*?"<>|]'''), '_');
    if (extension.isNotEmpty &&
        !name.toLowerCase().endsWith(extension.toLowerCase())) {
      name += extension;
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}nuist-announcement-$name',
    );
    await _dio.download(attachment.url, file.path, deleteOnError: true);
    return file;
  }
}

/// 解析官网返回的列表 HTML 和分页链接。
AnnouncementListPage parseAnnouncementPage(
  String html, {
  required Uri currentUri,
  required int pageNumber,
}) {
  final items = <Announcement>[];
  final seenIds = <String>{};
  final rows = RegExp(
    r'''<li\b[^>]*class=["'][^"']*\bnews\b[^"']*["'][^>]*>([\s\S]*?)</li>''',
    caseSensitive: false,
  ).allMatches(html);

  for (final rowMatch in rows) {
    final row = rowMatch.group(1) ?? '';
    final anchors = RegExp(
      r'<a\b([^>]*)>([\s\S]*?)</a>',
      caseSensitive: false,
    ).allMatches(row);
    RegExpMatch? articleAnchor;
    for (final anchor in anchors) {
      final attributes = _attributes(anchor.group(1) ?? '');
      final href = _decodeHtml(attributes['href'] ?? '');
      if (href.contains('wbnewsid=') ||
          RegExp(r'/info/[^/]+/\d+\.htm').hasMatch(href)) {
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
    final announcement = Announcement(
      id: id,
      title: title,
      url: url.toString(),
      officialCategory: category,
      publisher: _spanText(row, 'news_org'),
      publishedAt: _spanText(row, 'news_date'),
    );
    items.add(tagAnnouncement(announcement));
  }

  final paging =
      RegExp(
        r'''<div\b[^>]*class=["'][^"']*\bwp_paging\b[^"']*["'][^>]*>([\s\S]*?)</div>''',
        caseSensitive: false,
      ).firstMatch(html)?.group(1) ??
      '';
  String? nextUrl;
  for (final anchor in RegExp(
    r'<a\b([^>]*)>([\s\S]*?)</a>',
    caseSensitive: false,
  ).allMatches(paging)) {
    final label = _plainText(anchor.group(2) ?? '').trim();
    final href = _attributes(anchor.group(1) ?? '')['href'] ?? '';
    if (label.contains('下页') &&
        href.isNotEmpty &&
        !href.startsWith('javascript:')) {
      nextUrl = currentUri.resolve(_decodeHtml(href)).toString();
      break;
    }
  }
  final totalText = RegExp(r'总共\s*(?:&nbsp;\s*)?(\d+)')
      .firstMatch(paging)
      ?.group(1);

  return AnnouncementListPage(
    items: items,
    pageNumber: pageNumber,
    nextUrl: nextUrl,
    totalCount: int.tryParse(totalText ?? ''),
  );
}

String _articleId(Uri uri) {
  final queryId = uri.queryParameters['wbnewsid'];
  if (queryId != null && queryId.isNotEmpty) return queryId;
  return RegExp(r'/info/[^/]+/(\d+)\.htm').firstMatch(uri.path)?.group(1) ??
      uri.toString();
}

String _spanText(String html, String className) {
  final match = RegExp(
    """<span\\b[^>]*class=["'][^"']*\\b$className\\b[^"']*["'][^>]*>([\\s\\S]*?)</span>""",
    caseSensitive: false,
  ).firstMatch(html);
  return _plainText(match?.group(1) ?? '').trim();
}

Map<String, String> _attributes(String source) {
  final attributes = <String, String>{};
  final pattern = RegExp(r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
  for (final match in pattern.allMatches(source)) {
    attributes[match.group(1)!.toLowerCase()] =
        match.group(2) ?? match.group(3) ?? '';
  }
  return attributes;
}

String _plainText(String html) => _decodeHtml(
  html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' '),
).replaceAll(RegExp(r'\s+'), ' ');

String _decodeHtml(String text) {
  var value = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  value = value.replaceAllMapped(
    RegExp(r'&#(x[0-9a-f]+|\d+);', caseSensitive: false),
    (match) {
      final code = match.group(1)!;
      final value = code.toLowerCase().startsWith('x')
          ? int.tryParse(code.substring(1), radix: 16)
          : int.tryParse(code);
      return value == null ? match.group(0)! : String.fromCharCode(value);
    },
  );
  return value.replaceAll('&amp;', '&');
}
