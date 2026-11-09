import 'package:dio/dio.dart';

import '../config/api_endpoints.dart';
import '../logging/app_log.dart';
import 'client_metadata.dart';

final _ownedOrigin = Uri.parse(kApiBase);

/// 判断初始请求是否指向自有服务的 HTTPS 原点。
bool isOwnedApiUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == _ownedOrigin.host &&
    uri.port == _ownedOrigin.port &&
    uri.userInfo.isEmpty;

/// 创建自有服务专用客户端，不复用门户会话。
///
/// 调用者负责关闭所创建的客户端。统一追加元数据，不清理调用方的其他请求头。
/// 初始请求只允许访问自有服务，重定向遵循 Dio 默认行为及调用方配置。
Dio createOwnedApiDio({
  BaseOptions? options,
  Future<ClientMetadata> Function()? metadataProvider,
}) {
  final dio = Dio(
    options ??
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
  );
  final load = metadataProvider ?? ClientMetadataProvider.instance.get;
  final log = AppLog.logger('community.network');
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (!isOwnedApiUri(request.uri)) {
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.unknown,
              error: StateError('自有服务客户端不允许访问此地址'),
            ),
          );
          return;
        }
        try {
          request.headers.addAll((await load()).headers);
        } catch (error, stackTrace) {
          // 平台元数据不可用时仍标明新协议，让公告接口采用无版本限制的安全结果。
          request.headers.addAll(const ClientMetadata().headers);
          log.warning(
            'metadata.unavailable',
            error: error,
            stackTrace: stackTrace,
          );
        }
        handler.next(request);
      },
    ),
  );
  return dio;
}
