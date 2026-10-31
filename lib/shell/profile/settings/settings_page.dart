import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/colors.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/logging/log_export_service.dart';
import '../../../core/logging/log_store.dart';
import '../../../core/theme_mode.dart';

/// App 级设置页：外观模式，以及本地诊断日志的导出、详细模式与清理。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const themeModeLabels = {
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final modes = themeModeLabels.entries.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Semantics(
              header: true,
              child: Text(
                '深色模式',
                style: TextStyle(color: palette.labelText, fontSize: 13),
              ),
            ),
          ),
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: AppThemeMode.instance,
              builder: (context, current, _) => Column(
                children: [
                  for (var i = 0; i < modes.length; i++)
                    _OptionRow(
                      key: Key('settings_theme_${modes[i].key.name}'),
                      label: modes[i].value,
                      selected: modes[i].key == current,
                      showDivider: i < modes.length - 1,
                      onTap: () => AppThemeMode.instance.set(modes[i].key),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              '选择「跟随系统」时，App 会随手机的深色模式自动切换。',
              style: TextStyle(color: palette.labelText, fontSize: 12),
            ),
          ),
          const SizedBox(height: 20),
          const _DiagnosticLogSection(),
        ],
      ),
    );
  }
}

class _DiagnosticLogSection extends StatefulWidget {
  const _DiagnosticLogSection();

  @override
  State<_DiagnosticLogSection> createState() => _DiagnosticLogSectionState();
}

