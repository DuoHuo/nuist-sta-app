import 'timetable_appearance_page.dart';
import 'timetable_change_log_page.dart';
import 'timetable_copy.dart';
import 'timetable_day_swap_ui.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

export 'timetable_appearance_page.dart'
    show TimetableAppearancePage, TimetablePalettePage;
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_reminder_guide.dart';
export 'timetable_reminder_guide.dart';
export 'timetable_settings_text.dart';
import 'timetable_settings_text.dart';
import 'timetable_next_day_reminder_channel.dart';
import 'timetable_theme.dart';

/// 上课提醒开关的接入点（给权限/排通知留的位置）。
///
/// 传入时替代默认实现：用户拨动「上课提醒」时先调用，返回最终要写入的开关值。
/// 为空时走 [ReminderActions.setReminderEnabled]（申请通知权限，开关保持用户选择）。
typedef ReminderToggleHandler = Future<bool> Function(
  BuildContext context,
  bool enable,
);

// 上课提醒入口（docs/notify-widget-interface.md §1）。
const bool kShowReminderSettings = true;

/// 课表设置：首页 / 小组件 / 上课提醒 / 明日提醒 / 其他；周课表显示项统一放在外观页。
/// 「提醒」卡片受 [kShowReminderSettings] 控制。
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
    this.reminderActions,
  });

  /// 提醒卡片 / 保活引导页的操作；为空时用 [ReminderActions] 默认实现。
  final ReminderActions? reminderActions;

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

  static String _reminderTime(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  Future<void> _pickNextDayTime(
    BuildContext context,
    TimetableController c,
  ) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final minute in TimetableSettings.nextDayReminderOptions)
              ListTile(
                title: Text(_reminderTime(minute)),
                trailing: minute == c.settings.nextDayReminderMinute
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, minute),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await c.updateSettings(c.settings.copyWith(nextDayReminderMinute: picked));
    await NextDayReminderChannel.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    // 每次点击都读当前设置再合并。
    void update(TimetableSettings Function(TimetableSettings s) change) =>
        c.updateSettings(change(c.settings));

    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              // 外观入口：置顶的独立单行卡（spec-settings-regroup §1），无分组标题、
              // 无副标题，与其它卡片同 surface / 圆角 / 水平内边距。
              _Group(
                key: const Key('tt_settings_appearance_card'),
                children: [
                  _Row(
                    key: const Key('tt_settings_appearance_entry'),
                    title: '外观',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TimetableAppearancePage(controller: c),
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: TimetableTheme.colorsOf(context).hint,
                    ),
                  ),
                ],
              ),
              _Group(
                key: const Key('tt_settings_group_home'),
                title: '首页',
                children: [
                  _Row(
                    key: const Key('tt_settings_home_max_items'),
                    title: '首页显示课数',
                    trailing: _Segments<int>(
                      key: const Key('tt_settings_home_max_segments'),
                      options: const {1: '1', 2: '2', 3: '3', 4: '4'},
                      selected: s.homeMaxItems,
                      onSelected: (v) =>
                          update((x) => x.copyWith(homeMaxItems: v)),
                    ),
                  ),
                  _SwitchRow(
                    key: const Key('tt_settings_show_tomorrow'),
                    title: '显示明天的课',
                    value: s.showTomorrowOnHome,
                    onChanged: (v) =>
                        update((x) => x.copyWith(showTomorrowOnHome: v)),
                  ),
                ],
              ),

              if (showReminderCard)
                Builder(
                  builder: (context) {
                    final a = reminderActions ?? ReminderActions(controller: c);
                    return _Group(
                      key: const Key('tt_settings_group_widget'),
                      title: TtSettingsText.widgetCard,
                      children: [
                        _Row(
                          key: const Key('tt_settings_widgetCourseCount'),
                          title: TtSettingsText.courseCount,
                          trailing: _Segments<int>(
                            options: {
                              for (final n in kWidgetCourseCountOptions)
                                n: TtSettingsText.courses(n),
                            },
                            selected: a.widgetCourseCount,
                            onSelected: a.setWidgetCourseCount,
                          ),
                        ),
                        for (final o in WidgetDisplayOption.values)
                          SwitchListTile(
                            key: Key('tt_settings_${o.field}'),
                            title: Text(
                              o.title,
                              style: TimetableTheme.bodyStyle(
                                color: TimetableTheme.colorsOf(context)
                                    .titleText,
                              ),
                            ),
                            subtitle: o.subtitle == null
                                ? null
                                : Text(
                                    o.subtitle!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                            value: a.widgetOption(o),
                            activeThumbColor: TimetableTheme.colorsOf(context)
                                .accent,
                            onChanged: (v) => a.setWidgetOption(o, v),
                          ),
                      ],
                    );
                  },
                ),
              if (showReminderCard)
                _ReminderCard(
                  controller: c,
                  actions: reminderActions ?? ReminderActions(controller: c),
                  onToggle: onReminderToggle,
                ),
              _Group(
                key: const Key('tt_settings_group_next_day_reminder'),
                title: '明日提醒',
                children: [
                  _SwitchRow(
                    key: const Key('tt_settings_next_day_reminder'),
                    title: '明日提醒',
                    value: s.nextDayReminderEnabled,
                    onChanged: (v) async {
                      // 先落盘/刷新 UI，再请求权限，避免开关卡住灰显行。
                      await c.updateSettings(
                        c.settings.copyWith(nextDayReminderEnabled: v),
                      );
                      if (v) {
                        await NextDayReminderChannel.requestPermission();
                      }
                    },
                  ),
                  _Row(
                    key: const Key('tt_settings_next_day_time'),
                    title: '提醒时间',
                    enabled: s.nextDayReminderEnabled,
                    trailing: Text(_reminderTime(s.nextDayReminderMinute)),
                    onTap: () => _pickNextDayTime(context, c),
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
                                  ? TimetableTheme.colorsOf(context).hint
                                  : TimetableTheme.colorsOf(context).accent,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.colorsOf(context).hint,
                        ),
                      ],
                    ),
                  ),
                  _Row(
                    key: const Key('tt_settings_change_log'),
                    title: TimetableCopy.changeLogSettingsTitle,
                    semanticsStatus: TimetableCopy.changeLogSettingsSubtitle,
                    onTap: () =>
                        openTimetableChangeLogPage(context, controller: c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: Text(
                            TimetableCopy.changeLogSettingsSubtitle,
                            style: TimetableTheme.bodyStyle(
                              color: TimetableTheme.colorsOf(context).hint,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.colorsOf(context).hint,
                        ),
                      ],
                    ),
                  ),
                  _Row(
                    key: const Key('tt_settings_day_swaps'),
                    title: '整天调课',
                    semanticsStatus: c.daySwaps.isEmpty
                        ? '无'
                        : '${c.daySwaps.length} 条',
                    onTap: () => openDaySwapPage(context, c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: Text(
                            c.daySwaps.isEmpty ? '无' : '${c.daySwaps.length} 条',
                            style: TimetableTheme.bodyStyle(
                              color: TimetableTheme.colorsOf(context).hint,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: TimetableTheme.colorsOf(context).hint,
                        ),
                      ],
                    ),
                  ),
                  // 「最下面」：普通项的最后一行，debug 行之前。
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
            style: TextButton.styleFrom(
              foregroundColor: TimetableTheme.colorsOf(context).danger,
            ),
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
}

