/// 课表模块集中文案（≤6 字标题；句末无句号；浅/深用同一套字）。
abstract final class TimetableCopy {
  // —— WakeUp 导出：未导出时段 ——
  static const exportSkippedLink = '有 {n} 门课未导出';
  static const exportSkippedSheetTitle = '未导出的课';
  static const exportSkippedFooter = 'WakeUp 里需要手动补上';
  static const exportSkippedGotIt = '知道了';
  static const exportSkipNoFixedTime = '没有固定时间';
  static const exportSkipEmptyWeeks = '没排周次';

  static String exportSkippedLinkLabel(int n) =>
      exportSkippedLink.replaceFirst('{n}', '$n');

  // —— 同步变动提醒 / 变动记录 ——
  static const changeAlertTitle = '课表有变动';
  static const changeAlertViewLog = '查看记录';
  static const changeAlertGotIt = '知道了';
  static const changeAlertMore = '等共 {n} 项';
  static const changeLogTitle = '变动记录';
  static const changeLogEmpty = '还没有变动';
  static const changeLogSettingsTitle = '变动记录';
  static const changeLogSettingsSubtitle = '同步后的改动';

  static String changeAlertMoreLabel(int n) =>
      changeAlertMore.replaceFirst('{n}', '$n');

  // —— 首页今日卡 ——
  static const homeRefreshFailed = '刷新失败';
  static const homeSyncJustNow = '刚刚同步';
  static const homeSyncMinutesAgo = '{n} 分钟前同步';
  static const homeSyncHoursAgo = '{n} 小时前同步';
  static const homeSyncDaysAgo = '{n} 天前同步';

  static String homeSyncMinutesAgoLabel(int n) =>
      homeSyncMinutesAgo.replaceFirst('{n}', '$n');

  static String homeSyncHoursAgoLabel(int n) =>
      homeSyncHoursAgo.replaceFirst('{n}', '$n');

  static String homeSyncDaysAgoLabel(int n) =>
      homeSyncDaysAgo.replaceFirst('{n}', '$n');
}
