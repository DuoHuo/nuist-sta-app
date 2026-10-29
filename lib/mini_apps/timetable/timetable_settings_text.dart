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
