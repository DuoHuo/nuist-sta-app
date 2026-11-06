import '../core/app_registry.dart';
import 'academic/academic_manifest.dart';
import 'bulletin/bulletin_manifest.dart';
import 'campus_map/campus_map_manifest.dart';
import 'electricity/electricity_manifest.dart';
import 'free_classroom/free_classroom_manifest.dart';
import 'innovation_credit/innovation_credit_manifest.dart';
import 'labor_score/labor_score_manifest.dart';
import 'score/score_manifest.dart';
import 'student_info/student_info_manifest.dart';
import 'timetable/timetable_exams_manifest.dart';
import 'timetable/timetable_manifest.dart';

/// 全量小程序注册表：统一提供首页宫格、学习卡片及全屏入口。
///
/// 新增小程序 = 建 `lib/mini_apps/<name>/` 目录（或直接给 H5 地址），
/// 然后在这里加一行。除此之外不需要改动壳的任何代码。
final appRegistry = AppRegistry([
  bulletinManifest,
  electricityManifest,
  freeClassroomManifest,
  campusMapManifest,
  timetableManifest,
  // 考试安排：课表考试在主页的直观入口（issue #30），数据复用课表。
  examScheduleManifest,
  studentInfoManifest,
  academicManifest,
  scoreManifest,
  innovationCreditManifest,
  laborScoreManifest,
  // H5 小程序示例：给 url 即可，由通用 WebView 页承载。
  // AppManifest(id: 'demo-web', label: '网页示例', color: Color(0xFF8B5CF6),
  //     glyph: '网', url: 'https://example.com'),
]);