/// 一组：组标题（13sp onSurfaceVariant）+ 白底圆角 12 卡片。
/// [title] 为空时不画标题区，卡片本身就是独立单行卡（如设置首页置顶的「外观」）。
class _Group extends StatelessWidget {
  const _Group({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
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
          if (title != null)
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
            color: TimetableTheme.colorsOf(context).surface,
            borderRadius: BorderRadius.circular(
              TimetableSettingsPage.cardRadius,
            ),
            clipBehavior: Clip.antiAlias,
            child: _GroupScope(
              title: title ?? '',
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: TimetableSettingsPage.rowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final label = Text(
                title,
                semanticsLabel: semanticsStatus == null
                    ? _GroupScope.labelFor(context, title)
                    : '${_GroupScope.labelFor(context, title)}，$semanticsStatus',
                style: TimetableTheme.bodyStyle(
                  color: TimetableTheme.colorsOf(context).titleText,
                ),
              );
              // 开关 / 箭头始终右置；仅分段等宽控件在窄屏/大字号下改上下排。
              final stackTrailing =
                  trailing != null &&
                  trailing is! Switch &&
                  trailing is! Icon &&
                  (constraints.maxWidth < 340 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20);
              if (stackTrailing) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, const SizedBox(height: 6), trailing!],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: label),
                  ?trailing,
                ],
              );
            },
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
        activeThumbColor: TimetableTheme.colorsOf(context).accent,
        onChanged: onChanged,
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
  /// 浅色未选中描边；深色下改用 [TimetableColors.offWeekBorder]（PM 10/19）。
  static const Color unselectedBorder = Color(0xFFD0D4DC);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      runSpacing: 6,
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
              selectedColor: TimetableTheme.colorsOf(context).accentSoft,
              surfaceTintColor: Colors.transparent,
              // 未选中：中性灰描边；选中维持原样（浅蓝底、无描边）。不用 M3 种子色描边。
              side: e.key == selected
                  ? const BorderSide(color: Colors.transparent)
                  : BorderSide(
                      color: TimetableTheme.colorsOf(context).isDark
                          ? TimetableTheme.colorsOf(context).offWeekBorder
                          : _Segments.unselectedBorder,
                    ),
              labelStyle: TextStyle(
                fontSize: 13,
                color: e.key == selected
                    ? TimetableTheme.colorsOf(context).accent
                    : TimetableTheme.colorsOf(context).labelText,
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

/// 「上课提醒」卡片：开关 + 提前时间 + 权限提示 + 后台运行引导入口。
/// 回前台时重新读权限状态（用户从系统设置返回后刷新提示）。
class _ReminderCard extends StatefulWidget {
  const _ReminderCard({
    required this.controller,
    required this.actions,
    this.onToggle,
  });

  final TimetableController controller;
  final ReminderActions actions;
  final ReminderToggleHandler? onToggle;

  @override
  State<_ReminderCard> createState() => _ReminderCardState();
}

class _ReminderCardState extends State<_ReminderCard>
    with WidgetsBindingObserver {
  NotifyPermissionStatus _perm = NotifyPermissionStatus.unsupported;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final s = await widget.actions.permissionStatus();
    if (mounted) setState(() => _perm = s);
  }

  Future<void> _toggle(bool v) async {
    final handler = widget.onToggle;
    final c = widget.controller;
    if (handler != null) {
      final result = await handler(context, v);
      if (result != c.settings.reminderEnabled) {
        await c.updateSettings(c.settings.copyWith(reminderEnabled: result));
      }
      await _refreshPermission();
      return;
    }
    final s = await widget.actions.setReminderEnabled(v);
    if (mounted) setState(() => _perm = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.settings;
    final colors = TimetableTheme.colorsOf(context);
    final hint = reminderPermissionHint(_perm, s.reminderEnabled);
    final notifyDenied = !_perm.notificationsGranted;
    return _Group(
      key: const Key('tt_settings_group_reminder'),
      title: TtSettingsText.reminderCard,
      children: [
        _SwitchRow(
          key: const Key('tt_settings_reminder'),
          title: TtSettingsText.reminderSwitch,
          value: s.reminderEnabled,
          onChanged: _toggle,
        ),
        // spec §13.4：开关下面 12sp onSurfaceVariant 小字。
        Padding(
          key: const Key('tt_settings_reminder_hint'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            TtSettingsText.reminderHolidayHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (hint != null)
          Padding(
            key: const Key('tt_settings_reminder_permission'),
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hint,
                    style: TextStyle(fontSize: 12, color: colors.titleText),
                  ),
                ),
                TextButton(
                  key: const Key('tt_settings_reminder_goto'),
                  onPressed: () => notifyDenied
                      ? widget.actions.openNotificationSettings()
                      : widget.actions.openExactAlarmSettings(),
                  child: Text(
                    TtSettingsText.gotoSettings,
                    style: TextStyle(color: colors.accent),
                  ),
                ),
              ],
            ),
          ),
        _Row(
          key: const Key('tt_settings_reminder_lead'),
          title: TtSettingsText.reminderLead,
          enabled: s.reminderEnabled,
          // 文案规范：提前 [5 / 10 / 15 / 30 分钟]，单位写在档位后面一次。
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Segments<int>(
                options: {for (final m in kReminderLeadChoices) m: '$m'},
                selected: displayReminderLead(s.reminderLeadMinutes),
                onSelected: widget.actions.setReminderLeadMinutes,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  TtSettingsText.minuteUnit,
                  style: TimetableTheme.bodyStyle(color: colors.hint),
                ),
              ),
            ],
          ),
        ),
        _Row(
          key: const Key('tt_settings_keepalive_entry'),
          title: TtSettingsText.keepAliveEntry,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  TimetableKeepAliveGuidePage(actions: widget.actions),
            ),
          ),
          trailing: Icon(Icons.chevron_right, color: colors.hint),
        ),
        Padding(
          key: const Key('tt_settings_reminder_7day'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            TtSettingsText.reminderSevenDayHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
