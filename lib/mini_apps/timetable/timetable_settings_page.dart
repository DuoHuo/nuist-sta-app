import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/navigation/app_page.dart';
import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/miuix_dialog.dart';
import 'timetable_appearance_page.dart';
import 'timetable_change_log_page.dart';
import 'timetable_course_cell.dart';
import 'timetable_copy.dart';
import 'timetable_day_swap_ui.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_notify_plan.dart';
import 'timetable_persistence_feedback.dart';
import 'timetable_reminder_guide.dart';
import 'timetable_schedule_event_layout.dart' show SchedulePill;
import 'timetable_settings_text.dart';
import 'timetable_settings_widgets.dart';
import 'timetable_next_day_reminder_channel.dart';
import 'timetable_store.dart';
import 'timetable_theme.dart';
import 'timetable_week_widget_layout.dart';

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
    TimetableController c, {
    Future<void> Function()? onPermissionChecked,
  }) async {
    var saving = false;
    String? saveError;
    final saved = await showAppModalBottomSheet<bool>(
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
    await onPermissionChecked?.call();
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
                List<Widget> buildNextDayRows([
                  Future<void> Function()? onPermissionChecked,
                ]) => [
                  TimetableSettingsSwitchRow(
                    key: const Key('tt_settings_next_day_reminder'),
                    title: TtSettingsText.nextDayReminder,
                    subtitle: '每晚推送次日课程安排',
                    value: s.nextDayReminderEnabled,
                    onChanged: (v) async {
                      final saved = await update(
                        (s) => s.copyWith(nextDayReminderEnabled: v),
                      );
                      if (saved && v && context.mounted) {
                        await NextDayReminderChannel.requestPermission();
                        await onPermissionChecked?.call();
                      }
                    },
                  ),
                  TimetableSettingsRow(
                    key: const Key('tt_settings_next_day_time'),
                    title: TtSettingsText.nextDayTime,
                    enabled: s.nextDayReminderEnabled,
                    value: _reminderTime(s.nextDayReminderMinute),
                    showChevron: true,
                    onTap: () => _pickNextDayTime(
                      context,
                      c,
                      onPermissionChecked: onPermissionChecked,
                    ),
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
                            AppPageRoute<void>(
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
                        TimetableSettingsChoiceRow<int>(
                          key: const Key('tt_settings_home_max_exams'),
                          title: TtSettingsText.homeMaxExams,
                          showInlineOptions: false,
                          options: const {1: '1', 2: '2', 3: '3', 4: '4'},
                          selected: s.homeMaxExams,
                          onSelected: (v) =>
                              update((x) => x.copyWith(homeMaxExams: v)),
                        ),
                        TimetableSettingsSwitchRow(
                          key: const Key('tt_settings_show_tomorrow'),
                          title: '显示明天的课',
                          subtitle: '今日课程结束后展示明日安排',
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
                              AppPageRoute<void>(
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
                        nextDayRowsBuilder: buildNextDayRows,
                      )
                    else
                      TimetableSettingsGroup(
                        key: const Key('tt_settings_group_reminder'),
                        title: TtSettingsText.reminderCard,
                        children: buildNextDayRows(),
                      ),
                    TimetableSettingsGroup(
                      key: const Key('tt_settings_group_management'),
                      children: [
                        TimetableSettingsRow(
                          key: const Key('tt_settings_management_entry'),
                          title: '课表管理',
                          subtitle: '整天调课、变动记录与恢复课表',
                          showChevron: true,
                          onTap: () => Navigator.of(context).push(
                            AppPageRoute<void>(
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
  final changed = await showMiuixDialog<bool>(
    context,
    title: '恢复教务课程',
    builder: (dialogContext, dialog) => _RestoreJwxtContent(
      text: TimetableSettingsPage.restoreConfirmText,
      controller: c,
      onClose: dialog.close,
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

/// 恢复教务课程的确认内容；保存失败时留在弹窗里显示原因。
class _RestoreJwxtContent extends StatefulWidget {
  const _RestoreJwxtContent({
    required this.text,
    required this.controller,
    required this.onClose,
  });

  final String text;
  final TimetableController controller;
  final ValueChanged<bool?> onClose;

  @override
  State<_RestoreJwxtContent> createState() => _RestoreJwxtContentState();
}

class _RestoreJwxtContentState extends State<_RestoreJwxtContent> {
  bool _saving = false;
  String? _error;

  Future<void> _restore() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final changed = await withTimetablePersistenceFeedback(
      context,
      widget.controller.restoreAllJwxt,
      onError: (message) {
        if (mounted) setState(() => _error = message);
      },
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (changed != null) widget.onClose(changed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    return Column(
      key: const Key('tt_restore_jwxt_dialog'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.text,
          style: theme.textStyles.body1.copyWith(
            color: theme.colors.onSurfaceSecondary,
            height: 1.5,
          ),
        ),
        if (_error case final message?) ...[
          const SizedBox(height: 12),
          TimetablePersistenceErrorText(message),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                key: const Key('tt_restore_jwxt_cancel'),
                colors: primary,
                onPressed: _saving ? null : () => widget.onClose(null),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixButton(
                key: const Key('tt_restore_jwxt_confirm'),
                enabled: !_saving,
                colors: miuixDestructiveButtonColors(context),
                onPressed: _saving ? null : _restore,
                child: const Text('恢复'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 桌面小组件设置：预览显示内容，所有选项沿用原有设置与原生刷新入口。
class TimetableWidgetSettingsPage extends StatefulWidget {
  const TimetableWidgetSettingsPage({
    super.key,
    this.controller,
    this.actions,
    this.initialSize = WidgetPinSize.wide,
  });

  final TimetableController? controller;
  final ReminderActions? actions;

  /// 从桌面齿轮进入时，直接选中对应的小组件。
  final WidgetPinSize initialSize;

  @override
  State<TimetableWidgetSettingsPage> createState() =>
      _TimetableWidgetSettingsPageState();
}

class _TimetableWidgetSettingsPageState
    extends State<TimetableWidgetSettingsPage>
    with WidgetsBindingObserver {
  late WidgetPinSize _size = widget.initialSize;
  bool _previewLast = false;
  bool _pinning = false;
  bool _permissionSettingsPending = false;

  // 滑杆拖动期间只改预览；松手后保存一次，避免每个中间值都写盘。
  int? _draftWeekOpacity;
  int? _draftWeekSurfaceOpacity;

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
      final size = _size;
      final result = await a.pinWidget(size: size);
      if (!mounted) return;
      switch (result) {
        case WidgetPinResult.requested:
          break;
        case WidgetPinResult.permissionRequired:
          final confirmed = await _showGuide(result, size: size);
          if (!confirmed || !mounted) return;
          final opened = await a.openWidgetShortcutSettings();
          if (!mounted) return;
          if (opened) {
            // 返回后再提示重新添加，不让说明在系统设置页打开时消失。
            _permissionSettingsPending = true;
          } else {
            await _showGuide(result, size: size, settingsUnavailable: true);
          }
        case WidgetPinResult.miuiManual:
        case WidgetPinResult.originOsManual:
        case WidgetPinResult.manual:
          await _showGuide(result, size: size);
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  Future<bool> _showGuide(
    WidgetPinResult result, {
    required WidgetPinSize size,
    bool settingsUnavailable = false,
  }) async {
    return await showAppModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          constraints: const BoxConstraints(maxWidth: 560),
          builder: (_) => _WidgetPinGuideSheet(
            result: result,
            size: size,
            settingsUnavailable: settingsUnavailable,
          ),
        ) ??
        false;
  }

  Widget _weekOpacitySlider(
    TimetableController c,
    ReminderActions a, {
    required bool surface,
  }) {
    int? draft() => surface ? _draftWeekSurfaceOpacity : _draftWeekOpacity;
    int saved(TimetableSettings s) =>
        surface ? s.widgetWeekWidgetOpacity : s.widgetWeekOpacity;
    void setDraft(int? value) => setState(() {
      if (surface) {
        _draftWeekSurfaceOpacity = value;
      } else {
        _draftWeekOpacity = value;
      }
    });

    final setter = surface
        ? a.setWeekWidgetSurfaceOpacity
        : a.setWeekWidgetOpacity;
    final field = surface ? 'widgetWeekWidgetOpacity' : 'widgetWeekOpacity';
    final value = draft() ?? saved(c.settings);
    return _WidgetSliderRow(
      useSettingsHeader: !surface,
      title: surface
          ? TtSettingsText.weekWidgetOpacity
          : TtSettingsText.weekOpacity,
      valueLabel: '$value%',
      valueKey: Key('tt_settings_${field}_value'),
      slider: Slider(
        key: Key('tt_settings_$field'),
        min: 30,
        max: 100,
        divisions: 7,
        value: value.toDouble(),
        label: '$value%',
        onChanged: (v) => setDraft(v.round()),
        onChangeEnd: (v) async {
          final next = v.round();
          if (next != saved(c.settingsForEditing)) {
            await _saveSettingsAction(context, () => setter(next));
          }
          if (mounted && draft() == next) setDraft(null);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller ?? TimetableController.instance;
    final a = widget.actions ?? ReminderActions(controller: c);
    final week = _size == WidgetPinSize.week;
    final square = _size == WidgetPinSize.square;
    return _SettingsSubpage(
      title: TtSettingsText.widgetCard,
      controller: c,
      children: () {
        final s = c.settings;
        final pinRow = TimetableSettingsRow(
          key: const Key('tt_settings_widget_pin'),
          title: TtSettingsText.pinWidget,
          value: switch (_size) {
            WidgetPinSize.wide => '4×2',
            WidgetPinSize.square => '2×2',
            WidgetPinSize.week => '4×6',
          },
          showChevron: true,
          enabled: !_pinning,
          onTap: () => _pin(a),
        );
        return [
          TimetableSettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<WidgetPinSize>(
                  key: const Key('tt_settings_widget_size'),
                  segments: const [
                    ButtonSegment(
                      value: WidgetPinSize.square,
                      label: Text('2×2 日课表'),
                    ),
                    ButtonSegment(
                      value: WidgetPinSize.wide,
                      label: Text('4×2 日课表'),
                    ),
                    ButtonSegment(
                      value: WidgetPinSize.week,
                      label: Text('4×6 周课表'),
                    ),
                  ],
                  selected: {_size},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) =>
                      setState(() => _size = value.single),
                ),
              ),
              if (!week)
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
                size: _size,
                settings: week
                    ? s.copyWith(
                        widgetWeekOpacity: _draftWeekOpacity,
                        widgetWeekWidgetOpacity: _draftWeekSurfaceOpacity,
                      )
                    : s,
                last: _previewLast,
              ),
              pinRow,
            ],
          ),
          TimetableSettingsGroup(
            key: const Key('tt_settings_group_widget'),
            children: [
              if (_size == WidgetPinSize.wide)
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
              if (week) ...[
                _weekOpacitySlider(c, a, surface: false),
                _weekOpacitySlider(c, a, surface: true),
                TimetableSettingsSwitchRow(
                  key: const Key('tt_settings_widgetWeekShowWeekend'),
                  title: TtSettingsText.weekShowWeekend,
                  subtitle: TtSettingsText.weekShowWeekendSubtitle,
                  value: a.widgetWeekShowWeekend,
                  onChanged: (v) => _saveSettingsAction(
                    context,
                    () => a.setWeekWidgetShowWeekend(v),
                  ),
                ),
              ],
              for (final option in WidgetDisplayOption.values)
                if (week
                    ? (option == WidgetDisplayOption.teacher ||
                          option == WidgetDisplayOption.period)
                    : (!square ||
                          option == WidgetDisplayOption.teacher ||
                          option == WidgetDisplayOption.location))
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
        ];
      },
    );
  }
}

/// 设置页的小滑杆行；值在右侧，滑杆独占一行，避免窄屏挤压标题。
class _WidgetSliderRow extends StatelessWidget {
  const _WidgetSliderRow({
    required this.title,
    required this.valueLabel,
    required this.valueKey,
    required this.slider,
    required this.useSettingsHeader,
  });

  final String title;
  final String valueLabel;
  final Key valueKey;
  final Widget slider;
  final bool useSettingsHeader;

  @override
  Widget build(BuildContext context) {
    if (useSettingsHeader) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TimetableSettingsRow(
            title: title,
            trailing: Text(valueLabel, key: valueKey),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: slider,
          ),
        ],
      );
    }
    final colors = TimetableTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TimetableSettingsRow.textStyle(context),
                ),
              ),
              Text(
                valueLabel,
                key: valueKey,
                style: TimetableSettingsRow.textStyle(context)
                    .copyWith(color: colors.labelText),
              ),
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

/// 4×6 当周课表预览：示例内容走同一布局和颜色规则，不读取真实课程。
class _WeekWidgetSettingsPreview extends StatelessWidget {
  const _WeekWidgetSettingsPreview({required this.settings, required this.now});

  final TimetableSettings settings;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final prefs = WeekWidgetPrefs.fromSettings(settings);
    final week = WeekWidgetWeek(
      start: weekWidgetMonday(now),
      week: 7,
      days: _previewWeekDays(now),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 360.0);
        final height = width * 1.25;
        final plan = planWeekWidget(
          week: week,
          periods: _previewWeekPeriods,
          prefs: prefs,
          widthDp: width,
          heightDp: height,
          today: now,
        );
        const radius = BorderRadius.all(
          Radius.circular(TimetableTheme.cardRadius),
        );
        return Center(
          child: SizedBox(
            key: const Key('tt_widget_preview_4x5'),
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: radius,
              child: DecoratedBox(
                key: const Key('tt_widget_preview_week_background'),
                decoration: BoxDecoration(
                  color: prefs.background(colors),
                  borderRadius: radius,
                ),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: prefs.componentColor(colors.divider),
                    ),
                  ),
                  child: _WeekWidgetPreviewGrid(
                    plan: plan,
                    prefs: prefs,
                    examColor: Color(settings.examColor),
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

class _WeekWidgetPreviewGrid extends StatelessWidget {
  const _WeekWidgetPreviewGrid({
    required this.plan,
    required this.prefs,
    required this.examColor,
  });

  final WeekWidgetPlan plan;
  final WeekWidgetPrefs prefs;
  final Color examColor;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final geometry = plan.geometry;
    final heading = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: prefs.componentColor(colors.titleText),
    );
    // 与原生桌面周次标注使用同一套 wg_t2 浅 / 深色。
    final weekStyle = TimetableTheme.captionStyle(
      color: prefs.componentColor(
        colors.isDark ? const Color(0xFFAAB1C1) : const Color(0xFF5F6675),
      ),
    ).copyWith(fontSize: 11);
    final height = geometry.rowHeight * plan.rows.length;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: geometry.headerHeight,
          child: Padding(
            // 标题行整体比 v24 上移 3dp，行高与文字预算均不变。
            padding: const EdgeInsets.only(top: 11, bottom: 3),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 3, 8, 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _fitted(
                        Text('当周课表', maxLines: 1, style: heading),
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                  if (plan.weekLabel.isNotEmpty)
                    Flexible(
                      child: _fitted(
                        Text(plan.weekLabel, maxLines: 1, style: weekStyle),
                        alignment: Alignment.centerRight,
                      ),
                    ),
                  for (final icon in [Icons.arrow_forward, Icons.settings])
                    SizedBox(
                      width: 44,
                      child: Icon(
                        icon,
                        size: 18,
                        color: prefs.componentColor(colors.labelText),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          height: geometry.weekdayHeight,
          child: Row(
            children: [
              if (geometry.showTimeColumn)
                SizedBox(
                  width: geometry.timeColumnWidth,
                  child: _fitted(
                    padding: const EdgeInsets.all(2),
                    Text(
                      '${plan.month}月',
                      style: TimetableTheme.microStyle(
                        color: prefs.componentColor(colors.hint),
                      ).copyWith(fontSize: 9),
                    ),
                  ),
                ),
              for (final weekday in plan.weekdays)
                Expanded(child: _dayHeader(weekday, colors)),
            ],
          ),
        ),
        if (plan.rows.isNotEmpty)
          SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (geometry.showTimeColumn)
                  SizedBox(
                    width: geometry.timeColumnWidth,
                    child: Column(
                      children: [
                        for (final row in plan.rows) _periodLabel(row, colors),
                      ],
                    ),
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (prefs.showGridLines)
                        CustomPaint(
                          key: const Key('tt_widget_preview_week_grid'),
                          painter: _WeekWidgetPreviewLines(
                            plan,
                            prefs.gridLine(colors),
                            dpr,
                          ),
                        ),
                      for (final (column, weekday) in plan.weekdays.indexed)
                        for (final block in plan.blocks[weekday]!)
                          _courseBlock(dpr, column, weekday, block, colors),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayHeader(int weekday, TimetableColors colors) {
    final today = plan.todayWeekday == weekday;
    final dot = plan.unplaced[weekday]?.firstOrNull;
    return Stack(
      key: ValueKey('tt_widget_preview_week_header_$weekday'),
      fit: StackFit.expand,
      children: [
        if (today)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: prefs.componentColor(colors.accentSoft),
                borderRadius: BorderRadius.circular(
                  TimetableTheme.todayHeaderRadius,
                ),
              ),
            ),
          ),
        _fitted(
          padding: const EdgeInsets.all(2),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _weekdayShort(weekday),
                style: TextStyle(
                  fontSize: prefs.headerTextSize,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                  color: prefs.componentColor(
                    today ? colors.accent : colors.labelText,
                  ),
                ),
              ),
              Text(
                '${plan.dates[weekday]}',
                style: TimetableTheme.microStyle(
                  color: prefs.componentColor(
                    today ? colors.accent : colors.hint,
                  ),
                ).copyWith(fontSize: 9),
              ),
              if (dot != null) ...[
                const SizedBox(height: 1),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: prefs.componentColor(Color(dot.barColor)),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _periodLabel(WeekWidgetRow row, TimetableColors colors) => SizedBox(
    height: plan.geometry.rowHeight,
    child: _fitted(
      padding: const EdgeInsets.all(2),
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${row.node}',
            key: ValueKey('tt_widget_preview_week_number_${row.node}'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.05,
              color: prefs.componentColor(colors.titleText),
            ),
          ),
          if (row.period case final period?)
            Text(
              '${period.start}\n${period.end}',
              key: ValueKey('tt_widget_preview_week_time_${row.node}'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                height: 1.05,
                color: prefs.componentColor(colors.hint),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _courseBlock(
    double dpr,
    int column,
    int weekday,
    WeekWidgetBlock block,
    TimetableColors colors,
  ) {
    final geometry = plan.geometry;
    final margin = geometry.cellMargin;
    final inset = geometry.cellPadding;
    final area = TimetableTheme.snapDeviceRect(
      left: column * geometry.cellWidth + margin,
      top: (block.startNode - 1) * geometry.rowHeight + margin,
      width: geometry.cellWidth - margin * 2,
      height: block.span * geometry.rowHeight - margin * 2,
      dpr: dpr,
    );
    if (area.width <= inset * 2 || area.height <= inset * 2) {
      return const SizedBox.shrink();
    }
    final primary = block.primary;
    final pair = TimetableTheme.autoCoursePair(
      _previewColorIndex(primary.name),
      dark: colors.isDark,
    );
    final isExam = primary.kind == WidgetItemKind.exam;
    final bg = isExam
        ? TimetableTheme.examCellBg(examColor, dark: colors.isDark)
        : TimetableTheme.blendCellBg(
            pair.bg,
            prefs.opacity,
            dark: colors.isDark,
          );
    final fg = isExam
        ? TimetableTheme.readableCellText(bg, TimetableTheme.examText)
        : TimetableTheme.cellTextFor(
            TimetableTheme.readableCellText(bg, pair.fg),
            prefs.cellTextColor,
          );
    final badge = switch ((block.courses.length, primary.kind)) {
      (final count, _) when count > 1 =>
        '$count ${block.courses.every((item) => item.kind == WidgetItemKind.course) ? '门' : '项'}',
      (_, WidgetItemKind.exam) => '考试',
      (_, WidgetItemKind.schedule) => '日程',
      (_, WidgetItemKind.course) => primary.weekTag.trim(),
    };
    return Positioned(
      left: area.left,
      top: area.top,
      width: area.width,
      height: area.height,
      child: Material(
        key: ValueKey(
          'tt_widget_preview_week_cell_${weekday}_${block.startNode}',
        ),
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(TimetableTheme.cellRadius),
          ),
          child: Builder(
            builder: (context) {
              final base = DefaultTextStyle.of(context).style;
              final scaler = MediaQuery.textScalerOf(context);
              final direction = Directionality.of(context);
              final nameStyle = TimetableTheme.cellStyle(color: fg);
              final subStyle = TimetableTheme.cellSubStyle(color: fg);
              final locationStyle = TimetableTheme.cellLocationStyle(color: fg);
              final actualWidth = area.width - inset * 2;
              final actualHeight = area.height - inset * 2;
              final sizes = TimetableTheme.cellTextSizesForWidth(
                maxWidth: math.max(
                  1.0,
                  geometry.fontReferenceWidth(dpr) - inset * 2,
                ),
                nameStyle: base.merge(nameStyle),
                factor: prefs.fontScale.factor,
                nameBaseSize: TimetableTheme.cellSize - 1,
                subBaseSize: TimetableTheme.cellSubSize - 1,
                minSize: geometry.minimumTextSize,
                referenceText: geometry.compactText ? '课课课课' : '课课课',
                textScaler: scaler,
                textDirection: direction,
              );
              final minSize = geometry.minimumTextSize;
              final scale = scaler.scale(1);
              final minimum = scale > 0
                  ? (minSize / scale).ceilToDouble()
                  : minSize;
              var location = primary.location.isEmpty
                  ? ''
                  : cellLocationText(primary.location);
              if (location.isNotEmpty && geometry.compactText) {
                final withoutMarker = cellLocationText(
                  primary.location,
                  showMarker: false,
                );
                final style = base
                    .merge(locationStyle)
                    .copyWith(fontSize: minimum);
                int lines(String value) => TimetableTheme.measureText(
                  value,
                  style,
                  maxWidth: actualWidth,
                  scaler: scaler,
                  direction: direction,
                ).lines;
                if (lines(location) > lines(withoutMarker)) {
                  location = withoutMarker;
                }
              }
              final teacher = prefs.showTeacher
                  ? cellTeacherText(primary.teachers.join('，'))
                  : '';
              var badgeReserve = 0.0;
              // 与原生一致：标签超宽时单行省略，不按换行后的高度预留。
              if (badge.isNotEmpty && area.width > 12) {
                final badgeSize = TimetableTheme.cellBadgeSize(
                  context,
                  badge,
                  maxWidth: double.infinity,
                  fontSize: TimetableTheme.badgeSize - 1,
                );
                final reserve = math.max(
                  CourseCell.badgeReserve,
                  badgeSize.height + 2,
                );
                final minNameHeight = TimetableTheme.measureText(
                  '课',
                  base.merge(nameStyle).copyWith(fontSize: minimum),
                  maxWidth: actualWidth,
                  scaler: scaler,
                  direction: direction,
                ).height;
                final minLocationHeight = location.isNotEmpty
                    ? TimetableTheme.measureText(
                        location,
                        base.merge(locationStyle).copyWith(fontSize: minimum),
                        maxWidth: actualWidth,
                        scaler: scaler,
                        direction: direction,
                      ).height
                    : 0.0;
                if (reserve + minNameHeight + minLocationHeight <=
                    actualHeight) {
                  badgeReserve = reserve;
                }
              }
              CellContentPlan measure(String teacher) => planCellContent(
                name: primary.name,
                location: location,
                teacher: teacher,
                nameStyle: base.merge(nameStyle),
                subStyle: base.merge(subStyle),
                locationStyle: base.merge(locationStyle),
                nameSize: sizes.nameSize,
                subSize: sizes.subSize,
                maxWidth: actualWidth,
                maxHeight:
                    actualHeight - badgeReserve - (teacher.isEmpty ? 0 : 1),
                minSize: minSize,
                maxTeacherGap: geometry.compactText ? 2 : double.infinity,
                textScaler: scaler,
                textDirection: direction,
              );
              final withTeacher = measure(teacher);
              final text = withTeacher.showTeacher && !withTeacher.fits
                  ? measure('')
                  : withTeacher;
              return Stack(
                children: [
                  Positioned.fill(
                    left: inset,
                    right: inset,
                    top: inset,
                    bottom: inset + badgeReserve,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: AlignmentDirectional.topStart,
                        minHeight: 0,
                        maxHeight: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CourseNameText(
                              name: primary.name,
                              style: nameStyle.copyWith(
                                fontSize: text.nameSize,
                              ),
                              maxWidth: actualWidth,
                              maxLines: text.nameLines,
                              laidOutText: text.laidOutName,
                            ),
                            if (location.isNotEmpty)
                              Text(
                                location,
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                style: locationStyle.copyWith(
                                  fontSize: text.subSize,
                                ),
                              ),
                            if (text.showTeacher) ...[
                              SizedBox(height: text.teacherGap),
                              Text(
                                teacher,
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                style: subStyle.copyWith(
                                  fontSize: text.subSize,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (badgeReserve > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 3,
                      child: Center(
                        child: SchedulePill(
                          text: badge,
                          color: TimetableTheme.cellTextFor(
                            fg,
                            prefs.cellTextColor,
                          ),
                          fontSize: TimetableTheme.badgeSize - 1,
                          singleLine: true,
                        ),
                      ),
                    ),
                  if (block.courses.length > 1)
                    Positioned(
                      top: inset,
                      right: inset,
                      child: Container(
                        width: TimetableTheme.conflictDotSize,
                        height: TimetableTheme.conflictDotSize,
                        decoration: BoxDecoration(
                          color: fg,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _fitted(
    Widget child, {
    Alignment alignment = Alignment.center,
    EdgeInsets padding = EdgeInsets.zero,
  }) => Padding(
    padding: padding,
    child: Align(
      alignment: alignment,
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    ),
  );
}

class _WeekWidgetPreviewLines extends CustomPainter {
  _WeekWidgetPreviewLines(this.plan, this.color, this.devicePixelRatio);

  final WeekWidgetPlan plan;
  final Color color;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = weekWidgetGridStroke(devicePixelRatio);
    double snap(double offset) =>
        (offset * devicePixelRatio).round() / devicePixelRatio;
    final lines = Path();
    for (var i = 0; i <= plan.rows.length; i++) {
      final y = snap(i * plan.geometry.rowHeight)
          .clamp(0.0, math.max(0.0, size.height - strokeWidth))
          .toDouble();
      lines.addRect(Rect.fromLTWH(0, y, size.width, strokeWidth));
    }
    for (var i = 0; i < plan.weekdays.length; i++) {
      final x = snap(i * plan.geometry.cellWidth);
      lines.addRect(Rect.fromLTWH(x, 0, strokeWidth, size.height));
    }
    // 一次上色，交点不会因为多画一层而比线条更不透明。
    canvas.drawPath(
      lines,
      Paint()
        ..color = color
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_WeekWidgetPreviewLines old) =>
      color != old.color ||
      devicePixelRatio != old.devicePixelRatio ||
      plan.geometry.cellWidth != old.plan.geometry.cellWidth ||
      plan.geometry.rowHeight != old.plan.geometry.rowHeight ||
      plan.rows.length != old.plan.rows.length ||
      plan.weekdays.length != old.plan.weekdays.length;
}

final _previewWeekPeriods = [
  for (final period in TimetableController.defaultPeriods())
    WeekWidgetPeriod(node: period.node, start: period.start, end: period.end),
];

List<WeekWidgetDay> _previewWeekDays(DateTime now) {
  final monday = weekWidgetMonday(now);
  final courses = <int, List<NotifyClass>>{
    1: [
      _previewCourse(monday, 1, '高等数学 A', '示例教室 A101', 1, 2, weekTag: '单周'),
      _previewCourse(monday, 1, '大学物理', '示例教室 B203', 5, 6),
    ],
    2: [
      _previewCourse(
        monday,
        2,
        '小组讨论',
        '示例教室 C102',
        1,
        2,
        kind: WidgetItemKind.schedule,
      ),
      _previewCourse(monday, 2, '大学英语', '示例教室 C102', 3, 4, weekTag: '双周'),
    ],
    3: [
      _previewCourse(monday, 3, '程序设计', '示例机房 D401', 1, 2),
      _previewCourse(monday, 3, '体育', '示例操场', 3, 4, weekTag: '体育'),
    ],
    4: [
      _previewCourse(monday, 4, '大学物理', '示例教室 B203', 5, 6),
      _previewCourse(monday, 4, '大学物理 II', '示例教室 A103', 6, 6),
      _previewCourse(monday, 4, '物理实验', '示例教室 A103', 1, 2, weekTag: '实验'),
    ],
    5: [
      _previewCourse(monday, 5, '高等数学 A', '示例教室 A101', 1, 2),
      _previewCourse(monday, 5, '大学英语', '示例教室 C102', 3, 4),
      _previewCourse(
        monday,
        5,
        '线性代数',
        '示例教室 C102',
        5,
        6,
        kind: WidgetItemKind.exam,
      ),
    ],
    6: [_previewCourse(monday, 6, '选修课', '示例教室 E105', 3, 4)],
  };
  return [
    for (var index = 0; index < 7; index++)
      WeekWidgetDay(
        date: DateTime(monday.year, monday.month, monday.day + index),
        weekday: index + 1,
        items: courses[index + 1] ?? const [],
      ),
  ];
}

NotifyClass _previewCourse(
  DateTime monday,
  int weekday,
  String name,
  String location,
  int startNode,
  int endNode, {
  String weekTag = '',
  WidgetItemKind kind = WidgetItemKind.course,
}) {
  final startPeriod = _previewWeekPeriods.firstWhere(
    (period) => period.node == startNode,
  );
  final endPeriod = _previewWeekPeriods.firstWhere(
    (period) => period.node == endNode,
  );
  final date = DateTime(monday.year, monday.month, monday.day + weekday - 1);
  return NotifyClass(
    name: name,
    location: location,
    teachers: kind == WidgetItemKind.course ? const ['示例教师'] : const [],
    start: _previewClock(date, startPeriod.start),
    end: _previewClock(date, endPeriod.end),
    startNode: startNode,
    endNode: endNode,
    kind: kind,
    weekTag: weekTag,
  );
}

DateTime _previewClock(DateTime day, String hhmm) {
  final parts = hhmm.split(':');
  return DateTime(
    day.year,
    day.month,
    day.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

int _previewColorIndex(String name) => switch (name) {
  '高等数学 A' => 0,
  '大学英语' => 1,
  '程序设计' => 2,
  '大学物理' => 3,
  '体育' => 4,
  _ => 5,
};

String _weekdayShort(int weekday) =>
    const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1];

/// 仅由添加失败或指定桌面的添加请求打开，步骤内容可滚动，确认按钮保留在底部。
class _WidgetPinGuideSheet extends StatelessWidget {
  const _WidgetPinGuideSheet({
    required this.result,
    required this.size,
    this.settingsUnavailable = false,
  });

  final WidgetPinResult result;
  final WidgetPinSize size;
  final bool settingsUnavailable;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final permission = result == WidgetPinResult.permissionRequired;
    final permissionPrompt = permission && !settingsUnavailable;
    final steps = TtSettingsText.pinWidgetSteps(
      result,
      size: size,
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

/// 调课、变动记录与恢复操作集中管理，恢复继续保留二次确认。
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
          title: '课程调整',
          children: [
            TimetableSettingsRow(
              key: const Key('tt_settings_day_swaps'),
              title: '整天调课',
              subtitle: '互换任意两天的全部课程',
              showChevron: true,
              onTap: () => openDaySwapPage(context, c),
            ),
            TimetableSettingsRow(
              key: const Key('tt_settings_change_log'),
              title: TimetableCopy.changeLogSettingsTitle,
              subtitle: TimetableCopy.changeLogSettingsSubtitle,
              showChevron: true,
              onTap: () => openTimetableChangeLogPage(context, controller: c),
            ),
          ],
        ),
        if (!c.isImportedSchedule)
          TimetableSettingsGroup(
            key: const Key('tt_settings_group_restore'),
            children: [
              TimetableSettingsRow(
                key: const Key('tt_settings_restore_jwxt'),
                title: '恢复教务课程',
                subtitle: '清除本地编辑与调课，还原教务原始课表',
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
    required this.size,
    required this.last,
  });
  final TimetableSettings settings;
  final WidgetPinSize size;
  final bool last;

  bool get square => size == WidgetPinSize.square;

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

    String ellipsize(String value, double size, double maxWidth) {
      if (value.isEmpty ||
          maxWidth <= 0 ||
          textWidth(value, size) <= maxWidth) {
        return value;
      }
      const suffix = '…';
      if (textWidth(suffix, size) > maxWidth) return '';
      final runes = value.runes.toList();
      var low = 0;
      var high = runes.length;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        final candidate = '${String.fromCharCodes(runes.take(middle))}$suffix';
        if (textWidth(candidate, size) <= maxWidth) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      return '${String.fromCharCodes(runes.take(low))}$suffix';
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
          Text(
            '显示效果预览 · 示例内容',
            style: TimetableTheme.captionStyle(color: colors.labelText),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              if (size == WidgetPinSize.week) {
                return _WeekWidgetSettingsPreview(
                  settings: settings,
                  now: DateTime.now(),
                );
              }
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
                final locationText = settings.widgetShowLocation
                    ? location
                    : '';
                const teacherText = '示例教师';
                final fullDetails = [
                  locationText,
                  if (settings.widgetShowTeacher) teacherText,
                ].where((s) => s.isNotEmpty).join(' · ');
                var details = fullDetails;
                if (textWidth(fullDetails, 11) > contentWidth &&
                    settings.widgetShowTeacher) {
                  final prefix = locationText.isEmpty ? '' : '$locationText · ';
                  final teacher = ellipsize(
                    teacherText,
                    11,
                    contentWidth - textWidth(prefix, 11),
                  );
                  details = teacher.isEmpty ? locationText : '$prefix$teacher';
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
                  final full = [
                    prefix,
                    if (settings.widgetShowLocation) 'C102',
                  ].join(' · ');
                  if (textWidth(full, 11) <= contentWidth ||
                      !settings.widgetShowLocation) {
                    time = full;
                  } else {
                    final roomPrefix = '$prefix · ';
                    final room = ellipsize(
                      'C102',
                      11,
                      contentWidth - textWidth(roomPrefix, 11),
                    );
                    time = room.isNotEmpty
                        ? '$roomPrefix$room'
                        : textWidth(prefix, 11) <= contentWidth
                        ? prefix
                        : start;
                  }
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
    required this.nextDayRowsBuilder,
    this.onToggle,
  });

  final TimetableController controller;
  final ReminderActions actions;
  final ReminderToggleHandler? onToggle;
  final List<Widget> Function(Future<void> Function() refreshPermission)
  nextDayRowsBuilder;

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
    AppPageRoute<void>(
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
    final hint = reminderPermissionHint(
      _perm,
      s.reminderEnabled,
      nextDayEnabled: s.nextDayReminderEnabled,
    );
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
        ...widget.nextDayRowsBuilder(_refreshPermission),
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
