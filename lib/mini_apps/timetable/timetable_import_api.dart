import 'package:dio/dio.dart';

import '../../core/config/api_endpoints.dart';
import '../../core/network/owned_api_client.dart';
import 'timetable_import_models.dart';

/// 仅调用社团服务器解析 WakeUp 分享口令，独立客户端不携带门户 Cookie 或凭据。
///
/// 服务端未部署 `/timetable/wakeup-import` 前，内置示例口令可走本地 Mock 流程，
/// 其余真实口令仍请求社团服务端接口并在未上线时给出明确提示。
class TimetableImportApi {
  TimetableImportApi({Dio? dio})
    : _ownsDio = dio == null,
      _dio =
          dio ??
          createOwnedApiDio(
            options: BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final Dio _dio;
  final bool _ownsDio;

  /// 内置演示用 Mock 口令（用于服务端接口未上线前验证完整导入流程）。
  static const String demoShareKey = '00000000000000000000000000000001';
  static const String demoShareText =
      '这是来自「WakeUp课程表」的课表分享，分享口令为「$demoShareKey」';

  static const Set<String> _mockKeys = {
    demoShareKey,
    '11111111111111111111111111111111',
    'mock',
    'demo',
  };

  static bool isMockShareKey(String key) =>
      _mockKeys.contains(key.trim().toLowerCase());

  /// 根据粘贴文本提取口令并拉取解析后的课表结构。
  Future<WakeupImportResult> fetchByShareText(
    String rawInput, {
    CancelToken? cancelToken,
  }) async {
    final shareKey = extractWakeupShareKey(rawInput);
    if (isMockShareKey(shareKey)) {
      return WakeupImportParser.parsePayload(
        _mockPayloadFor(shareKey),
        isMock: true,
      );
    }
    try {
      final response = await _dio.post<Object?>(
        kTimetableWakeupImportEndpoint,
        data: {'code': shareKey},
        cancelToken: cancelToken,
      );
      final body = response.data;
      if (body is Map && body['code'] == 0 && body['data'] is Map) {
        final data = Map<String, dynamic>.from(body['data'] as Map);
        return WakeupImportParser.parsePayload(data);
      }
      if (body is Map && body['message'] is String) {
        throw TimetableImportException(
          body['message'] as String,
          code: 'import_server_rejected',
        );
      }
      throw const TimetableImportException(
        '解析口令失败，服务器返回了无效数据',
        code: 'import_invalid_response',
      );
    } on DioException catch (error, stackTrace) {
      if (CancelToken.isCancel(error)) rethrow;
      final status = error.response?.statusCode;
      final body = error.response?.data;
      if (body is Map && body['message'] is String) {
        throw TimetableImportException(
          body['message'] as String,
          code: 'import_request_failed',
          cause: error,
          causeStackTrace: stackTrace,
        );
      }
      if (status == 404 || status == 501) {
        throw TimetableImportException(
          '服务端分享口令解析接口暂未上线，可先点击「填入示例口令」体验 Mock 导入',
          code: 'import_endpoint_not_implemented',
          mockSupported: true,
          cause: error,
          causeStackTrace: stackTrace,
        );
      }
      throw TimetableImportException(
        '无法解析口令，请检查网络或稍后重试',
        code: 'import_request_failed',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 生成一份脱敏的本地 Mock WakeUp 课表，覆盖多时段、单双周与自定义颜色。
  static Map<String, dynamic> _mockPayloadFor(String key) {
    final alt = key.trim().toLowerCase() == '11111111111111111111111111111111';
    return {
      'name': alt ? '计算机同学的课表 (Mock)' : '测试导入课表 (Mock)',
      'startDate': '2026-08-31',
      'maxWeeks': 20,
      'periods': [
        {'node': 1, 'startTime': '08:00', 'endTime': '08:45'},
        {'node': 2, 'startTime': '08:55', 'endTime': '09:40'},
        {'node': 3, 'startTime': '10:10', 'endTime': '10:55'},
        {'node': 4, 'startTime': '11:05', 'endTime': '11:50'},
        {'node': 5, 'startTime': '13:45', 'endTime': '14:30'},
        {'node': 6, 'startTime': '14:40', 'endTime': '15:25'},
        {'node': 7, 'startTime': '15:55', 'endTime': '16:40'},
        {'node': 8, 'startTime': '16:50', 'endTime': '17:35'},
        {'node': 9, 'startTime': '18:30', 'endTime': '19:15'},
        {'node': 10, 'startTime': '19:25', 'endTime': '20:10'},
        {'node': 11, 'startTime': '20:20', 'endTime': '21:05'},
      ],
      'courses': [
        {
          'name': '数据结构与算法',
          'credit': 4.0,
          'color': '#3B82F6',
          'slots': [
            {
              'day': 1,
              'startNode': 1,
              'endNode': 2,
              'startWeek': 1,
              'endWeek': 16,
              'type': 0,
              'teacher': '王老师',
              'location': '揽江楼 N302',
            },
            {
              'day': 3,
              'startNode': 3,
              'endNode': 4,
              'startWeek': 1,
              'endWeek': 16,
              'type': 1,
              'teacher': '王老师',
              'location': '揽江楼 N302',
              'note': '单周上机',
            },
          ],
        },
        {
          'name': '操作系统',
          'credit': 3.5,
          'color': '#10B981',
          'slots': [
            {
              'day': 2,
              'startNode': 5,
              'endNode': 6,
              'startWeek': 1,
              'endWeek': 16,
              'type': 0,
              'teacher': '李老师',
              'location': '明德楼 S208',
            },
          ],
        },
        {
          'name': '软件工程导论',
          'credit': 2.0,
          'color': '#F59E0B',
          'slots': [
            {
              'day': 4,
              'startNode': 7,
              'endNode': 8,
              'startWeek': 2,
              'endWeek': 16,
              'type': 2,
              'teacher': '周老师',
              'location': '逸夫楼 104',
              'note': '双周实验',
            },
          ],
        },
      ],
    };
  }

  /// 释放本类创建的网络客户端。
  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}
