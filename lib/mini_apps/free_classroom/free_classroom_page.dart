import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import 'free_classroom_controller.dart';
import 'free_classroom_models.dart';
import 'free_classroom_sheets.dart';
import 'free_classroom_widgets.dart';

/// 座位筛选的档位，0 = 不限。
const List<int> _seatOptions = [0, 30, 60, 100];

/// 状态格之间的间距。时段表头与每一行共用同一套格宽，列才对得齐。
const double _kCellGap = 5;

/// 教室名那一列至少留这么宽，剩下的均分给状态格。
const double _kNameMinWidth = 112;

/// 空教室查询页。
///
/// 整页是一个 CustomScrollView：
/// - 筛选卡（教学楼 → 日期 → 分区 / 楼层 → 类型 / 座位）随内容一起滚走；
/// - 时段表头钉在顶部：五个格子既是「查哪几节」的开关，也是下面每行五个
///   状态格的列标题；
/// - 教室列表分三段：所选时段全部空闲、部分空闲、全部占用，每段都能折叠，
///   全部占用的默认收着放在最底下；点一行看逐节详情。
class FreeClassroomPage extends StatefulWidget {
  const FreeClassroomPage({super.key});

  @override
  State<FreeClassroomPage> createState() => _FreeClassroomPageState();
}

/// 教室列表的三段。
enum _Section { free, partial, busy }

class _FreeClassroomPageState extends State<FreeClassroomPage> {
  final _controller = FreeClassroomController.instance;

  /// 收起的段。全占用的教室对找空教室的人没用，默认收着。
  final _collapsed = <_Section>{_Section.busy};

