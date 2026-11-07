import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import 'timetable_appearance_page.dart';
import 'timetable_change_log_page.dart';
import 'timetable_copy.dart';
import 'timetable_day_swap_ui.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_notify_plan.dart';
import 'timetable_persistence_feedback.dart';
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
    var saving = false;
    String? saveError;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (saveError case final message?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TimetablePersistenceErrorText(message),
                  ),
                for (final minute in TimetableSettings.nextDayReminderOptions)
                  ListTile(
                    title: Text(_reminderTime(minute)),
                    trailing: minute == c.settings.nextDayReminderMinute
                        ? const Icon(Icons.check)
                        : null,
                    onTap: saving
                        ? null
                        : () async {
                            setSheetState(() {
                              saving = true;
                              saveError = null;
                            });
                            final saved = await _saveSettingsAction(
                              sheetContext,
                              () => c.updateSettings(
                                c.settingsForEditing.copyWith(
                                  nextDayReminderMinute: minute,
                                ),
                              ),
                              onError: (message) =>
                                  setSheetState(() => saveError = message),
                            );
                            if (!sheetContext.mounted) return;
                            setSheetState(() => saving = false);
                            if (saved) Navigator.pop(sheetContext, true);
                          },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !context.mounted) return;
    await NextDayReminderChannel.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TimetableController.instance;
    Future<bool> update(
      TimetableSettings Function(TimetableSettings s) change,
    ) => _saveSettingsAction(
      context,
      () => c.updateSettings(change(c.settingsForEditing)),
    );

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
                      final saved = await update(
                        (s) => s.copyWith(nextDayReminderEnabled: v),
                      );
                      if (saved && v && context.mounted) {
                        await NextDayReminderChannel.requestPermission();
                      }
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

/// 设置操作保存成功后才继续关闭面板或发起权限等后续操作。
Future<bool> _saveSettingsAction(
  BuildContext context,
  Future<void> Function() action, {
  ValueChanged<String>? onError,
}) async =>
    await withTimetablePersistenceFeedback(context, () async {
      await action();
      return true;
    }, onError: onError) ==
    true;

/// 「恢复教务课程」：二次确认后调用 [TimetableController.restoreAllJwxt]。
Future<void> _confirmRestoreAll(
  BuildContext context,
  TimetableController c,
) async {
  var saving = false;
  String? saveError;
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        key: const Key('tt_restore_jwxt_dialog'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(TimetableSettingsPage.restoreConfirmText),
            if (saveError case final message?) ...[
              const SizedBox(height: 12),
              TimetablePersistenceErrorText(message),
            ],
          ],
        ),
        actions: [
          TextButton(
            key: const Key('tt_restore_jwxt_cancel'),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('tt_restore_jwxt_confirm'),
            style: TextButton.styleFrom(
              foregroundColor: TimetableTheme.colorsOf(context).danger,
            ),
            onPressed: saving
                ? null
                : () async {
                    setDialogState(() {
                      saving = true;
                      saveError = null;
                    });
                    final changed = await withTimetablePersistenceFeedback(
                      dialogContext,
                      c.restoreAllJwxt,
                      onError: (message) =>
                          setDialogState(() => saveError = message),
                    );
                    if (!dialogContext.mounted) return;
                    setDialogState(() => saving = false);
                    if (changed != null) Navigator.pop(dialogContext, changed);
                  },
            child: const Text('恢复'),
          ),
        ],
      ),
    ),
  );
  if (changed == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    AppSnackBar(
      tone: changed ? AppSnackBarTone.success : AppSnackBarTone.info,
      behavior: SnackBarBehavior.floating,
      content: Text(changed ? '已恢复教务课程' : '没有需要恢复的修改'),
    ),
  );
}

/// 桌面小组件设置：预览显示内容，所有选项沿用原有设置与原生刷新入口。
class TimetableWidgetSettingsPage extends StatefulWidget {
  const TimetableWidgetSettingsPage({super.key, this.controller, this.actions});

  final TimetableController? controller;
  final ReminderActions? actions;

