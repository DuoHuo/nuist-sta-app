import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import '../update/update_markdown.dart';

/// 隐私政策页：渲染随安装包打包的 `PRIVACY.md`，与仓库中的文件保持同一份。
class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key, this.loader});

  /// 测试可注入正文；默认读取打包的 `PRIVACY.md`。
  final Future<String> Function()? loader;

  /// 打包进安装包的隐私政策资源路径。
  static const assetPath = 'PRIVACY.md';

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  static final _log = AppLog.logger('shell.privacy_policy');

  late Future<String> _text = _load();

  Future<String> _load() async {
    try {
      return await (widget.loader ??
          () => rootBundle.loadString(PrivacyPolicyPage.assetPath))();
    } catch (error, stackTrace) {
      _log.warning('load_failed', error: error, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('隐私政策')),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '隐私政策暂时无法显示',
                    style: TextStyle(color: palette.hint, fontSize: 14),
                  ),
                  TextButton(
                    onPressed: () {
                      final next = _load();
                      setState(() {
                        _text = next;
                      });
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return UpdateChangelog.scrollable(data: snapshot.data!);
        },
      ),
    );
  }
}