  void _toggleSection(_Section section) {
    setState(() {
      if (!_collapsed.remove(section)) _collapsed.add(section);
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.ensureStarted().then((_) {
      if (!mounted) return;
      final c = _controller;
      // 第一次用、还没选过楼：直接弹选楼面板，省一次点击。
      if (c.portalBound &&
          c.building == null &&
          (c.buildings?.isNotEmpty ?? false)) {
        _pickBuilding();
      }
    });
  }

  Future<void> _pickBuilding() async {
    final picked = await showBuildingSheet(context, _controller);
    if (picked != null) await _controller.selectBuilding(picked);
  }

  Future<void> _pickType() async {
    final c = _controller;
    final day = c.result;
    if (day == null) return;
    final picked = await showOptionSheet<String>(
      context,
      title: '房间类型',
      current: c.type,
      options: [
        SheetOption(
          value: null,
          label: '全部教室',
          hint: '不含${kNonClassroomTypeKeywords.join('、')}',
        ),
        for (final t in day.types)
          SheetOption(value: t.key, label: t.key, hint: '${t.value} 间'),
      ],
    );
    if (picked != null) c.setType(picked.value);
  }

  Future<void> _pickSeats() async {
    final c = _controller;
    final day = c.result;
    if (day == null) return;
    int count(int min) => day.rooms
        .where((r) => !r.isNonClassroom && (r.seats ?? 0) >= min)
        .length;
    final picked = await showOptionSheet<int>(
      context,
      title: '座位数',
      current: c.minSeats,
      options: [
        for (final n in _seatOptions)
          SheetOption(
            value: n,
            label: n == 0 ? '不限座位' : '$n 座以上',
            hint: n == 0 ? '' : '${count(n)} 间',
          ),
      ],
    );
    if (picked != null) c.setMinSeats(picked.value ?? 0);
  }

  Future<void> _goBindPortal() async {
    await context.push('/portal-bind');
    await _controller.recheckPortal();
  }

  void _showRoomDetail(Classroom room, ClassroomDay day) {
    showRoomDetailSheet(
      context,
      room: room,
      day: day,
      occupationNames: _controller.occupationNames,
      overGroups: _controller.overGroups(day),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return Scaffold(
          backgroundColor: AppColors.pageBg,
          appBar: AppBar(
            title: const Text('空教室'),
            actions: [
              if (c.portalBound && c.building != null)
                _RefreshAction(
                  loading: c.loading,
                  onPressed: () => c.query(force: true),
                ),
            ],
          ),
          body: c.portalBound
              ? _buildBody(context, c)
              : _PortalGuide(onTap: _goBindPortal),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, FreeClassroomController c) {
    final day = c.result;
    final matches = c.matches();
    final available = matches.where((m) => !m.fullyBusy).length;
    // 表头和每行的状态格宽度：屏幕越宽格子越大，但教室名那列至少留够。
    final rowWidth = MediaQuery.sizeOf(context).width - 32 - 24;
    final n = day?.groups.length ?? 5;
    final cellWidth = ((rowWidth - _kNameMinWidth - _kCellGap * (n - 1)) / n)
        .clamp(28.0, 40.0);
    return RefreshIndicator(
      onRefresh: () => c.query(force: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _FilterCard(
                controller: c,
                onPickBuilding: _pickBuilding,
                onPickType: _pickType,
                onPickSeats: _pickSeats,
              ),
            ),
          ),
          if (day == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _StateView(controller: c, onPickBuilding: _pickBuilding),
            )
          else ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PeriodHeaderDelegate(
                controller: c,
                day: day,
                matched: available,
                cellWidth: cellWidth,
              ),
            ),
            if (matches.isEmpty)
              SliverToBoxAdapter(child: _EmptyResult(day: day))
            else
              _RoomList(
                controller: c,
                day: day,
                matches: matches,
                cellWidth: cellWidth,
                collapsed: _collapsed,
                onToggleSection: _toggleSection,
                onRoomTap: (room) => _showRoomDetail(room, day),
              ),
            const SliverToBoxAdapter(child: _Footer()),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ==================== 筛选卡 ====================

class _FilterCard extends StatelessWidget {
  const _FilterCard({
    required this.controller,
    required this.onPickBuilding,
    required this.onPickType,
    required this.onPickSeats,
  });

  final FreeClassroomController controller;
  final VoidCallback onPickBuilding;
  final VoidCallback onPickType;
  final VoidCallback onPickSeats;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final day = c.result;
    final floors = day?.floors ?? const <int>[];
    final zones = day?.zones ?? const <String>[];
    return ClassroomCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BuildingRow(controller: c, onTap: onPickBuilding),
          const _CardDivider(),
          _DateStrip(selected: c.date, onChanged: c.selectDate),
          if (day != null) ...[
            const _CardDivider(),
            const SizedBox(height: 4),
            // 分区只有一个（或名字里根本没有）时这一行没意义，不占地方。
            if (zones.length > 1)
              _ChipRow(
                label: '区域',
                children: [
                  ClassroomChip(
                    label: '全部',
                    selected: c.zone == null,
                    onTap: () => c.setZone(null),
                  ),
                  for (final z in zones)
                    ClassroomChip(
                      label: '$z 区',
                      selected: c.zone == z,
                      onTap: () => c.setZone(z),
                    ),
                ],
              ),
            if (floors.length > 1)
              _ChipRow(
                label: '楼层',
                children: [
                  ClassroomChip(
                    label: '全部',
                    selected: c.floor == null,
                    onTap: () => c.setFloor(null),
                  ),
                  for (final f in floors)
                    ClassroomChip(
                      label: f == 0 ? '其他' : '$f 层',
                      selected: c.floor == f,
                      onTap: () => c.setFloor(f),
                    ),
                ],
              ),
            _ChipRow(
              label: '筛选',
              children: [
                ClassroomChip(
                  label: c.type ?? '全部教室',
                  selected: c.type != null,
                  dropdown: true,
                  onTap: onPickType,
                ),
                ClassroomChip(
                  label: c.minSeats == 0 ? '不限座位' : '${c.minSeats} 座以上',
                  selected: c.minSeats > 0,
                  dropdown: true,
                  onTap: onPickSeats,
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _BuildingRow extends StatelessWidget {
  const _BuildingRow({required this.controller, required this.onTap});

  final FreeClassroomController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final building = c.building;
    final day = c.result;
    final hasList = c.buildings?.isNotEmpty ?? false;
    final listLoading = c.buildingsLoading && !hasList;
    final listFailed = c.buildingsError != null && !hasList;

    final String subtitle;
    var isError = false;
    if (listLoading) {
      subtitle = '正在加载教学楼列表…';
    } else if (listFailed) {
      subtitle = c.buildingsError!;
      isError = true;
    } else if (building == null) {
      subtitle = '点击选择要查询的教学楼';
    } else if (day != null) {
      final cal = day.calendar;
      final when = '${day.date.month}月${day.date.day}日 ${cal.weekdayName}';
      if (c.error != null) {
        subtitle = '$when · 刷新失败：${c.error}';
        isError = true;
      } else {
        subtitle = '$when · 第${cal.week}周 · 更新于 ${_hhmm(day.fetchedAt)}';
      }
    } else if (c.loading) {
      subtitle = '正在查询 ${c.date.month}月${c.date.day}日 的教室…';
    } else if (c.error != null) {
      subtitle = c.error!;
      isError = true;
    } else {
      subtitle = '点击更换教学楼';
    }

    final Widget trailing;
    if (listLoading) {
      trailing = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (listFailed) {
      trailing = const Text(
        '重试',
        style: TextStyle(fontSize: 13, color: AppColors.accent),
      );
    } else {
      trailing = const Icon(Icons.expand_more, color: Color(0xFFC9CDD4));
    }

    return InkWell(
      onTap: hasList ? onTap : (listFailed ? c.refreshBuildings : null),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: kClassroomColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.apartment_outlined,
                color: kClassroomColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    building?.name ?? '选择教学楼',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: isError ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: isError
                          ? Theme.of(context).colorScheme.error
                          : AppColors.hint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// 从今天起两周的日期条，横向滚动。
class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.selected, required this.onChanged});

  final DateTime selected;
  final ValueChanged<DateTime> onChanged;

  static const _days = 14;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        itemCount: _days,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final date = today.add(Duration(days: i));
          final isSelected = dateKeyOf(date) == dateKeyOf(selected);
          final top = i == 0
              ? '今天'
              : i == 1
              ? '明天'
              : '周${kWeekdayNames[date.weekday - 1]}';
          final showMonth = i > 0 && date.day == 1;
          return GestureDetector(
            onTap: () => onChanged(date),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 46,
              decoration: BoxDecoration(
                color: isSelected ? kClassroomColor : AppColors.pageBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _FitText(
                    top,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.85)
                          : AppColors.hint,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _FitText(
                    showMonth ? '${date.month}/${date.day}' : '${date.day}',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.titleText,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 「标签 + 一排可横向滚动的 chip」。
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 14),
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.labelText),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 14),
      child: Divider(height: 1, thickness: 1, color: AppColors.rowDivider),
    );
  }
}

// ==================== 时段表头（钉住） ====================

class _PeriodHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PeriodHeaderDelegate({
    required this.controller,
    required this.day,
    required this.matched,
    required this.cellWidth,
  });

  final FreeClassroomController controller;
  final ClassroomDay day;
  final int matched;
  final double cellWidth;

  @override
  double get minExtent => _PeriodHeader.height;

  @override
  double get maxExtent => _PeriodHeader.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return _PeriodHeader(
      controller: controller,
      day: day,
      matched: matched,
      cellWidth: cellWidth,
      // 钉在顶上且有内容从下面滚过时才切成方角 + 投影。
      pinned: shrinkOffset > 0 || overlapsContent,
    );
  }

  @override
  bool shouldRebuild(covariant _PeriodHeaderDelegate oldDelegate) => true;
}

/// 五个时段格子：点一下切换是否纳入查询；它们同时是列表每行状态格的列标题。
/// 左边「N 间可用」下面一行小字写的是**当前**的时段范围（全天 / 现在起），
/// 点一下切到另一个范围。
class _PeriodHeader extends StatelessWidget {
  const _PeriodHeader({
    required this.controller,
    required this.day,
    required this.matched,
    required this.cellWidth,
    required this.pinned,
  });

  static const double height = 54;

  final FreeClassroomController controller;
  final ClassroomDay day;
  final int matched;
  final double cellWidth;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final groups = day.groups;
    final selected = c.selectedGroups;
    final over = c.overGroups(day);
    final allSelected = selected.length == groups.length;

    // 文案写的是现在的状态，点击才切到另一边：没全选 → 显示「现在起」，点了
    // 全选；全选了 → 显示「全天」，点了只留还没结束的。今天的课要么全没
    // 开始要么全结束时「现在起」等于「全天」，不给切换。
    final String? quickLabel;
    final VoidCallback? onQuick;
    if (!allSelected) {
      quickLabel = '现在起';
      onQuick = c.selectAllGroups;
    } else if (over.isNotEmpty && over.length < groups.length) {
      quickLabel = '全天';
      onQuick = c.selectUpcomingGroups;
    } else {
      quickLabel = null;
      onQuick = null;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: pinned
              ? BorderRadius.zero
              : const BorderRadius.vertical(top: Radius.circular(12)),
          boxShadow: pinned
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$matched 间可用',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.titleText,
                            ),
                          ),
                          if (quickLabel != null)
                            GestureDetector(
                              onTap: onQuick,
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  '$quickLabel ›',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    for (var i = 0; i < groups.length; i++) ...[
                      if (i > 0) const SizedBox(width: _kCellGap),
                      _ColumnToggle(
                        group: groups[i],
                        width: cellWidth,
                        selected: selected.contains(i),
                        over: over.contains(i),
                        onTap: () => c.toggleGroup(i),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1, color: AppColors.rowDivider),
          ],
        ),
      ),
    );
  }
}

class _ColumnToggle extends StatelessWidget {
  const _ColumnToggle({
    required this.group,
    required this.width,
    required this.selected,
    required this.over,
    required this.onTap,
  });

  final PeriodGroup group;
  final double width;
  final bool selected;
  final bool over;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (selected) {
      bg = kClassroomColor.withValues(alpha: 0.12);
      fg = kClassroomColor;
    } else if (over) {
      bg = const Color(0xFFF7F8FA);
      fg = const Color(0xFFC9CDD4);
    } else {
      bg = AppColors.pageBg;
      fg = AppColors.labelText;
    }
    // 「08:00」→「8:00」，格子窄，省一个字符。
    final start = group.startTime.replaceFirst(RegExp(r'^0'), '');
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Center(
          // 选中态直接切换、不做过渡：点「全天 / 现在起」时五个格子一起变色，
          // 渐变看起来像按压动效。
          child: Container(
            width: width,
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _FitText(
                  group.label,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: fg,
                    decoration: over && !selected
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: fg,
                  ),
                ),
                const SizedBox(height: 2),
                _FitText(
                  start,
                  style: TextStyle(
                    fontSize: 9,
                    height: 1.2,
                    color: selected ? fg : fg.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 教室列表 ====================

sealed class _Entry {
  const _Entry();
}

class _SectionEntry extends _Entry {
  const _SectionEntry(this.section, this.count, this.collapsed);

  final _Section section;
  final int count;
  final bool collapsed;
}

class _RoomEntry extends _Entry {
  const _RoomEntry(this.match);

  final RoomMatch match;
}

/// 筛选出的教室一间都不空时，列表顶部先放一条「没有空教室」的提示，
/// 全占用那一段仍折叠着跟在后面。
class _NoticeEntry extends _Entry {
  const _NoticeEntry();
}

class _RoomList extends StatelessWidget {
  const _RoomList({
    required this.controller,
    required this.day,
    required this.matches,
    required this.cellWidth,
    required this.collapsed,
    required this.onToggleSection,
    required this.onRoomTap,
  });

  final FreeClassroomController controller;
  final ClassroomDay day;
  final List<RoomMatch> matches;
  final double cellWidth;
  final Set<_Section> collapsed;
  final ValueChanged<_Section> onToggleSection;
  final ValueChanged<Classroom> onRoomTap;

  static _Section _sectionOf(RoomMatch m) => m.fullyFree
      ? _Section.free
      : m.fullyBusy
      ? _Section.busy
      : _Section.partial;

  @override
  Widget build(BuildContext context) {
    // matches 已经按全空 → 部分 → 全占用排好，这里只按段切开。
    final bySection = <_Section, List<RoomMatch>>{};
    for (final m in matches) {
      bySection.putIfAbsent(_sectionOf(m), () => []).add(m);
    }
    final entries = <_Entry>[
      if (!bySection.containsKey(_Section.free) &&
          !bySection.containsKey(_Section.partial))
        const _NoticeEntry(),
      for (final section in _Section.values)
        if (bySection[section] case final rooms?) ...[
          _SectionEntry(section, rooms.length, collapsed.contains(section)),
          if (!collapsed.contains(section))
            for (final m in rooms) _RoomEntry(m),
        ],
    ];
    final selected = controller.selectedGroups;
    final over = controller.overGroups(day);
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        final isLast = i == entries.length - 1;
        final nextIsSection = !isLast && entries[i + 1] is _SectionEntry;
        return _ListShell(
          isLast: isLast,
          child: switch (entry) {
            _NoticeEntry() => _EmptyBody(day: day),
            _SectionEntry e => _SectionLabel(
              section: e.section,
              count: e.count,
              collapsed: e.collapsed,
              onTap: () => onToggleSection(e.section),
            ),
            _RoomEntry e => _RoomRow(
              match: e.match,
              groups: day.groups,
              selected: selected,
              over: over,
              cellWidth: cellWidth,
              showDivider: !isLast && !nextIsSection,
              onTap: () => onRoomTap(e.match.room),
            ),
          },
        );
      },
    );
  }
}

/// 列表每一项的白底外壳：横向留出页边距，最后一项收出圆角，连起来就是一张卡。
class _ListShell extends StatelessWidget {
  const _ListShell({required this.isLast, required this.child});

  final bool isLast;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.white,
        borderRadius: isLast
            ? const BorderRadius.vertical(bottom: Radius.circular(12))
            : BorderRadius.zero,
        clipBehavior: isLast ? Clip.antiAlias : Clip.none,
        child: child,
      ),
    );
  }
}

/// 段标题：整行可点，收起 / 展开这一段；右侧箭头指示当前状态。
/// 用 GestureDetector 而不是 InkWell：这一行只是个开关，按下去不要水波纹和
/// 灰色按压层，和旁边的教室行区分开。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.section,
    required this.count,
    required this.collapsed,
    required this.onTap,
  });

  final _Section section;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;

  static String titleOf(_Section section) => switch (section) {
    _Section.free => '所选时段全部空闲',
    _Section.partial => '部分时段空闲',
    _Section.busy => '所选时段全部占用',
  };

  static Color colorOf(_Section section) => switch (section) {
    _Section.free => AppColors.success,
    _Section.partial => AppColors.warning,
    _Section.busy => AppColors.hint,
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // 收起时下面没有行了，多留点底边，别贴着卡片边缘。
        padding: EdgeInsets.fromLTRB(12, 10, 8, collapsed ? 10 : 2),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                color: colorOf(section),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              titleOf(section),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.titleText,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count 间',
              style: const TextStyle(fontSize: 12, color: AppColors.hint),
            ),
            const Spacer(),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: const Color(0xFFC9CDD4),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomRow extends StatelessWidget {
  const _RoomRow({
    required this.match,
    required this.groups,
    required this.selected,
    required this.over,
    required this.cellWidth,
    required this.showDivider,
    required this.onTap,
  });

  final RoomMatch match;
  final List<PeriodGroup> groups;
  final Set<int> selected;
  final Set<int> over;
  final double cellWidth;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final room = match.room;
    // 楼层不放这里：名字里通常带着，筛选行也有；列窄，留给类型和座位。
    final meta = [
      if (room.type.isNotEmpty) room.type,
      if (room.seats != null && room.seats! > 0) '${room.seats}座',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: AppColors.titleText,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta.isEmpty ? '—' : meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: AppColors.hint,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) const SizedBox(width: _kCellGap),
                  _StatusCell(
                    group: groups[i],
                    room: room,
                    width: cellWidth,
                    dimmed: !selected.contains(i),
                    over: over.contains(i),
                  ),
                ],
              ],
            ),
          ),
          if (showDivider)
            const Divider(
              height: 1,
              thickness: 1,
              indent: 12,
              color: AppColors.rowDivider,
            ),
        ],
      ),
    );
  }
}

