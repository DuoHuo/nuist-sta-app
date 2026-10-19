import 'dart:ui' show Color;

import 'timetable_colors.dart';
import 'timetable_theme.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';

/// UI 侧唯一的课程色号入口（0..15）：周视图格子、详情弹层、首页卡片、表单预览都走这里。
/// 委托 [TimetableController.colorIndexOf]（学期内相邻/近色撞色顺延）。
int courseColorIndex(TimetableController controller, Course course) =>
    controller.colorIndexOf(course);

/// 课程在当前明暗下的（底色, 文字色）：用户自选色优先（item 9，显示时换算），
/// 否则用色相步进自动色板（item 3，非 A/B/C）；已有 userColors 不迁。
CourseColorPair coursePairFor(
  TimetableController controller,
  Course course, {
  bool dark = false,
}) {
  final user = controller.userColorOf(course);
  if (user != null) {
    return TimetableTheme.userCoursePair(Color(user), dark: dark);
  }
  return TimetableTheme.autoCoursePair(
    courseColorIndex(controller, course),
    dark: dark,
  );
}

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
