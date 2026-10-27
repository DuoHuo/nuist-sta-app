import 'dart:ui' show Color;

import 'timetable_colors.dart';
import 'timetable_theme.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';

/// UI 侧课程色号入口（0..15，A/B/C / 旧撞色顺延用）。
/// 自动显示色请用 [coursePairFor]（id 优先 / 课名哈希进 12 预设）。
int courseColorIndex(TimetableController controller, Course course) =>
    controller.colorIndexOf(course);

/// 课程在当前明暗下的（底色, 文字色）——周视图 / 首页 / 外观 / 选色预览的**唯一**入口：
/// 自选颜色原样显示，单节课与全局遵循相同规则；未自选时使用自动分配的柔和配色。
CourseColorPair coursePairFor(
  TimetableController controller,
  Course course, {
  bool dark = false,
}) {
  final user = controller.userColorOf(course);
  if (user != null) {
    return TimetableTheme.userCoursePair(Color(user), dark: dark);
  }
  final index = coursePresetIndexForCourse(
    course,
    colorName: controller.colorNameOf(course),
  );
  return TimetableTheme.autoCoursePair(index, dark: dark);
}

/// 课程原始颜色：选色器用它初始化，避免将明暗主题的显示色再次换算。
Color courseRawColorFor(TimetableController controller, Course course) {
  final user = controller.userColorOf(course);
  if (user != null) return Color(user);
  final name = controller.colorNameOf(course);
  final index = coursePresetIndexForCourse(course, colorName: name);
  return TimetableTheme.coursePresetColors[index];
}

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
