import 'package:flutter/material.dart';

import '../../core/schedule/weekly_classes.dart';
import 'campus_map_data.dart';
import 'campus_map_schedule.dart';
import 'campus_map_source.dart';
import 'campus_map_widgets.dart';

/// 按分类与关键词筛选地点（面板列表和地图标注共用同一套规则）。
List<CampusPlace> filterPlaces(
  List<CampusPlace> places,
  PlaceCategory? category,
  String query,
) {
  final q = query.trim().toLowerCase();
  return places
      .where(
        (p) =>
            (category == null || p.category == category) &&
            (q.isEmpty || '${p.name} ${p.subtitle}'.toLowerCase().contains(q)),
      )
      .toList();
}

/// 本周上课的楼宇及节数（课表联动，按节数从多到少）。
List<({CampusPlace place, int count})> weekBuildings(
  List<WeeklyClass> classes,
  List<CampusPlace> places,
) {
  final buildings = [
    for (final place in places)
      if (place.poiId == null &&
          place.featureId == null &&
          place.name.trim().length >= 2 &&
          !place.name.startsWith('未命名'))
        place,
  ];
  final counts = <String, int>{};
  final byId = <String, CampusPlace>{};
  for (final item in classes) {
    // 同一地点可能同时以多个楼名开头（如「理科楼」「理科楼东」），取最长的那个。
    CampusPlace? best;
    for (final place in buildings) {
      if (!locationInBuilding(item.location, place.name)) continue;
      if (best == null || place.name.length > best.name.length) best = place;
    }
    if (best == null) continue;
    counts[best.id] = (counts[best.id] ?? 0) + 1;
    byId[best.id] = best;
  }
  final result = [
    for (final entry in counts.entries)
      (place: byId[entry.key]!, count: entry.value),
  ]..sort((a, b) => b.count.compareTo(a.count));
  return result;
}

/// 「离你最近」：有位置时按直线距离取最近的 [limit] 栋建筑（不含 POI 和
/// 道路、绿地等通用地物），只要有名字、有坐标的。
List<CampusPlace> nearestPlaces(
  List<CampusPlace> places,
  GeoPoint from, {
  int limit = 10,
}) {
  final candidates = [
    for (final place in places)
      if (place.poiId == null &&
          place.featureId == null &&
          place.center != null &&
          place.center!.isValid &&
          place.name.trim().isNotEmpty &&
          !place.name.startsWith('未命名'))
        place,
  ];
  candidates.sort(
    (a, b) => metersBetween(
      from,
      a.center!,
    ).compareTo(metersBetween(from, b.center!)),
  );
  return candidates.take(limit).toList();
}

/// 校园总览面板。搜索框在地图顶部（只有一个），这里放推荐、本周上课的楼、
/// 分类、附近 / 随机地点卡片和结果列表。
class CampusExplorePanel extends StatelessWidget {
  const CampusExplorePanel({
    super.key,
    required this.query,
    required this.category,
    required this.places,
    required this.loading,
    required this.error,
    required this.onCategory,
    required this.onRefresh,
    required this.onSelect,
    this.allPlaces = const [],
    this.userPoint,
    this.weekClasses = const [],
    this.onShuffle,
  });

  /// 顶部搜索栏当前的关键词。
  final String query;
  final PlaceCategory? category;
  final List<CampusPlace> places;

  /// 全部地点：附近排序、本周上课的楼都从这里算。
  final List<CampusPlace> allPlaces;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final ValueChanged<PlaceCategory?> onCategory;
  final ValueChanged<CampusPlace> onSelect;

  /// 当前位置；有它时卡片按距离排序并显示步行时间。
  final GeoPoint? userPoint;

  /// 本周课程（课表联动）。
  final List<WeeklyClass> weekClasses;