/// 一个时段的状态格：绿 = 该时段全空（纯色块，不加勾），橙 = 空一部分
/// （标出空闲节数），灰 = 都有课。勾选的时段永远画实；没勾选的画淡，其中
/// 今天已过的更淡。
class _StatusCell extends StatelessWidget {
  const _StatusCell({
    required this.group,
    required this.room,
    required this.width,
    required this.dimmed,
    required this.over,
  });

  final PeriodGroup group;
  final Classroom room;
  final double width;
  final bool dimmed;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final free = room.freeCountIn(group);
    final total = group.periods.length;
    final Color bg;
    final Widget? mark;
    if (free == total) {
      bg = AppColors.success.withValues(alpha: 0.18);
      mark = null;
    } else if (free > 0) {
      bg = AppColors.warning.withValues(alpha: 0.18);
      mark = _FitText(
        '$free/$total',
        style: const TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w700,
          color: AppColors.warning,
        ),
      );
    } else {
      bg = const Color(0xFFEDEFF2);
      mark = null;
    }
    return Opacity(
      // 用户特意把已过的时段勾回来，这一列就得和其他选中列一样清楚。
      opacity: !dimmed ? 1 : (over ? 0.3 : 0.4),
      child: Container(
        width: width,
        height: 26,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: mark == null ? null : Center(child: mark),
      ),
    );
  }
}

