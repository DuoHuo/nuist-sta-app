import 'package:dio/dio.dart';

import '../../../core/config/api_endpoints.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/network/owned_api_client.dart';
import 'contributor_models.dart';

/// 拉取贡献者名单。网络或格式错误直接抛出，由调用方处理。
class ContributorApi {
  static final _log = AppLog.logger('shell.profile.contributors.api');

  ContributorApi({Dio? dio})
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

  Future<List<Contributor>> fetch() async {
    final response = await _dio.get<Object?>(kContributorsEndpoint);
    _log.debug('fetch.response', fields: {'status_code': response.statusCode});
    return parseContributorsResponse(response.data);
  }

  /// 仅关闭本类创建的客户端。
  void close() {
    if (_ownsDio) _dio.close(force: true);
  }
}
