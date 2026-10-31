import 'package:flutter/material.dart';

import '../../core/logging/app_log.dart';
import 'timetable_store.dart';

/// 保存失败时保留当前编辑界面，显示安全提示，不输出底层异常文本。
Future<T?> withTimetablePersistenceFeedback<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  try {
    return await AppLog.logger('timetable.controller')
        .operation('edit.persist', action);
  } on TimetablePersistenceException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
    return null;
  }
}
