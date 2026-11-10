import '../../core/network/owned_api_client.dart';

/// 服务端已完整缓存、批准并允许分发的不可变修订。
class UpdateRelease {
  const UpdateRelease({
    required this.revision,
    required this.versionName,
    required this.versionCode,
    required this.packageName,
    required this.channel,
    required this.abi,
    required this.minSdk,
    required this.title,
    required this.changelog,
    required this.publishedAt,
    required this.size,
    required this.sha256,
    required this.downloadUrl,
    required this.statusUrl,
    this.popupEnabled = false,
  });

  final String revision;
  final String versionName;
  final int versionCode;
  final String packageName;
  final String channel;
  final String abi;
  final int minSdk;
  final String title;
  final String changelog;
  final DateTime publishedAt;
  final int size;
  final String sha256;
  final Uri downloadUrl;
  final Uri statusUrl;

  /// 管理员控制自动弹窗，关闭时作为公告悬浮条提示。
  final bool popupEnabled;

  /// 拒绝缺字段、非法摘要和外域地址，不从文件名推算安装信息。
  factory UpdateRelease.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('更新信息格式无效');
    String text(String key, int limit, {bool empty = false}) {
      final valueAtKey = value[key];
      if (valueAtKey is! String ||
          (!empty && valueAtKey.isEmpty) ||
          valueAtKey.length > limit) {
        throw const FormatException('更新信息字段无效');
      }
      return valueAtKey;
    }

    int number(String key, int max) {
      final n = value[key];
      if (n is! int || n <= 0 || n > max) {
        throw const FormatException('更新信息数值无效');
      }
      return n;
    }

    Uri url(String key) {
      final uri = Uri.tryParse(text(key, 2048));
      if (uri == null || !isOwnedApiUri(uri) || uri.hasFragment) {
        throw const FormatException('更新地址无效');
      }
      return uri;
    }

    final revision = text('revision', 128);
    final hash = text('sha256', 64);
    final date = DateTime.tryParse(text('publishedAt', 64));
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(revision) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        date == null) {
      throw const FormatException('更新修订无效');
    }
    return UpdateRelease(
      revision: revision,
      versionName: text('versionName', 64),
      versionCode: number('versionCode', 2100000000),
      packageName: text('packageName', 255),
      channel: text('channel', 32),
      abi: text('abi', 32),
      minSdk: number('minSdk', 1000),
      title: text('title', 1000, empty: true),
      changelog: text('changelog', 1024 * 1024, empty: true),
      publishedAt: date,
      size: number('size', 2 * 1024 * 1024 * 1024),
      sha256: hash,
      downloadUrl: url('downloadUrl'),
      statusUrl: url('statusUrl'),
      popupEnabled: value['popupEnabled'] == true,
    );
  }

  /// 状态复查不能把原修订悄悄替换成另一份安装包。
  bool sameArtifact(UpdateRelease other) =>
      revision == other.revision &&
      sha256 == other.sha256 &&
      size == other.size &&
      versionCode == other.versionCode &&
      packageName == other.packageName &&
      channel == other.channel &&
      abi == other.abi &&
      minSdk == other.minSdk &&
      downloadUrl == other.downloadUrl &&
      statusUrl == other.statusUrl;

  /// 传给原生下载服务的完整修订描述。
  Map<String, Object> toJson() => {
    'revision': revision,
    'versionName': versionName,
    'versionCode': versionCode,
    'packageName': packageName,
    'channel': channel,
    'abi': abi,
    'minSdk': minSdk,
    'title': title,
    'changelog': changelog,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'size': size,
    'sha256': sha256,
    'downloadUrl': downloadUrl.toString(),
    'statusUrl': statusUrl.toString(),
    'popupEnabled': popupEnabled,
  };
}

/// 原生任务状态，下载不依赖 Flutter 页面存活。
enum UpdateTaskStatus {
  idle,
  downloading,
  paused,
  verifying,
  ready,
  installing,
  failed,
  revoked,
}

/// 下载服务的状态快照；进度事件不写业务日志。
class UpdateTask {
  const UpdateTask({
    this.status = UpdateTaskStatus.idle,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.release,
    this.errorCode,
    this.installAllowed = false,
  });

  final UpdateTaskStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final UpdateRelease? release;
  final String? errorCode;
  final bool installAllowed;

  bool get hasTask => release != null && status != UpdateTaskStatus.idle;

  double? get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : null;

  /// 平台快照损坏时交给控制器反馈，不把异常文本直接显示给用户。
  factory UpdateTask.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('下载状态无效');
    final status = UpdateTaskStatus.values.where(
      (s) => s.name == value['status'],
    );
    if (status.isEmpty) throw const FormatException('下载状态无效');
    int bytes(String key) {
      final n = value[key];
      return n is int && n >= 0 ? n : 0;
    }

    return UpdateTask(
      status: status.first,
      downloadedBytes: bytes('downloadedBytes'),
      totalBytes: bytes('totalBytes'),
      release: value['release'] == null
          ? null
          : UpdateRelease.fromJson(value['release']),
      errorCode: value['errorCode'] is String ? value['errorCode'] : null,
      installAllowed: value['installAllowed'] == true,
    );
  }
}
