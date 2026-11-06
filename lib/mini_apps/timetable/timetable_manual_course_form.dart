import 'package:flutter/material.dart';

import 'timetable_controller.dart';
import 'timetable_course_form.dart';
import 'timetable_models.dart';

export 'timetable_course_form.dart' show describeManualConflicts;

/// 打开添加或编辑手动课程的统一表单；取消返回 null。
Future<Course?> showManualCourseForm(
  BuildContext context, {
  required TimetableController controller,
  Course? initial,
  CourseSlot? initialSlot,
  GridCell? cell,
  bool autofocusNote = false,
}) => Navigator.of(context).push<Course>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ManualCourseForm(
      controller: controller,
      initial: initial,
      initialSlot: initialSlot,
      cell: cell,
      autofocusNote: autofocusNote,
    ),
  ),
);

/// 手动课程入口，保留旧调用接口并复用统一课程表单。
class ManualCourseForm extends StatelessWidget {
  const ManualCourseForm({
    super.key,
    required this.controller,
    this.initial,
    this.initialSlot,
    this.cell,
    this.autofocusNote = false,
  });

  final TimetableController controller;
  final Course? initial;
  final CourseSlot? initialSlot;
  final GridCell? cell;
  final bool autofocusNote;

  @override
  Widget build(BuildContext context) => TimetableCourseForm(
    controller: controller,
    initial: initial,
    initialSlot: initialSlot,
    cell: cell,
    autofocusNote: autofocusNote,
  );
}
