import 'package:dio/dio.dart';

import '../../core/config/api_endpoints.dart';
import 'timetable_export_models.dart';

/// 仅调用社团服务器生成口令，独立客户端不携带门户 Cookie 或凭据。
class TimetableExportApi {
  TimetableExportApi({Dio? dio})
    : _ownsDio = dio == null,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final Dio _dio;
  final bool _ownsDio;

  /// 上传已去除身份信息的快照并获取口令；不自动重试生成请求。
  Future<TimetableWakeupShare> generate(
    TimetableExportSnapshot snapshot, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        kTimetableWakeupEndpoint,
        data: snapshot.payload,
        cancelToken: cancelToken,
      );
      final body = response.data;
      if (body is Map && body['code'] == 0 && body['data'] is Map) {
        final data = body['data'] as Map;
        final text = data['shareText'];
        if (text is String && text.isNotEmpty) {
          return TimetableWakeupShare(shareText: text);
        }
      }
      throw const TimetableExportException('生成口令失败，服务器返回了无效数据');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final body = error.response?.data;
      if (body is Map && body['message'] is String) {
        throw TimetableExportException(body['message'] as String);
      }
      throw const TimetableExportException('无法生成口令，请检查网络或稍后重试');
    }
  }

  /// 释放本类创建的网络客户端。
  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}
