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
/// - 用户自选色优先（[TimetableController.userColorOf]，键为 Course.id）；
/// - 否则 [coursePresetIndexForCourse]（id 优先，否则配色用名）进 12 预设，
///   再经 [TimetableTheme.userCoursePair] 统一为浅底深字 / 深色 darkCoursePair。
/// 不走 A/B/C 柔和色板，不按亮度分叉白字。
CourseColorPair coursePairFor(
  TimetableController controller,
  Course course, {
  bool dark = false,
}) {
  final user = controller.userColorOf(course);
  if (user != null) {
    return TimetableTheme.userCoursePair(Color(user), dark: dark);
  }
  final name = controller.colorNameOf(course);
  final index = coursePresetIndexForCourse(course, colorName: name);
  return TimetableTheme.autoCoursePair(index, dark: dark);
}

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
