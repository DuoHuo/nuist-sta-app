import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:package_info_plus/package_info_plus.dart';

PackageInfo packageInfo({String buildNumber = '02800'}) => PackageInfo(
  appName: 'NUIST++',
  packageName: 'dev.duohuo.nuist_sta_app',
  version: '0.2.8',
  buildNumber: buildNumber,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('基础信息与原生字段独立读取，并规范化数字构建号', () async {
    final provider = ClientMetadataProvider(
      platform: 'android',
      appChannel: 'ci',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => {
        'appPackage': 'dev.duohuo.nuist_sta_app',
        'clientId': 'ab' * 32,
        'androidVersion': '14',
        'androidSdk': 34,
        'romName': 'OriginOS',
        'romVersion': '4',
      },
    );
    final metadata = await provider.get();
    expect(metadata.appVersionCode, 2800);
    expect(metadata.headers, {
      'X-Client-Metadata-Version': '1',
      'X-Client-Platform': 'android',
      'X-App-Package': 'dev.duohuo.nuist_sta_app',
      'X-App-Channel': 'ci',
      'X-App-Version': '0.2.8',
      'X-App-Version-Code': '2800',
      'X-Client-ID': 'ab' * 32,
      'X-Client-ID-Type': 'ssaid_sha256_v1',
      'X-Android-Version': '14',
      'X-Android-SDK': '34',
      'X-ROM-Name': 'OriginOS',
      'X-ROM-Version': '4',
    });
    expect(
      () => metadata.headers['X-App-Package'] = 'changed',
      throwsUnsupportedError,
    );
  });

  test('并发与后续读取复用同一个Future及元数据', () async {
    var packageCalls = 0;
    var nativeCalls = 0;
    final pending = Completer<PackageInfo>();
    final provider = ClientMetadataProvider(
      platform: 'android',
      packageLoader: () {
        packageCalls++;
        return pending.future;
      },
      nativeLoader: () async {
        nativeCalls++;
        return {};
      },
    );
    final first = provider.get();
    final second = provider.get();
    expect(identical(first, second), isTrue);
    pending.complete(packageInfo());
    expect(identical(await first, await provider.get()), isTrue);
    expect(packageCalls, 1);
    expect(nativeCalls, 1);
  });

  test('原生通道失败仍返回包名和版本，失败结果不重复采集', () async {
    var calls = 0;
    final provider = ClientMetadataProvider(
      platform: 'android',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async {
        calls++;
        throw MissingPluginException();
      },
    );
    final result = await provider.get();
    expect(result.headers['X-App-Version-Code'], '2800');
    expect(result.headers.containsKey('X-Client-ID'), isFalse);
    expect(result.headers.containsKey('X-ROM-Name'), isFalse);
    await provider.get();
    expect(calls, 1);
  });

  test('非Android平台不调用设备通道，也不发送Android字段', () async {
    final provider = ClientMetadataProvider(
      platform: 'ios',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => fail('不应调用Android通道'),
    );
    expect((await provider.get()).headers['X-Client-Platform'], 'ios');
    final headers = ClientMetadata(
      platform: 'ios',
      appPackage: 'dev.duohuo.nuist_sta_app',
      clientId: 'ab' * 32,
      androidVersion: '14',
      androidSdk: 34,
      romName: 'OneUI',
      romVersion: '6.1',
    ).headers;
    expect(
      headers.keys.any(
        (key) => key.startsWith('X-Android') || key.startsWith('X-ROM'),
      ),
      isFalse,
    );
    expect(headers.containsKey('X-Client-ID'), isFalse);
  });

  test('非法渠道和不安全字段省略，不伪装成release或注入请求头', () {
    final headers = ClientMetadata(
      platform: 'android',
      appPackage: 'valid.package\r\nInjected: yes',
      appChannel: 'production',
      appVersion: '0.2.8\n',
      appVersionCode: -1,
      clientId: 'ab' * 32,
      androidVersion: '14\t',
      androidSdk: 0,
      romName: 'arbitrary',
      romVersion: '99999999.0',
    ).headers;
    expect(headers, {
      'X-Client-Metadata-Version': '1',
      'X-Client-Platform': 'android',
      'X-Client-ID': 'ab' * 32,
      'X-Client-ID-Type': 'ssaid_sha256_v1',
    });
  });

  test('设备标识格式错误时不带类型头，ROM名称可独立存在', () {
    const metadata = ClientMetadata(
      platform: 'android',
      appPackage: 'dev.duohuo.nuist_sta_app',
      clientId: 'raw-android-id',
      romName: 'HarmonyOS',
    );
    expect(metadata.headers['X-ROM-Name'], 'HarmonyOS');
    expect(metadata.headers.containsKey('X-ROM-Version'), isFalse);
    expect(metadata.headers.containsKey('X-Client-ID'), isFalse);
    expect(metadata.headers.containsKey('X-Client-ID-Type'), isFalse);
  });

  test('OriginOS Ocean 使用确证的市场代号，其他 ROM 不接受该代号', () {
    Map<String, String> headers(String name, String version) => ClientMetadata(
      platform: 'android',
      romName: name,
      romVersion: version,
    ).headers;
    expect(headers('OriginOS', 'Ocean')['X-ROM-Version'], 'Ocean');
    expect(headers('HyperOS', 'Ocean').containsKey('X-ROM-Version'), isFalse);
    expect(
      headers(
        'OriginOS',
        'Ocean\r\nInjected: true',
      ).containsKey('X-ROM-Version'),
      isFalse,
    );
    expect(headers('OriginOS', '6')['X-ROM-Version'], '6');
  });

  test('鸿蒙 Android 兼容环境单独分类，宿主版本与 Android 版本分开', () {
    const metadata = ClientMetadata(
      platform: 'android',
      androidVersion: '12',
      androidSdk: 31,
      romName: 'HarmonyOSNEXT',
      romVersion: '6.0.0',
    );
    expect(metadata.headers['X-ROM-Name'], 'HarmonyOSNEXT');
    expect(metadata.headers['X-ROM-Version'], '6.0.0');
    expect(metadata.headers['X-Android-Version'], '12');
    expect(
      const ClientMetadata(
        platform: 'android',
        romName: 'HarmonyOSNEXT',
      ).headers.containsKey('X-ROM-Version'),
      isFalse,
    );
  });

  test('包信息失败时可使用原生实际包名，但不编造应用版本', () async {
    final provider = ClientMetadataProvider(
      platform: 'android',
      packageLoader: () async => throw PlatformException(code: 'unavailable'),
      nativeLoader: () async => {'appPackage': 'dev.duohuo.nuist_sta_app'},
    );
    final metadata = await provider.get();
    expect(metadata.headers['X-App-Package'], 'dev.duohuo.nuist_sta_app');
    expect(metadata.headers.containsKey('X-App-Version-Code'), isFalse);
  });

  test('设备标识不依赖包名来源，包信息单独处理', () async {
    final provider = ClientMetadataProvider(
      platform: 'android',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => {
        'appPackage': 'another.package',
        'clientId': 'ab' * 32,
      },
    );
    final headers = (await provider.get()).headers;
    expect(headers['X-Client-ID'], 'ab' * 32);
    expect(headers['X-App-Package'], 'dev.duohuo.nuist_sta_app');
  });

  test('不同包名和渠道共享相同设备标识，包名缺失也可发送标识', () {
    ClientMetadata metadata({String? package, String channel = 'dev'}) =>
        ClientMetadata(
          platform: 'android',
          appPackage: package,
          appChannel: channel,
          clientId: 'cd' * 32,
        );
    final dev = metadata(package: 'org.example.nuist.dev').headers;
    final release = metadata(
      package: 'org.example.nuist',
      channel: 'release',
    ).headers;
    final unknown = metadata().headers;
    expect(dev['X-Client-ID'], release['X-Client-ID']);
    expect(unknown['X-Client-ID'], dev['X-Client-ID']);
    expect(unknown.containsKey('X-App-Package'), isFalse);
    expect(dev['X-App-Package'], isNot(release['X-App-Package']));
    expect(dev['X-App-Channel'], isNot(release['X-App-Channel']));
  });

  test('无效渠道及版本号不会被包装成有效兼容信息', () async {
    final provider = ClientMetadataProvider(
      platform: 'android',
      appChannel: 'invalid',
      packageLoader: () async => packageInfo(buildNumber: 'v02800'),
      nativeLoader: () async => {},
    );
    final metadata = await provider.get();
    expect(metadata.headers.containsKey('X-App-Channel'), isFalse);
    expect(metadata.headers.containsKey('X-App-Version-Code'), isFalse);
  });

  test('公告缓存变体区分包渠道版本，且不包含设备信息', () {
    ClientMetadata metadata({
      String package = 'a.package',
      String channel = 'dev',
      int? code = 2800,
      String version = '0.2.8',
      String? id,
    }) => ClientMetadata(
      platform: 'android',
      appPackage: package,
      appChannel: channel,
      appVersionCode: code,
      appVersion: version,
      clientId: id,
    );
    final key = metadata().cacheKey;
    expect(metadata(package: 'b.package').cacheKey, isNot(key));
    expect(metadata(channel: 'ci').cacheKey, isNot(key));
    expect(metadata(code: 2801).cacheKey, isNot(key));
    expect(metadata(id: 'ab' * 32).cacheKey, key);
    expect(
      metadata(code: null, version: '0.2.8').cacheKey,
      isNot(metadata(code: null, version: '0.2.9').cacheKey),
    );
    expect(jsonDecode(key), [1, 'android', 'a.package', 'dev', '2800']);
  });

  test('实际MethodChannel方法名和返回值可正常接入', () async {
    const channel = MethodChannel('nuist/client_metadata');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getMetadata');
      return {
        'androidVersion': '14',
        'androidSdk': 34,
        'romName': 'EMUI',
        'romVersion': '12.0.0',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final provider = ClientMetadataProvider(
      platform: 'android',
      packageLoader: () async => packageInfo(),
    );
    expect((await provider.get()).headers['X-ROM-Name'], 'EMUI');
  });
}
