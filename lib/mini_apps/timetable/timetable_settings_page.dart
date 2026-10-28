import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'timetable_appearance_page.dart';
import 'timetable_change_log_page.dart';
import 'timetable_copy.dart';
import 'timetable_day_swap_ui.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_reminder_guide.dart';
import 'timetable_settings_text.dart';
import 'timetable_settings_widgets.dart';
import 'timetable_next_day_reminder_channel.dart';
import 'timetable_store.dart';
import 'timetable_theme.dart';

export 'timetable_appearance_page.dart'
    show TimetableAppearancePage, TimetablePalettePage;
export 'timetable_reminder_guide.dart';
export 'timetable_settings_text.dart';

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

/// 课表设置：外观、首页、小组件、提醒与课表管理。
/// 所有修改读取控制器当前值再合并，保留既有设置键和即时保存行为。
class TimetableSettingsPage extends StatelessWidget {
  const TimetableSettingsPage({
    super.key,
    this.controller,
    this.onReminderToggle,
    this.showReminderCard = kShowReminderSettings,
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

  /// 格子高度步长（dp）。
  static const double periodHeightStep = 2;

  /// 卡片行高与圆角（spec §13.3）。
  static const double rowHeight = 52;

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
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
      ),
    );
    if (picked == null) return;
    await c.updateSettings(c.settings.copyWith(nextDayReminderMinute: picked));
    await NextDayReminderChannel.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    void update(TimetableSettings Function(TimetableSettings s) change) =>
        c.updateSettings(change(c.settings));

