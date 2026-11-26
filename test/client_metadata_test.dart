import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:package_info_plus/package_info_plus.dart';

PackageInfo packageInfo({String buildNumber = '02800'}) => PackageInfo(
  appName: 'NUIST++',
  packageName: 'dev.duohuo.nuist_sta_app',
  version: '0.2.8',
  buildNumber: buildNumber,
);

/// 不落盘的同意状态，匿名标识只在内存里生成。
PrivacyConsent consentOf(PrivacyDecision decision) =>
    PrivacyConsent(directory: () async => null)..value = decision;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('基础信息与原生字段独立读取，并规范化数字构建号', () async {
    final provider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.accepted),
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
      consent: consentOf(PrivacyDecision.accepted),
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
    pending.complete(packageInfo());
    // 平台读取只发生一次；已同意时返回的就是缓存的同一份元数据。
    expect(identical(await first, await second), isTrue);
    expect(identical(await first, await provider.get()), isTrue);
    expect(packageCalls, 1);
    expect(nativeCalls, 1);
  });

  test('原生通道失败仍返回包名和版本，失败结果不重复采集', () async {
    var calls = 0;
    final provider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.accepted),
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
      consent: consentOf(PrivacyDecision.accepted),
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

  test('非法渠道、不安全字段及无效标识均被省略，匿名标识校验 UUID v4', () {
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

    const badClientId = ClientMetadata(
      platform: 'android',
      appPackage: 'dev.duohuo.nuist_sta_app',
      clientId: 'raw-android-id',
      romName: 'HarmonyOS',
    );
    expect(badClientId.headers['X-ROM-Name'], 'HarmonyOS');
    expect(badClientId.headers.containsKey('X-ROM-Version'), isFalse);
    expect(badClientId.headers.containsKey('X-Client-ID'), isFalse);
    expect(badClientId.headers.containsKey('X-Client-ID-Type'), isFalse);

    final badAnon = ClientMetadata(
      platform: 'android',
      anonymousId: 'ab' * 32,
    ).headers;
    expect(badAnon.containsKey('X-Client-ID'), isFalse);
    expect(badAnon.containsKey('X-Client-ID-Type'), isFalse);
  });

  test('特殊 ROM 版本代号（OriginOS Ocean、HarmonyOSNEXT）按规则清洗', () {
    Map<String, String> headers(String name, String? version) => ClientMetadata(
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

    const harmonyNext = ClientMetadata(
      platform: 'android',
      androidVersion: '12',
      androidSdk: 31,
      romName: 'HarmonyOSNEXT',
      romVersion: '6.0.0',
    );
    expect(harmonyNext.headers['X-ROM-Name'], 'HarmonyOSNEXT');
    expect(harmonyNext.headers['X-ROM-Version'], '6.0.0');
    expect(harmonyNext.headers['X-Android-Version'], '12');
    expect(
      headers('HarmonyOSNEXT', null).containsKey('X-ROM-Version'),
      isFalse,
    );
  });

  test('包名来源回退、渠道版本号校验与设备标识解耦', () async {
    final fallbackProvider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.accepted),
      platform: 'android',
      packageLoader: () async => throw PlatformException(code: 'unavailable'),
      nativeLoader: () async => {'appPackage': 'dev.duohuo.nuist_sta_app'},
    );
    final fallback = await fallbackProvider.get();
    expect(fallback.headers['X-App-Package'], 'dev.duohuo.nuist_sta_app');
    expect(fallback.headers.containsKey('X-App-Version-Code'), isFalse);

    final independentProvider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.accepted),
      platform: 'android',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => {
        'appPackage': 'another.package',
        'clientId': 'ab' * 32,
      },
    );
    final independent = (await independentProvider.get()).headers;
    expect(independent['X-Client-ID'], 'ab' * 32);
    expect(independent['X-App-Package'], 'dev.duohuo.nuist_sta_app');

    final invalidProvider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.accepted),
      platform: 'android',
      appChannel: 'invalid',
      packageLoader: () async => packageInfo(buildNumber: 'v02800'),
      nativeLoader: () async => {},
    );
    final invalid = await invalidProvider.get();
    expect(invalid.headers.containsKey('X-App-Channel'), isFalse);
    expect(invalid.headers.containsKey('X-App-Version-Code'), isFalse);

    ClientMetadata of({String? package, String channel = 'dev'}) =>
        ClientMetadata(
          platform: 'android',
          appPackage: package,
          appChannel: channel,
          clientId: 'cd' * 32,
        );
    final dev = of(package: 'org.example.nuist.dev').headers;
    final release = of(
      package: 'org.example.nuist',
      channel: 'release',
    ).headers;
    final unknown = of().headers;
    expect(dev['X-Client-ID'], release['X-Client-ID']);
    expect(unknown['X-Client-ID'], dev['X-Client-ID']);
    expect(unknown.containsKey('X-App-Package'), isFalse);
    expect(dev['X-App-Package'], isNot(release['X-App-Package']));
    expect(dev['X-App-Channel'], isNot(release['X-App-Channel']));
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
      consent: consentOf(PrivacyDecision.accepted),
      platform: 'android',
      packageLoader: () async => packageInfo(),
    );
    expect((await provider.get()).headers['X-ROM-Name'], 'EMUI');
  });

  Map<Object?, Object?> nativeFields() => {
    'appPackage': 'dev.duohuo.nuist_sta_app',
    'clientId': 'ab' * 32,
    'androidVersion': '14',
    'androidSdk': 34,
    'romName': 'OriginOS',
    'romVersion': '4',
  };

  test('已拒绝：只发送随机 UUID，Android 版本和厂商系统固定为 anonymous', () async {
    final provider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.declined),
      platform: 'android',
      appChannel: 'ci',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => nativeFields(),
    );
    final headers = (await provider.get()).headers;
    expect(headers['X-Client-ID'], isNot('ab' * 32));
    expect(PrivacyConsent.isUuid(headers['X-Client-ID']!), isTrue);
    expect(headers['X-Client-ID-Type'], 'random_uuid_v1');
    expect(headers['X-Android-Version'], 'anonymous');
    expect(headers['X-ROM-Name'], 'anonymous');
    expect(headers.containsKey('X-Android-SDK'), isFalse);
    expect(headers.containsKey('X-ROM-Version'), isFalse);
    // 应用版本和包名不受影响，公告筛选仍可用。
    expect(headers['X-App-Version-Code'], '2800');
    expect(headers['X-App-Package'], 'dev.duohuo.nuist_sta_app');
    expect(headers.values.join(), isNot(contains('OriginOS')));
    expect(headers.values, isNot(contains('14')));
  });

  test('未选择：不发送任何标识和系统信息，随机 UUID 也不发送', () async {
    final provider = ClientMetadataProvider(
      consent: consentOf(PrivacyDecision.undecided),
      platform: 'android',
      appChannel: 'ci',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => nativeFields(),
    );
    final headers = (await provider.get()).headers;
    for (final name in [
      'X-Client-ID',
      'X-Client-ID-Type',
      'X-Android-Version',
      'X-Android-SDK',
      'X-ROM-Name',
      'X-ROM-Version',
    ]) {
      expect(headers.containsKey(name), isFalse, reason: name);
    }
    expect(headers['X-App-Version-Code'], '2800');
    expect(headers['X-App-Package'], 'dev.duohuo.nuist_sta_app');
  });
  test('匿名标识在同一份同意状态里保持不变，且每个实例各自随机', () async {
    final consent = consentOf(PrivacyDecision.declined);
    final provider = ClientMetadataProvider(
      consent: consent,
      platform: 'android',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => nativeFields(),
    );
    final first = (await provider.get()).headers['X-Client-ID'];
    expect((await provider.get()).headers['X-Client-ID'], first);
    expect(await consent.anonymousId(), first);
    expect(
      await consentOf(PrivacyDecision.declined).anonymousId(),
      isNot(first),
    );
  });

  test('同意后立即改发设备派生标识，撤回后改回匿名', () async {
    final consent = consentOf(PrivacyDecision.undecided);
    final provider = ClientMetadataProvider(
      consent: consent,
      platform: 'android',
      packageLoader: () async => packageInfo(),
      nativeLoader: () async => nativeFields(),
    );
    expect((await provider.get()).headers.containsKey('X-Client-ID'), isFalse);
    await consent.set(PrivacyDecision.accepted);
    var headers = (await provider.get()).headers;
    expect(headers['X-Client-ID'], 'ab' * 32);
    expect(headers['X-Client-ID-Type'], 'ssaid_sha256_v1');
    expect(headers['X-ROM-Name'], 'OriginOS');
    await consent.set(PrivacyDecision.declined);
    headers = (await provider.get()).headers;
    expect(headers['X-Client-ID-Type'], 'random_uuid_v1');
    expect(headers['X-ROM-Name'], 'anonymous');
    expect(headers['X-Android-Version'], 'anonymous');
  });
}