  /// 「随机去个地方」（骰子按钮）。
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: children(context),
  );

  String? _walking(CampusPlace place) {
    final from = userPoint;
    final to = place.center;
    if (from == null || to == null || !to.isValid) return null;
    return walkingLabel(metersBetween(from, to));
  }

  /// 面板的各个列表项。放进 ListView 时逐项懒构建，地点再多也只布局可见部分。
  List<Widget> children(BuildContext context) {
    final colors = MapPalette.of(context);
    final q = query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    // 未搜索、未选分类时是「发现」模式：卡片横排；否则是结果列表。
    final discover = !searching && category == null;
    final located = userPoint != null && userPoint!.isValid;
    final cards = discover
        ? (located ? nearestPlaces(allPlaces, userPoint!) : places)
        : const <CampusPlace>[];
    final results = discover
        ? const <CampusPlace>[]
        : filterPlaces(places, category, q);
    final buildings = searching
        ? const <({CampusPlace place, int count})>[]
        : weekBuildings(weekClasses, allPlaces);
    return [
      if (!searching) ...[
        if (buildings.isNotEmpty) ...[
          _WeekBuildings(buildings: buildings, onSelect: onSelect),
          const SizedBox(height: 14),
        ],
        // 四个分类入口等宽铺满整行、内容居中（各占 1/4）。
        Row(
          children: [
            for (final item in PlaceCategory.values)
              Expanded(
                child: _CategoryBadge(
                  category: item,
                  selected: category == item,
                  onTap: () => onCategory(category == item ? null : item),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
      ],
      MapSectionTitle(
        searching
            ? '搜索结果'
            : category != null
            ? categoryName(category!)
            : located
            ? '离你最近'
            : '随便逛逛',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onShuffle != null && !searching)
              MapIconButton(
                icon: Icons.casino_rounded,
                label: '随机去个地方',
                onPressed: loading || allPlaces.isEmpty ? null : onShuffle,
                color: colors.blue,
              ),
            MapIconButton(
              icon: Icons.refresh_rounded,
              label: discover && !located ? '换一批' : '刷新地点',
              onPressed: loading ? null : onRefresh,
              color: colors.secondary,
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      if (loading)
        const Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        )
      else if (error != null)
        MapEmptyState(
          icon: Icons.cloud_off_outlined,
          title: error!,
          description: '检查网络连接后，再试一次。',
          action: TextButton(onPressed: onRefresh, child: const Text('重新加载')),
        )
      else if (discover && cards.isNotEmpty)
        _ExploreCarousel(places: cards, walking: _walking, onSelect: onSelect)
      else if (!discover && results.isNotEmpty)
        for (var i = 0; i < results.length; i++)
          _PlaceRow(
            place: results[i],
            first: i == 0,
            last: i == results.length - 1,
            trailingLabel: _walking(results[i]),
            onTap: () => onSelect(results[i]),
          )
      else
        MapEmptyState(
          icon: searching ? Icons.search_off_rounded : Icons.place_outlined,
          title: searching ? '没有找到相关地点' : '暂无地点信息',
          description: searching ? '试试其他楼宇名称或清除分类。' : '地点信息接入后，将在这里显示。',
        ),
      const SizedBox(height: 24),
      Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: colors.secondary),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              located ? '步行时间按直线距离估算' : '选择楼宇后可查看室内地图与可用楼层',
              style: TextStyle(
                fontSize: 12,
                color: colors.secondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    ];
  }
}

/// 「你本周常去」：本周上课的楼，按节数排；点一下直接选中这栋楼。
class _WeekBuildings extends StatelessWidget {
  const _WeekBuildings({required this.buildings, required this.onSelect});
  final List<({CampusPlace place, int count})> buildings;
  final ValueChanged<CampusPlace> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final total = buildings.fold<int>(0, (sum, b) => sum + b.count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.event_note_rounded, size: 16, color: colors.blue),
            const SizedBox(width: 6),
            Text(
              '你本周常去 · 共 $total 节课',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.secondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in buildings.take(6))
              Material(
                color: colors.blue.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onSelect(item.place),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      '${item.place.name} · ${item.count} 节',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colors.blue,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 地点卡片横排：分类色顶栏 + 名称 + 步行时间 / 分类，左右滑动浏览。
class _ExploreCarousel extends StatelessWidget {
  const _ExploreCarousel({
    required this.places,
    required this.walking,
    required this.onSelect,
  });
  final List<CampusPlace> places;
  final String? Function(CampusPlace) walking;
  final ValueChanged<CampusPlace> onSelect;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // 卡片高度随字号放大，大字体下也不溢出。
    final height =
        56 + scaler.scale(15) * 1.35 * 2 + scaler.scale(12) * 1.4 + 34;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: places.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => _ExploreCard(
          place: places[index],
          walking: walking(places[index]),
          onTap: () => onSelect(places[index]),
        ),
      ),
    );
  }
}

class _ExploreCard extends StatelessWidget {
  const _ExploreCard({
    required this.place,
    required this.walking,
    required this.onTap,
  });
  final CampusPlace place;
  final String? walking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final color = categoryColor(place.category);
    final indoor = place.hasIndoor && place.floors.isNotEmpty;
    return SizedBox(
      width: 148,
      child: Material(
        color: colors.panel,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 56,
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 0),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, Color.lerp(color, Colors.black, .25)!],
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      categoryIcon(place.category),
                      color: Colors.white,
                      size: 26,
                    ),
                    const Spacer(),
                    if (indoor)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .25),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          '室内图',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        place.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(
                            walking != null
                                ? Icons.directions_walk_rounded
                                : Icons.place_outlined,
                            size: 14,
                            color: walking != null ? colors.blue : colors.muted,
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              walking ??
                                  (place.subtitle.isNotEmpty
                                      ? place.subtitle
                                      : categoryName(place.category)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: walking != null
                                    ? colors.blue
                                    : colors.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 地点列表的一行。每行自带所在分组的圆角与分隔线，
/// 这样整组可以拆成独立列表项交给 ListView 懒构建。
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.place,
    required this.first,
    required this.last,
    required this.onTap,
    this.trailingLabel,
  });
  final CampusPlace place;
  final bool first, last;
  final VoidCallback onTap;

  /// 行尾的步行时间（有定位时）；为空只显示箭头。
  final String? trailingLabel;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final color = categoryColor(place.category);
    final radius = BorderRadius.vertical(
      top: Radius.circular(first ? 18 : 0),
      bottom: Radius.circular(last ? 18 : 0),
    );
    return Material(
      color: colors.panel,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!first)
            const Padding(
              padding: EdgeInsets.only(left: 66),
              child: Divider(height: 1),
            ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(categoryIcon(place.category), size: 21, color: color),
            ),
            title: Text(
              place.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: place.subtitle.isEmpty
                ? null
                : Text(
                    place.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.secondary),
                  ),
            trailing: trailingLabel == null
                ? Icon(
                    Icons.chevron_right_rounded,
                    color: colors.secondary,
                    size: 20,
                  )
                : Text(
                    trailingLabel!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.blue,
                    ),
                  ),
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

