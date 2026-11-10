import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/app_snack_bar.dart';
import '../../../core/app_info.dart';
import '../../../core/colors.dart';
import '../../../core/logging/app_log.dart';
import '../../update/update_controller.dart';
import '../../update/update_dialog.dart';
import 'contributor_avatar.dart';
import 'contributor_controller.dart';
import 'contributor_models.dart';

/// 版本号展示格式：`v1.2.3 (45)`。
String formatAppVersion(String version, String buildNumber) =>
    buildNumber.isEmpty ? 'v$version' : 'v$version ($buildNumber)';

/// 关于页：应用图标、名称、版本号与贡献者名单。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.updates});

  /// 默认使用应用级更新状态，测试可注入同一控制器。
  final UpdateController? updates;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final _controller = ContributorController();
  String? _version;
  int _versionTapCount = 0;
  Timer? _versionTapReset;
  bool _checkingUpdate = false;
  UpdateController get _updates => widget.updates ?? UpdateController.instance;

  @override
  void initState() {
    super.initState();
    _controller.load();
    _loadVersion();
    unawaited(_updates.ensureStarted());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(
          () => _version = formatAppVersion(info.version, info.buildNumber),
        );
      }
    } catch (_) {
      // 没有平台通道时不显示版本号。
    }
  }

  void _onVersionTap() {
    if (_version == null) return;
    _versionTapReset?.cancel();
    _versionTapCount++;
    if (_versionTapCount < 5) {
      _versionTapReset = Timer(const Duration(seconds: 3), () {
        _versionTapCount = 0;
      });
      return;
    }
    _versionTapCount = 0;
    AppLog.diagnosticsVisible.value = true;
    _message('已显示诊断与日志入口');
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(tone: AppSnackBarTone.success, content: Text(text)),
      );
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    await _updates.check(manual: true);
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final release = _updates.available;
    final failed = _updates.checkError != null;
    final navigator = Navigator.of(context, rootNavigator: true);
    final updates = _updates;
    if (!failed && release != null) _updates.markPrompted(release);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(
          tone: failed ? AppSnackBarTone.error : AppSnackBarTone.info,
          content: Text(
            failed
                ? '检查更新失败'
                : release == null
                ? '暂无新版本'
                : '发现新版本 v${release.versionName}',
          ),
          action: !failed && release != null
              ? SnackBarAction(
                  label: '查看',
                  onPressed: () {
                    if (navigator.mounted) {
                      showUpdateDetails(navigator.context, controller: updates);
                    }
                  },
                )
              : null,
        ),
      );
  }

  @override
  void dispose() {
    _versionTapReset?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 72,
                height: 72,
                semanticLabel: '$kAppName 图标',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            kAppName,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.titleText,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onVersionTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _version ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.hint, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ListenableBuilder(
            listenable: _updates,
            builder: (context, _) => ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              tileColor: palette.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: Icon(Icons.system_update_rounded, color: palette.accent),
              title: Text(_checkingUpdate ? '正在检查更新…' : '检查更新'),
              trailing: _checkingUpdate
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _updates.task.hasTask || _updates.available != null
                  ? TextButton(
                      onPressed: () =>
                          showUpdateDetails(context, controller: _updates),
                      child: Text(_updates.task.hasTask ? '下载进度' : '查看更新'),
                    )
                  : null,
              onTap: _checkingUpdate ? null : _checkUpdates,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '贡献者',
                  style: TextStyle(
                    color: palette.titleText,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) => _buildContributors(palette),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContributors(AppPalette palette) {
    final items = _controller.items;
    if (items == null) {
      if (_controller.failed) {
        return Center(
          child: Column(
            children: [
              Text(
                '贡献者名单暂时无法获取',
                style: TextStyle(color: palette.hint, fontSize: 13),
              ),
              TextButton(onPressed: _controller.retry, child: const Text('重试')),
            ],
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (items.isEmpty) {
      return Text('暂无', style: TextStyle(color: palette.hint, fontSize: 13));
    }
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [for (final c in items) _ContributorChip(contributor: c)],
    );
  }
}

class _ContributorChip extends StatelessWidget {
  const _ContributorChip({required this.contributor});

  final Contributor contributor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 首字母贴在 accent 实心圆上，底色不随主题变浅，保持白色。
    final initial = Text(
      contributor.name.characters.first,
      style: const TextStyle(color: Colors.white, fontSize: 16),
    );
    final avatar = contributor.avatar;
    return SizedBox(
      width: 56,
      child: Column(
        children: [
          ClipOval(
            child: Container(
              width: 44,
              height: 44,
              color: palette.accent,
              alignment: Alignment.center,
              child: avatar == null
                  ? initial
                  : ContributorAvatar(url: avatar, fallback: initial),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            contributor.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.labelText, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
