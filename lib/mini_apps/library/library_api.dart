import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/http_diagnostics.dart';
import 'library_models.dart';

/// 公开馆藏使用独立客户端，读者接口复用统一门户会话。
class LibraryApi {
  LibraryApi({Dio? catalogue, Dio? coverImages, PortalSession? portal})
    : _catalogue = catalogue ?? _publicClient,
      _coverImages = coverImages ?? _coverClient,
      _portal = portal ?? PortalSession.instance {
    installHttpDiagnostics(_catalogue);
  }

  static final _log = AppLog.logger('mini_apps.library');
  static const _opac = '/meta-local/opac';
  static const _pageSize = 20;
  static const _maxCoverBytes = 2 * 1024 * 1024;
  static final _publicClient = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 12),
      followRedirects: false,
    ),
  );
  // 独立于馆藏和门户的客户端，仅读取静态封面。
  static final _coverClient = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      followRedirects: false,
    ),
  );
  static final _dangdangImageHost = RegExp(r'^img3m[0-9]\.ddimg\.cn$');
  static const _headers = {
    'Accept': 'application/json',
    'X-Hw-Lang': 'zh_CN',
    'X-Hw-explorer': 'm',
  };

  final Dio _catalogue;
  final Dio _coverImages;
  final PortalSession _portal;

  /// 检查本机是否已绑定统一门户。
  Future<bool> hasPortalBinding() async => await PasskeyStore.read() != null;

  /// 查询公开馆藏的一页结果。
  Future<LibraryResultPage<LibraryBook>> search(
    String keyword,
    LibrarySearchField field,
    int page, {
    CancelToken? cancelToken,
  }) => _log.operation('catalogue.search', () async {
    final response = await _catalogue.postUri<String>(
      _uri('$_opac/search/'),
      data: {
        'queryFieldList': [
          {
            'logic': 0,
            'field': field.field,
            'values': [keyword],
            'operator': field.operator,
          },
        ],
        'sortField': 'relevance',
        'sortType': 'desc',
        'indexName': 'idx.opac',
        'collapseField': 'groupId',
        'filterFieldList': [],
        'page': page,
        'pageSize': _pageSize,
      },
      options: Options(
        headers: _headers,
        contentType: Headers.jsonContentType,
        responseType: ResponseType.plain,
      ),
      cancelToken: cancelToken,
    );
    return libraryResultPage(
      libraryResponseData(response.data),
      'dataList',
      LibraryBook.fromJson,
    );
  });

  /// 读取某一书目的出版与编目信息。
  Future<LibraryBookInfo> fetchBookInfo(String id, CancelToken cancelToken) =>
      _log.operation('catalogue.info', () async {
        final data = await _getBookData(id, 'infos', cancelToken);
        return LibraryBookInfo.fromJson(data);
      });

  /// 根据书目和 ISBN 查封面；无可用封面时返回 null。
  Future<Uint8List?> fetchCover(
    String id,
    List<String> isbns,
    CancelToken cancelToken,
  ) async {
    if (isbns.isEmpty) return null;
    return _log.operation('catalogue.cover', () async {
      final response = await _catalogue.postUri<String>(
        _uri('$_opac/search/extend3', {'coversOnly': 'true'}),
        data: {
          'isbns': isbns,
          'bibIds': [id],
        },
        options: Options(
          headers: _headers,
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
        ),
        cancelToken: cancelToken,
      );
      final body = jsonDecode(response.data ?? '');
      // 校方对未收录封面的 ISBN 返回 code: 0、data: null。
      if (body is Map && body['data'] == null && body['code'] == 0) return null;
      final covers = libraryResponseData(body)[id];
      if (covers is! List) return null;
      for (final cover in covers.whereType<Map>()) {
        final uri = _coverUri(cover['imageUrl']);
        if (uri == null) continue;
        try {
          final image = await _downloadCover(uri, cancelToken);
          if (image != null) return image;
        } on DioException catch (error) {
          if (error.type == DioExceptionType.cancel) rethrow;
          // 图片已失效时继续尝试馆藏接口提供的其他封面。
        }
      }
      return null;
    });
  }

  /// 读取各馆藏副本的位置和可借状态。
  Future<List<LibraryHolding>> fetchHoldings(
    String id,
    CancelToken cancelToken,
  ) => _log.operation('catalogue.holdings', () async {
    final data = await _getBookData(id, 'holdings', cancelToken);
    return libraryHoldings(data);
  });

  /// 读取登录用户当前借阅的一页记录。
  Future<LibraryResultPage<LibraryLoan>> fetchLoans(
    int page, {
    CancelToken? cancelToken,
  }) => _log.operation('loans.list', () async {
    final uri = _uri('$_opac/users/loans', {
      'page': '$page',
      'pageSize': '$_pageSize',
    });
    final response = await _portal.request(
      PortalServices.library,
      (http) => http.get(uri, headers: _headers, cancelToken: cancelToken),
    );
    if (response.statusCode != 200 || response.realUri != uri) {
      throw const FormatException('图书馆借阅接口返回异常响应');
    }
    return libraryResultPage(
      libraryResponseData(response.data),
      'items',
      LibraryLoan.fromJson,
    );
  });

  Future<Map<String, dynamic>> _getBookData(
    String id,
    String section,
    CancelToken cancelToken,
  ) async {
    final response = await _catalogue.getUri<String>(
      Uri(
        scheme: 'https',
        host: CampusHosts.library,
        pathSegments: ['meta-local', 'opac', 'bibs', id, section],
      ),
      options: Options(headers: _headers, responseType: ResponseType.plain),
      cancelToken: cancelToken,
    );
    return libraryResponseData(response.data);
  }

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.https(CampusHosts.library, path, query);

  static Uri? _coverUri(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final source = Uri.tryParse(value.trim());
    if (source == null ||
        !source.hasAuthority ||
        source.userInfo.isNotEmpty ||
        (source.hasPort && source.port != 443) ||
        (source.scheme.isNotEmpty &&
            source.scheme != 'http' &&
            source.scheme != 'https')) {
      return null;
    }
    final host = source.host;
    if (host != CampusHosts.library &&
        host != 'img.hwlsp.cn' &&
        !_dangdangImageHost.hasMatch(host)) {
      return null;
    }
    return source.replace(scheme: 'https').removeFragment();
  }

  Future<Uint8List?> _downloadCover(Uri uri, CancelToken token) async {
    final result = await _coverImages.getUri<ResponseBody>(
      uri,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
      ),
      cancelToken: token,
    );
    final body = result.data;
    if (body == null) return null;
    final type = result.headers.value(Headers.contentTypeHeader);
    if (type == null || !type.toLowerCase().startsWith('image/')) {
      await body.stream.listen(null).cancel();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > _maxCoverBytes) return null;
      bytes.add(chunk);
    }
    return bytes.isEmpty ? null : bytes.takeBytes();
  }
}
