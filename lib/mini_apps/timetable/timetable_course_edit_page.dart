import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_course_form.dart';
import 'timetable_models.dart';

/// 删除教务课程前的确认提示。
const String kJwxtCourseDeleteMessage = '删除这门课？同步后也不会恢复，可在设置里一键恢复。';

/// 打开教务课程编辑页；保存成功返回 true。
Future<bool?> showJwxtCourseEditPage(
  BuildContext context, {
  required TimetableController controller,
  required GridCell cell,
  bool autofocusNote = false,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    // Android 的全屏对话框会禁用预测性返回，其他平台保留原有模态行为。
    fullscreenDialog: Theme.of(context).platform != TargetPlatform.android,
    builder: (_) => JwxtCourseEditPage(
      controller: controller,
      cell: cell,
      autofocusNote: autofocusNote,
    ),
  ),
);

/// 教务课程入口，内容通过本地覆盖层保存，复用统一课程表单。
class JwxtCourseEditPage extends StatelessWidget {
  const JwxtCourseEditPage({
    super.key,
    required this.controller,
    required this.cell,
    this.autofocusNote = false,
  });

  final TimetableController controller;
  final GridCell cell;
  final bool autofocusNote;

  @override
  Widget build(BuildContext context) => TimetableCourseForm(
    controller: controller,
    initial: cell.course,
    initialSlot: cell.slot,
    cell: cell,
    autofocusNote: autofocusNote,
    returnSavedFlag: true,
  );
}
