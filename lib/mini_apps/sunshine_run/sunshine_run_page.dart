import 'dart:async';
import 'dart:math' as math;

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

  Widget _activityTile(
    SunshineRunActivity activity,
    int count, {
    SunshineRunCustomActivity? custom,
  }) => _ActivityTile(
    key: ValueKey('sunshine-tile-${activity.id}'),
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
  void dispose() {
    _controller.finishActivityAdjustment();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final textScaler = MediaQuery.textScalerOf(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;
        final result = _controller.result;
        final canEdit = !_controller.restoringState;
        final canReset =
            canEdit &&
            (result.total > 0 ||
                state.customActivities.isNotEmpty ||
                state.exemption != SunshineRunExemption.none);
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
                  if (canEdit &&
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
                  centerTitle: false,
                  titleSpacing: 0,
                  toolbarHeight: math.max(
                    64,
                    textScaler.scale(16) * 1.3 + textScaler.scale(11) * 2.6 + 8,
                  ),
                  title: _RunHeading(result: result),
                ),
                body: SafeArea(
                  top: false,
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: IgnorePointer(
                        ignoring: !canEdit,
                        child: ListView(
                          key: const PageStorageKey('sunshine-run-scroll'),
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          children: [
                            if (_controller.restoringState) ...[
                              Text(
                                '正在恢复本机记录…',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.hint,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_controller.storageWarning
                                case final warning?) ...[
                              _StorageWarning(
                                message: warning,
                                corrupt: _controller.storageCorrupt,
                                onRetry: () => _perform(
                                  _controller.retrySave,
                                  '已保存当前记录',
                                  undo: false,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            _RunSummary(result: result),
                            const SizedBox(height: _RunSpacing.section),
                            const _SectionHeading(
                              title: '活动计数',
                              note: '点数字可直填 · 长按 ± 连增减',
                            ),
                            const SizedBox(height: _RunSpacing.group),
                            _ActivityGrid(
                              children: [
                                for (final activity in kSunshineRunActivities)
                                  _activityTile(
                                    activity,
                                    state.activities[activity.id]!,
                                  ),
                                for (final custom in state.customActivities)
                                  _activityTile(
                                    SunshineRunActivity(
                                      id: custom.id,
                                      label: custom.label,
                                      total: custom.total,
                                      morning: custom.morning,
                                    ),
                                    custom.count,
                                    custom: custom,
                                  ),
                                _AddActivityTile(
                                  key: const ValueKey('sunshine-add-custom'),
                                  onPressed:
                                      state.customActivities.length <
                                          kSunshineRunMaxCustomActivities
                                      ? _editCustom
                                      : null,
                                ),
                              ],
                            ),
                            const SizedBox(height: _RunSpacing.section),
                            _ExemptionCard(
                              state: state,
                              onChanged: (value) => _perform(
                                () => _controller.toggleExemption(value),
                                state.exemption == value
                                    ? '已取消减免'
                                    : '已设置${value == SunshineRunExemption.half ? '半免' : '全免'}',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Semantics(
                              liveRegion: _controller.storageWarning != null,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 13,
                                    color: colors.hint,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      _controller.storageWarning == null
                                          ? '记录自动保存在本机'
                                          : '当前记录尚未保存',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.hint,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                bottomNavigationBar: _ActionDock(
                  onBaseline: canEdit ? _editBaseline : null,
                  onReset: canReset ? _reset : null,
                  onRules: () => showDialog<void>(
                    context: context,
                    useRootNavigator: false,
                    builder: (_) => _RulesDialog(state: state),
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

/// 紧密内容、同级元素、内容分组与独立模块使用不同的间距。
abstract final class _RunSpacing {
  static const tight = 4.0;
  static const peer = 8.0;
  static const group = 12.0;
  static const section = 16.0;
}

/// 从应用色板派生操作色、渐变和背景，跟随应用的明暗设置。
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
  Color get onGradient => palette.isDark ? palette.pageBg : palette.surface;

  // 从应用语义色派生柔亮的蓝橙渐变，深色下保持清晰的环带。
  Color _ringTint(Color base, int red, int green, int blue) => Color.from(
    alpha: base.a,
    red: (base.r + red / 255).clamp(0.0, 1.0),
    green: (base.g + green / 255).clamp(0.0, 1.0),
    blue: (base.b + blue / 255).clamp(0.0, 1.0),
    colorSpace: base.colorSpace,
  );

  (Color, Color) get ringBlue => palette.isDark
      ? (
          _ringTint(palette.accent, 22, 25, 10),
          _ringTint(palette.accent, 10, -7, 10),
        )
      : (
          Color.lerp(
            _ringTint(palette.accent, 46, 46, 5),
            palette.surface,
            0.4,
          )!,
          Color.lerp(
            _ringTint(palette.accent, 59, 20, -6),
            palette.surface,
            0.2,
          )!,
        );
  (Color, Color) get ringSun => palette.isDark
      ? (
          _ringTint(palette.warning, 0, 48, 83),
          _ringTint(palette.warning, 0, 8, 47),
        )
      : (
          Color.lerp(
            _ringTint(palette.warning, -24, 56, 115),
            palette.surface,
            0.25,
          )!,
          Color.lerp(
            _ringTint(palette.warning, -29, 23, 74),
            palette.surface,
            0.12,
          )!,
        );
  (Color, Color) get ringGreen => palette.isDark
      ? (
          _ringTint(palette.success, 113, 50, 117),
          _ringTint(palette.success, 39, 26, 80),
        )
      : (
          _ringTint(palette.success, 83, 41, 107),
          _ringTint(palette.success, 27, 8, 70),
        );
  Color get ringTrack => Color.alphaBlend(
    palette.accent.withValues(alpha: palette.isDark ? 0.04 : 0.065),
    Color.lerp(palette.pageBg, palette.surface, palette.isDark ? 0.7 : 0.3)!,
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider.withValues(alpha: 0.65)),
      ),
      child: child,
    );
  }
}

class _RunHeading extends StatelessWidget {
  const _RunHeading({required this.result});
  final SunshineRunResult result;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final showIcon =
        MediaQuery.sizeOf(context).width >= 360 &&
        MediaQuery.textScalerOf(context).scale(14) <= 19;
    return Row(
      children: [
        if (showIcon) ...[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.sunSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.directions_run_rounded,
              size: 20,
              color: colors.sun,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '阳光跑计算器',
                style: TextStyle(
                  fontSize: 16,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                  color: palette.titleText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                result.status == SunshineRunStatus.exempt
                    ? '已开启全免 · 无需跑步'
                    : '满分 ${result.fullTotal} 次 · 晨跑 ${result.requiredMorning} 次',
                style: TextStyle(fontSize: 11, height: 1.3, color: colors.hint),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
      ],
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
          borderRadius: BorderRadius.circular(12),
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
  const _RunSummary({required this.result});
  final SunshineRunResult result;

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
    final totalColors = result.status == SunshineRunStatus.passed
        ? colors.ringGreen
        : colors.ringBlue;
    final morningColors = exempt
        ? colors.ringBlue
        : result.remainingMorning == 0
        ? colors.ringGreen
        : colors.ringSun;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          key: const ValueKey('sunshine-summary'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  colors.ringBlue.$1.withValues(
                    alpha: palette.isDark ? 0.15 : 0.23,
                  ),
                  palette.surface,
                ),
                palette.surface,
                Color.alphaBlend(
                  colors.ringSun.$1.withValues(
                    alpha: palette.isDark ? 0.09 : 0.15,
                  ),
                  palette.surface,
                ),
              ],
              stops: const [0, 0.5, 1],
            ),
            boxShadow: [
              BoxShadow(
                color: palette.labelText.withValues(
                  alpha: palette.isDark ? 0.05 : 0.035,
                ),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(_RunSpacing.section),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final textScaler = MediaQuery.textScalerOf(context);
                final metrics = [
                  _RunMetric(
                    label: '累计总次数',
                    value: result.total,
                    target: result.fullTotal,
                    color: totalColors.$1,
                    endColor: totalColors.$2,
                    exempt: exempt,
                    valueKey: const ValueKey('sunshine-total'),
                  ),
                  _RunMetric(
                    label: '其中晨跑',
                    value: result.morning,
                    target: result.requiredMorning,
                    color: morningColors.$1,
                    endColor: morningColors.$2,
                    exempt: exempt,
                    valueKey: const ValueKey('sunshine-morning'),
                  ),
                ];
                final stacked =
                    constraints.maxWidth < 280 ||
                    textScaler.scale(12) > 17 ||
                    '${result.total}'.length > 10 ||
                    '${result.morning}'.length > 10;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: _DualRunRing(
                        result: result,
                        size: math.min(
                          constraints.maxWidth - 16,
                          math.max(228, textScaler.scale(28) * 4.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: _RunSpacing.section),
                    if (stacked)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          metrics[0],
                          const SizedBox(height: _RunSpacing.peer),
                          metrics[1],
                        ],
                      )
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: metrics[0]),
                          const SizedBox(width: _RunSpacing.peer),
                          Expanded(child: metrics[1]),
                        ],
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: _RunSpacing.group),
        Text(
          _detail,
          key: const ValueKey('sunshine-status-detail'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, height: 1.4, color: colors.hint),
        ),
      ],
    );
  }
}

class _RunMetric extends StatelessWidget {
  const _RunMetric({
    required this.label,
    required this.value,
    required this.target,
    required this.color,
    this.endColor,
    required this.exempt,
    required this.valueKey,
  });
  final String label;
  final int value;
  final int target;
  final Color color;
  final Color? endColor;
  final bool exempt;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    return Container(
      padding: const EdgeInsets.all(_RunSpacing.group),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: palette.isDark ? 0.65 : 0.76),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, endColor ?? color],
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: _RunSpacing.tight),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.labelText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: _RunSpacing.peer),
          Wrap(
            spacing: _RunSpacing.tight,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$value',
                key: valueKey,
                style: TextStyle(
                  fontSize: 19,
                  height: 1.2,
                  color: palette.titleText,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                exempt ? '次 · 已免跑' : '/ $target 次',
                style: TextStyle(fontSize: 12, color: colors.hint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DualRunRing extends StatelessWidget {
  const _DualRunRing({required this.result, required this.size});
  final SunshineRunResult result;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final totalColors = result.status == SunshineRunStatus.passed
        ? colors.ringGreen
        : colors.ringBlue;
    final morningColors = result.status == SunshineRunStatus.exempt
        ? colors.ringBlue
        : result.remainingMorning == 0
        ? colors.ringGreen
        : colors.ringSun;
    final (statusText, statusColor, statusBg) = switch (result.status) {
      SunshineRunStatus.incomplete => (
        result.percentage == 100 ? '未达标' : '进行中',
        colors.sun,
        colors.sunSoft,
      ),
      SunshineRunStatus.passed => ('已达标', colors.success, colors.successSoft),
      SunshineRunStatus.full => ('已满分', colors.action, colors.accentSoft),
      SunshineRunStatus.exempt => ('已全免', colors.action, colors.accentSoft),
    };
    final labelColor = result.status == SunshineRunStatus.passed
        ? palette.success
        : palette.accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: palette.isDark ? 0.7 : 0.86),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: palette.accent.withValues(
              alpha: palette.isDark ? 0.07 : 0.045,
            ),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Semantics(
          key: const ValueKey('sunshine-dual-ring'),
          excludeSemantics: true,
          label: result.status == SunshineRunStatus.exempt
              ? '免跑完成度'
              : '跑步完成度，${result.status == SunshineRunStatus.incomplete ? '未达标' : statusText}',
          value:
              '总完成率 ${result.percentage}%，晨跑完成率 ${result.morningPercentage}%',
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: _RunRingPainter(
                totalProgress: result.percentage / 100,
                morningProgress: result.morningPercentage / 100,
                totalColor: totalColors.$1,
                totalEndColor: totalColors.$2,
                morningColor: morningColors.$1,
                morningEndColor: morningColors.$2,
                trackColor: colors.ringTrack,
              ),
              child: Center(
                child: Container(
                  width: size * 0.64,
                  height: size * 0.64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        palette.surface,
                        Color.alphaBlend(
                          colors.ringSun.$1.withValues(
                            alpha: palette.isDark ? 0.04 : 0.035,
                          ),
                          palette.surface,
                        ),
                      ],
                    ),
                    border: Border.all(
                      color: palette.surface.withValues(alpha: 0.7),
                      width: size * 0.02,
                    ),
                  ),
                  padding: EdgeInsets.all(size * 0.02),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: size * 0.56,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: ShaderMask(
                              blendMode: BlendMode.srcIn,
                              shaderCallback: (bounds) => LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color.lerp(
                                    labelColor,
                                    palette.isDark
                                        ? palette.titleText
                                        : palette.surface,
                                    0.12,
                                  )!,
                                  labelColor,
                                ],
                              ).createShader(bounds),
                              child: Text(
                                '${result.percentage}%',
                                style: TextStyle(
                                  fontSize: 36,
                                  height: 1.05,
                                  letterSpacing: -1.08,
                                  fontWeight: FontWeight.w900,
                                  color: palette.titleText,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            result.status == SunshineRunStatus.exempt
                                ? '免跑完成度'
                                : '总次数完成率',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: colors.hint,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _Pill(
                            key: const ValueKey('sunshine-status'),
                            label: statusText,
                            color: statusColor,
                            background: statusBg,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RunRingPainter extends CustomPainter {
  const _RunRingPainter({
    required this.totalProgress,
    required this.morningProgress,
    required this.totalColor,
    required this.totalEndColor,
    required this.morningColor,
    required this.morningEndColor,
    required this.trackColor,
  });
  final double totalProgress;
  final double morningProgress;
  final Color totalColor;
  final Color totalEndColor;
  final Color morningColor;
  final Color morningEndColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = size.shortestSide / 128;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 21 * scale;
    canvas.drawCircle(center, 53.5 * scale, track);

    void ring(
      double radius,
      double width,
      double progress,
      List<Color> colors,
    ) {
      if (progress <= 0) return;
      final rect = Rect.fromCircle(center: center, radius: radius);
      final arc = Paint()
        ..shader = _fadedGradient(progress, colors).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width;
      canvas.drawCircle(center, radius, arc);
    }

    // 对应 HTML 的 128px 双环遮罩，两条环带在半径 53px 处相接。
    ring(58.5 * scale, 11 * scale, totalProgress, [totalColor, totalEndColor]);
    ring(48 * scale, 10 * scale, morningProgress, [
      morningColor,
      morningEndColor,
    ]);
  }

  SweepGradient _fadedGradient(double progress, List<Color> colors) {
    if (progress >= 1) {
      return SweepGradient(
        colors: [colors.first, colors.last, colors.first],
        stops: const [0, 0.5, 1],
        transform: const GradientRotation(-math.pi / 2),
      );
    }
    final degrees = math.max(4.0, progress * 360);
    double rounded(double value) => (value * 10).round() / 10;
    final startFade = rounded(math.min(18.0, degrees * 0.24));
    final endFade = rounded(
      math.max(startFade, degrees - math.min(26.0, degrees * 0.3)),
    );
    // 原稿以透明度淡入、淡出端点，不添加圆角端头或额外环间空隙。
    return SweepGradient(
      colors: [
        colors.first.withValues(alpha: 0),
        colors.first,
        colors.last,
        colors.last.withValues(alpha: 0),
        colors.last.withValues(alpha: 0),
      ],
      stops: [0, startFade / 360, endFade / 360, rounded(degrees) / 360, 1],
      transform: const GradientRotation(-math.pi / 2),
    );
  }

  @override
  bool shouldRepaint(_RunRingPainter oldDelegate) =>
      totalProgress != oldDelegate.totalProgress ||
      morningProgress != oldDelegate.morningProgress ||
      totalColor != oldDelegate.totalColor ||
      totalEndColor != oldDelegate.totalEndColor ||
      morningColor != oldDelegate.morningColor ||
      morningEndColor != oldDelegate.morningEndColor ||
      trackColor != oldDelegate.trackColor;
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
  });
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: _RunSpacing.peer,
      vertical: _RunSpacing.tight,
    ),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: color,
      ),
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
    final colors = _RunColors(palette);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: _RunSpacing.peer,
      runSpacing: _RunSpacing.tight,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: palette.titleText,
          ),
        ),
        Text(note, style: TextStyle(fontSize: 11, color: colors.hint)),
      ],
    );
  }
}

class _ActivityGrid extends StatelessWidget {
  const _ActivityGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // 单卡至少容纳 32dp 图标、两个 44dp 操作按钮与两侧内边距。
      // 列数只由可用宽度决定，系统字号变化不会把普通手机切成整行大卡片。
      const minTileWidth = 32.0 + 44 * 2 + _RunSpacing.group * 2;
      final columns =
          constraints.maxWidth >= minTileWidth * 2 + _RunSpacing.peer ? 2 : 1;
      return Column(
        key: const ValueKey('sunshine-activity-grid'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var start = 0; start < children.length; start += columns) ...[
            if (start > 0) const SizedBox(height: _RunSpacing.peer),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) const SizedBox(width: _RunSpacing.peer),
                    Expanded(
                      child: start + column < children.length
                          ? children[start + column]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    super.key,
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
    final sunny = activity.morning > 0;
    final color = sunny ? colors.sun : colors.action;
    final soft = sunny ? colors.sunSoft : colors.accentSoft;
    final icon = custom
        ? Icons.auto_awesome_outlined
        : switch (activity.id) {
            'regular' => Icons.directions_run_rounded,
            'morning' => Icons.wb_twilight_rounded,
            'fluorescent' => Icons.nights_stay_outlined,
            _ => Icons.emoji_events_outlined,
          };
    final stepper = Container(
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
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$count',
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: count > 0
                                ? colors.action
                                : palette.titleText,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
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
    );
    return _RunCard(
      child: Padding(
        padding: const EdgeInsets.all(_RunSpacing.group),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: soft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const Spacer(),
                if (custom) ...[
                  IconButton(
                    tooltip: '修改${activity.label}设置',
                    onPressed: onEdit,
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 17,
                      color: colors.hint,
                    ),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: '删除${activity.label}',
                    onPressed: onRemove,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 18,
                      color: colors.danger,
                    ),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 38),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activity.label,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: palette.titleText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '总+${activity.total}${sunny ? ' · 晨+${activity.morning}' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: colors.hint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: _RunSpacing.group),
            stepper,
          ],
        ),
      ),
    );
  }
}

