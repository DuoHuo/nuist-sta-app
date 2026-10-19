import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/app_info.dart';
import '../../../core/colors.dart';
import 'contributor_controller.dart';
import 'contributor_models.dart';

/// 版本号展示格式：`v1.2.3 (45)`。
String formatAppVersion(String version, String buildNumber) =>
    buildNumber.isEmpty ? 'v$version' : 'v$version ($buildNumber)';

/// 关于页：应用图标、名称、版本号与贡献者名单。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final _controller = ContributorController();
  String? _version;

  @override
  void initState() {
    super.initState();
    _controller.load();
    _loadVersion();
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

  @override
  void dispose() {
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
          Text(
            _version ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.hint, fontSize: 13),
          ),
          const SizedBox(height: 24),
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
                  : Image.network(
                      avatar,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => initial,
                    ),
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
