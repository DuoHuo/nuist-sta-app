import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';

/// 上课提醒开关的接入点（给权限/排通知留的位置）。
///
/// 用户拨动「上课提醒」时先调用；返回最终要写入的开关值（例如通知权限被拒时返回
/// false，让开关弹回关闭）。为空时直接写入用户选的值。
/// 本版只读写设置字段，不申请权限、不排通知。
typedef ReminderToggleHandler = Future<bool> Function(
  BuildContext context,
  bool enable,
);

// 本版不做上课提醒，入口隐藏，代码保留；打开改 true。
const bool kShowReminderSettings = false;

/// 设置页（spec §13.3 + §13.16 命名）：显示 / 外观 / 提醒 / 首页 / 考试 / 其他 白底卡片。
/// 「提醒」卡片受 [kShowReminderSettings] 控制，本版隐藏。
/// §13.16 只改界面文字和读屏文案（读屏「卡片名，行名」），settings.json 的 key 一律不变。
/// 「其他」卡片（§13.12）承接原顶栏「⋮」菜单除「立即同步」外的项：教务账号（原「去登录」）、
/// 恢复教务课程；debug 包另有「[DEBUG] 清空本地课表」。
///
/// 每次点击都在回调里读 [TimetableController.settings] 的当前值再 copyWith 合并，
/// 由 [TimetableController.updateSettings] 走 mergeSettingsChanges 只写改动的键，
/// 避免连点互相覆盖。
class TimetableSettingsPage extends StatelessWidget {
  const TimetableSettingsPage({
    super.key,
    this.controller,
    this.onReminderToggle,
    this.showReminderCard = kShowReminderSettings,
    this.onOpenAccount,
  });

  /// 为空时用 [TimetableController.instance]。
  final TimetableController? controller;

  /// 提醒开关接入点，见 [ReminderToggleHandler]。
  final ReminderToggleHandler? onReminderToggle;

  /// 是否显示「提醒」卡片；默认取 [kShowReminderSettings]，测试可传 true。
  final bool showReminderCard;

  /// 「其他 → 教务账号」：已绑定进解绑流程、未绑定进登录流程（两者都是门户绑定状态页
  /// `/portal-bind`，与原「⋮」菜单「去登录」相同）。为空时用 go_router 打开该页。
  /// 传入时由调用方负责回来后的刷新与登录成功同步。
  final Future<void> Function()? onOpenAccount;

  /// 格子高度步长（dp）。
  static const double periodHeightStep = 2;

  /// 不透明度范围与步长（%）。
  static const int opacityMin = 30;
  static const int opacityMax = 100;
  static const int opacityStep = 10;

  /// 卡片行高与圆角（spec §13.3）。
  static const double rowHeight = TimetableTheme.listRowHeight;

  /// 滑块行左侧标题的固定宽度（「格子不透明度」「格子高度」共用）。
  static const double sliderLabelWidth = 88;
  static const double cardRadius = TimetableTheme.cardRadius;

  /// 「恢复教务课程」二次确认文案（§14.3，含考试覆盖）。
  static const restoreConfirmText = '恢复所有教务课程和考试？你的修改、删除和调课都会清除。';

  static const fontScaleLabels = {
    CellFontScale.small: '小',
    CellFontScale.standard: '标准',
    CellFontScale.large: '大',
  };

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    // 每次点击都读当前设置再合并。
    void update(TimetableSettings Function(TimetableSettings s) change) =>
        c.updateSettings(change(c.settings));