/// 筛选后一间教室都没有（连全占用的都没有）时整块占位。
class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.day});

  final ClassroomDay day;

  @override
  Widget build(BuildContext context) {
    return _ListShell(isLast: true, child: _EmptyBody(day: day));
  }
}

/// 「没有空教室」的提示正文；单独占位和列表顶部的提示条共用。
class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.day});

  final ClassroomDay day;

  @override
  Widget build(BuildContext context) {
    final noRooms = day.rooms.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_outlined,
            size: 32,
            color: AppColors.hint.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 10),
          Text(
            noRooms ? '教务没有返回这栋楼的教室' : '所选条件下没有空教室',
            style: const TextStyle(fontSize: 14, color: AppColors.labelText),
          ),
          if (!noRooms) ...[
            const SizedBox(height: 4),
            const Text(
              '试试换个时段、楼层或放宽筛选',
              style: TextStyle(fontSize: 12, color: AppColors.hint),
            ),
          ],
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Text(
        '绿色：该时段全部空闲；橙色：部分节次空闲，数字为空闲节数 / 总节数；'
        '灰色：有课或已被占用。数据来自教务排课与借用记录，临时使用可能未登记，以现场为准。',
        style: TextStyle(fontSize: 11, color: AppColors.hint, height: 1.5),
      ),
    );
  }
}

