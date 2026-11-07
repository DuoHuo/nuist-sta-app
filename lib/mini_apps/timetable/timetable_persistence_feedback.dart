import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/logging/app_log.dart';
import 'timetable_store.dart';
import 'timetable_theme.dart';

/// 保存失败时保留当前编辑界面，显示安全提示，不输出底层异常文本。
/// 弹层可通过 [onError] 在内部展示错误，避免提示被弹层遮挡。
Future<T?> withTimetablePersistenceFeedback<T>(
  BuildContext context,
  Future<T> Function() action, {
  ValueChanged<String>? onError,
}) async {
  try {
    return await AppLog.logger('timetable.controller')
        .operation('edit.persist', action);
  } on TimetablePersistenceException catch (error) {
    if (context.mounted) {
      final message = error.toString();
      if (onError != null) {
        onError(message);
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          AppSnackBar(tone: AppSnackBarTone.error, content: Text(message)),
        );
      }
    }
    return null;
  }
}

/// 弹层内的保存错误，支持屏幕阅读器播报与系统字号。
class TimetablePersistenceErrorText extends StatelessWidget {
  const TimetablePersistenceErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(
        color: TimetableTheme.colorsOf(context).danger,
        height: 1.4,
      ),
    ),
  );
}
