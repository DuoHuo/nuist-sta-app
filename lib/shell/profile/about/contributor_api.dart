import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/api_endpoints.dart';
import 'contributor_models.dart';

/// 拉取贡献者名单。网络或格式错误直接抛出，由调用方处理。
class ContributorApi {
  ContributorApi({Dio? dio})
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

  Future<List<Contributor>> fetch() async {
    final response = await _dio.get<Object?>(kContributorsEndpoint);
    if (kDebugMode) debugPrint('[contributors] HTTP ${response.statusCode}');
    return parseContributorsResponse(response.data);
  }
}