class CampusPlacePanel extends StatelessWidget {
  const CampusPlacePanel({
    super.key,
    required this.place,
    required this.floor,
    required this.room,
    required this.floorData,
    required this.floorLoading,
    required this.floorError,
    required this.route,
    required this.routing,
    required this.onClose,
    required this.onRoute,
    required this.onIndoor,
    required this.onStreet,
    required this.onRetryFloor,
    required this.onRoom,
    required this.onCloseRoute,
    this.onFloor,
    this.mediaEntry,
    this.onDetail,
    this.weekClasses = const [],
    this.hasWeekClasses = false,
    this.onClass,
    this.locatingClass,
  });
  final CampusPlace place;
  final CampusFloor? floor;
  final CampusRoom? room;
  final CampusFloorSnapshot floorData;
  final bool floorLoading, routing;
  final String? floorError;
  final CampusRouteResult? route;
  final VoidCallback onClose, onStreet, onRetryFloor, onCloseRoute;
  final VoidCallback? onRoute, onIndoor;
  final ValueChanged<CampusRoom> onRoom;

  /// 室内模式下切换楼层（面板里的楼层页签）。
  final ValueChanged<CampusFloor>? onFloor;

  /// 媒体入口（实拍图片）。没有内容时它自己不占位，间距也由它负责。
  final Widget? mediaEntry;

  /// 打开该地物的完整详情页；为空时不显示入口（例如房间预览）。
  final VoidCallback? onDetail;

  /// 本周在这栋楼里的课（课表联动）；为空时不显示卡片。
  final List<WeeklyClass> weekClasses;

  /// 课表本周是否有任何课（决定这栋楼没课时是否显示「这里没有你的课」）。
  final bool hasWeekClasses;

  /// 点一节课：进室内并定位到教室。
  final ValueChanged<WeeklyClass>? onClass;

