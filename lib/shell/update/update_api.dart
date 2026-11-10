import 'package:dio/dio.dart';

import '../../core/config/api_endpoints.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/owned_api_client.dart';
import 'update_models.dart';

/// 修订已撤包或不再允许分发。
class UpdateRevoked implements Exception {
  const UpdateRevoked();
}

/// 仅访问自有服务缓存的更新接口，也便于测试注入。
abstract interface class UpdateClient {
  Future<UpdateRelease?> check();
  Future<void> validate(UpdateRelease release);
}

/// 不跟随外域重定向，不触发 GitHub 拉取。
class UpdateApi implements UpdateClient {
  UpdateApi({Dio? dio})
    : _dio = dio ?? createOwnedApiDio(),
      _ownsDio = dio == null;

  final Dio _dio;
  final bool _ownsDio;
  static final _log = AppLog.logger('shell.update.api');

  Future<UpdateRelease?> _get(Uri uri) async {
    if (!isOwnedApiUri(uri)) throw const FormatException('更新地址无效');
    final response = await _dio.getUri<Object?>(
      uri,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Cache-Control': 'no-cache'},
        validateStatus: (s) => s == 200 || s == 410,
      ),
    );
    _log.debug('fetch.response', fields: {'status_code': response.statusCode});
    if (response.statusCode == 410) throw const UpdateRevoked();
    final data = response.data;
    if (data is! Map || data['available'] is! bool) {
      throw const FormatException('更新响应无效');
    }
    if (data['available'] == false) return null;
    return UpdateRelease.fromJson(data['release']);
  }

  @override
  Future<UpdateRelease?> check() =>
      _get(Uri.parse('$kUpdateEndpoint/check?abi=arm64-v8a'));

  @override
  Future<void> validate(UpdateRelease release) async {
    final current = await _get(release.statusUrl);
    if (current == null || !current.sameArtifact(release)) {
      throw const UpdateRevoked();
    }
  }

  /// 仅关闭本对象创建的网络客户端。
  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}
