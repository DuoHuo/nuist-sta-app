import 'dart:ui' show Color;

import 'timetable_colors.dart';
import 'timetable_theme.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';

/// UI 侧课程色号入口（0..15，全局防重与相邻避撞）。
int courseColorIndex(TimetableController controller, Course course) =>
    controller.colorIndexOf(course);

/// 课程在当前明暗下的（底色, 文字色）——周视图 / 首页 / 外观 / 选色预览的**唯一**入口：
/// 自选颜色原样显示，单节课与全局遵循相同规则；未自选时使用全局去重分配的「晴空清透」16 色。
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
    controller.colorIndexOf(course),
    dark: dark,
  );
}

/// 课程原始颜色：选色器用它初始化，避免将明暗主题的显示色再次换算。
Color courseRawColorFor(TimetableController controller, Course course) {
  final user = controller.userColorOf(course);
  if (user != null) return Color(user);
  return TimetableTheme.autoCoursePair(controller.colorIndexOf(course)).bg;
}

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