    return Scaffold(
      backgroundColor: TimetableTheme.colorsOf(context).pageBg,
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                final s = c.settings;
                final a = reminderActions ?? ReminderActions(controller: c);
                final nextDayRows = <Widget>[
                  TimetableSettingsSwitchRow(
                    key: const Key('tt_settings_next_day_reminder'),
                    title: TtSettingsText.nextDayReminder,
                    value: s.nextDayReminderEnabled,
                    onChanged: (v) async {
                      await c.updateSettings(
                        c.settings.copyWith(nextDayReminderEnabled: v),
                      );
                      if (v) await NextDayReminderChannel.requestPermission();
                    },
                  ),
                  TimetableSettingsRow(
                    key: const Key('tt_settings_next_day_time'),
                    title: TtSettingsText.nextDayTime,
                    enabled: s.nextDayReminderEnabled,
                    value: _reminderTime(s.nextDayReminderMinute),
                    showChevron: true,
                    onTap: () => _pickNextDayTime(context, c),
                  ),
                ];
                return ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    TimetableSettingsGroup(
                      key: const Key('tt_settings_appearance_card'),
                      title: '课表',
                      children: [
                        TimetableSettingsRow(
                          key: const Key('tt_settings_appearance_entry'),
                          title: '外观',
                          showChevron: true,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  TimetableAppearancePage(controller: c),
                            ),
                          ),
                        ),
                      ],
                    ),
                    TimetableSettingsGroup(
                      key: const Key('tt_settings_group_home'),
                      title: '首页与桌面',
                      children: [
                        TimetableSettingsChoiceRow<int>(
                          key: const Key('tt_settings_home_max_items'),
                          title: TtSettingsText.homeMaxItems,
                          showInlineOptions: false,
                          options: const {1: '1', 2: '2', 3: '3', 4: '4'},
                          selected: s.homeMaxItems,
                          onSelected: (v) =>
                              update((x) => x.copyWith(homeMaxItems: v)),
                        ),
                        TimetableSettingsSwitchRow(
                          key: const Key('tt_settings_show_tomorrow'),
                          title: '显示明天的课',
                          value: s.showTomorrowOnHome,
                          onChanged: (v) =>
                              update((x) => x.copyWith(showTomorrowOnHome: v)),
                        ),
                        if (showReminderCard)
                          TimetableSettingsRow(
                            key: const Key('tt_settings_widget_entry'),
                            title: TtSettingsText.widgetCard,
                            showChevron: true,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => TimetableWidgetSettingsPage(
                                  controller: c,
                                  actions: a,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (showReminderCard)
                      _ReminderCard(
                        controller: c,
                        actions: a,
                        onToggle: onReminderToggle,
                        nextDayRows: nextDayRows,
                      )
                    else
                      TimetableSettingsGroup(
                        key: const Key('tt_settings_group_reminder'),
                        title: TtSettingsText.reminderCard,
                        children: nextDayRows,
                      ),
                    TimetableSettingsGroup(
                      key: const Key('tt_settings_group_management'),
                      children: [
                        TimetableSettingsRow(
                          key: const Key('tt_settings_management_entry'),
                          title: '课表管理',
                          showChevron: true,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  TimetableManagementPage(controller: c),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
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
      content: const Text(TimetableSettingsPage.restoreConfirmText),
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

/// 桌面小组件设置：预览显示内容，所有选项沿用原有设置与原生刷新入口。
class TimetableWidgetSettingsPage extends StatelessWidget {
  const TimetableWidgetSettingsPage({super.key, this.controller, this.actions});

  final TimetableController? controller;
  final ReminderActions? actions;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    final a = actions ?? ReminderActions(controller: c);
    return _SettingsSubpage(
      title: TtSettingsText.widgetCard,
      controller: c,
      children: () => [
        TimetableSettingsGroup(
          children: [_WidgetSettingsPreview(settings: c.settings)],
        ),
        TimetableSettingsGroup(
          key: const Key('tt_settings_group_widget'),
          children: [
            TimetableSettingsChoiceRow<int>(
              key: const Key('tt_settings_widgetCourseCount'),
              title: TtSettingsText.courseCount,
              showInlineOptions: false,
              options: {
                for (final n in kWidgetCourseCountOptions)
                  n: TtSettingsText.courses(n),
              },
              selected: a.widgetCourseCount,
              onSelected: a.setWidgetCourseCount,
            ),
            for (final option in WidgetDisplayOption.values)
              TimetableSettingsSwitchRow(
                key: Key('tt_settings_${option.field}'),
                title: option.title,
                value: a.widgetOption(option),
                onChanged: (v) => a.setWidgetOption(option, v),
              ),
          ],
        ),
      ],
    );
  }
}

/// 调课、变动记录和恢复操作集中管理，恢复继续保留二次确认。
class TimetableManagementPage extends StatelessWidget {
  const TimetableManagementPage({super.key, this.controller});

  final TimetableController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    return _SettingsSubpage(
      title: '课表管理',
      controller: c,
      children: () => [
        TimetableSettingsGroup(
          key: const Key('tt_settings_group_management'),
          children: [
            TimetableSettingsRow(
              key: const Key('tt_settings_day_swaps'),
              title: '整天调课',
              showChevron: true,
              onTap: () => openDaySwapPage(context, c),
            ),
            TimetableSettingsRow(
              key: const Key('tt_settings_change_log'),
              title: TimetableCopy.changeLogSettingsTitle,
              showChevron: true,
              onTap: () => openTimetableChangeLogPage(context, controller: c),
            ),
          ],
        ),
        TimetableSettingsGroup(
          key: const Key('tt_settings_group_restore'),
          children: [
            TimetableSettingsRow(
              key: const Key('tt_settings_restore_jwxt'),
              title: '恢复教务课程',
              titleColor: TimetableTheme.colorsOf(context).danger,
              onTap: () => _confirmRestoreAll(context, c),
            ),
          ],
        ),
        if (kDebugMode && c.hasCourses)
          TimetableSettingsGroup(
            key: const Key('tt_settings_group_debug'),
            title: '调试',
            children: [
              TimetableSettingsRow(
                key: const Key('tt_settings_debug_clear'),
                title: '[DEBUG] 清空本地课表',
                onTap: () => c.clearCourses(),
              ),
            ],
          ),
      ],
    );
  }
}

class _SettingsSubpage extends StatelessWidget {
  const _SettingsSubpage({
    required this.title,
    required this.controller,
    required this.children,
  });
  final String title;
  final TimetableController controller;
  final List<Widget> Function() children;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TimetableTheme.colorsOf(context).pageBg,
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: children(),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 使用明确的示例内容演示开关效果，不读取或生成真实课程数据。
class _WidgetSettingsPreview extends StatelessWidget {
  const _WidgetSettingsPreview({required this.settings});
  final TimetableSettings settings;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final count = TimetableSettings.sanitizeCourseCount(
      settings.widgetCourseCount,
    );
    return Padding(
      key: const Key('tt_settings_widget_preview'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '显示效果预览',
            style: TimetableSettingsRow.textStyle(context)
                .copyWith(fontSize: 13, color: colors.labelText),
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < count; index++)
            Padding(
              key: ValueKey('tt_widget_preview_course_$index'),
              padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '示例课程${const ['一', '二', '三'][index]}',
                        style: TimetableSettingsRow.textStyle(context)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (settings.widgetShowTeacher) '示例教师',
                          if (settings.widgetShowLocation) '示例教室',
                          if (settings.widgetShowPeriod)
                            '第 ${index * 2 + 1}–${index * 2 + 2} 节',
                          '${(8 + index * 2).toString().padLeft(2, '0')}:00',
                        ].join(' · '),
                        style: TimetableSettingsRow.textStyle(context)
                            .copyWith(fontSize: 12, color: colors.labelText),
                      ),
                      if (index == 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          settings.widgetShowCountdown
                              ? '30 分钟后上课'
                              : '08:00 上课',
                          style: TimetableSettingsRow.textStyle(context)
                              .copyWith(
                                fontSize: 12,
                                color: TimetableTheme.settingsAccentText(
                                  context,
                                ),
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (settings.widgetShowCount) ...[
            const SizedBox(height: 8),
            Text(
              '还有 2 节',
              style: TimetableSettingsRow.textStyle(context)
                  .copyWith(fontSize: 12, color: colors.labelText),
            ),
          ],
        ],
      ),
    );
  }
}

/// 上课与次日课表提醒共用分组，权限提示紧邻上课提醒，运行限制集中在帮助页。
class _ReminderCard extends StatefulWidget {
  const _ReminderCard({
    required this.controller,
    required this.actions,
    required this.nextDayRows,
    this.onToggle,
  });

  final TimetableController controller;
  final ReminderActions actions;
  final ReminderToggleHandler? onToggle;
  final List<Widget> nextDayRows;

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
      if (result && mounted) await _showFirstEnableHint();
      return;
    }
    final s = await widget.actions.setReminderEnabled(v);
    if (mounted) setState(() => _perm = s);
    if (v && widget.controller.settings.reminderEnabled && mounted) {
      await _showFirstEnableHint();
    }
  }

  void _openGuide() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TimetableKeepAliveGuidePage(actions: widget.actions),
    ),
  );

  Future<void> _showFirstEnableHint() async {
    if (await TimetableStore.readReminderIntroSeen() || !mounted) return;
    await TimetableStore.saveReminderIntroSeen();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(TtSettingsText.reminderIntro),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: '查看说明', onPressed: _openGuide),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.settings;
    final colors = TimetableTheme.colorsOf(context);
    final hint = reminderPermissionHint(_perm, s.reminderEnabled);
    return TimetableSettingsGroup(
      key: const Key('tt_settings_group_reminder'),
      title: TtSettingsText.reminderCard,
      children: [
        TimetableSettingsSwitchRow(
          key: const Key('tt_settings_reminder'),
          title: TtSettingsText.reminderSwitch,
          value: s.reminderEnabled,
          onChanged: _toggle,
        ),
        if (hint != null)
          Padding(
            key: const Key('tt_settings_reminder_permission'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: colors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    style: TimetableSettingsRow.textStyle(context)
                        .copyWith(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const Key('tt_settings_reminder_goto'),
                  onPressed: () => !_perm.notificationsGranted
                      ? widget.actions.openNotificationSettings()
                      : widget.actions.openExactAlarmSettings(),
                  child: Text(
                    TtSettingsText.gotoSettings,
                    style: TextStyle(
                      color: TimetableTheme.settingsAccentText(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        TimetableSettingsChoiceRow<int>(
          key: const Key('tt_settings_reminder_lead'),
          title: TtSettingsText.reminderLead,
          unit: TtSettingsText.minuteUnit,
          showInlineOptions: false,
          enabled: s.reminderEnabled,
          options: {for (final m in kReminderLeadChoices) m: '$m'},
          selected: displayReminderLead(s.reminderLeadMinutes),
          onSelected: widget.actions.setReminderLeadMinutes,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Divider(height: 1, color: colors.divider),
        ),
        ...widget.nextDayRows,
        TimetableSettingsRow(
          key: const Key('tt_settings_keepalive_entry'),
          title: TtSettingsText.keepAliveEntry,
          showChevron: true,
          onTap: _openGuide,
        ),
      ],
    );
  }
}
