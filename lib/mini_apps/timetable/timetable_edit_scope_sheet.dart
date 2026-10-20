import 'package:flutter/material.dart';

import 'timetable_date_edits.dart';
import 'timetable_theme.dart';

/// 「只改这一天（10月21日）」文案。
String editScopeThisDayLabel(DateTime date) =>
    '只改这一天（${date.month}月${date.day}日）';

/// 编辑 / 拖动保存时的范围面板（第 1 条）：「只改这一天（M月D日）」/「所有周」，
/// 默认（第一项、实心按钮）只改这一天。点遮罩 / 下拉关闭返回 null（调用方不保存）。
Future<EditScope?> showEditScopeSheet(
  BuildContext context, {
  required DateTime date,
}) {
  return showModalBottomSheet<EditScope>(
    context: context,
    isDismissible: true,
    enableDrag: true,
    builder: (sheetContext) {
      final colors = TimetableTheme.colorsOf(sheetContext);
      return SafeArea(
        child: Padding(
          key: const Key('edit_scope_sheet'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '此更改应用范围？',
                style: TimetableTheme.titleStyle(color: colors.titleText),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const Key('edit_scope_this_day'),
                  autofocus: true,
                  onPressed: () =>
                      Navigator.pop(sheetContext, EditScope.thisDay),
                  child: Text(editScopeThisDayLabel(date)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const Key('edit_scope_all_weeks'),
                  onPressed: () =>
                      Navigator.pop(sheetContext, EditScope.allWeeks),
                  child: const Text('所有周'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
