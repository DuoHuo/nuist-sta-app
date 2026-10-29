import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_notify_bridge.dart';
import 'timetable_notify_service.dart';
import 'timetable_settings_text.dart';
import 'timetable_theme.dart';

/// 设置页「提醒」卡片与保活引导页用到的操作（docs/notify-widget-interface.md §2）。
///
/// 默认实现走 [TimetableNotifyService.instance]；测试可继承覆写，不碰原生通道。
class ReminderActions {
  const ReminderActions({this.controller});

  /// 非 [TimetableController.instance] 时直接写该控制器的设置（测试 / 预览用）。
  final TimetableController? controller;

  bool get _useService =>
      controller == null || identical(controller, TimetableController.instance);

  TimetableNotifyService get _svc => TimetableNotifyService.instance;

  /// 开关提醒；返回最新权限状态。开关保持用户选择。
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    if (_useService) return _svc.setReminderEnabled(enabled);
    final c = controller!;
    if (c.settings.reminderEnabled != enabled) {
      await c.updateSettings(c.settings.copyWith(reminderEnabled: enabled));
    }
    return NotifyPermissionStatus.unsupported;
  }

  Future<void> setReminderLeadMinutes(int minutes) async {
    if (_useService) return _svc.setReminderLeadMinutes(minutes);
    final c = controller!;
    await c.updateSettings(c.settings.copyWith(reminderLeadMinutes: minutes));
  }

  Future<NotifyPermissionStatus> permissionStatus() => _svc.permissionStatus();

  Future<bool> openNotificationSettings() => _svc.openNotificationSettings();

  Future<bool> openExactAlarmSettings() => _svc.openExactAlarmSettings();

  Future<bool> openBatteryOptimizationSettings() =>
      _svc.openBatteryOptimizationSettings();

  /// 请求桌面固定小组件；false 时设置页改为显示手动添加步骤。
  Future<bool> pinWidget({required bool square}) =>
      _svc.pinWidget(square: square);

  TimetableSettings get _settings =>
      (controller ?? TimetableController.instance).settings;

  /// 小组件显示开关当前值（默认全开）。
  bool widgetOption(WidgetDisplayOption o) {
    final s = _settings;
    return switch (o) {
      WidgetDisplayOption.teacher => s.widgetShowTeacher,
      WidgetDisplayOption.location => s.widgetShowLocation,
      WidgetDisplayOption.countdown => s.widgetShowCountdown,
      WidgetDisplayOption.count => s.widgetShowCount,
      WidgetDisplayOption.period => s.widgetShowPeriod,
    };
  }

  /// 改开关；走 [TimetableNotifyService] 的 setter（保存后立即刷新小组件）。
  Future<void> setWidgetOption(WidgetDisplayOption o, bool v) async {
    if (_useService) {
      return switch (o) {
        WidgetDisplayOption.teacher => _svc.setWidgetShowTeacher(v),
        WidgetDisplayOption.location => _svc.setWidgetShowLocation(v),
        WidgetDisplayOption.countdown => _svc.setWidgetShowCountdown(v),
        WidgetDisplayOption.count => _svc.setWidgetShowCount(v),
        WidgetDisplayOption.period => _svc.setWidgetShowPeriod(v),
      };
    }
    final c = controller!;
    final s = c.settings;
    await c.updateSettings(switch (o) {
      WidgetDisplayOption.teacher => s.copyWith(widgetShowTeacher: v),
      WidgetDisplayOption.location => s.copyWith(widgetShowLocation: v),
      WidgetDisplayOption.countdown => s.copyWith(widgetShowCountdown: v),
      WidgetDisplayOption.count => s.copyWith(widgetShowCount: v),
      WidgetDisplayOption.period => s.copyWith(widgetShowPeriod: v),
    });
  }

  /// 小组件最多显示的课程条目数（1 / 2 / 3，默认 2）。
  int get widgetCourseCount => _settings.widgetCourseCount;

  Future<void> setWidgetCourseCount(int n) async {
    if (_useService) return _svc.setWidgetCourseCount(n);
    final c = controller!;
    await c.updateSettings(
      c.settings.copyWith(
        widgetCourseCount: TimetableSettings.sanitizeCourseCount(n),
      ),
    );
  }
}

/// 小组件「显示」开关（文案规范顺序）；[field] 为设置字段名。
enum WidgetDisplayOption {
  teacher('widgetShowTeacher', TtSettingsText.showTeacher),
  location('widgetShowLocation', TtSettingsText.showLocation),
  period('widgetShowPeriod', TtSettingsText.showPeriod),
  countdown('widgetShowCountdown', TtSettingsText.showCountdown),
  count('widgetShowCount', TtSettingsText.showCount);

  const WidgetDisplayOption(this.field, this.title);

  final String field;
  final String title;

  /// 副标题；标题已说清时为空（文案规范第 4 条）。
  String? get subtitle => null;
}

/// 「同时显示」可选节数（widgetCourseCount，默认 2）。
const List<int> kWidgetCourseCountOptions = [1, 2, 3];

/// 设置页「提前」可选分钟（文案规范：5 / 10 / 15 / 30，默认 15）。
const List<int> kReminderLeadChoices = [5, 10, 15, 30];

/// 当前提前量不在 [kReminderLeadChoices] 时按 15 显示。
int displayReminderLead(int minutes) =>
    kReminderLeadChoices.contains(minutes) ? minutes : 15;

/// 后台保活引导页：从设置页「提醒」卡片进入。只做说明 + 打开系统电池优化设置。
class TimetableKeepAliveGuidePage extends StatelessWidget {
  const TimetableKeepAliveGuidePage({super.key, this.actions});

  final ReminderActions? actions;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final a = actions ?? const ReminderActions();
    final body = TimetableTheme.bodyStyle(color: colors.titleText);
    final small = TextStyle(
      fontSize: 13,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    Widget card(Widget child, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(
        TimetableTheme.pagePaddingH,
        12,
        TimetableTheme.pagePaddingH,
        0,
      ),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(TimetableTheme.cardRadius),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
    return Scaffold(
      backgroundColor: colors.pageBg,
      appBar: AppBar(title: const Text(TtSettingsText.keepAliveTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(TtSettingsText.keepAliveIntro, style: body),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('tt_keepalive_battery'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.accent,
                    ),
                    onPressed: () => a.openBatteryOptimizationSettings(),
                    child: const Text(TtSettingsText.keepAliveBatteryButton),
                  ),
                ),
              ],
            ),
          ),
          card(
            key: const Key('tt_keepalive_warning'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TtSettingsText.keepAliveNotice,
                  style: body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text('· ${TtSettingsText.reminderHolidayHint}', style: small),
                Text('· ${TtSettingsText.forceStopWarning}', style: small),
                Text('· ${TtSettingsText.sevenDayWarning}', style: small),
                Text('· 清理后台（划掉最近任务）一般不影响提醒，但部分机型会连带停止，建议锁定本应用。', style: small),
              ],
            ),
          ),
          for (final (brand, tip) in TtSettingsText.brandTips)
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    brand,
                    style: body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(tip, style: small),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(TtSettingsText.menuNamesVary, style: small),
          ),
        ],
      ),
    );
  }
}

/// 卡片里的权限提示文案。
String? reminderPermissionHint(NotifyPermissionStatus s, bool enabled) {
  if (!enabled || !s.supported) return null;
  if (!s.notificationsGranted) return TtSettingsText.permissionNotification;
  if (!s.exactAlarmGranted) return TtSettingsText.permissionExactAlarm;
  return null;
}