    return Scaffold(
      backgroundColor: TimetableTheme.pageBg,
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings;
          final height = s.periodHeight.clamp(
            TimetableTheme.periodHeightMin,
            TimetableTheme.periodHeightMax,
          );
          final opacity = s.cellOpacity.clamp(opacityMin, opacityMax);
          final scheme = coursePaletteSchemeOf(s.paletteScheme);
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _Group(
                key: const Key('tt_settings_group_display'),
                title: '显示',
                children: [
                  _SwitchRow(
                    key: const Key('tt_settings_saturday'),
                    title: '周六',
                    value: s.showSaturday,
                    onChanged: (v) =>
                        update((x) => x.copyWith(showSaturday: v)),
                  ),
                  _SwitchRow(
                    key: const Key('tt_settings_sunday'),
                    title: '周日',
                    value: s.showSunday,
                    onChanged: (v) => update((x) => x.copyWith(showSunday: v)),
                  ),
                  _SwitchRow(
                    key: const Key('tt_settings_non_current'),
                    title: '非本周课程',
                    value: s.showNonCurrentWeek,
                    onChanged: (v) =>
                        update((x) => x.copyWith(showNonCurrentWeek: v)),
                  ),
                  _SwitchRow(
                    key: const Key('tt_settings_show_location'),
                    title: '地点',
                    value: s.showLocation,
                    onChanged: (v) =>
                        update((x) => x.copyWith(showLocation: v)),
                  ),
                  _SwitchRow(
                    key: const Key('tt_settings_show_teacher'),
                    title: '老师',
                    value: s.showTeacher,
                    onChanged: (v) => update((x) => x.copyWith(showTeacher: v)),
                  ),
                  _Row(
                    title: '一周起始',
                    trailing: _Segments<bool>(
                      key: const Key('tt_settings_week_start'),
                      options: const {true: '周一', false: '周日'},
                      selected: s.weekStartsOnMonday,
                      onSelected: (v) =>
                          update((x) => x.copyWith(weekStartsOnMonday: v)),
                    ),
                  ),
                ],
              ),
              _Group(
                key: const Key('tt_settings_group_appearance'),
                title: '外观',
                children: [
                  _Row(
                    key: const Key('tt_settings_palette'),
                    title: '配色',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TimetablePalettePage(controller: c),
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          coursePaletteSchemeLabel(scheme),
                          style: TimetableTheme.bodyStyle(
                            color: TimetableTheme.hint,
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.hint,
                        ),
                      ],
                    ),
                  ),
                  _Row(
                    title: '字号',
                    trailing: _Segments<CellFontScale>(
                      key: const Key('tt_settings_font_scale'),
                      options: fontScaleLabels,
                      selected: s.fontScale,
                      onSelected: (v) =>
                          update((x) => x.copyWith(fontScale: v)),
                    ),
                  ),
                  _SliderRow(
                    title: '不透明度',
                    valueLabel: '$opacity%',
                    valueKey: const Key('tt_settings_opacity_value'),
                    slider: Slider(
                      key: const Key('tt_settings_opacity'),
                      min: opacityMin.toDouble(),
                      max: opacityMax.toDouble(),
                      divisions: (opacityMax - opacityMin) ~/ opacityStep,
                      value: opacity.toDouble(),
                      activeColor: TimetableTheme.accent,
                      label: '$opacity%',
                      onChanged: (v) {
                        final next = v.round();
                        if (next == c.settings.cellOpacity) return;
                        update((x) => x.copyWith(cellOpacity: next));
                      },
                    ),
                  ),
                  _SliderRow(
                    title: '格子高度',
                    // spec §13.3：右边只显示数字，不写「dp」。
                    valueLabel: '${height.round()}',
                    valueKey: const Key('tt_settings_period_height_value'),
                    slider: Slider(
                      key: const Key('tt_settings_period_height'),
                      min: TimetableTheme.periodHeightMin,
                      max: TimetableTheme.periodHeightMax,
                      divisions:
                          ((TimetableTheme.periodHeightMax -
                                      TimetableTheme.periodHeightMin) /
                                  periodHeightStep)
                              .round(),
                      value: height,
                      activeColor: TimetableTheme.accent,
                      label: '${height.round()}',
                      onChanged: (v) {
                        if (v == c.settings.periodHeight) return;
                        update((x) => x.copyWith(periodHeight: v));
                      },
                    ),
                  ),
                ],
              ),
              if (showReminderCard)
                _Group(
                  key: const Key('tt_settings_group_reminder'),
                  title: '提醒',
                  children: [
                    _SwitchRow(
                      key: const Key('tt_settings_reminder'),
                      title: '上课提醒',
                      value: s.reminderEnabled,
                      onChanged: (v) async {
                        final handler = onReminderToggle;
                        final result = handler == null
                            ? v
                            : await handler(context, v);
                        if (result == c.settings.reminderEnabled) return;
                        update((x) => x.copyWith(reminderEnabled: result));
                      },
                    ),
                    // spec §13.4：开关下面 12sp onSurfaceVariant 小字；精确闹钟提示
                    // （另一位开发接权限后再加）放在这行下面。
                    Padding(
                      key: const Key('tt_settings_reminder_hint'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        '放假期间也会提醒',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    _Row(
                      key: const Key('tt_settings_reminder_lead'),
                      title: '提前时间',
                      enabled: s.reminderEnabled,
                      onTap: () => _pickLead(context, c),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${s.reminderLeadMinutes} 分钟',
                            style: TimetableTheme.bodyStyle(
                              color: TimetableTheme.hint,
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: TimetableTheme.hint,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              _Group(
                key: const Key('tt_settings_group_home'),
                title: '首页',
                children: [
                  _SwitchRow(
                    key: const Key('tt_settings_show_tomorrow'),
                    title: '显示明天的课',
                    value: s.showTomorrowOnHome,
                    onChanged: (v) =>
                        update((x) => x.copyWith(showTomorrowOnHome: v)),
                  ),
                ],
              ),
              _Group(
                key: const Key('tt_settings_group_exam'),
                title: '考试',
                children: [
                  _SwitchRow(
                    key: const Key('tt_settings_show_exams'),
                    title: '显示考试',
                    value: s.showExams,
                    onChanged: (v) => update((x) => x.copyWith(showExams: v)),
                  ),
                  _Row(
                    key: const Key('tt_settings_exam_color'),
                    title: '颜色',
                    onTap: () => _pickExamColor(context, c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          key: const Key('tt_settings_exam_color_swatch'),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: Color(s.examColor),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.hint,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              _Group(
                key: const Key('tt_settings_group_other'),
                title: '其他',
                children: [
                  _Row(
                    key: const Key('tt_settings_account'),
                    title: '教务账号',
                    // 登录已过期：读屏「其他，教务账号，已过期」；点这一行重新登录。
                    semanticsStatus: c.portalSessionExpired ? '已过期' : null,
                    onTap: () => _openAccount(context, c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          excluding: c.portalSessionExpired,
                          child: Text(
                            c.portalSessionExpired
                                ? '已过期'
                                : c.portalBound
                                ? '已绑定'
                                : '去登录',
                            key: const Key('tt_settings_account_state'),
                            style: TimetableTheme.bodyStyle(
                              color: c.portalSessionExpired
                                  ? TimetableTheme.sessionExpiredText
                                  : c.portalBound
                                  ? TimetableTheme.hint
                                  : TimetableTheme.accent,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.hint,
                        ),
                      ],
                    ),
                  ),
                  _Row(
                    key: const Key('tt_settings_restore_jwxt'),
                    title: '恢复教务课程',
                    onTap: () => _confirmRestoreAll(context, c),
                  ),
                  // 原「⋮」菜单的 debug 项，只在 debug 包出现（是否保留待产品确认）。
                  if (kDebugMode && c.hasCourses)
                    _Row(
                      key: const Key('tt_settings_debug_clear'),
                      title: '[DEBUG] 清空本地课表',
                      onTap: () => c.clearCourses(),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openAccount(BuildContext context, TimetableController c) async {
    final open = onOpenAccount;
    if (open != null) {
      await open();
      return;
    }
    await GoRouter.maybeOf(context)?.push('/portal-bind');
    if (!context.mounted) return;
    // 从登录 / 解绑页回来后只刷新「已绑定 / 去登录」；登录成功的同步由门户绑定页
    // （portal_status_page）自己调用 onLoginSucceeded，这里不重复调用。
    await c.refreshPortalBound();
  }

  /// 「恢复教务课程」：二次确认后调用 [TimetableController.restoreAllJwxt]。
  Future<void> _confirmRestoreAll(
    BuildContext context,
    TimetableController c,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('tt_restore_jwxt_dialog'),
        content: const Text(restoreConfirmText),
        actions: [
          TextButton(
            key: const Key('tt_restore_jwxt_cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('tt_restore_jwxt_confirm'),
            style: TextButton.styleFrom(foregroundColor: TimetableTheme.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final changed = await c.restoreAllJwxt();
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(changed ? '已恢复教务课程' : '没有需要恢复的修改'),
      ),
    );
  }

  /// 「考试 → 颜色」：色板单选（选项与白字对比度均 ≥ 4.5，见 [TimetableTheme.examColorOptions]）。
  Future<void> _pickExamColor(
    BuildContext context,
    TimetableController c,
  ) async {
    final picked = await showModalBottomSheet<Color>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('颜色', style: TimetableTheme.titleStyle()),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final color in TimetableTheme.examColorOptions)
                    Semantics(
                      button: true,
                      selected: color.toARGB32() == c.settings.examColor,
                      label: '考试颜色 ${_hex(color)}',
                      child: InkWell(
                        key: Key('tt_exam_color_${_hex(color)}'),
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.pop(sheetContext, color),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                          child: color.toARGB32() == c.settings.examColor
                              ? const Icon(
                                  Icons.check,
                                  color: TimetableTheme.examText,
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    final argb = picked.toARGB32();
    if (argb == c.settings.examColor) return;
    await c.updateSettings(c.settings.copyWith(examColor: argb));
  }

  static String _hex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  Future<void> _pickLead(BuildContext context, TimetableController c) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('提前时间', style: TimetableTheme.titleStyle()),
            ),
            for (final m in TimetableSettings.reminderLeadOptions)
              ListTile(
                key: Key('tt_settings_lead_$m'),
                title: Text('$m 分钟'),
                trailing: m == c.settings.reminderLeadMinutes
                    ? const Icon(Icons.check, color: TimetableTheme.accent)
                    : null,
                onTap: () => Navigator.pop(sheetContext, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == c.settings.reminderLeadMinutes) return;
    await c.updateSettings(c.settings.copyWith(reminderLeadMinutes: picked));
  }
}

/// 课程配色二级页：每个方案一行（名字 + 8 个色块），单选。
class TimetablePalettePage extends StatelessWidget {
  const TimetablePalettePage({super.key, this.controller});

  final TimetableController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    return Scaffold(
      backgroundColor: TimetableTheme.pageBg,
      appBar: AppBar(title: const Text('配色')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final current = coursePaletteSchemeOf(c.settings.paletteScheme);
          return ListView(
            children: [
              _Group(
                title: '方案',
                children: [
                  for (final scheme in CoursePaletteScheme.values)
                    _Row(
                      key: Key('tt_palette_${coursePaletteSchemeKey(scheme)}'),
                      title: coursePaletteSchemeLabel(scheme),
                      onTap: () {
                        final key = coursePaletteSchemeKey(scheme);
                        if (c.settings.paletteScheme == key) return;
                        c.updateSettings(
                          c.settings.copyWith(paletteScheme: key),
                        );
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final pair in TimetableTheme.pairsOf(
                            scheme,
                          ).take(8))
                            Container(
                              width: 14,
                              height: 14,
                              margin: const EdgeInsets.only(left: 3),
                              decoration: BoxDecoration(
                                color: pair.bg,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Icon(
                            scheme == current
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: scheme == current
                                ? TimetableTheme.accent
                                : TimetableTheme.hint,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 一组：组标题（13sp onSurfaceVariant）+ 白底圆角 12 卡片。
class _Group extends StatelessWidget {
  const _Group({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TimetableTheme.pagePaddingH,
        12,
        TimetableTheme.pagePaddingH,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Semantics(
              container: true,
              header: true,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Material(
            color: TimetableTheme.surface,
            borderRadius: BorderRadius.circular(
              TimetableSettingsPage.cardRadius,
            ),
            clipBehavior: Clip.antiAlias,
            child: _GroupScope(
              title: title,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把卡片标题传给行，读屏标签用「卡片名，行名」（§13.16）。
class _GroupScope extends InheritedWidget {
  const _GroupScope({required this.title, required super.child});

  final String title;

  /// 「卡片名，行名」；不在卡片里时只读行名。
  static String labelFor(BuildContext context, String row) {
    final group = context
        .dependOnInheritedWidgetOfExactType<_GroupScope>()
        ?.title;
    return group == null || group.isEmpty ? row : '$group，$row';
  }

  @override
  bool updateShouldNotify(_GroupScope oldWidget) => oldWidget.title != title;
}

/// 行高 52 的一行：标题 + 右侧控件。[enabled] 为 false 时整行置灰不可点。
/// 可点的行合并成一个读屏节点（「卡片名，行名」+ 右侧状态）；分段选择行不合并，
/// 各选项仍可单独聚焦。
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.semanticsStatus,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// 非空时读屏为「卡片名，行名，状态」（右侧状态文字需自行排除读屏，避免重复）。
  final String? semanticsStatus;

  @override
  Widget build(BuildContext context) {
    final Widget row = InkWell(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        height: TimetableSettingsPage.rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  semanticsLabel: semanticsStatus == null
                      ? _GroupScope.labelFor(context, title)
                      : '${_GroupScope.labelFor(context, title)}，$semanticsStatus',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TimetableTheme.bodyStyle(
                    color: TimetableTheme.titleText,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
    // 每行独立成读屏节点，不与卡片标题、相邻行混读。
    final merged = onTap == null
        ? Semantics(container: true, child: row)
        : MergeSemantics(child: row);
    if (enabled) return merged;
    return IgnorePointer(child: Opacity(opacity: 0.38, child: merged));
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Row(
      title: title,
      onTap: () => onChanged(!value),
      trailing: Switch(
        value: value,
        activeThumbColor: TimetableTheme.accent,
        onChanged: onChanged,
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.title,
    required this.valueLabel,
    required this.slider,
    this.valueKey,
  });

  final String title;
  final String valueLabel;
  final Widget slider;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: SizedBox(
        height: TimetableSettingsPage.rowHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16),
          child: Row(
            children: [
              // 左侧标题定宽（各滑块行相同），保证滑块起止 x 一致。
              SizedBox(
                width: TimetableSettingsPage.sliderLabelWidth,
                child: Text(
                  title,
                  semanticsLabel: _GroupScope.labelFor(context, title),
                  maxLines: 1,
                  softWrap: false,
                  style: TimetableTheme.bodyStyle(
                    color: TimetableTheme.titleText,
                  ),
                ),
              ),
              Expanded(child: slider),
              SizedBox(
                width: 40,
                child: Text(
                  valueLabel,
                  key: valueKey,
                  textAlign: TextAlign.end,
                  style: TimetableTheme.bodyStyle(color: TimetableTheme.hint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 紧凑单选分段（每周第一天、文字大小）。
class _Segments<T> extends StatelessWidget {
  const _Segments({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;

  /// 未选中项描边（中性灰）。
  static const Color unselectedBorder = Color(0xFFD0D4DC);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in options.entries)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: ChoiceChip(
              key: ValueKey('seg_${e.value}'),
              label: Text(e.value),
              selected: e.key == selected,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              selectedColor: TimetableTheme.accentSoft,
              surfaceTintColor: Colors.transparent,
              // 未选中：中性灰描边；选中维持原样（浅蓝底、无描边）。不用 M3 种子色描边。
              side: e.key == selected
                  ? const BorderSide(color: Colors.transparent)
                  : const BorderSide(color: _Segments.unselectedBorder),
              labelStyle: TextStyle(
                fontSize: 13,
                color: e.key == selected
                    ? TimetableTheme.accent
                    : TimetableTheme.labelText,
              ),
              onSelected: (_) {
                if (e.key != selected) onSelected(e.key);
              },
            ),
          ),
      ],
    );
  }
}
