import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'free_classroom_controller.dart';
import 'free_classroom_models.dart';
import 'free_classroom_widgets.dart';

/// 本小程序所有底部面板的统一外观。
Future<T?> _present<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: builder,
  );
}

/// 选教学楼：所有楼栋平铺成标签，当前这栋高亮。收起面板返回 null。
Future<Building?> showBuildingSheet(
  BuildContext context,
  FreeClassroomController controller,
) => _present<Building>(context, (_) => _BuildingSheet(controller: controller));

/// 单选面板里的一项；[value] 为 null 表示「全部 / 不限」。
class SheetOption<T> {
  const SheetOption({required this.value, required this.label, this.hint = ''});

  final T? value;
  final String label;
  final String hint;
}

/// 通用单选面板。返回被点的那一项，收起面板返回 null。
Future<SheetOption<T>?> showOptionSheet<T>(
  BuildContext context, {
  required String title,
  required List<SheetOption<T>> options,
  required T? current,
}) => _present<SheetOption<T>>(
  context,
  (_) => _OptionSheet<T>(title: title, options: options, current: current),
);

/// 单间教室的逐节占用详情。
Future<void> showRoomDetailSheet(
  BuildContext context, {
  required Classroom room,
  required ClassroomDay day,
  required Map<String, String> occupationNames,
  required Set<int> overGroups,
}) => _present<void>(
  context,
  (_) => _RoomDetailSheet(
    room: room,
    day: day,
    occupationNames: occupationNames,
    overGroups: overGroups,
  ),
);

// ==================== 教学楼 ====================

class _BuildingSheet extends StatelessWidget {
  const _BuildingSheet({required this.controller});

  final FreeClassroomController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final list = controller.buildings ?? const <Building>[];
        final current = controller.building;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _SheetTitle('选择教学楼'),
                    const Spacer(),
                    if (controller.buildingsLoading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '暂无教学楼数据',
                      style: TextStyle(fontSize: 13, color: AppColors.hint),
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final b in list)
                        _BuildingTile(
                          building: b,
                          selected: b == current,
                          onTap: () => Navigator.of(context).pop(b),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BuildingTile extends StatelessWidget {
  const _BuildingTile({
    required this.building,
    required this.selected,
    required this.onTap,
  });

  final Building building;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? kClassroomColor.withValues(alpha: 0.12)
              : AppColors.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? kClassroomColor.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        // widthFactor 让它按文字定宽，否则会被 Wrap 的宽松约束撑满一行。
        child: Center(
          widthFactor: 1,
          child: Text(
            building.name,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? kClassroomColor : AppColors.titleText,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 通用单选 ====================

class _OptionSheet<T> extends StatelessWidget {
  const _OptionSheet({
    required this.title,
    required this.options,
    required this.current,
  });

  final String title;
  final List<SheetOption<T>> options;
  final T? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(title),
            const SizedBox(height: 6),
            for (final o in options)
              _OptionRow(
                label: o.label,
                hint: o.hint,
                selected: o.value == current,
                onTap: () => Navigator.of(context).pop(o),
              ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? kClassroomColor : AppColors.titleText,
                ),
              ),
            ),
            Text(
              hint,
              style: const TextStyle(fontSize: 12, color: AppColors.hint),
            ),
            const SizedBox(width: 10),
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 18,
              color: selected ? kClassroomColor : const Color(0xFFC9CDD4),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 教室详情 ====================

class _RoomDetailSheet extends StatelessWidget {
  const _RoomDetailSheet({
    required this.room,
    required this.day,
    required this.occupationNames,
    required this.overGroups,
  });

  final Classroom room;
  final ClassroomDay day;
  final Map<String, String> occupationNames;
  final Set<int> overGroups;

  @override
  Widget build(BuildContext context) {
    final cal = day.calendar;
    final meta = [
      if (room.type.isNotEmpty) room.type,
      if (room.floor > 0) '${room.floor} 层',
      if (room.seats != null && room.seats! > 0) '${room.seats} 座',
    ].join(' · ');
    final groups = day.groups;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  room.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.titleText,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    meta,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.labelText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${day.building.name} · ${day.date.month}月${day.date.day}日 '
              '${cal.weekdayName} · 第${cal.week}周',
              style: const TextStyle(fontSize: 12, color: AppColors.hint),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.rowDivider),
            for (var i = 0; i < groups.length; i++)
              _GroupDetailRow(
                group: groups[i],
                room: room,
                occupationNames: occupationNames,
                over: overGroups.contains(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupDetailRow extends StatelessWidget {
  const _GroupDetailRow({
    required this.group,
    required this.room,
    required this.occupationNames,
    required this.over,
  });

  final PeriodGroup group;
  final Classroom room;
  final Map<String, String> occupationNames;
  final bool over;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: over ? 0.45 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${group.label} 节',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    group.timeRange,
                    style: const TextStyle(fontSize: 11, color: AppColors.hint),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final p in group.periods)
                    _PeriodStatusTag(
                      period: p,
                      codes: room.occupationOf(p),
                      occupationNames: occupationNames,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodStatusTag extends StatelessWidget {
  const _PeriodStatusTag({
    required this.period,
    required this.codes,
    required this.occupationNames,
  });

  final int period;
  final List<String> codes;
  final Map<String, String> occupationNames;

  @override
  Widget build(BuildContext context) {
    final free = codes.isEmpty;
    final status = free
        ? '空闲'
        : codes.map((c) => occupationNames[c] ?? '占用($c)').toSet().join('、');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: free
            ? AppColors.success.withValues(alpha: 0.1)
            : AppColors.pageBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '第$period节 $status',
        style: TextStyle(
          fontSize: 12,
          color: free ? AppColors.success : AppColors.labelText,
          fontWeight: free ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.titleText,
      ),
    );
  }
}