class _AddActivityTile extends StatelessWidget {
  const _AddActivityTile({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = _RunColors(AppPalette.of(context));
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: '添加其他活动',
      child: Tooltip(
        message: '添加其他活动',
        child: Material(
          color: colors.accentSoft,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 154),
              child: Center(
                child: Icon(
                  Icons.add_rounded,
                  size: 36,
                  color: onPressed == null
                      ? colors.action.withValues(alpha: 0.4)
                      : colors.action,
                ),
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
    final colors = _RunColors(AppPalette.of(context));
    return _RunCard(
      child: Padding(
        padding: const EdgeInsets.all(_RunSpacing.group),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeading(title: '比赛减免', note: '再次点击可取消'),
            const SizedBox(height: _RunSpacing.group),
            _ExemptionChoices(selected: state.exemption, onChanged: onChanged),
            const SizedBox(height: _RunSpacing.peer),
            Text(switch (state.exemption) {
              SunshineRunExemption.none => '按完整标准计算总次数与晨跑要求。',
              SunshineRunExemption.half => '总次数要求减半，晨跑要求不变。',
              SunshineRunExemption.full => '无需完成跑步要求，已录入记录继续保留。',
            }, style: TextStyle(fontSize: 11, height: 1.4, color: colors.hint)),
          ],
        ),
      ),
    );
  }
}

class _ExemptionChoices extends StatelessWidget {
  const _ExemptionChoices({required this.selected, required this.onChanged});
  final SunshineRunExemption selected;
  final ValueChanged<SunshineRunExemption> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    return Semantics(
      label: '选择比赛减免',
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: palette.rowDivider,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.divider),
        ),
        child: Row(
          children: [
            for (final value in [
              SunshineRunExemption.half,
              SunshineRunExemption.full,
            ]) ...[
              if (value == SunshineRunExemption.full) const SizedBox(width: 3),
              Expanded(
                child: Semantics(
                  selected: selected == value,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: selected == value
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                value == SunshineRunExemption.half
                                    ? colors.sun
                                    : colors.action,
                                Color.lerp(
                                  value == SunshineRunExemption.half
                                      ? colors.sun
                                      : colors.action,
                                  palette.isDark
                                      ? palette.accent
                                      : palette.titleText,
                                  0.18,
                                )!,
                              ],
                            )
                          : null,
                    ),
                    child: TextButton(
                      onPressed: () => onChanged(value),
                      style: TextButton.styleFrom(
                        foregroundColor: selected == value
                            ? colors.onGradient
                            : palette.labelText,
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: Text(
                        value == SunshineRunExemption.half
                            ? '半免 50%'
                            : '全免 100%',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionDock extends StatelessWidget {
  const _ActionDock({
    required this.onBaseline,
    required this.onReset,
    required this.onRules,
  });
  final VoidCallback? onBaseline;
  final VoidCallback? onReset;
  final VoidCallback onRules;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.rowDivider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _DockAction(
                  key: const ValueKey('sunshine-edit-baseline'),
                  label: '已有次数',
                  tooltip: '录入已有次数',
                  icon: Icons.edit_outlined,
                  onPressed: onBaseline,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _DockAction(
                  key: const ValueKey('sunshine-reset'),
                  label: '重置',
                  tooltip: '重置记录',
                  icon: Icons.restart_alt_rounded,
                  onPressed: onReset,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _DockAction(
                  key: const ValueKey('sunshine-rules'),
                  label: '规则',
                  tooltip: '计算规则',
                  icon: Icons.info_outline_rounded,
                  onPressed: onRules,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    super.key,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final colors = _RunColors(palette);
    final color = onPressed == null
        ? colors.hint.withValues(alpha: 0.5)
        : palette.labelText;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: palette.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: color,
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
