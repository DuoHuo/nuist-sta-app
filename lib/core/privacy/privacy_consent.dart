import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:path_provider/path_provider.dart';

import '../logging/app_log.dart';

/// 当前隐私政策的版本号。
///
/// `PRIVACY.md` 的收集范围、用途或接收方变化时递增，已有的同意记录随之失效，
/// 应用会重新询问一次。
const int kPrivacyPolicyVersion = 1;

/// 用户对隐私政策的选择。
enum PrivacyDecision {
  /// 还没有选择，或同意的是旧版政策。自有服务请求不带设备标识和系统信息，只发送
  /// 应用版本、包名与渠道；课表分享不可用。
  undecided,

  /// 已同意：自有服务请求携带设备统计标识，课表分享可用。
  accepted,

  /// 已拒绝：自有服务请求只携带匿名元数据，课表分享不可用。
  declined,
}

/// 隐私政策同意状态与匿名标识的存取。
///
/// 全局单例，状态变化时通知监听者。选择与匿名标识都存在应用支持目录的
/// `settings/` 下，数据不敏感，不占安全存储。存储不可用时（widget 测试没有平台
/// 通道）退化为只在内存中保存。
class PrivacyConsent extends ValueNotifier<PrivacyDecision> {
  PrivacyConsent({Future<Directory?> Function()? directory})
    : _directory = directory ?? _supportDirectory,
      super(PrivacyDecision.undecided);

  static final instance = PrivacyConsent();

  /// 打开完整隐私政策页，由壳在启动时登记（core 不能依赖 shell）。
  /// 为空时弹窗不显示「查看完整隐私政策」。
  static void Function(BuildContext context)? openPolicy;

  static final _log = AppLog.logger('core.privacy_consent');
  static const _consentFile = 'privacy_consent';
  static const _anonymousIdFile = 'anonymous_id';

  final Future<Directory?> Function() _directory;
  Future<void>? _loading;
  Future<String>? _anonymousId;

  static Future<Directory?> _supportDirectory() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}settings');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<File?> _file(String name) async {
    final dir = await _directory();
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// 是否已同意当前版本的隐私政策。
  bool get accepted => value == PrivacyDecision.accepted;

  /// 冷启动读一次本地记录；重复调用共用同一次读取。
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final file = await _file(_consentFile);
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != kPrivacyPolicyVersion) return;
      value = switch (json['decision']) {
        'accepted' => PrivacyDecision.accepted,
        'declined' => PrivacyDecision.declined,
        _ => PrivacyDecision.undecided,
      };
    } catch (error, stackTrace) {
      _log.warning('load_failed', error: error, stackTrace: stackTrace);
      // 记录损坏就当没选过，下次启动重新询问。
    }
  }

  /// 记录选择并落盘。界面先变，写盘失败不回滚。
  Future<void> set(PrivacyDecision decision) async {
    if (decision == value) return;
    value = decision;
    _log.info('decision.changed', fields: {'decision': decision.name});
    final file = await _file(_consentFile);
    if (file == null) return;
    try {
      await file.writeAsString(
        jsonEncode({
          'version': kPrivacyPolicyVersion,
          'decision': decision.name,
        }),
        flush: true,
      );
    } catch (error, stackTrace) {
      _log.warning('save_failed', error: error, stackTrace: stackTrace);
    }
  }

  /// 匿名客户端标识：随机 UUID v4，与 Android ID 等设备信息无关。
  ///
  /// 首次调用时生成并保存，之后复用。存储不可用时本次进程内保持不变。
  Future<String> anonymousId() => _anonymousId ??= _loadAnonymousId();

  Future<String> _loadAnonymousId() async {
    final file = await _file(_anonymousIdFile);
    try {
      if (file != null && await file.exists()) {
        final stored = (await file.readAsString()).trim();
        if (isUuid(stored)) return stored;
      }
    } catch (error, stackTrace) {
      _log.warning(
        'anonymous_id.load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final id = generateUuid();
    if (file != null) {
      try {
        await file.writeAsString(id, flush: true);
      } catch (error, stackTrace) {
        _log.warning(
          'anonymous_id.save_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return id;
  }

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// 是否是本类生成的小写 UUID v4 格式。
  static bool isUuid(String value) => _uuidPattern.hasMatch(value);

  /// 用安全随机数生成小写 UUID v4。
  @visibleForTesting
  static String generateUuid([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
