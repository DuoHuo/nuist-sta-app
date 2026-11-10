import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'update_controller.dart';
import 'update_markdown.dart';
import 'update_models.dart';

final _openDetails = Expando<Future<void>>('updateDetails');

/// 在根导航器显示更新详情；重复入口共用同一弹层，关闭不取消下载。
Future<void> showUpdateDetails(
  BuildContext context, {
  UpdateController? controller,
  bool automatic = false,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final existing = _openDetails[navigator];
  if (existing != null) return existing;
  final c = controller ?? UpdateController.instance;
  final future = _presentDetails(navigator, c, automatic).whenComplete(() {
    _openDetails[navigator] = null;
  });
  _openDetails[navigator] = future;
  return future;
}

Future<void> _presentDetails(
  NavigatorState navigator,
  UpdateController controller,
  bool automatic,
) async {
  await controller.ensureStarted();
  if (!navigator.mounted || _releaseFor(controller) == null) return;
  final route = DialogRoute<void>(
    context: navigator.context,
    builder: (_) => UpdateDetailsDialog(
      key: const ValueKey('update-details'),
      controller: controller,
      automatic: automatic,
    ),
  );
  await navigator.push(route);
  await route.completed;
}

UpdateRelease? _releaseFor(UpdateController controller) =>
    controller.task.hasTask ? controller.task.release : controller.available;

/// 更新日志与下载操作共用的可关闭详情弹层。
class UpdateDetailsDialog extends StatefulWidget {
  const UpdateDetailsDialog({
    super.key,
    required this.controller,
    this.automatic = false,
  });

  final UpdateController controller;
  final bool automatic;

  @override
  State<UpdateDetailsDialog> createState() => _UpdateDetailsDialogState();
}

class _UpdateDetailsDialogState extends State<UpdateDetailsDialog> {
  final _scroll = ScrollController();
  UpdateRelease? _release;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _release = _releaseFor(widget.controller);
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(UpdateDetailsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _release = _releaseFor(widget.controller);
    }
  }

  void _onChanged() {
    if (!mounted || _closing) return;
    final release = _releaseFor(widget.controller);
    if (release == null) {
      // 操作失败的结果保留在原弹层中，底部不会再使用旧修订发起下载。
      if (widget.controller.actionError != null) return;
      _closing = true;
      // 详情上可以叠着日志链接网页，只移除详情自身。
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      });
      return;
    }
    final previous = _release;
    // 原生进度事件也会携带一份修订快照，不据对象身份重建 Markdown。
    if (release.revision != previous?.revision ||
        release.changelog != previous?.changelog ||
        release.versionName != previous?.versionName ||
        release.size != previous?.size ||
        release.publishedAt != previous?.publishedAt) {
      setState(() => _release = release);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    if (release == null) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final hasChangelog = release.changelog.trim().isNotEmpty;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '发现新版本 v${release.versionName}',
                    style: TextStyle(
                      color: palette.titleText,
                      fontSize: 20,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${formatUpdateBytes(release.size)} · ${_date(release.publishedAt)}',
                  style: TextStyle(color: palette.labelText, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭更新详情',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
    final changelog = hasChangelog
        ? Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: UpdateChangelog(data: release.changelog),
          )
        : const SizedBox.shrink();
    return Dialog(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 480),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: palette.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight = math.min(
            constraints.maxHeight,
            MediaQuery.sizeOf(context).height * 0.8,
          );
          final compact =
              maxHeight < 320 * MediaQuery.textScalerOf(context).scale(1);
          final content = Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              key: const ValueKey('update-changelog-scroll'),
              controller: _scroll,
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [header, changelog],
                    )
                  : changelog,
            ),
          );
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact) header,
                  if (compact || hasChangelog) Flexible(child: content),
                  // 操作区不随长日志滚动；极矮窗口中仍可滚动访问所有按钮。
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight * 0.55),
                    child: SingleChildScrollView(
                      primary: false,
                      child: _UpdateActions(
                        controller: widget.controller,
                        automatic: widget.automatic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({required this.controller, required this.automatic});

  final UpdateController controller;
  final bool automatic;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final task = c.task;
        final release = _releaseFor(c);
        final error =
            c.actionError ??
            (task.errorCode == null
                ? null
                : updateErrorMessage(task.errorCode));
        final buttons = <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(automatic && !task.hasTask ? '稍后提醒' : '关闭'),
          ),
          if (!task.hasTask && release != null)
            FilledButton.icon(
              onPressed: c.acting ? null : () => c.download(release),
              icon: const Icon(Icons.download_rounded),
              label: Text(automatic ? '立即下载' : '下载更新'),
            ),
          if (task.hasTask && task.status != UpdateTaskStatus.installing)
            TextButton(
              onPressed: c.acting ? null : c.cancel,
              child: Text(
                task.status == UpdateTaskStatus.revoked ? '清除任务' : '取消下载',
              ),
            ),
          if (task.status == UpdateTaskStatus.paused ||
              task.status == UpdateTaskStatus.failed)
            FilledButton.icon(
              onPressed: c.acting ? null : c.resume,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('继续下载'),
            ),
          if (task.status == UpdateTaskStatus.ready)
            FilledButton.icon(
              onPressed: c.acting
                  ? null
                  : task.installAllowed
                  ? c.install
                  : c.openInstallSettings,
              icon: const Icon(Icons.system_update_rounded),
              label: Text(task.installAllowed ? '安装更新' : '允许安装'),
            ),
        ];
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.rowDivider)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (task.hasTask) ...[
                  Text(
                    _taskLabel(task),
                    style: TextStyle(
                      color: palette.titleText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (task.status == UpdateTaskStatus.downloading ||
                      task.status == UpdateTaskStatus.verifying) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: task.status == UpdateTaskStatus.verifying
                          ? null
                          : task.progress,
                      semanticsLabel: '更新下载进度',
                      semanticsValue: task.progress == null
                          ? null
                          : '${(task.progress! * 100).round()}%',
                    ),
                  ],
                  if (task.status == UpdateTaskStatus.downloading) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${formatUpdateBytes(task.downloadedBytes)} / ${formatUpdateBytes(task.totalBytes)}',
                      style: TextStyle(color: palette.labelText, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
                if (error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(error, style: TextStyle(color: palette.danger)),
                  ),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: buttons,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _date(DateTime value) {
  final date = value.toLocal();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// 下载体积按二进制单位展示。
String formatUpdateBytes(int bytes) => bytes <= 0
    ? '0 B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

String _taskLabel(UpdateTask task) => switch (task.status) {
  UpdateTaskStatus.idle => '',
  UpdateTaskStatus.downloading => '正在下载',
  UpdateTaskStatus.paused => '下载已暂停',
  UpdateTaskStatus.verifying => '正在校验安装包',
  UpdateTaskStatus.ready => '下载完成',
  UpdateTaskStatus.installing => '正在安装',
  UpdateTaskStatus.failed => '下载失败',
  UpdateTaskStatus.revoked => '此版本已停止分发',
};