  /// 正在查找教室的那节课。
  final WeeklyClass? locatingClass;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final indoor = floor != null;
    final color = categoryColor(place.category);
    // 信息标签：只放真实字段，不重复楼名。
    final chips = <Widget>[
      if (place.category != null || place.kind != null)
        _InfoChip(
          icon: categoryIcon(place.category),
          label: place.category != null
              ? categoryName(place.category)
              : featureKindLabel(place.kind),
          color: color,
        ),
      if (room != null && floor != null)
        _InfoChip(
          icon: Icons.apartment_rounded,
          label: '${place.name} · ${floor!.label}',
        ),
      if (room == null && place.floors.isNotEmpty)
        _InfoChip(
          icon: Icons.stacked_bar_chart_rounded,
          label: '${place.floors.length} 层',
        ),
      if (room == null && place.hasIndoor && place.floors.isNotEmpty)
        _InfoChip(
          icon: Icons.layers_rounded,
          label: '有室内图',
          color: colors.green,
        ),
      if (room == null &&
          place.subtitle.isNotEmpty &&
          place.subtitle != place.name &&
          place.subtitle != categoryName(place.category))
        _InfoChip(icon: Icons.place_outlined, label: place.subtitle),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 分类色竖条：一眼区分教学 / 餐饮 / 运动 / 服务。
            Container(
              width: 5,
              height: 30,
              margin: const EdgeInsets.only(top: 4, right: 12),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Expanded(
              child: Text(
                room?.name ?? place.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ),
            MapIconButton(
              icon: Icons.close_rounded,
              label: room != null ? '关闭房间详情' : '关闭楼宇详情',
              onPressed: onClose,
            ),
          ],
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
        const SizedBox(height: 16),
        // 主操作：路线是主按钮，其余三个「图标 + 文字」小方块，全部带文字。
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: MapAction(
                  icon: Icons.turn_right_rounded,
                  label: routing ? '规划中' : '路线',
                  primary: true,
                  onPressed: routing ? null : onRoute,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionTile(
                  icon: indoor ? Icons.logout_rounded : Icons.layers_outlined,
                  label: indoor ? '退出室内' : '室内',
                  onPressed: onIndoor,
                ),
              ),
              if (onDetail != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.article_outlined,
                    label: '详情',
                    onPressed: onDetail,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: _ActionTile(
                  icon: Icons.streetview_rounded,
                  label: '街景',
                  tooltip: '查看街景',
                  onPressed: onStreet,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (!indoor && route == null && room == null && weekClasses.isNotEmpty)
          _WeekClassesCard(
            place: place,
            classes: weekClasses,
            onClass: onClass,
            locatingClass: locatingClass,
          )
        else if (!indoor && route == null && room == null && hasWeekClasses)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Icon(
                  Icons.event_available_rounded,
                  size: 17,
                  color: colors.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '本周课表里没有在这栋楼的课',
                    style: TextStyle(fontSize: 13, color: colors.secondary),
                  ),
                ),
              ],
            ),
          ),
        ?mediaEntry,
        if (route != null) ...[
          MapSectionTitle(
            '路线指引',
            trailing: MapIconButton(
              icon: Icons.close_rounded,
              label: '关闭路线',
              onPressed: onCloseRoute,
            ),
          ),
          if (route!.summary != null)
            Text(route!.summary!, style: TextStyle(color: colors.secondary)),
          for (final instruction in route!.instructions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.turn_right_rounded, color: colors.blue),
              title: Text(instruction),
            ),
        ] else if (floor != null) ...[
          _FloorTabs(floors: place.floors, current: floor!, onFloor: onFloor),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${floor!.label}  楼层导览',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.view_in_ar_outlined,
                size: 18,
                color: colors.secondary,
              ),
            ],
          ),
          if (floor!.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                floor!.description,
                style: TextStyle(color: colors.secondary, fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          if (floorLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (floorError != null)
            MapEmptyState(
              icon: Icons.cloud_off_outlined,
              title: floorError!,
              description: '可以重试或切换其他楼层。',
              action: TextButton(
                onPressed: onRetryFloor,
                child: const Text('重新加载'),
              ),
            )
          else if (floorData.rooms.isEmpty)
            const MapEmptyState(
              icon: Icons.layers_outlined,
              title: '暂无本层室内信息',
              description: '楼层图与房间数据接入后显示。',
            )
          else
            _FloorRooms(rooms: floorData.rooms, selected: room, onRoom: onRoom),
        ] else ...[
          const MapSectionTitle('楼宇信息'),
          const SizedBox(height: 14),
          if (place.hasIndoor && place.floors.isNotEmpty)
            MapSurface(
              radius: 18,
              child: ListTile(
                leading: Icon(Icons.layers_outlined, color: colors.blue),
                title: const Text(
                  '室内地图',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${place.floors.length} 个可用楼层',
                  style: TextStyle(fontSize: 12, color: colors.secondary),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: onIndoor,
              ),
            )
          else
            const MapEmptyState(
              icon: Icons.layers_outlined,
              title: '室内地图尚未开放',
              description: '该楼宇暂未提供室内数据。',
            ),
        ],
      ],
    );
  }
}

/// 楼宇卡片里的「本周在这里的课」：和课表联动，点一节课直接进室内定位到教室。
class _WeekClassesCard extends StatefulWidget {
  const _WeekClassesCard({
    required this.place,
    required this.classes,
    required this.onClass,
    this.locatingClass,
  });
  final CampusPlace place;
  final List<WeeklyClass> classes;
  final ValueChanged<WeeklyClass>? onClass;

  /// 正在查找教室的那节课（显示进度）。
  final WeeklyClass? locatingClass;

  @override
  State<_WeekClassesCard> createState() => _WeekClassesCardState();
}