  @override
  State<TimetableWidgetSettingsPage> createState() =>
      _TimetableWidgetSettingsPageState();
}

class _TimetableWidgetSettingsPageState
    extends State<TimetableWidgetSettingsPage>
    with WidgetsBindingObserver {
  bool _square = false;
  bool _previewLast = false;
  bool _pinning = false;
  bool _permissionSettingsPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_permissionSettingsPending) {
      return;
    }
    _permissionSettingsPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.warning,
          content: Text(TtSettingsText.pinWidgetPermissionHint),
        ),
      );
    });
  }

  /// 原生检查权限，未授权时先解释并等待确认，再打开系统设置。
  Future<void> _pin(ReminderActions a) async {
    if (_pinning) return;
    setState(() => _pinning = true);
    try {
      final square = _square;
      final result = await a.pinWidget(square: square);
      if (!mounted) return;
      switch (result) {
        case WidgetPinResult.requested:
          break;
        case WidgetPinResult.permissionRequired:
          final confirmed = await _showGuide(result, square: square);
          if (!confirmed || !mounted) return;
          final opened = await a.openWidgetShortcutSettings();
          if (!mounted) return;
          if (opened) {
            // 返回后再提示重新添加，不让说明在系统设置页打开时消失。
            _permissionSettingsPending = true;
          } else {
            await _showGuide(result, square: square, settingsUnavailable: true);
          }
        case WidgetPinResult.miuiManual:
        case WidgetPinResult.originOsManual:
        case WidgetPinResult.manual:
          await _showGuide(result, square: square);
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  Future<bool> _showGuide(
    WidgetPinResult result, {
    required bool square,
    bool settingsUnavailable = false,
  }) async {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          constraints: const BoxConstraints(maxWidth: 560),
          builder: (_) => _WidgetPinGuideSheet(
            result: result,
            square: square,
            settingsUnavailable: settingsUnavailable,
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller ?? TimetableController.instance;
    final a = widget.actions ?? ReminderActions(controller: c);
    return _SettingsSubpage(
      title: TtSettingsText.widgetCard,
      controller: c,
      children: () => [
        TimetableSettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<bool>(
                key: const Key('tt_settings_widget_size'),
                segments: const [
                  ButtonSegment(value: false, label: Text('4×2 今日课表')),
                  ButtonSegment(value: true, label: Text('2×2 当前与下一节')),
                ],
                selected: {_square},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _square = v.single),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('有后续课程'),
                    selected: !_previewLast,
                    onSelected: (_) => setState(() => _previewLast = false),
                  ),
                  ChoiceChip(
                    label: const Text('最后一节'),
                    selected: _previewLast,
                    onSelected: (_) => setState(() => _previewLast = true),
                  ),
                ],
              ),
            ),
            _WidgetSettingsPreview(
              settings: c.settings,
              square: _square,
              last: _previewLast,
            ),
            TimetableSettingsRow(
              key: const Key('tt_settings_widget_pin'),
              title: TtSettingsText.pinWidget,
              value: _square ? '2×2' : '4×2',
              showChevron: true,
              enabled: !_pinning,
              onTap: () => _pin(a),
            ),
          ],
        ),
        TimetableSettingsGroup(
          key: const Key('tt_settings_group_widget'),
          children: [
            if (!_square)
              TimetableSettingsChoiceRow<int>(
                key: const Key('tt_settings_widgetCourseCount'),
                title: TtSettingsText.courseCount,
                showInlineOptions: false,
                options: {
                  for (final n in kWidgetCourseCountOptions)
                    n: TtSettingsText.courses(n),
                },
                selected: a.widgetCourseCount,
                onSelected: (n) => _saveSettingsAction(
                  context,
                  () => a.setWidgetCourseCount(n),
                ),
              ),
            for (final option in WidgetDisplayOption.values)
              if (!_square ||
                  option == WidgetDisplayOption.teacher ||
                  option == WidgetDisplayOption.location)
                TimetableSettingsSwitchRow(
                  key: Key('tt_settings_${option.field}'),
                  title: option.title,
                  value: a.widgetOption(option),
                  onChanged: (v) => _saveSettingsAction(
                    context,
                    () => a.setWidgetOption(option, v),
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

/// 仅由添加失败或指定桌面的添加请求打开，步骤内容可滚动，确认按钮保留在底部。
class _WidgetPinGuideSheet extends StatelessWidget {
  const _WidgetPinGuideSheet({
    required this.result,
    required this.square,
    this.settingsUnavailable = false,
  });

  final WidgetPinResult result;
  final bool square;
  final bool settingsUnavailable;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final permission = result == WidgetPinResult.permissionRequired;
    final permissionPrompt = permission && !settingsUnavailable;
    final steps = TtSettingsText.pinWidgetSteps(
      result,
      square: square,
      settingsUnavailable: settingsUnavailable,
    );
    final bodyStyle = TimetableTheme.bodyStyle(color: colors.labelText)
        .copyWith(height: 1.5);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Material(
        key: const Key('tt_settings_widget_pin_manual'),
        color: colors.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TimetableTheme.sheetTopRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Semantics(
                  header: true,
                  child: Text(
                    permission
                        ? TtSettingsText.pinWidgetPermissionTitle
                        : TtSettingsText.pinWidgetGuideTitle,
                    style: TimetableTheme.titleStyle(color: colors.titleText)
                        .copyWith(fontSize: 20),
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    key: const Key('tt_widget_pin_guide_scroll'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          settingsUnavailable
                              ? TtSettingsText.pinWidgetSettingsUnavailable
                              : TtSettingsText.pinWidgetIntro(result),
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 24),
                        for (var index = 0; index < steps.length; index++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ExcludeSemantics(
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: colors.accent.withValues(
                                        alpha: 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '${index + 1}',
                                      textScaler: TextScaler.noScaling,
                                      style: TextStyle(
                                        fontSize: 13,
                                        height: 1,
                                        color: colors.accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        steps[index].$1,
                                        style:
                                            TimetableTheme.bodyStyle(
                                              color: colors.titleText,
                                            ).copyWith(
                                              fontWeight: FontWeight.w600,
                                              height: 1.5,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(steps[index].$2, style: bodyStyle),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Text(
                          TtSettingsText.pinWidgetTip(result),
                          style: bodyStyle,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('tt_widget_pin_guide_close'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => Navigator.pop(context, permissionPrompt),
                  child: Text(
                    permissionPrompt
                        ? TtSettingsText.pinWidgetOpenSettings
                        : '知道了',
                  ),
                ),
                if (permissionPrompt)
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('暂不开启'),
                  ),
              ],
            ),
          ),
        ),
      ),
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
                onTap: () =>
                    withTimetablePersistenceFeedback(context, c.clearCourses),
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
  const _WidgetSettingsPreview({
    required this.settings,
    required this.square,
    required this.last,
  });
  final TimetableSettings settings;
  final bool square;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final accent = TimetableTheme.settingsAccentText(context);
    final base = TextStyle(
      color: colors.titleText,
      fontSize: 12,
      height: square ? 1.2 : 1.35,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final scale = scaler.scale(12) / 12;
    final count = TimetableSettings.sanitizeCourseCount(
      settings.widgetCourseCount,
    );

    double textWidth(
      String value,
      double size, [
      FontWeight weight = FontWeight.normal,
    ]) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: base.copyWith(fontSize: size, fontWeight: weight),
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    Widget label(
      String value,
      double size, {
      Color? color,
      FontWeight? weight,
      Key? key,
    }) => Text(
      value,
      key: key,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(
        fontSize: size,
        color: color ?? colors.titleText,
        fontWeight: weight,
      ),
    );

    Widget bar(Color color) => SizedBox(
      width: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );

    return Padding(
      key: const Key('tt_settings_widget_preview'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label('显示效果预览 · 示例内容', 12, color: colors.labelText),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth
                  .clamp(0.0, square ? 160.0 : 320.0)
                  .toDouble();
              final height = square ? width : 168.0;
              final innerWidth = width - 20;
              final timerWidth = textWidth(
                '60 分钟',
                17,
                FontWeight.w600,
              ).clamp(68.0, double.infinity);
              final available =
                  innerWidth - (square ? 12 : 28 + timerWidth + 8);
              final minimal =
                  scale >= 1.5 ||
                  (!square &&
                      !last &&
                      count > 1 &&
                      height <
                          20 +
                              16 * scale +
                              4 +
                              56 * scale +
                              kWidgetBlockGapDp +
                              kWidgetNextCourseDp);
              final showClock =
                  !square &&
                  !minimal &&
                  textWidth('18:45–20:20', 10) <= available;
              final layout = widgetLayout(
                remaining: last ? 0 : 3,
                widthDp: width.round(),
                heightDp: height.round(),
                fontScale: scale,
                prefs: WidgetPrefs(
                  courseCount: count,
                  showCount: settings.widgetShowCount,
                ),
              );
              final follows = last
                  ? 0
                  : square
                  ? (scale < 1.3 ? 1 : 0)
                  : layout.rows;

              Widget course(int index) {
                final compact = index == 2;
                final hasClock =
                    !square && (index > 0 || showClock) && !minimal;
                final courseTimerWidth = index == 0
                    ? timerWidth
                    : textWidth(
                        '23:59',
                        15,
                        FontWeight.w500,
                      ).clamp(64.0, double.infinity);
                final contentWidth =
                    innerWidth -
                    (square ? 12 : 28 + (hasClock ? 8 + courseTimerWidth : 0));
                final name = index == 0
                    ? '高等数学 A'
                    : index == 1
                    ? '大学英语'
                    : '大学物理';
                final start = index == 0
                    ? '18:45'
                    : index == 1
                    ? '20:30'
                    : '21:20';
                final range = index == 0 ? '18:45–20:20' : '20:30–21:20';
                final location = index == 0 ? '示例教室 A101' : '示例教室 C102';
                var details = settings.widgetShowLocation ? location : '';
                final teacher = [
                  details,
                  if (settings.widgetShowTeacher) '示例教师',
                ].where((s) => s.isNotEmpty).join(' · ');
                if (!minimal && textWidth(teacher, 11) <= contentWidth) {
                  details = teacher;
                }
                final fullTime = settings.widgetShowPeriod && !square
                    ? '${index == 0 ? '第9–10节' : '第11–12节'} · $range'
                    : range;
                var time =
                    !minimal &&
                        textWidth(fullTime, square ? 11 : 10) <= contentWidth
                    ? fullTime
                    : textWidth(range, square ? 11 : 10) <= contentWidth
                    ? range
                    : textWidth('$start 上课', square ? 11 : 10) <= contentWidth
                    ? '$start 上课'
                    : start;
                if (square && index > 0) {
                  final prefix = '之后 $start';
                  final detail = [
                    prefix,
                    if (settings.widgetShowLocation) 'C102',
                  ].join(' · ');
                  time = textWidth(detail, 11) <= contentWidth
                      ? detail
                      : textWidth(prefix, 11) <= contentWidth
                      ? prefix
                      : start;
                }

                return IntrinsicHeight(
                  key: ValueKey('tt_widget_preview_course_data_$index'),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      bar(index == 0 ? accent : AppPalette.of(context).success),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            label(
                              name,
                              square
                                  ? (index == 0 ? 16 : 12)
                                  : (compact ? 13 : 14),
                              weight: FontWeight.w500,
                              key: ValueKey('tt_widget_preview_course_$index'),
                            ),
                            if (!compact &&
                                !minimal &&
                                details.isNotEmpty &&
                                (!square || index == 0)) ...[
                              const SizedBox(height: 2),
                              label(details, 11, color: colors.labelText),
                            ],
                            if (!compact) ...[
                              const SizedBox(height: 2),
                              label(
                                time,
                                square ? 11 : 10,
                                color: colors.labelText,
                                key: ValueKey('tt_widget_preview_time_$index'),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (hasClock) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: courseTimerWidth,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (!compact)
                                label(
                                  index == 0 && settings.widgetShowCountdown
                                      ? '距上课'
                                      : '上课',
                                  10,
                                  color: index == 0 ? accent : colors.labelText,
                                ),
                              label(
                                index == 0 && settings.widgetShowCountdown
                                    ? '49 分钟'
                                    : start,
                                index == 0
                                    ? 17
                                    : compact
                                    ? 12
                                    : 15,
                                color: index == 0 ? accent : colors.titleText,
                                weight: FontWeight.w500,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }

              Widget block(int index) => DecoratedBox(
                decoration: BoxDecoration(
                  color: square ? colors.surface : colors.chipBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: square
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Align(
                    heightFactor: index == 0 && (square || follows == 0)
                        ? 1
                        : null,
                    alignment: index == 0 && follows == 0
                        ? Alignment.topLeft
                        : Alignment.centerLeft,
                    child: course(index),
                  ),
                ),
              );

              final mainArea = Align(
                key: const Key('tt_widget_preview_main_area'),
                heightFactor: square || follows == 0 ? 1 : null,
                alignment: follows == 0
                    ? Alignment.topLeft
                    : Alignment.centerLeft,
                child: block(0),
              );

              return Center(
                child: SizedBox(
                  key: Key(
                    square ? 'tt_widget_preview_2x2' : 'tt_widget_preview_4x2',
                  ),
                  width: width,
                  height: height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: colors.divider),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!minimal) ...[
                            ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 16),
                              child: Row(
                                crossAxisAlignment: square
                                    ? CrossAxisAlignment.baseline
                                    : CrossAxisAlignment.center,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Expanded(
                                    child: label(
                                      square ? '我的课表' : '今日课表',
                                      square ? 11 : 12,
                                      color: colors.labelText,
                                      key: const Key(
                                        'tt_widget_preview_header_title',
                                      ),
                                    ),
                                  ),
                                  if (!square &&
                                      settings.widgetShowCount &&
                                      !last &&
                                      3 - follows > 0) ...[
                                    const SizedBox(width: 8),
                                    label('+${3 - follows}', 12, color: accent),
                                  ],
                                  const SizedBox(width: 8),
                                  label(
                                    '10/28',
                                    square ? 10 : 11,
                                    color: colors.labelText,
                                    key: const Key(
                                      'tt_widget_preview_header_date',
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  label(
                                    '周三',
                                    square ? 10 : 11,
                                    color: colors.accent,
                                    key: const Key('tt_widget_preview_weekday'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          if (square && follows > 0) const Spacer(),
                          if (!square && follows > 0)
                            Expanded(child: mainArea)
                          else
                            mainArea,
                          if (follows > 0) ...[
                            const SizedBox(height: 5),
                            if (square)
                              SizedBox(
                                key: const Key('tt_widget_preview_after_area'),
                                height: 42,
                                child: block(1),
                              )
                            else
                              Expanded(
                                child: SizedBox(
                                  key: const Key(
                                    'tt_widget_preview_after_area',
                                  ),
                                  child: block(1),
                                ),
                              ),
                            if (follows > 1) ...[
                              const SizedBox(height: 5),
                              SizedBox(height: 24 * scale, child: block(2)),
                            ],
                          ],
                          if (square || follows == 0) const Spacer(),
                          if (last) ...[
                            const SizedBox(height: 4),
                            Padding(
                              padding: EdgeInsets.only(left: square ? 0 : 8),
                              child: label(
                                '今天最后一节',
                                10,
                                color: colors.labelText,
                                key: const Key('tt_widget_preview_last'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
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
    await withTimetablePersistenceFeedback(context, () => _toggleUnchecked(v));
  }

  Future<void> _toggleUnchecked(bool v) async {
    final handler = widget.onToggle;
    final c = widget.controller;
    if (handler != null) {
      final result = await handler(context, v);
      if (result != c.settingsForEditing.reminderEnabled) {
        await c.updateSettings(
          c.settingsForEditing.copyWith(reminderEnabled: result),
        );
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
      AppSnackBar(
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
          onSelected: (minutes) => _saveSettingsAction(
            context,
            () => widget.actions.setReminderLeadMinutes(minutes),
          ),
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
