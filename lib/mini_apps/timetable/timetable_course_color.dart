import 'dart:ui' show Color;

import 'timetable_colors.dart';
import 'timetable_theme.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';

/// UI 侧课程色号入口（0..15，A/B/C / 旧撞色顺延用）。
/// 自动显示色请用 [coursePairFor]（课名哈希进 12 预设）。
int courseColorIndex(TimetableController controller, Course course) =>
    controller.colorIndexOf(course);

/// 课程在当前明暗下的（底色, 文字色）：
/// - 用户自选色优先（[TimetableController.userColorOf]，键为 Course.id）；
/// - 否则按**课名**哈希进 [TimetableTheme.coursePresetColors]（同名同色，稳定）。
/// 不走 Course.id，不走 A/B/C 柔和色板。
CourseColorPair coursePairFor(
  TimetableController controller,
  Course course, {
  bool dark = false,
}) {
  final user = controller.userColorOf(course);
  if (user != null) {
    return TimetableTheme.userCoursePair(Color(user), dark: dark);
  }
  // 教务改名不换色：与 colorIndexOf 相同，用控制器解析后的配色用名。
  final name = controller.colorNameOf(course);
  return TimetableTheme.autoCoursePairForName(name, dark: dark);
}

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