// ==================== 还没有结果时的整块状态 ====================

class _StateView extends StatelessWidget {
  const _StateView({required this.controller, required this.onPickBuilding});

  final FreeClassroomController controller;
  final VoidCallback onPickBuilding;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final Widget child;
    if (c.building == null) {
      child = _Prompt(
        icon: Icons.apartment_outlined,
        text: '先选一栋教学楼，再看哪些教室空着',
        action: (c.buildings?.isNotEmpty ?? false) ? '选择教学楼' : null,
        onAction: onPickBuilding,
      );
    } else if (c.loading) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 14),
          Text(
            '正在查询${c.building!.name}…',
            style: const TextStyle(fontSize: 13, color: AppColors.labelText),
          ),
        ],
      );
    } else {
      child = _Prompt(
        icon: Icons.error_outline,
        text: c.error ?? '暂无数据',
        isError: c.error != null,
        action: '重试',
        onAction: () => c.query(force: true),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
        child: child,
      ),
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 40,
          color: isError
              ? errorColor.withValues(alpha: 0.7)
              : AppColors.hint.withValues(alpha: 0.6),
        ),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: isError ? errorColor : AppColors.labelText,
          ),
        ),
        if (action != null && onAction != null) ...[
          const SizedBox(height: 14),
          FilledButton.tonal(
            onPressed: onAction,
            style: FilledButton.styleFrom(
              backgroundColor: kClassroomColor.withValues(alpha: 0.1),
              foregroundColor: kClassroomColor,
            ),
            child: Text(action!),
          ),
        ],
      ],
    );
  }
}

/// 未绑定门户：整页只放一张引导卡。
class _PortalGuide extends StatelessWidget {
  const _PortalGuide({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        ClassroomCard(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.hint.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.link_off,
                      color: AppColors.hint,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '未绑定统一门户',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.titleText,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '空教室数据来自教务系统，请先到「我的 → 绑定统一门户」完成绑定。',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.hint,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RefreshAction extends StatelessWidget {
  const _RefreshAction({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        width: 48,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.refresh),
      color: AppColors.accent,
      tooltip: '刷新',
      onPressed: onPressed,
    );
  }
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 单行文字，放不下就整体缩小而不是换行 —— 日期格、时段格这些窄格子里，
/// 系统字体偏宽或用户把字号调大时不至于溢出。
class _FitText extends StatelessWidget {
  const _FitText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, softWrap: false, style: style),
    );
  }
}
