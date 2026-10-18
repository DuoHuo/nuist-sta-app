import 'timetable_colors.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';

/// UI 侧唯一的课程色号入口（0..15）：周视图格子、详情弹层、首页卡片、表单预览都走这里。
/// 委托 [TimetableController.colorIndexOf]（学期内相邻/近色撞色顺延）。
int courseColorIndex(TimetableController controller, Course course) =>
    controller.colorIndexOf(course);

/// 当前设置里的配色方案（`paletteScheme` 'A'/'B'/'C'）。
CoursePaletteScheme coursePaletteSchemeFor(TimetableController controller) =>
    coursePaletteSchemeOf(controller.settings.paletteScheme);
