import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import 'timetable_controller.dart';
import 'timetable_export_page.dart';
import 'timetable_import_page.dart';
import 'timetable_multi_models.dart';
import 'timetable_persistence_feedback.dart';
import 'timetable_theme.dart';

/// 弹出周数与多课表切换弹窗：可选周次并管理「我的课表（本学期/往年）」与「导入的课表」。
Future<void> showTimetableSwitcherSheet(
  BuildContext context, {
  TimetableController? controller,
  int? totalWeeks,
  int? currentWeek,
  int? selectedWeek,
  ValueChanged<int>? onSelectWeek,
}) {
  final host = controller ?? TimetableController.instance;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black38,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => _TimetableSwitcherSheet(
      controller: host,
      totalWeeks: totalWeeks,
      currentWeek: currentWeek,
      selectedWeek: selectedWeek,
      onSelectWeek: onSelectWeek,
    ),
  );
}

/// 弹出重命名课表对话框，保留自定义名称不被后续教务同步覆盖。
Future<void> showRenameScheduleDialog(
  BuildContext context, {
  required TimetableController controller,
  required ScheduleMetadata meta,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _RenameScheduleDialog(controller: controller, meta: meta),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      AppSnackBar(
        tone: AppSnackBarTone.success,
        content: const Text('已更新课表名称'),
      ),
    );
  }
}

class _RenameScheduleDialog extends StatefulWidget {
  const _RenameScheduleDialog({required this.controller, required this.meta});

  final TimetableController controller;
  final ScheduleMetadata meta;

  @override
  State<_RenameScheduleDialog> createState() => _RenameScheduleDialogState();
}

