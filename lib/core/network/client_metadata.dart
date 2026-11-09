import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../logging/app_log.dart';

/// 自有服务请求使用的客户端信息，不包含门户身份或业务内容。
@immutable
class ClientMetadata {
  const ClientMetadata({
    this.platform,
    this.appPackage,
    this.appChannel,
    this.appVersion,
    this.appVersionCode,
    this.clientId,
    this.androidVersion,
    this.androidSdk,
    this.romName,
    this.romVersion,
  });

  final String? platform;
  final String? appPackage;
  final String? appChannel;
  final String? appVersion;
  final int? appVersionCode;
  final String? clientId;
  final String? androidVersion;
  final int? androidSdk;
  final String? romName;
  final String? romVersion;

  /// 只生成通过格式校验的请求头；不可用字段直接省略。
  Map<String, String> get headers {
    final result = <String, String>{'X-Client-Metadata-Version': '1'};
    void add(String key, String? value) {
      if (value != null) result[key] = value;
    }

    final validPlatform = _member(platform, _platforms);
    final validPackage = _text(appPackage, _packagePattern, 255);
    add('X-Client-Platform', validPlatform);
    add('X-App-Package', validPackage);
    add('X-App-Channel', _member(appChannel, _channels));
    add('X-App-Version', _text(appVersion, _versionPattern, 64));
    add('X-App-Version-Code', _positiveNumber(appVersionCode, 2100000000));
    if (validPlatform == 'android') {
      final validId = _text(clientId, _idPattern, 64);
      if (validId != null) {
        result['X-Client-ID'] = validId;
        result['X-Client-ID-Type'] = 'ssaid_sha256_v1';
      }
      add('X-Android-Version', _text(androidVersion, _versionPattern, 32));
      add('X-Android-SDK', _positiveNumber(androidSdk, 1000));
      final validRom = _member(romName, _romNames);
      add('X-ROM-Name', validRom);
      if (validRom != null) {
        add(
          'X-ROM-Version',
          validRom == 'OriginOS' && romVersion == 'Ocean'
              ? 'Ocean'
              : _text(romVersion, _romVersionPattern, 32),
        );
      }
    }
    return Map.unmodifiable(result);
  }

  /// 公告缓存的客户端变体，不使用设备标识或系统版本。
  String get cacheKey {
    final values = headers;
    final code = values['X-App-Version-Code'];
    return jsonEncode([
      1,
      values['X-Client-Platform'],
      values['X-App-Package'],
      values['X-App-Channel'],
      code,
      // 缺少数字版本时也不能误用另一未知构建的已筛选公告。
      if (code == null) values['X-App-Version'],
    ]);
  }

  static const _platforms = {
    'android',
    'ios',
    'windows',
    'linux',
    'macos',
    'fuchsia',
    'web',
  };
  static const _channels = {'release', 'dev', 'ci'};
  static const _romNames = {
    'HyperOS',
    'MIUI',
    'HarmonyOS',
    'HarmonyOSNEXT',
    'EMUI',
    'MagicOS',
    'MagicUI',
    'ColorOS',
    'realmeUI',
    'OxygenOS',
    'H2OS',
    'OriginOS',
    'FuntouchOS',
    'OneUI',
    'Flyme',
  };
  static final _packagePattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$',
  );
  static final _versionPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+\-]*$');
  static final _romVersionPattern = RegExp(r'^\d{1,3}(?:\.\d{1,3}){0,3}$');
  static final _idPattern = RegExp(r'^[0-9a-f]{64}$');

  static String? _member(String? value, Set<String> allowed) =>
      allowed.contains(value) ? value : null;

  static String? _text(String? value, RegExp pattern, int maxLength) {
    if (value == null ||
        value.isEmpty ||
        value.length > maxLength ||
        value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      return null;
    }
    return pattern.hasMatch(value) ? value : null;
  }

  static String? _positiveNumber(int? value, int maximum) =>
      value != null && value > 0 && value <= maximum ? '$value' : null;
}

/// 惰性获取并在进程内缓存客户端信息，读取失败不阻断网络功能。
class ClientMetadataProvider {
  ClientMetadataProvider({
    Future<PackageInfo> Function()? packageLoader,
    Future<Map<Object?, Object?>?> Function()? nativeLoader,
    String? platform,
    String? appChannel,
  }) : _packageLoader = packageLoader ?? PackageInfo.fromPlatform,
       _nativeLoader = nativeLoader ?? _readNative,
       _platform = platform ?? _currentPlatform,
       _appChannel =
           appChannel ??
           const String.fromEnvironment('APP_CHANNEL', defaultValue: 'dev');

  /// 公告、贡献者和其他自有服务共用同一份元数据。
  static final instance = ClientMetadataProvider();
  static final _log = AppLog.logger('client_metadata');
  static const _channel = MethodChannel('nuist/client_metadata');
  final Future<PackageInfo> Function() _packageLoader;
  final Future<Map<Object?, Object?>?> Function() _nativeLoader;
  final String _platform;
  final String _appChannel;
  Future<ClientMetadata>? _loading;

  /// 同时发起的调用复用同一读取，不重复访问平台通道。
  Future<ClientMetadata> get() => _loading ??= _load();

  Future<ClientMetadata> _load() async {
    // 两个来源各自兜底，原生通道失败仍保留应用版本和包名。
    final packageFuture = _readPackage();
    final nativeFuture = _readAndroid();
    final info = await packageFuture;
    final native = await nativeFuture;
    String? nativeText(String key) =>
        native[key] is String ? native[key] as String : null;
    final nativePackage = nativeText('appPackage');
    final package = info?.packageName ?? nativePackage;
    final rawBuild = info?.buildNumber;
    final buildNumber =
        rawBuild != null && RegExp(r'^\d{1,10}$').hasMatch(rawBuild)
        ? int.tryParse(rawBuild)
        : null;
    if (!ClientMetadata._channels.contains(_appChannel)) {
      _log.warning('channel.invalid');
    }
    return ClientMetadata(
      platform: _platform,
      appPackage: package,
      appChannel: _appChannel,
      appVersion: info?.version,
      appVersionCode: buildNumber,
      // 设备标识与包名独立；相同 SSAID 的不同包共用一个统计标识。
      clientId: nativeText('clientId'),
      androidVersion: nativeText('androidVersion'),
      androidSdk: native['androidSdk'] is int
          ? native['androidSdk'] as int
          : null,
      romName: nativeText('romName'),
      romVersion: nativeText('romVersion'),
    );
  }

  Future<PackageInfo?> _readPackage() async {
    try {
      return await _packageLoader().timeout(const Duration(seconds: 2));
    } catch (error) {
      _log.warning(
        'package.unavailable',
        errorKind: AppLog.errorKindFor(error),
      );
      return null;
    }
  }

  Future<Map<Object?, Object?>> _readAndroid() async {
    if (_platform != 'android') return const {};
    try {
      return await _nativeLoader().timeout(const Duration(seconds: 2)) ??
          const {};
    } catch (error) {
      _log.warning('native.unavailable', errorKind: AppLog.errorKindFor(error));
      return const {};
    }
  }

  static Future<Map<Object?, Object?>?> _readNative() =>
      _channel.invokeMapMethod<Object?, Object?>('getMetadata');

  static String get _currentPlatform => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => 'android',
          TargetPlatform.iOS => 'ios',
          TargetPlatform.linux => 'linux',
          TargetPlatform.macOS => 'macos',
          TargetPlatform.windows => 'windows',
          TargetPlatform.fuchsia => 'fuchsia',
        };
}
