import 'package:flutter/material.dart';

import 'timetable_change_format.dart';
import 'timetable_change_log_page.dart';
import 'timetable_controller.dart';
import 'timetable_copy.dart';
import 'timetable_sync_diff.dart';
import 'timetable_theme.dart';

/// 同步成功后弹出变动摘要（底部 sheet）；每 fingerprint 只弹一次。
///
/// 关闭（下滑 / 知道了 / 查看记录）都会 [TimetableChangeLogStore.markNotified]
/// 并清空 [TimetableController.lastSyncDiff]，避免同页重复弹出。
Future<void> showTimetableChangeAlert(
  BuildContext context, {
  List<TimetableChangeRecord>? records,
  TimetableController? controller,
  int maxRows = 5,
}) async {
  final c = controller ?? TimetableController.instance;
  final list = List<TimetableChangeRecord>.of(records ?? c.pendingChangeAlerts);
  if (list.isEmpty) return;

  var notified = false;
  Future<void> markDone() async {
    if (notified) return;
    notified = true;
    final fps = {for (final r in list) r.fingerprint};
    await TimetableChangeLogStore.markNotified(fps);
    c.lastSyncDiff = null;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TimetableTheme.colorsOf(context).surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final colors = TimetableTheme.colorsOf(ctx);
      final shown = list.take(maxRows).toList();
      final more = list.length > maxRows;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: colors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                TimetableCopy.changeAlertTitle,
                key: const Key('tt_change_alert_title'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(height: 14),
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _AlertRow(record: shown[i], index: i),
              ],
              if (more) ...[
                const SizedBox(height: 12),
                Text(
                  TimetableCopy.changeAlertMoreLabel(list.length),
                  key: const Key('tt_change_alert_more'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.hint),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('tt_change_alert_view_log'),
                      onPressed: () async {
                        await markDone();
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (!context.mounted) return;
                        await openTimetableChangeLogPage(
                          context,
                          controller: c,
                        );
                      },
                      child: const Text(TimetableCopy.changeAlertViewLog),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    key: const Key('tt_change_alert_got_it'),
                    onPressed: () async {
                      await markDone();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: Text(
                      TimetableCopy.changeAlertGotIt,
                      style: TextStyle(color: colors.hint),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  ).whenComplete(markDone);
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.record, required this.index});

  final TimetableChangeRecord record;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final chip = changeTypeChipStyle(record.type, colors);
    return Row(
      key: Key('tt_change_alert_row_$index'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: Key('tt_change_alert_chip_$index'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: chip.bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            record.type.labelZh,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: chip.fg,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            TimetableChangeFormat.alertBody(record),
            style: TextStyle(
              fontSize: 14,
              color: colors.titleText,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// 类型胶囊色（弹窗浅底深字；记录页可复用 [bg]/[fg]）。
({Color bg, Color fg}) changeTypeChipStyle(
  TimetableChangeType type,
  TimetableColors colors,
) {
  // 色值来自 [TimetableColors] / [TimetableTheme] 变动类型 token；文案仍用 type.labelZh。
  switch (type) {
    case TimetableChangeType.added:
      return (bg: colors.changeAddedBg, fg: colors.changeAddedFg);
    case TimetableChangeType.removed:
      return (bg: colors.changeRemovedBg, fg: colors.changeRemovedFg);
    case TimetableChangeType.timeChanged:
      return (bg: colors.changeTimeBg, fg: colors.changeTimeFg);
    case TimetableChangeType.locationChanged:
      return (bg: colors.changeLocationBg, fg: colors.changeLocationFg);
    case TimetableChangeType.teacherChanged:
      return (bg: colors.changeTeacherBg, fg: colors.changeTeacherFg);
    case TimetableChangeType.retakeFlagChanged:
      return (bg: colors.changeRetakeBg, fg: colors.changeRetakeFg);
  }
}