class _DiagnosticLogSectionState extends State<_DiagnosticLogSection> {
  static final _log = AppLog.logger('app.logging');
  LogStoreStats? _stats;
  bool _working = false;
  String? _progress;
  bool _statsFailed = false;
  bool _statsLoading = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _loadStats();
    AppLog.verboseEnabled.addListener(_updateMode);
    AppLog.verboseExpiresAt.addListener(_updateMode);
    AppLog.storageAvailable.addListener(_updateMode);
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateMode();
      if (!_working) unawaited(_loadStats());
    });
  }

  void _updateMode() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    AppLog.verboseEnabled.removeListener(_updateMode);
    AppLog.verboseExpiresAt.removeListener(_updateMode);
    AppLog.storageAvailable.removeListener(_updateMode);
    super.dispose();
  }

  Future<void> _loadStats() async {
    if (_statsLoading) return;
    _statsLoading = true;
    try {
      final stats = await AppLog.stats();
      if (mounted) {
        setState(() {
          _stats = stats;
          _statsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statsFailed = true);
    } finally {
      _statsLoading = false;
    }
  }

  Future<void> _preview() async {
    if (_working) return;
    setState(() {
      _working = true;
      _progress = '正在读取日志…';
    });
    try {
      final preview = await _log.operation('preview.read', () async {
        final snapshot = await AppLog.snapshot();
        final records = await compute(_parseLogPreview, snapshot.content);
        return (records: records, stats: snapshot.stats);
      }, successLevel: AppLogLevel.debug);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              _LogPreviewPage(records: preview.records, stats: preview.stats),
        ),
      );
      await _loadStats();
    } catch (_) {
      if (mounted) _message('日志读取失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _export() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导出诊断日志'),
          content: const Text(
            '日志会自动过滤账号、凭据、Cookie 和业务内容，只包含运行状态与错误类别。'
            '请仍然确认分享对象可信。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _log.operation(
        'export.share',
        () async {
          setState(() => _progress = '正在生成诊断日志…');
          final file = await LogExportService.createExport();
          if (!mounted) return null;
          final box = context.findRenderObject() as RenderBox?;
          setState(() => _progress = '正在打开分享面板…');
          return SharePlus.instance.share(
            ShareParams(
              files: [XFile(file.path, mimeType: 'text/plain')],
              subject: 'NUIST++ 诊断日志',
              sharePositionOrigin: box == null
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        },
        resultFields: (result) => {
          'outcome': result?.status.name ?? 'cancelled',
        },
      );
      await _loadStats();
    } catch (_) {
      if (mounted) _message('日志导出失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _clear() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清除诊断日志'),
          content: const Text('将清除本机运行日志和应用生成的导出副本。清除后无法恢复，当前日志模式不变。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _progress = '正在清除日志…');
      await AppLog.clear();
      await _loadStats();
      if (mounted) _message('诊断日志已清除');
    } catch (_) {
      if (mounted) _message('部分日志未能清除，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _progress = null;
        });
      }
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final stats = _stats;
    final detail = stats == null
        ? '正在统计…'
        : stats.bytes == 0
        ? '暂无可导出的日志'
        : '${_formatBytes(stats.bytes)}，最多保留 7 天';
    final verbose = AppLog.verboseEnabled.value;
    final until = AppLog.verboseExpiresAt.value;
    final remaining = until?.difference(DateTime.now().toUtc());
    final mode = kDebugMode
        ? '详细模式 · 调试构建默认开启'
        : verbose
        ? '详细模式 · 剩余 ${((remaining?.inSeconds ?? 0).clamp(0, 1800) / 60).ceil()} 分钟'
        : '标准模式 · 记录运行结果和错误';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Semantics(
            header: true,
            child: Text(
              '诊断与日志',
              style: TextStyle(color: palette.labelText, fontSize: 13),
            ),
          ),
        ),
        Material(
          color: palette.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.bug_report_outlined, color: palette.accent),
                title: Text(mode),
                subtitle: Text(
                  !AppLog.storageAvailable.value
                      ? '日志存储暂不可用'
                      : _statsFailed
                      ? '日志统计失败，请稍后重试'
                      : (stats?.unreadableFileCount ?? 0) > 0
                      ? '部分文件不可读，其余日志仍可查看和导出'
                      : detail,
                ),
                trailing: verbose && !kDebugMode
                    ? TextButton(
                        onPressed: _working ? null : AppLog.disableVerbose,
                        child: const Text('关闭'),
                      )
                    : null,
              ),
              Divider(height: 1, indent: 52, color: palette.rowDivider),
              _SettingsActionRow(
                icon: Icons.subject_outlined,
                title: '查看日志',
                subtitle: '按模块与级别筛选，展开查看堆栈',
                enabled: !_working && (stats?.bytes ?? 0) > 0,
                onTap: _preview,
              ),
              Divider(height: 1, indent: 52, color: palette.rowDivider),
              _SettingsActionRow(
                icon: Icons.ios_share_outlined,
                title: '导出诊断日志',
                subtitle: '生成诊断文件，通过系统分享',
                enabled: !_working && (stats?.bytes ?? 0) > 0,
                onTap: _export,
              ),
              Divider(height: 1, indent: 52, color: palette.rowDivider),
              _SettingsActionRow(
                icon: Icons.delete_outline,
                title: '清除诊断日志',
                enabled:
                    !_working &&
                    ((stats?.bytes ?? 0) > 0 ||
                        (stats?.unreadableFileCount ?? 0) > 0 ||
                        (stats?.exportFileCount ?? 0) > 0),
                onTap: _clear,
              ),
            ],
          ),
        ),
        if (_progress != null) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(_progress!, style: TextStyle(color: palette.labelText)),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            '日志仅保存在本机，不会自动上传。'
            '${verbose ? '' : '需要详细诊断时，在「关于」页连续点击版本号 5 次。'}',
            style: TextStyle(color: palette.labelText, fontSize: 12),
          ),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}

List<Map<String, Object?>> _parseLogPreview(String content) {
  final lines = const LineSplitter().convert(content);
  final records = <Map<String, Object?>>[];
  for (final line in lines.reversed) {
    try {
      final record = jsonDecode(line);
      if (record is Map<String, dynamic> &&
          record['level'] is String &&
          record['scope'] is String &&
          record['event'] is String) {
        records.add(record);
      }
    } catch (_) {
      // 损坏的单行跳过，不影响其他诊断事件。
    }
  }
  return records;
}

class _LogPreviewPage extends StatefulWidget {
  const _LogPreviewPage({required this.records, required this.stats});
  final List<Map<String, Object?>> records;
  final LogStoreStats stats;

  @override
  State<_LogPreviewPage> createState() => _LogPreviewPageState();
}

class _LogPreviewPageState extends State<_LogPreviewPage> {
  static final _log = AppLog.logger('app.logging');
  String _level = 'results';
  String? _scope;
  late List<Map<String, Object?>> _records = widget.records;
  late LogStoreStats _stats = widget.stats;
  late List<String> _scopes = _collectScopes(_records);
  bool _refreshing = false;

