import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import '../../core/app_registry.dart';
import '../../core/logging/app_log.dart';
import '../../core/pull_to_refresh.dart';
import '../../mini_apps/registry.dart';

/// 按注册表排列学习卡片，并在下拉时并发刷新这些卡片。
/// 各卡自己负责启动及未绑定、加载、失败等状态的展示。
class StudyPage extends StatelessWidget {
  const StudyPage({super.key, this.registry});
  static final _log = AppLog.logger('shell.study');

  /// 可覆盖注册表；未指定时使用应用的全量注册信息。
  final AppRegistry? registry;

  static Future<void> _refreshAll(List<AppManifest> apps) =>
      _log.startSpan().run(
        () => Future.wait<void>([
          for (final app in apps)
            if (app.studyCard?.onRefresh case final refresh?)
              Future<void>.sync(refresh).catchError((
                Object error,
                StackTrace stack,
              ) {
                // 模块通常自行展示业务错误；意外异常也不能中断其他卡片的刷新。
                _log.warning('refresh.failed', error: error, stackTrace: stack);
              }),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final apps = (registry ?? appRegistry).studyApps;
    return Scaffold(
      appBar: AppBar(title: const Text('学习')),
      body: PullToRefresh(
        onRefresh: () => _refreshAll(apps),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            for (final (index, app) in apps.indexed) ...[
              if (index > 0) const SizedBox(height: 12),
              Builder(key: ValueKey(app.id), builder: app.studyCard!.builder),
            ],
          ],
        ),
      ),
    );
  }
}