class _RenameScheduleDialogState extends State<_RenameScheduleDialog> {
  late final _textCtrl = TextEditingController(text: widget.meta.name);
  String? _error;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('tt_rename_schedule_dialog'),
      title: const Text('重命名课表'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('tt_rename_schedule_input'),
            controller: _textCtrl,
            autofocus: true,
            maxLength: 24,
            decoration: const InputDecoration(
              labelText: '课表名称',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            TimetablePersistenceErrorText(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('tt_rename_schedule_confirm'),
          onPressed: () async {
            final nextName = _textCtrl.text.trim();
            if (nextName.isEmpty) {
              setState(() => _error = '名称不能为空');
              return;
            }
            final navigator = Navigator.of(context);
            final ok = await withTimetablePersistenceFeedback<bool>(
              context,
              () async {
                await widget.controller.renameSchedule(
                  widget.meta.id,
                  nextName,
                );
                return true;
              },
              onError: (msg) => setState(() => _error = msg),
            );
            if (ok == true && mounted) navigator.pop(true);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _TimetableSwitcherSheet extends StatelessWidget {
  const _TimetableSwitcherSheet({
    required this.controller,
    this.totalWeeks,
    this.currentWeek,
    this.selectedWeek,
    this.onSelectWeek,
  });

  final TimetableController controller;
  final int? totalWeeks;
  final int? currentWeek;
  final int? selectedWeek;
  final ValueChanged<int>? onSelectWeek;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final hasWeeks =
        onSelectWeek != null &&
        totalWeeks != null &&
        currentWeek != null &&
        selectedWeek != null &&
        totalWeeks! > 0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hasWeeks ? '切换周数与课表' : '切换课表',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: palette.titleText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasWeeks) ...[
                        _WeekChipStrip(
                          total: totalWeeks!,
                          current: currentWeek!,
                          selected: selectedWeek!,
                          onSlideWeek: onSelectWeek!,
                          onSelect: (w) {
                            Navigator.of(context).pop();
                            onSelectWeek!(w);
                          },
                        ),
                        Divider(
                          height: 16,
                          indent: 12,
                          endIndent: 12,
                          color: palette.divider,
                        ),
                      ],
                      TimetableSwitcherContent(
                        controller: controller,
                        onClosePanel: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekChipStrip extends StatefulWidget {
  const _WeekChipStrip({
    required this.total,
    required this.current,
    required this.selected,
    required this.onSlideWeek,
    required this.onSelect,
  });

  final int total;
  final int current;
  final int selected;
  final ValueChanged<int> onSlideWeek;
  final ValueChanged<int> onSelect;

  @override
  State<_WeekChipStrip> createState() => _WeekChipStripState();
}

class _WeekChipStripState extends State<_WeekChipStrip> {
  late int _draftWeek = widget.selected.clamp(1, math.max(1, widget.total));

  @override
  void didUpdateWidget(covariant _WeekChipStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        oldWidget.total != widget.total) {
      _draftWeek = widget.selected.clamp(1, math.max(1, widget.total));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final palette = AppPalette.of(context);
    final total = math.max(1, widget.total);
    final hasCurrent = widget.current >= 1 && widget.current <= total;
    final isDraftCurrent = hasCurrent && _draftWeek == widget.current;

    return Column(
      key: const Key('timetable_week_strip'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
          child: Row(
            children: [
              Text(
                '切换周数',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.titleText,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$_draftWeek/$total 周',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.accent,
                  ),
                ),
              ),
              if (hasCurrent)
                Semantics(
                  button: true,
                  selected: isDraftCurrent,
                  excludeSemantics: true,
                  label: '第 ${widget.current} 周，本周',
                  child: Material(
                    color: isDraftCurrent
                        ? colors.accent.withValues(alpha: 0.14)
                        : colors.chipBg,
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: colors.accent.withValues(
                          alpha: isDraftCurrent ? 0.9 : 0.45,
                        ),
                      ),
                    ),
                    child: InkWell(
                      key: const Key('timetable_week_strip_current'),
                      customBorder: const StadiumBorder(),
                      onTap: () => widget.onSelect(widget.current),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        child: Text(
                          '本周',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '1',
                  style: TextStyle(fontSize: 11, color: palette.hint),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16,
                    ),
                    activeTrackColor: colors.accent,
                    inactiveTrackColor: colors.chipBg,
                    thumbColor: colors.accent,
                    valueIndicatorColor: colors.accent,
                    valueIndicatorTextStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Slider(
                    key: const Key('timetable_week_slider'),
                    min: 1,
                    max: total.toDouble(),
                    divisions: total > 1 ? total - 1 : null,
                    value: _draftWeek.toDouble(),
                    label: '$_draftWeek 周',
                    onChanged: total > 1
                        ? (v) => setState(() => _draftWeek = v.round())
                        : null,
                    onChangeEnd: total > 1
                        ? (v) {
                            final target = v.round();
                            if (_draftWeek != target) {
                              setState(() => _draftWeek = target);
                            }
                            widget.onSlideWeek(target);
                          }
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '$total',
                  style: TextStyle(fontSize: 11, color: palette.hint),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可嵌入顶部展开面板或底部弹层的多课表列表（我的课表 + 导入的课表 + 导入口令）。
class TimetableSwitcherContent extends StatefulWidget {
  const TimetableSwitcherContent({
    super.key,
    required this.controller,
    this.onClosePanel,
  });

  final TimetableController controller;
  final VoidCallback? onClosePanel;

  @override
  State<TimetableSwitcherContent> createState() =>
      _TimetableSwitcherContentState();
}

class _TimetableSwitcherContentState extends State<TimetableSwitcherContent> {
  bool _resyncingOwn = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller.portalBound &&
        !widget.controller.historicalDiscoveryAttempted) {
      unawaited(widget.controller.triggerHistoricalDiscoveryIfNeeded());
    }
  }

  Future<void> _resyncAllOwn() async {
    if (_resyncingOwn) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!await widget.controller.refreshPortalBound()) {
      if (!mounted) return;
      messenger.showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.info,
          content: const Text('请先绑定统一门户后再重新拉取'),
        ),
      );
      return;
    }
    setState(() => _resyncingOwn = true);
    try {
      await widget.controller.manualSync();
      await widget.controller.discoverHistoricalTerms(forceRescan: true);
      if (!mounted) return;
      messenger.showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.success,
          content: const Text('已重新拉取我的课表'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        AppSnackBar(tone: AppSnackBarTone.warning, content: Text('重新拉取失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _resyncingOwn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = AppPalette.of(context);
    return ListenableBuilder(
      key: const Key('tt_switcher_sheet'),
      listenable: controller,
      builder: (context, _) {
        final own = controller.ownSchedules;
        final imported = controller.importedSchedules;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '我的课表',
              subtitle: '当前与往年教务课表',
              palette: palette,
              trailing: TextButton.icon(
                key: const Key('tt_switcher_resync_own'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _resyncingOwn ? null : _resyncAllOwn,
                icon: _resyncingOwn
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('重新拉取', style: TextStyle(fontSize: 12)),
              ),
            ),
            for (final meta in own)
              _ScheduleItemTile(
                meta: meta,
                controller: controller,
                onClosePanel: widget.onClosePanel,
                onSelect: () async {
                  await controller.switchViewingSchedule(meta.id);
                  if (context.mounted) widget.onClosePanel?.call();
                },
              ),
            const SizedBox(height: 8),
            _SectionHeader(
              title: '导入的课表',
              subtitle: '通过口令导入，仅保存在本地',
              palette: palette,
            ),
            if (imported.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  '暂无导入的课表，可通过口令导入其他课表',
                  style: TextStyle(fontSize: 12, color: palette.hint),
                ),
              )
            else
              for (final meta in imported)
                _ScheduleItemTile(
                  meta: meta,
                  controller: controller,
                  onClosePanel: widget.onClosePanel,
                  onSelect: () async {
                    await controller.switchViewingSchedule(meta.id);
                    if (context.mounted) widget.onClosePanel?.call();
                  },
                ),
            ListTile(
              key: const Key('tt_switcher_import_wakeup'),
              dense: true,
              leading: Icon(
                Icons.file_download_outlined,
                color: palette.accent,
              ),
              title: Text(
                '从口令导入',
                style: TextStyle(
                  color: palette.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '粘贴分享文案或 32 位口令（兼容 WakeUp）',
                style: TextStyle(fontSize: 12, color: palette.hint),
              ),
              onTap: () async {
                final nav = Navigator.of(context);
                widget.onClosePanel?.call();
                await nav.push(
                  MaterialPageRoute<void>(
                    builder: (_) => TimetableImportPage(controller: controller),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.palette,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final AppPalette palette;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.titleText,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.hint),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _ScheduleItemTile extends StatelessWidget {
  const _ScheduleItemTile({
    required this.meta,
    required this.controller,
    required this.onSelect,
    this.onClosePanel,
  });

  final ScheduleMetadata meta;
  final TimetableController controller;
  final VoidCallback onSelect;
  final VoidCallback? onClosePanel;

  Future<void> _resyncOne(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await controller.refreshPortalBound()) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.info,
          content: const Text('请先绑定统一门户后再重新拉取'),
        ),
      );
      return;
    }
    try {
      final isCurrent =
          meta.id == kDefaultScheduleId ||
          (meta.termCode.isNotEmpty &&
              meta.termCode == controller.currentTermCode);
      if (isCurrent) {
        await controller.manualSync();
      } else if (meta.termCode.isNotEmpty) {
        await controller.syncHistoricalTerm(meta.termCode);
      }
      if (!context.mounted) return;
      messenger.showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.success,
          content: Text('已重新拉取「${meta.name}」'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        AppSnackBar(tone: AppSnackBarTone.warning, content: Text('重新拉取失败：$e')),
      );
    }
  }

  Future<void> _exportWakeup(BuildContext context) async {
    final nav = Navigator.of(context);
    final targetController = await controller.controllerForSchedule(meta.id);
    if (!nav.mounted) return;
    onClosePanel?.call();
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => TimetableExportPage(controller: targetController),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isPrimary = controller.primaryScheduleId == meta.id;
    final isViewing = controller.viewingScheduleId == meta.id;
    final isHistory = controller.isHistoricalSchedule(meta.id);
    final tags = <String>[
      if (isPrimary) '主课表',
      if (meta.isImportedSchedule)
        '口令导入'
      else if (isHistory)
        '往年'
      else if (meta.id == kDefaultScheduleId)
        '本学期',
    ];
    final subtitleParts = <String>[
      if (meta.termCode.isNotEmpty && meta.termCode != meta.name) meta.termCode,
      if (meta.courseCount != null) '${meta.courseCount} 门课程',
    ];

    return ListTile(
      key: Key('tt_schedule_item_${meta.id}'),
      selected: isViewing,
      selectedTileColor: palette.accent.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(
        isViewing ? Icons.radio_button_checked : Icons.calendar_today_outlined,
        size: 20,
        color: isViewing ? palette.accent : palette.hint,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              meta.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isViewing ? FontWeight.w600 : FontWeight.w500,
                color: palette.titleText,
              ),
            ),
          ),
          for (final tag in tags) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: tag == '主课表'
                    ? palette.accent.withValues(alpha: 0.14)
                    : palette.divider.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: tag == '主课表' ? palette.accent : palette.labelText,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: subtitleParts.isEmpty
          ? null
          : Text(
              subtitleParts.join(' · '),
              style: TextStyle(fontSize: 12, color: palette.hint),
            ),
      trailing: PopupMenuButton<String>(
        key: Key('tt_schedule_menu_${meta.id}'),
        tooltip: '课表操作',
        onSelected: (action) async {
          switch (action) {
            case 'primary':
              await withTimetablePersistenceFeedback(
                context,
                () => controller.setPrimarySchedule(meta.id),
              );
            case 'resync':
              await _resyncOne(context);
            case 'export':
              await _exportWakeup(context);
            case 'rename':
              await showRenameScheduleDialog(
                context,
                controller: controller,
                meta: meta,
              );
            case 'delete':
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  key: const Key('tt_delete_schedule_dialog'),
                  title: const Text('删除课表'),
                  content: Text('确定删除「${meta.name}」？本地数据将一并清除。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      key: const Key('tt_delete_schedule_confirm'),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(
                        '删除',
                        style: TextStyle(color: palette.danger),
                      ),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !context.mounted) return;
              final ok = await withTimetablePersistenceFeedback(
                context,
                () => controller.deleteSchedule(meta.id),
              );
              if (ok == true && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  AppSnackBar(
                    tone: AppSnackBarTone.info,
                    content: Text('已删除「${meta.name}」'),
                  ),
                );
              }
          }
        },
        itemBuilder: (_) => [
          if (!isPrimary)
            const PopupMenuItem(value: 'primary', child: Text('设为主课表')),
          if (meta.isOwnSchedule)
            const PopupMenuItem(value: 'resync', child: Text('重新拉取')),
          const PopupMenuItem(value: 'export', child: Text('导出到 WakeUp')),
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
          if (meta.isImportedSchedule)
            const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: onSelect,
    );
  }
}
