import 'package:flutter/material.dart';

import 'timetable_change_format.dart';
import 'timetable_controller.dart';
import 'timetable_copy.dart';
import 'timetable_sync_diff.dart';
import 'timetable_theme.dart';
import 'timetable_change_alert.dart' show changeTypeChipStyle;

Future<void> openTimetableChangeLogPage(
  BuildContext context, {
  TimetableController? controller,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TimetableChangeLogPage(controller: controller),
    ),
  );
}

/// 变动记录页：按同步时间倒序分组；空态「还没有变动」。
class TimetableChangeLogPage extends StatefulWidget {
  const TimetableChangeLogPage({super.key, this.controller});

  final TimetableController? controller;

  @override
  State<TimetableChangeLogPage> createState() => _TimetableChangeLogPageState();
}

class _TimetableChangeLogPageState extends State<TimetableChangeLogPage> {
  late Future<List<TimetableChangeRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = TimetableChangeLogStore.readNewestFirst();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    return Scaffold(
      key: const Key('tt_change_log_page'),
      backgroundColor: colors.pageBg,
      appBar: AppBar(title: const Text(TimetableCopy.changeLogTitle)),
      body: FutureBuilder<List<TimetableChangeRecord>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = snap.data ?? const [];
          if (records.isEmpty) {
            return Center(
              child: Text(
                TimetableCopy.changeLogEmpty,
                key: const Key('tt_change_log_empty'),
                style: TextStyle(color: colors.hint, fontSize: 15),
              ),
            );
          }
          final groups = _groupByFingerprintTime(records);
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: groups.length,
            itemBuilder: (context, gi) {
              final g = groups[gi];
              return Padding(
                padding: EdgeInsets.only(top: gi == 0 ? 0 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        TimetableChangeFormat.groupTitle(g.time),
                        key: Key('tt_change_log_group_$gi'),
                        style: TextStyle(fontSize: 13, color: colors.hint),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < g.items.length; i++) ...[
                            if (i > 0)
                              Divider(height: 1, color: colors.divider),
                            _LogRow(record: g.items[i], index: i, group: gi),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 同一 fingerprint（同一次 sync）合成一组；组内按原顺序。
  List<_LogGroup> _groupByFingerprintTime(
    List<TimetableChangeRecord> newestFirst,
  ) {
    final out = <_LogGroup>[];
    final seen = <String>{};
    for (final r in newestFirst) {
      if (!seen.add(r.fingerprint)) continue;
      final items = [
        for (final x in newestFirst)
          if (x.fingerprint == r.fingerprint) x,
      ];
      out.add(
        _LogGroup(time: r.time, fingerprint: r.fingerprint, items: items),
      );
    }
    return out;
  }
}

class _LogGroup {
  const _LogGroup({
    required this.time,
    required this.fingerprint,
    required this.items,
  });
  final DateTime time;
  final String fingerprint;
  final List<TimetableChangeRecord> items;
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.record,
    required this.index,
    required this.group,
  });

  final TimetableChangeRecord record;
  final int index;
  final int group;

  @override
  Widget build(BuildContext context) {
    final colors = TimetableTheme.colorsOf(context);
    final chip = changeTypeChipStyle(record.type, colors);
    final detail = TimetableChangeFormat.detailOf(record);
    return Padding(
      key: Key('tt_change_log_row_${group}_$index'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: chip.fg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              record.type.labelZh,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.surface,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.courseName.isEmpty ? '（无课名）' : record.courseName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: colors.titleText,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(fontSize: 13, color: colors.hint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
