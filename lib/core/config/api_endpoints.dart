/// 自有公网服务（非校内地址），按普通常量明文存放，不做 hex 编码。
library;

/// 自有服务的接口根路径。
const String kApiBase = 'https://app.duohuo.org.cn/api/v1';

/// 贡献者名单接口。
const String kContributorsEndpoint = '$kApiBase/contributors';

/// 公告接口。
const String kAnnouncementEndpoint = '$kApiBase/announcement';

/// 课表 WakeUp 分享口令生成接口。
const String kTimetableWakeupEndpoint = '$kApiBase/timetable/wakeup-share';