class _WeekClassesCardState extends State<_WeekClassesCard> {
  static const _collapsed = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final classes = widget.classes;
    final today = DateTime.now().weekday;
    final visible = _expanded || classes.length <= _collapsed + 1
        ? classes
        : classes.take(_collapsed).toList();
    final todayCount = classes.where((c) => c.weekday == today).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: colors.panel,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colors.blue.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      Icons.event_note_rounded,
                      size: 20,
                      color: colors.blue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本周在这里有 ${classes.length} 节课',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          todayCount > 0
                              ? '今天 $todayCount 节 · 点课程直达教室'
                              : '点课程直达教室',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            for (final item in visible) _classRow(context, item, today),
            if (classes.length > visible.length || _expanded)
              if (classes.length > _collapsed + 1)
                TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? '收起' : '展开全部 ${classes.length} 节'),
                ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _classRow(BuildContext context, WeeklyClass item, int today) {
    final colors = MapPalette.of(context);
    final code = roomCodeIn(item.location, widget.place.name);
    final isToday = item.weekday == today;
    final locating = identical(item, widget.locatingClass);
    final canJump = code != null && widget.onClass != null;
    return InkWell(
      onTap: canJump && !locating ? () => widget.onClass!(item) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
        child: Row(
          children: [
            Container(
              width: 66,
              padding: const EdgeInsets.symmetric(vertical: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isToday ? colors.blue : colors.field,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                classTimeLabel(item),
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: isToday ? Colors.white : colors.secondary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.courseName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (locating)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              Text(
                code ?? item.location,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: canJump ? colors.blue : colors.secondary,
                ),
              ),
              if (canJump)
                Icon(Icons.chevron_right_rounded, size: 18, color: colors.blue),
            ],
          ],
        ),
      ),
    );
  }
}

/// 标题下的信息标签（分类、层数、是否有室内图…）。
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final fg = color ?? colors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color == null ? colors.field : fg.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color ?? colors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 次要操作：图标在上、文字在下的小方块，和主按钮等高。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final enabled = onPressed != null;
    final fg = enabled ? colors.blue : colors.muted;
    final tile = Material(
      color: colors.blue.withValues(alpha: enabled ? .10 : .04),
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 21, color: fg),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip!, child: tile);
  }
}

