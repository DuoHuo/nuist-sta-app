import 'package:flutter/material.dart';

import '../../core/ui/miuix_dialog.dart';

/// 删除范围（详情「删除」三档）。
enum DeleteScope {
  /// 仅第 X 周周 Y 的这节课。
  oneDay,

  /// 全部周 Y 同老师同地点（空则同名）。
  weekdayMatch,

  /// 这门课程的全部时间段。
  wholeCourse,
}

const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 「仅第 7 周周一的这节课」类文案。
String deleteScopeOneDayLabel(int week, int weekday) {
  final wd = _weekdayCn[(weekday - 1).clamp(0, 6)];
  return '仅第 $week 周周$wd的这节课';
}

/// 「全部周一同老师同地点的这节课」；空老师或地点时文案仍显示，匹配放宽在数据层。
String deleteScopeWeekdayMatchLabel(int weekday, {required bool relaxed}) {
  final wd = _weekdayCn[(weekday - 1).clamp(0, 6)];
  if (relaxed) return '全部周$wd同名课程的这节课';
  return '全部周$wd同老师同地点的这节课';
}

/// WakeUp 风格三档删除菜单；取消独立、danger 色。返回 null = 取消。
///
/// [anchorContext] 用来定位原地弹出的菜单，传触发删除的按钮上下文。
Future<DeleteScope?> showDeleteScopeSheet(
  BuildContext anchorContext, {
  required int week,
  required int weekday,
  required bool teacherOrLocationEmpty,
}) {
  return showMiuixOptionMenu<DeleteScope>(
    anchorContext,
    anchorBounds: miuixAnchorRect(anchorContext),
    menuKey: const Key('delete_scope_sheet'),
    cancelLabel: '取消',
    cancelKey: const Key('delete_scope_cancel'),
    items: [
      MiuixOptionItem(
        key: const Key('delete_scope_one_day'),
        value: DeleteScope.oneDay,
        label: deleteScopeOneDayLabel(week, weekday),
      ),
      MiuixOptionItem(
        key: const Key('delete_scope_weekday_match'),
        value: DeleteScope.weekdayMatch,
        label: deleteScopeWeekdayMatchLabel(
          weekday,
          relaxed: teacherOrLocationEmpty,
        ),
      ),
      MiuixOptionItem(
        key: const Key('delete_scope_whole_course'),
        value: DeleteScope.wholeCourse,
        label: '这门课程的全部时间段',
      ),
    ],
  );
}
