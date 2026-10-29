import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'timetable_appearance_page.dart';
import 'timetable_change_log_page.dart';
import 'timetable_copy.dart';
import 'timetable_day_swap_ui.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_notify_plan.dart';
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
class TimetableWidgetSettingsPage extends StatefulWidget {
  const TimetableWidgetSettingsPage({super.key, this.controller, this.actions});

  final TimetableController? controller;
  final ReminderActions? actions;

  @override
  State<TimetableWidgetSettingsPage> createState() =>
      _TimetableWidgetSettingsPageState();
}

class _TimetableWidgetSettingsPageState
    extends State<TimetableWidgetSettingsPage> {
  bool _square = false;
  bool _previewLast = false;

  /// 固定当前选中尺寸；系统或桌面不支持时改为说明手动添加步骤。
  Future<void> _pin(ReminderActions a) async {
    if (await a.pinWidget(square: _square) || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('tt_settings_widget_pin_manual'),
        content: const Text(TtSettingsText.pinWidgetManual),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
                onSelected: a.setWidgetCourseCount,
              ),
            for (final option in WidgetDisplayOption.values)
              if (!_square ||
                  option == WidgetDisplayOption.teacher ||
                  option == WidgetDisplayOption.location)
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