/// 面板里的楼层页签：一排 1F 2F 3F…，点一下切层，不用再去找右侧的楼层条。
class _FloorTabs extends StatelessWidget {
  const _FloorTabs({
    required this.floors,
    required this.current,
    required this.onFloor,
  });
  final List<CampusFloor> floors;
  final CampusFloor current;
  final ValueChanged<CampusFloor>? onFloor;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final sorted = [...floors]..sort((a, b) => a.number.compareTo(b.number));
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sorted.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final floor = sorted[index];
          final selected = floor.id == current.id;
          return Semantics(
            button: true,
            selected: selected,
            label: '${floor.label}${selected ? '，当前楼层' : ''}',
            excludeSemantics: true,
            child: Material(
              color: selected ? colors.blue : colors.panel,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: selected || onFloor == null
                    ? null
                    : () => onFloor!(floor),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 52),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    floor.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? Colors.white : colors.ink,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 房间分组：按后端 category / kind 归类，不按名称猜。
enum _RoomGroup {
  room('房间', Icons.class_outlined, Color(0xFF4C8BF5)),
  toilet('卫生间', Icons.wc_rounded, Color(0xFF13A8A8)),
  stair('楼梯电梯', Icons.stairs_rounded, Color(0xFFF2994A)),
  other('其他', Icons.widgets_outlined, Color(0xFF8A94A6));

  const _RoomGroup(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;

  static _RoomGroup of(CampusRoom room) {
    switch (room.category?.trim().toLowerCase()) {
      case 'toilet' || 'restroom' || 'wc' || 'washroom':
        return _RoomGroup.toilet;
      case 'stair' || 'stairs' || 'elevator' || 'lift' || 'escalator':
        return _RoomGroup.stair;
      case 'classroom' || 'lab' || 'lecture' || 'office' || 'meeting':
        return _RoomGroup.room;
    }
    // 没有可识别 category 时按要素类型：房间要素归「房间」，设施归「其他」。
    return room.isFacility ? _RoomGroup.other : _RoomGroup.room;
  }

  IconData iconFor(CampusRoom room) =>
      this == _RoomGroup.stair &&
          const {'elevator', 'lift'}.contains(room.category?.toLowerCase())
      ? Icons.elevator_rounded
      : icon;
}

/// 本层房间：顶部按类型筛选，房间用门牌方块网格，其余设施用带图标的列表。
class _FloorRooms extends StatefulWidget {
  const _FloorRooms({
    required this.rooms,
    required this.selected,
    required this.onRoom,
  });
  final List<CampusRoom> rooms;
  final CampusRoom? selected;
  final ValueChanged<CampusRoom> onRoom;

  @override
  State<_FloorRooms> createState() => _FloorRoomsState();
}

class _FloorRoomsState extends State<_FloorRooms> {
  // null = 全部。切层时保留筛选（同一栋楼找卫生间往往要连着看几层）。
  _RoomGroup? _filter;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final groups = <_RoomGroup, List<CampusRoom>>{};
    for (final room in widget.rooms) {
      groups.putIfAbsent(_RoomGroup.of(room), () => []).add(room);
    }
    final present = [
      for (final group in _RoomGroup.values)
        if (groups[group] != null) group,
    ];
    final filter = present.contains(_filter) ? _filter : null;
    final shown = filter == null ? present : [filter];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (present.length > 1) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _GroupChip(
                label: '全部 ${widget.rooms.length}',
                selected: filter == null,
                color: colors.blue,
                onTap: () => setState(() => _filter = null),
              ),
              for (final group in present)
                _GroupChip(
                  label: '${group.label} ${groups[group]!.length}',
                  icon: group.icon,
                  selected: filter == group,
                  color: group.color,
                  onTap: () =>
                      setState(() => _filter = filter == group ? null : group),
                ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        for (final group in shown) ...[
          if (filter == null && present.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 2),
              child: Row(
                children: [
                  Icon(group.icon, size: 16, color: group.color),
                  const SizedBox(width: 6),
                  Text(
                    group.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.secondary,
                    ),
                  ),
                ],
              ),
            ),
          if (group == _RoomGroup.room)
            _RoomGrid(
              rooms: groups[group]!,
              selected: widget.selected,
              onRoom: widget.onRoom,
            )
          else
            _FacilityList(
              group: group,
              rooms: groups[group]!,
              selected: widget.selected,
              onRoom: widget.onRoom,
            ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final Color color;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? color : colors.panel,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: selected ? Colors.white : color),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : colors.ink,
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

/// 房间门牌网格：一行三块，门牌号大字；名称和门牌不同时在下面补一行名称。
class _RoomGrid extends StatelessWidget {
  const _RoomGrid({
    required this.rooms,
    required this.selected,
    required this.onRoom,
  });
  final List<CampusRoom> rooms;
  final CampusRoom? selected;
  final ValueChanged<CampusRoom> onRoom;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 8.0;
        final columns = box.maxWidth >= 420 ? 4 : 3;
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final room in rooms)
              SizedBox(
                width: width,
                child: Builder(
                  builder: (context) {
                    final active = room.id == selected?.id;
                    final code = room.roomCode ?? room.name;
                    final showName =
                        room.roomCode != null &&
                        room.name.isNotEmpty &&
                        room.name != room.roomCode;
                    return Semantics(
                      button: true,
                      selected: active,
                      child: Material(
                        color: active ? colors.blue : colors.panel,
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => onRoom(room),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 58),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 9,
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  code,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: active ? Colors.white : colors.ink,
                                  ),
                                ),
                                if (showName) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    room.name,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: active
                                          ? Colors.white.withValues(alpha: .85)
                                          : colors.secondary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 卫生间、楼梯等设施：带类型图标的紧凑列表。
class _FacilityList extends StatelessWidget {
  const _FacilityList({
    required this.group,
    required this.rooms,
    required this.selected,
    required this.onRoom,
  });
  final _RoomGroup group;
  final List<CampusRoom> rooms;
  final CampusRoom? selected;
  final ValueChanged<CampusRoom> onRoom;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return Material(
      color: colors.panel,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rooms.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 58),
                child: Divider(height: 1),
              ),
            ListTile(
              dense: true,
              selected: rooms[i].id == selected?.id,
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: group.color.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  group.iconFor(rooms[i]),
                  size: 19,
                  color: group.color,
                ),
              ),
              title: Text(
                rooms[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              trailing: Icon(
                rooms[i].id == selected?.id
                    ? Icons.room_rounded
                    : Icons.chevron_right_rounded,
                size: 18,
                color: rooms[i].id == selected?.id
                    ? colors.blue
                    : colors.secondary,
              ),
              onTap: () => onRoom(rooms[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class MapEmptyState extends StatelessWidget {
  const MapEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 23),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: colors.muted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: colors.secondary,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class MapLoadingView extends StatelessWidget {
  const MapLoadingView({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return ColoredBox(
      color: colors.field,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 14),
            Text(
              '正在加载校园地图…',
              style: TextStyle(fontSize: 13, color: colors.secondary),
            ),
          ],
        ),
      ),
    );
  }
}

class MapUnconfiguredView extends StatelessWidget {
  const MapUnconfiguredView({
    super.key,
    required this.wide,
    this.title = '地图即将就绪',
    this.message,
    this.action,
  });
  final bool wide;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return ColoredBox(
      color: colors.field,
      child: Align(
        alignment: wide ? const Alignment(.35, -.12) : const Alignment(0, -.3),
        child: Padding(
          padding: EdgeInsets.only(
            left: wide ? 352 : 28,
            right: wide ? 100 : 76,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: colors.panel.withValues(alpha: .8),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Icon(Icons.map_outlined, size: 38, color: colors.muted),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  color: colors.secondary,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message ?? '底图服务尚未配置',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.secondary),
              ),
              if (action != null) ...[const SizedBox(height: 10), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class CampusRoutePlanner extends StatefulWidget {
  const CampusRoutePlanner({
    super.key,
    required this.places,
    required this.destination,
    this.floor,
    this.room,
    this.userPoint,
  });
  final List<CampusPlace> places;
  final CampusPlace destination;
  final CampusFloor? floor;
  final CampusRoom? room;

  /// 用户当前定位；有效时起点默认取「我的位置」。
  final GeoPoint? userPoint;
  @override
  State<CampusRoutePlanner> createState() => _CampusRoutePlannerState();
}

class _CampusRoutePlannerState extends State<CampusRoutePlanner> {
  MapPalette get colors => MapPalette.of(context);

  /// 起点哨兵值：表示「我的位置」。
  static const _kMyLocation = '__my_location__';
  final _originSearch = TextEditingController();
  String? _originId;
  bool _accessible = false;
  bool _editingOrigin = false;

  bool get _hasLocation => widget.userPoint?.isValid == true;

  @override
  void initState() {
    super.initState();
    // 有定位时默认从我的位置出发，免去手动选起点。
    if (_hasLocation) _originId = _kMyLocation;
    _originSearch.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _originSearch.dispose();
    super.dispose();
  }

  String get _originLabel {
    if (_originId == _kMyLocation) return '我的位置';
    for (final place in widget.places) {
      if (place.id == _originId) return place.name;
    }
    return '';
  }

  void _chooseOrigin(String id) {
    setState(() {
      _originId = id;
      _editingOrigin = false;
      _originSearch.clear();
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 起点搜索结果：本地按名称/副标题过滤，「我的位置」常驻置顶。
  List<Widget> _originResults() {
    final query = _originSearch.text.trim().toLowerCase();
    final matches = widget.places.where(
      (p) =>
          query.isEmpty ||
          '${p.name} ${p.subtitle}'.toLowerCase().contains(query),
    );
    return [
      if (_hasLocation)
        ListTile(
          dense: true,
          leading: Icon(Icons.my_location_rounded, color: colors.blue),
          title: const Text('我的位置'),
          onTap: () => _chooseOrigin(_kMyLocation),
        ),
      for (final place in matches.take(8))
        ListTile(
          dense: true,
          leading: Icon(
            categoryIcon(place.category),
            color: categoryColor(place.category),
          ),
          title: Text(place.name, overflow: TextOverflow.ellipsis),
          onTap: () => _chooseOrigin(place.id),
        ),
      if (matches.isEmpty && query.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '没有匹配的地点',
            style: TextStyle(fontSize: 13, color: colors.secondary),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.floor != null
        ? '${widget.destination.name} · ${widget.floor!.label}'
        : widget.destination.poiId == null &&
              widget.destination.featureId != null
        ? featureKindLabel(widget.destination.kind)
        : null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '导航',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                ),
                MapIconButton(
                  icon: Icons.close_rounded,
                  label: '关闭导航',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 起终点卡片：起点是搜索栏（百度式），终点固定。
            // 卡片用 Material 而不是 Container：里面的 ListTile 需要 Material 祖先，
            // 否则 debug 下断言「背景与水波被 DecoratedBox 盖住」，这块面板根本渲染不出来。
            Material(
              color: colors.panel,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: colors.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_editingOrigin)
                    ListTile(
                      leading: Icon(
                        Icons.trip_origin_rounded,
                        color: colors.blue,
                      ),
                      title: Text(
                        _originLabel.isEmpty ? '搜索起点' : _originLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: _originLabel.isEmpty
                              ? colors.secondary
                              : colors.ink,
                        ),
                      ),
                      subtitle: const Text('起点'),
                      trailing: Icon(
                        Icons.search_rounded,
                        color: colors.secondary,
                      ),
                      onTap: () => setState(() => _editingOrigin = true),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                      child: Row(
                        children: [
                          Icon(Icons.trip_origin_rounded, color: colors.blue),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextField(
                              controller: _originSearch,
                              autofocus: true,
                              decoration: const InputDecoration(
                                hintText: '搜索起点',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '取消',
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => setState(() {
                              _editingOrigin = false;
                              _originSearch.clear();
                            }),
                          ),
                        ],
                      ),
                    ),
                    ..._originResults(),
                  ],
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(
                      Icons.place_rounded,
                      color: Color(0xFFE15A4E),
                    ),
                    title: Text(
                      widget.room?.name ?? widget.destination.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: subtitle == null
                        ? const Text('终点')
                        : Text('终点 · $subtitle'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.accessible_rounded),
              title: const Text('无障碍优先'),
              value: _accessible,
              onChanged: (value) => setState(() => _accessible = value),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: MapAction(
                icon: Icons.navigation_rounded,
                label: '开始导航',
                primary: true,
                onPressed: _originId == null
                    ? null
                    : () => Navigator.pop(
                        context,
                        CampusRouteRequest(
                          originPlaceId: _originId == _kMyLocation
                              ? null
                              : _originId,
                          originPoint: _originId == _kMyLocation
                              ? widget.userPoint
                              : null,
                          destinationPlaceId: widget.destination.id,
                          destinationFloorId: widget.floor?.id,
                          destinationRoomId: widget.room?.id,
                          accessible: _accessible,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导航结果页（百度风格）：目的地标题 + 摘要卡 + 开始导航 + 路线详情。
class CampusRoutePreview extends StatelessWidget {
  const CampusRoutePreview({
    super.key,
    required this.route,
    required this.destinationLabel,
    required this.onStart,
    required this.onClose,
    this.destinationSubtitle,
  });
  final CampusRouteResult route;
  final String destinationLabel;
  final String? destinationSubtitle;
  final VoidCallback onStart, onClose;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    destinationLabel,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (destinationSubtitle != null)
                    Text(
                      destinationSubtitle!,
                      style: TextStyle(fontSize: 13, color: colors.secondary),
                    ),
                ],
              ),
            ),
            MapIconButton(
              icon: Icons.close_rounded,
              label: '结束路线',
              onPressed: onClose,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 摘要卡：大号距离 + 段数（仿百度「2小时19分 / 23.9公里」摘要区）。
        MapSurface(
          radius: 18,
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(Icons.directions_walk_rounded, color: colors.blue, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.summary ?? '路线已规划',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '步行 · ${route.instructions.length} 段指引',
                      style: TextStyle(fontSize: 12, color: colors.secondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: MapAction(
            icon: Icons.navigation_rounded,
            label: '开始导航',
            primary: true,
            onPressed: onStart,
          ),
        ),
        const SizedBox(height: 16),
        const MapSectionTitle('路线详情'),
        MapSurface(
          radius: 18,
          child: Column(
            children: [
              for (final instruction in route.instructions)
                ListTile(
                  leading: Icon(Icons.turn_right_rounded, color: colors.blue),
                  title: Text(
                    instruction,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String categoryName(PlaceCategory? category) => switch (category) {
  null => '地点',
  PlaceCategory.study => '教学',
  PlaceCategory.food => '餐饮',
  PlaceCategory.sports => '运动',
  PlaceCategory.services => '服务',
};
IconData categoryIcon(PlaceCategory? category) => switch (category) {
  null => Icons.location_city_outlined,
  PlaceCategory.study => Icons.school_rounded,
  PlaceCategory.food => Icons.restaurant_rounded,
  PlaceCategory.sports => Icons.sports_basketball,
  PlaceCategory.services => Icons.storefront_rounded,
};
Color categoryColor(PlaceCategory? category) => switch (category) {
  null => const Color(0xFF7A808C),
  PlaceCategory.study => const Color(0xFF4C8BF5),
  PlaceCategory.food => const Color(0xFFF2994A),
  PlaceCategory.sports => const Color(0xFF35B26F),
  PlaceCategory.services => const Color(0xFF9B6BF3),
};

/// 搜索栏下方的分类入口：实心彩色圆角徽章 + 名称，选中加描边投影。
class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({
    required this.category,
    required this.selected,
    required this.onTap,
  });
  final PlaceCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    final color = categoryColor(category);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(
                      color: colors.ink.withValues(alpha: .5),
                      width: 2,
                    )
                  : null,
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: .35),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(categoryIcon(category), size: 28, color: Colors.white),
          ),
          const SizedBox(height: 5),
          Text(
            categoryName(category),
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? color : colors.ink,
            ),
          ),
        ],
      ),
    );
  }
}
