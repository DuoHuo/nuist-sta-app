import 'timetable_notify_bridge.dart';

/// 设置页「上课提醒」「小组件」卡片与后台运行引导页的全部界面文案。
///
/// 设置行只保留标题与值，运行限制集中在帮助页和首次开启提示。
abstract final class TtSettingsText {
  // ---- 外观页 ----
  static const homeMaxItems = '首页显示课程数量';
  static const headerFontSize = '表头字号';
  static const periodShowTime = '节次显示时间';

  // ---- 提醒卡片 ----
  static const reminderCard = '提醒';
  static const reminderSwitch = '上课提醒';
  static const reminderHolidayHint = '放假期间也会提醒';
  static const reminderIntro = '按课表提醒，放假期间也会提醒；请至少每 7 天打开一次 App，保持后续提醒。';
  static const reminderLead = '提前时间';
  static const nextDayReminder = '次日课表提醒';
  static const nextDayTime = '前一晚提醒时间';
  static String minutes(int m) => '$m $minuteUnit';
  static const minuteUnit = '分钟';
  static const permissionNotification = '通知权限未开启，收不到上课提醒';
  static const permissionExactAlarm = '授予精确闹钟权限可准时提醒';
  static const gotoSettings = '去设置';
  static const keepAliveEntry = '后台运行设置';

  // ---- 小组件卡片 ----
  static const widgetCard = '桌面小组件';
  static const showTeacher = '显示教师';
  static const showLocation = '显示地点';
  static const showCountdown = '显示倒计时';
  static const showCount = '显示剩余节数';
  static const showPeriod = '显示节次';
  static const courseCount = '最多显示课程数量';
  static String courses(int n) => '$n';
  static const pinWidget = '添加到桌面';
  static const pinWidgetGuideTitle = '手动添加小组件';
  static const pinWidgetPermissionTitle = '开启桌面快捷方式';
  static const pinWidgetOpenSettings = '去开启权限';
  static const pinWidgetSettingsUnavailable = '未能打开系统设置，请按下面步骤手动开启权限。';
  static const pinWidgetPermissionHint = '开启「添加桌面快捷方式」权限后，请再次点击「添加到桌面」。';

  /// 指引只解释当前添加结果。
  static String pinWidgetIntro(WidgetPinResult result) => switch (result) {
    WidgetPinResult.permissionRequired => '一键添加小组件需要「添加桌面快捷方式」权限。',
    WidgetPinResult.originOsManual => 'OriginOS 需要从桌面组件列表手动添加。',
    _ => '未能直接添加，可以按下面步骤放到桌面。',
  };

  /// 仅展示此次选中尺寸的操作步骤。
  static List<(String, String)> pinWidgetSteps(
    WidgetPinResult result, {
    required bool square,
    bool settingsUnavailable = false,
  }) {
    final add = (
      '添加「${square ? '当前/下一节' : '今日课表'}」',
      '选择 ${square ? '2×2' : '4×2'}，长按并拖到桌面空白处。',
    );
    return switch (result) {
      WidgetPinResult.permissionRequired => [
        (
          '打开应用权限',
          settingsUnavailable
              ? '系统设置 → 应用管理 → NUIST++。'
              : '点击「去开启权限」，进入本应用的权限页。',
        ),
        ('允许添加桌面快捷方式', '在「其他权限」中，将该权限设为允许。'),
        ('返回并重新添加', '回到本页面，再次点击「添加到桌面」。'),
      ],
      WidgetPinResult.miuiManual => [
        ('打开小部件列表', '返回桌面，双指捏合后点击「添加小部件」。'),
        ('找到 NUIST++', '点击搜索，再进入「安卓小部件」列表。'),
        add,
      ],
      WidgetPinResult.originOsManual => [
        ('打开原子组件', '返回桌面，长按空白处，进入「原子组件」。'),
        ('找到 NUIST++', '在底部进入「更多组件」或「应用挂件」。'),
        add,
      ],
      _ => [
        ('进入桌面编辑', '返回桌面，长按空白处或双指捏合。'),
        ('找到 NUIST++', '打开「小组件」或「窗口小工具」列表。'),
        add,
      ],
    };
  }

  /// 次要说明不与主要步骤混排。
  static String pinWidgetTip(WidgetPinResult result) => switch (result) {
    WidgetPinResult.permissionRequired => '不同系统版本的权限菜单名称可能略有不同。',
    WidgetPinResult.miuiManual => '一键添加还需开启「添加桌面快捷方式」权限。',
    WidgetPinResult.originOsManual => '旧版本可在「桌面挂件」中找到本应用；探索桌面从应用列表顶部进入原子组件。',
    _ => '桌面需要留出足够空间，菜单名称可能随系统版本变化。',
  };

  // ---- 后台运行引导页 ----
  static const keepAliveTitle = '后台运行设置';
  static const keepAliveIntro = '部分手机会限制后台应用，导致上课提醒延迟或不弹出。建议允许本应用自启动，并关闭电池优化。';
  static const keepAliveBatteryButton = '关闭电池优化';
  static const keepAliveNotice = '注意';
  static const forceStopWarning = '在系统设置里「强行停止」App 后，提醒会失效，需要重新打开一次 App 才能恢复。';
  static const sevenDayWarning = '提醒最多提前安排 7 天：超过 7 天不打开 App，之后可能不再提醒。';
  static const recentTasksWarning = '清理后台（划掉最近任务）一般不影响提醒，但部分机型会连带停止，建议锁定本应用。';
  static const menuNamesVary = '不同系统版本菜单名称可能略有不同。';

  /// 各品牌后台保活说明（只做引导，不检测机型）。
  static const List<(String, String)> brandTips = [
    ('小米 / 红米（HyperOS / MIUI）', '设置 → 应用设置 → 应用管理 → 本应用：打开「自启动」；「省电策略」选「无限制」。'),
    (
      '华为 / 荣耀（HarmonyOS / MagicOS）',
      '设置 → 电池 → 启动管理（应用启动管理）→ 本应用：关闭「自动管理」，在弹框中打开「允许自启动」「允许后台活动」。',
    ),
    (
      'OPPO / 一加 / realme（ColorOS）',
      '设置 → 应用 → 应用管理 → 本应用：打开「允许自启动」；「耗电管理」中打开「允许后台运行」。',
    ),
    (
      'vivo / iQOO（OriginOS）',
      '设置 → 电池 → 后台耗电管理 → 本应用选「允许后台高耗电」；i 管家 → 应用管理 → 自启动 中打开本应用。',
    ),
    (
      '三星（One UI）',
      '设置 → 电池 → 后台使用限制：确保本应用不在「休眠应用」「深度休眠应用」中；应用详情 → 电池 选「不受限制」。',
    ),
    ('其他品牌', '在系统设置中搜索「自启动」「后台运行」「电池优化」，对本应用选择允许 / 不优化。'),
  ];
}
