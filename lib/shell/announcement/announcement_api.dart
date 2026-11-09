import 'package:dio/dio.dart';

import '../../core/config/api_endpoints.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/owned_api_client.dart';
import 'announcement_models.dart';

/// 一次公告请求的结果。
class AnnouncementFetchResult {
  const AnnouncementFetchResult({
    required this.notModified,
    this.items,
    this.etag,
    this.lastModified,
  });

  /// 服务端返回 304，应沿用缓存。
  final bool notModified;

  /// 200 时的新列表；304 时为 null。
  final List<Announcement>? items;
  final String? etag;
  final String? lastModified;
}

/// 通过自有服务客户端拉取公告，由服务端根据客户端信息筛选版本范围。
/// 网络或格式错误直接抛出，由调用方静默处理。
class AnnouncementApi {
  static final _log = AppLog.logger('shell.announcement.api');

  AnnouncementApi({Dio? dio})
    : _ownsDio = dio == null,
      _dio =
          dio ??
          createOwnedApiDio(
            options: BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;
  final bool _ownsDio;

  /// 带条件头请求；只有传入非 null 的校验值才会发对应请求头。
  Future<AnnouncementFetchResult> fetch({
    String? etag,
    String? lastModified,
  }) async {
    final response = await _dio.get<Object?>(
      kAnnouncementEndpoint,
      options: Options(
        headers: {'If-None-Match': ?etag, 'If-Modified-Since': ?lastModified},
        validateStatus: (s) => s != null && (s >= 200 && s < 300 || s == 304),
      ),
    );
    _log.debug(
      'fetch.response',
      fields: {
        'status_code': response.statusCode,
        'not_modified': response.statusCode == 304,
      },
    );
    if (response.statusCode == 304) {
      return const AnnouncementFetchResult(notModified: true);
    }
    return AnnouncementFetchResult(
      notModified: false,
      items: parseAnnouncementResponse(response.data),
      etag: response.headers.value('etag'),
      lastModified: response.headers.value('last-modified'),
    );
  }

  /// 释放本类创建的客户端，外部注入的客户端由调用方管理。
  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}
