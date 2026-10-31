import 'package:dio/dio.dart';

import '../../core/config/api_endpoints.dart';
import '../../core/logging/app_log.dart';
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

/// 拉取公告。公网接口、无鉴权，不发送任何身份 / 设备 / 版本信息。
/// 网络或格式错误直接抛出，由调用方静默处理。
class AnnouncementApi {
  static final _log = AppLog.logger('shell.announcement.api');

  AnnouncementApi({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;

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
}