  static List<String> _collectScopes(List<Map<String, Object?>> records) =>
      records.map((record) => record['scope']! as String).toSet().toList()
        ..sort();

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final preview = await _log.operation('preview.refresh', () async {
        final snapshot = await AppLog.snapshot();
        final records = await compute(_parseLogPreview, snapshot.content);
        return (records: records, stats: snapshot.stats);
      }, successLevel: AppLogLevel.debug);
      if (!mounted) return;
      setState(() {
        _records = preview.records;
        _stats = preview.stats;
        _scopes = _collectScopes(preview.records);
        if (!_scopes.contains(_scope)) _scope = null;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('日志刷新失败，已保留当前内容')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final matching = _records.where((r) {
      if (_scope != null && r['scope'] != _scope) return false;
      return switch (_level) {
        'results' => r['level'] != 'DEBUG',
        'warnings' => ['WARNING', 'ERROR', 'FATAL'].contains(r['level']),
        'errors' => ['ERROR', 'FATAL'].contains(r['level']),
        _ => true,
      };
    });
    final count = matching.length;
    final records = matching.take(300).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        actions: [
          IconButton(
            tooltip: '刷新日志',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '匹配 $count 条 · 显示最近 ${records.length} 条',
                      style: TextStyle(color: palette.labelText),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '最新记录在前，时间已转换为本地时间',
                      style: TextStyle(color: palette.labelText, fontSize: 12),
                    ),
                    if (_stats.unreadableFileCount > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '部分文件不可读，已显示其余可用记录',
                        style: TextStyle(color: palette.labelText),
                      ),
                    ],
                    if (_refreshing) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in {
                          'results': '结果与错误',
                          'all': '全部',
                          'warnings': '警告及以上',
                          'errors': '仅错误',
                        }.entries)
                          FilterChip(
                            label: Text(option.value),
                            selected: _level == option.key,
                            onSelected: (_) =>
                                setState(() => _level = option.key),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey('log_scope:$_scope'),
                      initialValue: _scope,
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: '模块',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('所有模块'),
                        ),
                        for (final scope in _scopes)
                          DropdownMenuItem(
                            value: scope,
                            child: Text(scope, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (value) => setState(() => _scope = value),
                    ),
                  ],
                ),
              ),
            ),
            if (records.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('没有符合条件的日志')),
                ),
              )
            else
              SliverList.builder(
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  final level = record['level'] as String;
                  final at = DateTime.tryParse('${record['ts']}')?.toLocal();
                  final time = at == null ? '' : _formatLogTime(at);
                  final attrs = record['attrs'] as Map?;
                  final stack = attrs?['stack_trace'] as String?;
                  return ExpansionTile(
                    key: PageStorageKey(
                      '${record['session_id']}:${record['seq']}:${record['ts']}',
                    ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _LogLevelBadge(level: level),
                            Text(
                              time,
                              style: TextStyle(
                                color: palette.labelText,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppLog.formatSummary(record),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(height: 1.5),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      '${record['scope']}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        AppLog.formatDetails(record),
                        key: PageStorageKey(
                          '${record['session_id']}:${record['seq']}:summary',
                        ),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.5,
                          color: palette.titleText,
                        ),
                      ),
                      if (stack != null) ...[
                        const SizedBox(height: 12),
                        const Text('调用堆栈'),
                        const SizedBox(height: 4),
                        SelectableText(
                          stack,
                          key: PageStorageKey(
                            '${record['session_id']}:${record['seq']}:stack',
                          ),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                            color: palette.titleText,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _formatLogTime(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}.'
        '${at.millisecond.toString().padLeft(3, '0')}';
  }
}

class _LogLevelBadge extends StatelessWidget {
  const _LogLevelBadge({required this.level});
  final String level;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final label =
        const {
          'DEBUG': '调试',
          'INFO': '信息',
          'WARNING': '警告',
          'ERROR': '错误',
          'FATAL': '严重',
        }[level] ??
        level;
    final color = switch (level) {
      'ERROR' || 'FATAL' => palette.danger,
      'WARNING' => palette.warning,
      _ => palette.accent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: palette.titleText,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  const _SettingsActionRow({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, color: enabled ? palette.accent : palette.hint),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right),
      onTap: enabled ? onTap : null,
    );
  }
}

/// 单选行：文字 + 选中时右侧对勾。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.showDivider,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: palette.titleText,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check, color: palette.accent, size: 20),
                  ],
                ),
              ),
            ),
            if (showDivider)
              Divider(height: 1, indent: 16, color: palette.rowDivider),
          ],
        ),
      ),
    );
  }
}
