import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import 'sunshine_run_controller.dart';
import 'sunshine_run_models.dart';

part 'sunshine_run_dialogs.dart';

/// 阳光跑原生计算器：活动场次与已有次数独立保存，明暗随应用主题变化。
class SunshineRunPage extends StatefulWidget {
  const SunshineRunPage({super.key, this.controller});

  /// 测试可注入独立状态，不接触真实个人信息和本地记录。
  final SunshineRunController? controller;

  @override
  State<SunshineRunPage> createState() => _SunshineRunPageState();
}

class _SunshineRunPageState extends State<SunshineRunPage> {
  static final _log = AppLog.logger('sunshine_run.page');
  late final _controller = widget.controller ?? SunshineRunController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.ensureStarted());
  }

  void _feedback(String message, {bool undo = true, bool failed = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      AppSnackBar(
        content: Text(message),
        tone: failed ? AppSnackBarTone.warning : AppSnackBarTone.info,
        duration: const Duration(milliseconds: 5500),
        persist: false,
        action: undo && _controller.canUndo
            ? SnackBarAction(
                label: '撤销',
                onPressed: () => unawaited(
                  _perform(_controller.undo, '已撤销上一步', undo: false),
                ),
              )
            : null,
      ),
    );
  }

  Future<void> _perform(
    Future<bool> Function() action,
    String message, {
    bool undo = true,
    bool feedback = true,
  }) async {
    try {
      final saved = await action();
      if (!mounted) return;
      if (feedback) {
        _feedback(
          saved ? message : '修改已用于当前计算，但本次未保存。',
          undo: undo,
          failed: !saved,
        );
      }
    } on FormatException catch (error) {
      _feedback(error.message, undo: false, failed: true);
    } catch (error, stackTrace) {
      _log.warning('edit_failed', error: error, stackTrace: stackTrace);
      _feedback('暂时无法更新，请重试。', undo: false, failed: true);
    }
  }

  Future<void> _editBaseline() async {
    final next = await showDialog<SunshineRunState>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _CountEditor(state: _controller.state),
    );
    if (next == null || !mounted) return;
    await _perform(
      () => _controller.setBaseline(next.baseTotal, next.baseMorning),
      '已更新已有次数',
    );
  }

  Future<void> _editCount(
    SunshineRunActivity activity, {
    SunshineRunCustomActivity? custom,
  }) async {
    final next = await showDialog<SunshineRunState>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _CountEditor(
        state: _controller.state,
        activity: activity,
        custom: custom,
      ),
    );
    if (next == null || !mounted) return;
    final count = custom == null
        ? next.activities[activity.id]!
        : next.customActivities.firstWhere((a) => a.id == custom.id).count;
    await _perform(
      () => custom == null
          ? _controller.setActivityCount(activity.id, count)
          : _controller.setCustomCount(custom.id, count),
      '${activity.label}已设为 $count 场',
    );
  }

  Future<void> _editCustom([SunshineRunCustomActivity? custom]) async {
    final next = await showDialog<SunshineRunCustomActivity>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _CustomEditor(state: _controller.state, initial: custom),
    );
    if (next == null || !mounted) return;
    await _perform(
      () => _controller.saveCustomActivity(
        id: custom?.id,
        label: next.label,
        total: next.total,
        morning: next.morning,
        count: next.count,
      ),
      custom == null ? '已添加「${next.label}」' : '已更新「${next.label}」',
    );
  }

  void _step(
    SunshineRunActivity activity,
    int delta, {
    String? customId,
    bool recordUndo = true,
    bool feedback = true,
  }) {
    final state = _controller.state;
    final current = customId == null
        ? state.activities[activity.id]!
        : state.customActivities.firstWhere((a) => a.id == customId).count;
    final count = current + delta;
    if (count < 0) return;
    unawaited(
      _perform(
        () => customId == null
            ? _controller.adjustActivityCount(
                activity.id,
                delta,
                recordUndo: recordUndo,
              )
            : _controller.adjustCustomCount(
                customId,
                delta,
                recordUndo: recordUndo,
              ),
        '${activity.label} ${delta > 0 ? '+' : '−'}${delta.abs()} 场',
        feedback: feedback,
      ),
    );
  }

  Future<void> _reset() async {
    final action = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _ResetDialog(state: _controller.state),
    );
    if (action == null || !mounted) return;
    await _perform(
      action == 'activities'
          ? _controller.resetActivities
          : _controller.resetAll,
      action == 'activities' ? '已清空新增活动场次' : '已清空全部跑步记录',
    );
  }

  Widget _activityRow(
    SunshineRunActivity activity,
    int count, {
    SunshineRunCustomActivity? custom,
  }) => _ActivityRow(
    activity: activity,
    count: count,
    custom: custom != null,
    onEditCount: () => _editCount(activity, custom: custom),
    onEdit: custom == null ? null : () => _editCustom(custom),
    onRemove: custom == null
        ? null
        : () => _perform(
            () => _controller.removeCustomActivity(custom.id),
            '已删除「${custom.label}」',
          ),
    onStep: (delta, recordUndo, feedback) => _step(
      activity,
      delta,
      customId: custom?.id,
      recordUndo: recordUndo,
      feedback: feedback,
    ),
    onRepeatEnd: () {
      _controller.finishActivityAdjustment();
      _feedback(
        _controller.storageWarning == null
            ? '已更新${activity.label}场次'
            : '修改已用于当前计算，当前记录尚未保存。',
        failed: _controller.storageWarning != null,
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;
        final result = _controller.result;
        final canReset =
            !_controller.restoringState &&
            (result.total > 0 ||
                state.customActivities.isNotEmpty ||
                state.exemption != SunshineRunExemption.none);
        final compact =
            MediaQuery.sizeOf(context).width < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 19;
        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                _UndoRunIntent(),
            SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                _UndoRunIntent(),
          },
          child: Actions(
            actions: {
              _UndoRunIntent: CallbackAction<_UndoRunIntent>(
                onInvoke: (_) {
                  if (!_controller.restoringState &&
                      _controller.canUndo &&
                      (ModalRoute.of(context)?.isCurrent ?? false)) {
                    unawaited(
                      _perform(_controller.undo, '已撤销上一步', undo: false),
                    );
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: palette.pageBg,
                appBar: AppBar(
                  title: const Text('阳光跑计算器'),
                  centerTitle: false,
                  titleSpacing: 0,
                  actions: [
                    if (compact) ...[
                      IconButton(
                        tooltip: '重置记录',
                        onPressed: canReset ? _reset : null,
                        icon: const Icon(Icons.restart_alt_rounded, size: 21),
                      ),
                      IconButton(
                        tooltip: '计算规则',
                        onPressed: () => showDialog<void>(
                          context: context,
                          useRootNavigator: false,
                          builder: (_) => _RulesDialog(state: state),
                        ),
                        icon: Icon(
                          Icons.info_outline_rounded,
                          color: colors.action,
                          size: 21,
                        ),
                      ),
                    ] else ...[
                      TextButton.icon(
                        onPressed: canReset ? _reset : null,
                        icon: const Icon(Icons.restart_alt_rounded, size: 16),
                        label: const Text('重置'),
                        style: TextButton.styleFrom(
                          foregroundColor: palette.labelText,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          useRootNavigator: false,
                          builder: (_) => _RulesDialog(state: state),
                        ),
                        icon: const Icon(Icons.info_outline_rounded, size: 16),
                        label: const Text('规则'),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.action,
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                  ],
                ),
                body: SafeArea(
                  top: false,
                  child: IgnorePointer(
                    ignoring: _controller.restoringState,
                    child: ListView(
                      key: const PageStorageKey('sunshine-run-scroll'),
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                      children: [
                        if (_controller.restoringState) ...[
                          Text(
                            '正在恢复本机记录…',
                            style: TextStyle(fontSize: 12, color: colors.hint),
                          ),
                          const SizedBox(height: 12),
                        ],
                        _GradeBar(controller: _controller),
                        const SizedBox(height: 12),
                        if (_controller.storageWarning case final warning?) ...[
                          _StorageWarning(
                            message: warning,
                            corrupt: _controller.storageCorrupt,
                            onRetry: () => _perform(
                              _controller.retrySave,
                              '已保存当前记录',
                              undo: false,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        _RunSummary(
                          state: state,
                          result: result,
                          onEditBaseline: _editBaseline,
                        ),
                        const SizedBox(height: 12),
                        _RunCard(
                          child: Column(
                            children: [
                              const _SectionHeading(
                                title: '活动计数',
                                note: '点击数字可直接输入，长按 ± 连续增减',
                              ),
                              for (final activity in kSunshineRunActivities)
                                _activityRow(
                                  activity,
                                  state.activities[activity.id]!,
                                ),
                              for (final custom in state.customActivities)
                                _activityRow(
                                  SunshineRunActivity(
                                    id: custom.id,
                                    label: custom.label,
                                    total: custom.total,
                                    morning: custom.morning,
                                  ),
                                  custom.count,
                                  custom: custom,
                                ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  2,
                                  16,
                                  14,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: _editCustom,
                                    icon: const Icon(
                                      Icons.add_rounded,
                                      size: 18,
                                    ),
                                    label: const Text(
                                      '添加其他活动（自定义总次数与晨跑）',
                                      textAlign: TextAlign.center,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: colors.action,
                                      backgroundColor: colors.accentSoft,
                                      side: BorderSide(
                                        color: palette.accent.withValues(
                                          alpha: 0.35,
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      textStyle: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ExemptionCard(
                          state: state,
                          onChanged: (value) => _perform(
                            () => _controller.toggleExemption(value),
                            state.exemption == value
                                ? '已取消减免'
                                : '已设置${value == SunshineRunExemption.half ? '半免' : '全免'}',
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 14,
                              color: colors.hint,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _controller.storageWarning == null
                                    ? '记录自动保存在本机'
                                    : '当前记录尚未保存',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.hint,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UndoRunIntent extends Intent {
  const _UndoRunIntent();
}

/// 从应用色板派生小字号操作色和柔和背景，避免局部假定浅色。
class _RunColors {
  _RunColors(this.palette);
  final AppPalette palette;
  Color get action => appSnackBarActionColor(palette);
  Color get hint => Color.lerp(palette.hint, palette.labelText, 0.38)!;
  Color get sun => Color.lerp(
    palette.warning,
    palette.titleText,
    palette.isDark ? 0.18 : 0.3,
  )!;
  Color get success => Color.lerp(
    palette.success,
    palette.titleText,
    palette.isDark ? 0.3 : 0.36,
  )!;
  Color get danger => Color.lerp(
    palette.danger,
    palette.titleText,
    palette.isDark ? 0.15 : 0.2,
  )!;
  Color get accentSoft => Color.alphaBlend(
    palette.accent.withValues(alpha: palette.isDark ? 0.14 : 0.09),
    palette.surface,
  );
  Color get sunSoft => Color.alphaBlend(
    palette.warning.withValues(alpha: palette.isDark ? 0.14 : 0.1),
    palette.surface,
  );
  Color get successSoft => Color.alphaBlend(
    palette.success.withValues(alpha: palette.isDark ? 0.12 : 0.08),
    palette.surface,
  );
  Color get dangerSoft => Color.alphaBlend(
    palette.danger.withValues(alpha: palette.isDark ? 0.14 : 0.08),
    palette.surface,
  );
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.divider),
      ),
      child: child,
    );
  }
}

class _GradeBar extends StatelessWidget {
  const _GradeBar({required this.controller});
  final SunshineRunController controller;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final result = controller.result;
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '当前年级',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: palette.titleText,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          result.status == SunshineRunStatus.exempt
              ? '当前已全免 · 无需完成跑步'
              : '满分 ${result.fullTotal} 次 · 晨跑 ${result.requiredMorning} 次',
          style: TextStyle(fontSize: 12, color: colors.hint),
        ),
        if (controller.gradeMessage case final message?) ...[
          const SizedBox(height: 3),
          Text(
            message,
            key: const ValueKey('sunshine-grade-source'),
            style: TextStyle(fontSize: 11, color: colors.hint),
          ),
        ],
      ],
    );
    final select = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ChoiceGroup<int>(
          values: const [1, 2],
          selected: controller.state.grade,
          labels: const ['大一', '大二'],
          onChanged: (grade) => unawaited(controller.setGrade(grade)),
          label: '选择年级',
        ),
        IconButton(
          tooltip: '重新识别年级',
          onPressed: controller.identifyingGrade
              ? null
              : controller.identifyGrade,
          icon: Icon(Icons.sync_rounded, size: 18, color: colors.hint),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
          padding: const EdgeInsets.all(8),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 350 ||
            MediaQuery.textScalerOf(context).scale(14) > 19) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              meta,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: select),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: meta),
            const SizedBox(width: 8),
            select,
          ],
        );
      },
    );
  }
}

class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.values,
    required this.selected,
    required this.labels,
    required this.onChanged,
    required this.label,
    this.exemption = false,
  });
  final List<T> values;
  final T? selected;
  final List<String> labels;
  final ValueChanged<T> onChanged;
  final String label;
  final bool exemption;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: palette.rowDivider,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.divider),
        ),
        child: Row(
          mainAxisSize: exemption ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var index = 0; index < values.length; index++) ...[
              if (index > 0) const SizedBox(width: 3),
              if (exemption)
                Expanded(child: _button(context, index, palette, colors))
              else
                _button(context, index, palette, colors),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(
    BuildContext context,
    int index,
    AppPalette palette,
    _RunColors colors,
  ) {
    final active = values[index] == selected;
    final color = exemption && active
        ? (palette.isDark ? palette.titleText : palette.surface)
        : active
        ? colors.action
        : palette.labelText;
    final button = TextButton(
      onPressed: () => onChanged(values[index]),
      style: TextButton.styleFrom(
        foregroundColor: color,
        backgroundColor: active && !exemption ? palette.surface : null,
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: TextStyle(
          fontSize: 13,
          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      child: Text(labels[index], textAlign: TextAlign.center),
    );
    final base = values[index] == SunshineRunExemption.half
        ? palette.warning
        : palette.accent;
    return Semantics(
      selected: active,
      child: exemption && active
          ? DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(
                      base,
                      palette.titleText,
                      palette.isDark ? 0 : 0.12,
                    )!,
                    Color.lerp(
                      base,
                      palette.isDark ? palette.pageBg : palette.titleText,
                      palette.isDark ? 0.25 : 0.36,
                    )!,
                  ],
                ),
              ),
              child: button,
            )
          : button,
    );
  }
}

class _StorageWarning extends StatelessWidget {
  const _StorageWarning({
    required this.message,
    required this.corrupt,
    required this.onRetry,
  });
  final String message;
  final bool corrupt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = _RunColors(AppPalette.of(context));
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        decoration: BoxDecoration(
          color: colors.dangerSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.danger),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(fontSize: 12, color: colors.danger, height: 1.5),
            ),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              child: Text(corrupt ? '用当前记录替换' : '重试保存'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunSummary extends StatelessWidget {
  const _RunSummary({
    required this.state,
    required this.result,
    required this.onEditBaseline,
  });
  final SunshineRunState state;
  final SunshineRunResult result;
  final VoidCallback onEditBaseline;

  String get _detail {
    switch (result.status) {
      case SunshineRunStatus.exempt:
        return '无需跑步，已录入的记录继续保留';
      case SunshineRunStatus.full:
        final extra = result.total - result.fullTotal;
        return extra > 0 ? '总次数与晨跑均已满足满分（超出 $extra 次）' : '总次数与晨跑均已满足满分要求';
      case SunshineRunStatus.passed:
        return '距满分还差 ${result.remainingFullTotal} 次总次数';
      case SunshineRunStatus.incomplete:
        if (result.total >= result.fullTotal) {
          return '总次数已满，还差 ${result.remainingMorning} 次晨跑即可满分';
        }
        final gaps = [
          if (result.remainingPassingTotal > 0)
            '总次数 ${result.remainingPassingTotal} 次',
          if (result.remainingMorning > 0) '晨跑 ${result.remainingMorning} 次',
        ];
        return '距达标还差 ${gaps.join('、')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final exempt = result.status == SunshineRunStatus.exempt;
    final morningMet = result.morning >= result.requiredMorning;
    final (statusText, statusColor, statusBg) = switch (result.status) {
      SunshineRunStatus.incomplete => ('未达标', colors.sun, colors.sunSoft),
      SunshineRunStatus.passed => ('已达标', colors.success, colors.successSoft),
      SunshineRunStatus.full => ('已满分', colors.action, colors.accentSoft),
      SunshineRunStatus.exempt => ('已全免', colors.action, colors.accentSoft),
    };
    final numberSize =
        (48 - (result.total.toString().length - 3).clamp(0, 8) * 3).toDouble();
    return _RunCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  '累计总次数',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.labelText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('sunshine-edit-baseline'),
                  onPressed: onEditBaseline,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: Text(
                    state.baseTotal > 0 ? '已有 ${state.baseTotal} 次' : '录入已有次数',
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.action,
                    backgroundColor: colors.accentSoft,
                    side: state.baseTotal > 0
                        ? BorderSide(color: palette.accent)
                        : null,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final metric = Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${result.total}',
                        style: TextStyle(
                          fontSize: numberSize,
                          color: palette.titleText,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      TextSpan(
                        text: exempt ? ' 次 · 已免跑' : ' / ${result.fullTotal} 次',
                        style: TextStyle(
                          fontSize: 15,
                          color: colors.hint,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                  key: const ValueKey('sunshine-total'),
                );
                final percentage = Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${result.percentage}%',
                      key: const ValueKey('sunshine-percentage'),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: result.status == SunshineRunStatus.passed
                            ? colors.success
                            : colors.action,
                      ),
                    ),
                    Text(
                      exempt ? '免跑完成度' : '总次数完成率',
                      style: TextStyle(fontSize: 11, color: colors.hint),
                    ),
                  ],
                );
                if (MediaQuery.textScalerOf(context).scale(14) > 19 ||
                    result.total.toString().length > 6) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      metric,
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: percentage,
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: metric),
                    const SizedBox(width: 8),
                    percentage,
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            _ProgressTrack(
              percentage: result.percentage,
              color: result.status == SunshineRunStatus.passed
                  ? colors.success
                  : palette.accent,
              label: exempt ? '免跑完成度' : '总次数完成率',
              marker: !exempt && result.passingTotal != null
                  ? result.passingTotal! / result.fullTotal
                  : null,
            ),
            if (!exempt) ...[
              const SizedBox(height: 5),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                runSpacing: 3,
                children: [
                  Text('0', style: TextStyle(fontSize: 11, color: colors.hint)),
                  Text(
                    result.passingTotal == null
                        ? '达标仅看晨跑'
                        : '达标线 ${result.passingTotal} 次',
                    style: TextStyle(fontSize: 11, color: palette.labelText),
                  ),
                  Text(
                    '满分 ${result.fullTotal} 次',
                    style: TextStyle(fontSize: 11, color: colors.hint),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 5,
                  children: [
                    _Pill(
                      label: statusText,
                      color: statusColor,
                      background: palette.surface,
                    ),
                    Text(
                      _detail,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Divider(height: 1, color: palette.rowDivider),
            const SizedBox(height: 13),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wb_twilight_rounded,
                      size: 18,
                      color: colors.sun,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '其中晨跑',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: palette.labelText,
                      ),
                    ),
                  ],
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${result.morning}',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: palette.titleText,
                        ),
                      ),
                      TextSpan(
                        text: exempt
                            ? ' 次 · 无需晨跑'
                            : ' / ${result.requiredMorning} 次',
                        style: TextStyle(fontSize: 12, color: colors.hint),
                      ),
                    ],
                  ),
                  key: const ValueKey('sunshine-morning'),
                ),
                _Pill(
                  label: exempt
                      ? '已免跑'
                      : morningMet
                      ? '已达标'
                      : '差 ${result.remainingMorning} 次',
                  color: exempt
                      ? colors.action
                      : morningMet
                      ? colors.success
                      : colors.sun,
                  background: exempt
                      ? colors.accentSoft
                      : morningMet
                      ? colors.successSoft
                      : colors.sunSoft,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ProgressTrack(
              percentage: result.morningPercentage,
              color: exempt
                  ? palette.accent
                  : morningMet
                  ? colors.success
                  : colors.sun,
              label: '晨跑完成率',
              height: 6,
            ),
            const SizedBox(height: 9),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 3,
              children: [
                Text(
                  result.total > 0
                      ? '已有 ${state.baseTotal} 次 + 新增 ${result.addedTotal} 次'
                      : '晨跑已计入总次数',
                  style: TextStyle(fontSize: 12, color: colors.hint),
                ),
                if (result.total > 0)
                  Text(
                    result.addedMorning > 0
                        ? '新增含晨跑 ${result.addedMorning} 次'
                        : '晨跑已计入总次数',
                    style: TextStyle(fontSize: 12, color: colors.hint),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({
    required this.percentage,
    required this.color,
    required this.label,
    this.height = 9,
    this.marker,
  });
  final int percentage;
  final Color color;
  final String label;
  final double height;
  final double? marker;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Semantics(
      label: label,
      value: '$percentage%',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) => ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: palette.rowDivider)),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: percentage / 100),
                    duration: const Duration(milliseconds: 220),
                    builder: (context, value, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: value,
                        heightFactor: 1,
                        child: ColoredBox(color: color),
                      ),
                    ),
                  ),
                  if (marker case final marker?)
                    Positioned(
                      left:
                          (constraints.maxWidth * marker).clamp(
                            1,
                            constraints.maxWidth - 2,
                          ) -
                          1,
                      width: 2,
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surface,
                          border: Border.symmetric(
                            vertical: BorderSide(
                              color: palette.divider,
                              width: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.color,
    required this.background,
  });
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.note});
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.rowDivider)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.titleText,
            ),
          ),
          Text(
            note,
            style: TextStyle(fontSize: 12, color: _RunColors(palette).hint),
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.activity,
    required this.count,
    required this.custom,
    required this.onEditCount,
    required this.onStep,
    required this.onRepeatEnd,
    this.onEdit,
    this.onRemove,
  });
  final SunshineRunActivity activity;
  final int count;
  final bool custom;
  final VoidCallback onEditCount;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;
  final void Function(int delta, bool recordUndo, bool feedback) onStep;
  final VoidCallback onRepeatEnd;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final sunnyIcon =
        activity.id == 'morning' || (custom && activity.morning > 0);
    final icon = custom
        ? Icons.auto_awesome_outlined
        : switch (activity.id) {
            'regular' => Icons.directions_run_rounded,
            'morning' => Icons.wb_twilight_rounded,
            'fluorescent' => Icons.nights_stay_outlined,
            _ => Icons.emoji_events_outlined,
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.rowDivider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: sunnyIcon ? colors.sunSoft : colors.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: sunnyIcon ? colors.sun : colors.action,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 3,
                      children: [
                        Text(
                          activity.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: palette.titleText,
                          ),
                        ),
                        if (count > 0)
                          _Pill(
                            label: '已计 +${count * activity.total} 次',
                            color: activity.morning > 0
                                ? colors.sun
                                : colors.action,
                            background: activity.morning > 0
                                ? colors.sunSoft
                                : colors.accentSoft,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 5,
                      runSpacing: 3,
                      children: [
                        _Pill(
                          label: '每场总次数 +${activity.total}',
                          color: palette.labelText,
                          background: palette.rowDivider,
                        ),
                        if (activity.morning > 0)
                          _Pill(
                            label: '晨跑 +${activity.morning}',
                            color: colors.sun,
                            background: colors.sunSoft,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (custom) ...[
                IconButton(
                  tooltip: '修改${activity.label}设置',
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_outlined, size: 17, color: colors.hint),
                  padding: const EdgeInsets.all(7),
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 40,
                  ),
                ),
                IconButton(
                  tooltip: '删除${activity.label}',
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: colors.danger,
                  ),
                  padding: const EdgeInsets.all(7),
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 40,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: palette.pageBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: palette.divider),
                  ),
                  child: Row(
                    children: [
                      _StepButton(
                        key: ValueKey('sunshine-minus-${activity.id}'),
                        enabled: count > 0,
                        label: '减少${activity.label}1场',
                        icon: Icons.remove_rounded,
                        onStep: (undo, feedback) => onStep(-1, undo, feedback),
                        onRepeatEnd: onRepeatEnd,
                      ),
                      Expanded(
                        child: Semantics(
                          button: true,
                          label: '直接修改${activity.label}场次',
                          value: '$count 场',
                          child: InkWell(
                            key: ValueKey('sunshine-count-${activity.id}'),
                            onTap: onEditCount,
                            borderRadius: BorderRadius.circular(7),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 6,
                                ),
                                child: Center(
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: '$count',
                                          style: TextStyle(
                                            fontSize:
                                                count.toString().length > 5
                                                ? 15
                                                : 20,
                                            fontWeight: FontWeight.w600,
                                            color: count > 0
                                                ? colors.action
                                                : palette.titleText,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                        TextSpan(
                                          text: ' 场',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: colors.hint,
                                          ),
                                        ),
                                      ],
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _StepButton(
                        key: ValueKey('sunshine-plus-${activity.id}'),
                        enabled: true,
                        label: '增加${activity.label}1场',
                        icon: Icons.add_rounded,
                        onStep: (undo, feedback) => onStep(1, undo, feedback),
                        onRepeatEnd: onRepeatEnd,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                label: '快速增加${activity.label}5场',
                button: true,
                child: TextButton(
                  key: ValueKey('sunshine-quick-${activity.id}'),
                  onPressed: () => onStep(5, true, true),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.action,
                    backgroundColor: colors.accentSoft,
                    minimumSize: const Size(52, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('+5'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatefulWidget {
  const _StepButton({
    super.key,
    required this.enabled,
    required this.label,
    required this.icon,
    required this.onStep,
    required this.onRepeatEnd,
  });
  final bool enabled;
  final String label;
  final IconData icon;
  final void Function(bool recordUndo, bool feedback) onStep;
  final VoidCallback onRepeatEnd;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  Timer? _timer;
  bool _repeating = false;

  void _start() {
    if (!widget.enabled) return;
    _repeating = true;
    widget.onStep(true, false);
    _timer = Timer.periodic(const Duration(milliseconds: 95), (_) {
      if (!mounted || !widget.enabled) {
        _timer?.cancel();
        return;
      }
      widget.onStep(false, false);
    });
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    if (_repeating) {
      _repeating = false;
      widget.onRepeatEnd();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _RunColors(AppPalette.of(context));
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled ? () => widget.onStep(true, true) : null,
      child: Tooltip(
        message: widget.label,
        child: Listener(
          onPointerUp: (_) => _finish(),
          onPointerCancel: (_) => _finish(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? () => widget.onStep(true, true) : null,
            onLongPressStart: widget.enabled ? (_) => _start() : null,
            onLongPressEnd: (_) => _finish(),
            onLongPressCancel: _finish,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                widget.icon,
                size: 20,
                color: widget.enabled
                    ? colors.action
                    : colors.hint.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExemptionCard extends StatelessWidget {
  const _ExemptionCard({required this.state, required this.onChanged});
  final SunshineRunState state;
  final ValueChanged<SunshineRunExemption> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    return _RunCard(
      child: Column(
        children: [
          const _SectionHeading(title: '比赛减免', note: '再次点击可取消，半免与全免互斥'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ChoiceGroup<SunshineRunExemption>(
                  values: const [
                    SunshineRunExemption.half,
                    SunshineRunExemption.full,
                  ],
                  selected: state.exemption,
                  labels: const ['半免 50%', '全免 100%'],
                  onChanged: onChanged,
                  label: '选择比赛减免',
                  exemption: true,
                ),
                const SizedBox(height: 9),
                Text(
                  switch (state.exemption) {
                    SunshineRunExemption.none => '按当前年级完整标准计算总次数与晨跑要求。',
                    SunshineRunExemption.half => '总次数要求减半，晨跑要求不变。',
                    SunshineRunExemption.full => '无需完成跑步要求，已录入记录继续保留。',
                  },
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: colors.hint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
