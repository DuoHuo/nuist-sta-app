import 'package:flutter/material.dart';

import 'campus_map_data.dart';
import 'campus_map_source.dart';
import 'campus_map_widgets.dart';

class CampusExplorePanel extends StatelessWidget {
  const CampusExplorePanel({
    super.key,
    required this.search,
    required this.category,
    required this.places,
    required this.loading,
    required this.error,
    required this.onSearchFocus,
    required this.onCategory,
    required this.onRefresh,
    required this.onSelect,
  });
  final TextEditingController search;
  final PlaceCategory? category;
  final List<CampusPlace> places;
  final bool loading;
  final String? error;
  final VoidCallback onSearchFocus, onRefresh;
  final ValueChanged<PlaceCategory?> onCategory;
  final ValueChanged<CampusPlace> onSelect;
  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final results = places
        .where(
          (p) =>
              (category == null || p.category == category) &&
              (query.isEmpty ||
                  '${p.name} ${p.subtitle}'.toLowerCase().contains(query)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: search,
          onTap: onSearchFocus,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: '搜索地点、楼宇',
            hintStyle: const TextStyle(color: MapPalette.secondary),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: MapPalette.secondary,
              size: 22,
            ),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: search.clear,
                    icon: const Icon(Icons.cancel_rounded, size: 20),
                  ),
            filled: true,
            fillColor: MapPalette.field,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: MapPalette.blue),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
          ),
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final item in PlaceCategory.values)
                Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: _CategoryBadge(
                    category: item,
                    selected: category == item,
                    onTap: () =>
                        onCategory(category == item ? null : item),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        MapSectionTitle(
          query.isNotEmpty
              ? '搜索结果'
              : category == null
              ? '探索校园'
              : categoryName(category!),
          trailing: MapIconButton(
            icon: Icons.refresh_rounded,
            label: '刷新地点',
            onPressed: loading ? null : onRefresh,
            color: MapPalette.secondary,
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
        else if (results.isEmpty)
          MapEmptyState(
            icon: query.isNotEmpty
                ? Icons.search_off_rounded
                : Icons.place_outlined,
            title: query.isNotEmpty ? '没有找到相关地点' : '暂无地点信息',
            description: query.isNotEmpty
                ? '试试其他楼宇名称或清除分类。'
                : '地点信息接入后，将在这里显示。',
          )
        else
          MapSurface(
            radius: 18,
            child: Column(
              children: [
                for (var i = 0; i < results.length; i++) ...[
                  if (i > 0)
                    const Padding(
                      padding: EdgeInsets.only(left: 62),
                      child: Divider(height: 1),
                    ),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: categoryColor(results[i].category)
                            .withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        categoryIcon(results[i].category),
                        size: 21,
                        color: categoryColor(results[i].category),
                      ),
                    ),
                    title: Text(
                      results[i].name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: results[i].subtitle.isEmpty
                        ? null
                        : Text(
                            results[i].subtitle,
                            style: const TextStyle(
                              fontSize: 12,
                              color: MapPalette.secondary,
                            ),
                          ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: MapPalette.secondary,
                      size: 20,
                    ),
                    onTap: () => onSelect(results[i]),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 24),
        const Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 15,
              color: MapPalette.secondary,
            ),
            SizedBox(width: 7),
            Expanded(
              child: Text(
                '选择楼宇后可查看室内地图与可用楼层',
                style: TextStyle(
                  fontSize: 12,
                  color: MapPalette.secondary,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ],
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
    this.mediaEntry,
    this.onDetail,
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
  final Widget? mediaEntry;

  /// 打开该地物的完整详情页；为空时不显示入口（例如房间预览）。
  final VoidCallback? onDetail;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room?.name ?? place.name,
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  floor != null
                      ? '${place.name} · ${floor!.label}'
                      : place.subtitle.isEmpty
                      ? categoryName(place.category)
                      : place.subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: MapPalette.secondary,
                  ),
                ),
              ],
            ),
          ),
          MapIconButton(
            icon: Icons.close_rounded,
            label: room != null ? '关闭房间详情' : '关闭楼宇详情',
            onPressed: onClose,
          ),
        ],
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: MapAction(
              icon: Icons.turn_right_rounded,
              label: routing ? '规划中' : '路线',
              primary: true,
              onPressed: routing ? null : onRoute,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MapAction(
              icon: floor != null ? Icons.map_outlined : Icons.layers_outlined,
              label: floor != null ? '校园' : '室内',
              onPressed: onIndoor,
            ),
          ),
          const SizedBox(width: 8),
          MapSurface(
            radius: 15,
            child: MapIconButton(
              icon: Icons.streetview_rounded,
              label: '查看街景',
              color: MapPalette.blue,
              onPressed: onStreet,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (onDetail != null) ...[
        SizedBox(
          width: double.infinity,
          child: MapAction(
            icon: Icons.article_outlined,
            label: '查看详情',
            onPressed: onDetail,
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (mediaEntry != null) ...[mediaEntry!, const SizedBox(height: 16)],
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
          Text(
            route!.summary!,
            style: const TextStyle(color: MapPalette.secondary),
          ),
        for (final instruction in route!.instructions)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.turn_right_rounded,
              color: MapPalette.blue,
            ),
            title: Text(instruction),
          ),
      ] else if (floor != null) ...[
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
            const Icon(
              Icons.view_in_ar_outlined,
              size: 18,
              color: MapPalette.secondary,
            ),
          ],
        ),
        if (floor!.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              floor!.description,
              style: const TextStyle(color: MapPalette.secondary, fontSize: 13),
            ),
          ),
        const SizedBox(height: 16),
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
          MapSurface(
            radius: 18,
            child: Column(
              children: [
                for (final item in floorData.rooms)
                  ListTile(
                    leading: Icon(
                      item.id == room?.id
                          ? Icons.room_rounded
                          : Icons.meeting_room_outlined,
                      color: MapPalette.blue,
                    ),
                    title: Text(
                      item.name,
                      style: const TextStyle(fontSize: 14),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                    selected: item.id == room?.id,
                    onTap: () => onRoom(item),
                  ),
              ],
            ),
          ),
      ] else ...[
        const MapSectionTitle('楼宇信息'),
        const SizedBox(height: 14),
        if (place.hasIndoor && place.floors.isNotEmpty)
          MapSurface(
            radius: 18,
            child: ListTile(
              leading: const Icon(
                Icons.layers_outlined,
                color: MapPalette.blue,
              ),
              title: const Text(
                '室内地图',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${place.floors.length} 个可用楼层',
                style: const TextStyle(
                  fontSize: 12,
                  color: MapPalette.secondary,
                ),
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
        const SizedBox(height: 12),
        MapSurface(
          radius: 18,
          child: ListTile(
            leading: const Icon(
              Icons.streetview_rounded,
              color: MapPalette.blue,
            ),
            title: const Text(
              '走进实景',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '街景暂未开放',
              style: TextStyle(fontSize: 12, color: MapPalette.secondary),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: onStreet,
          ),
        ),
      ],
    ],
  );
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
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 23),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Icon(icon, size: 28, color: const Color(0xFF909AA8)),
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
          style: const TextStyle(
            fontSize: 12,
            height: 1.6,
            color: MapPalette.secondary,
          ),
        ),
        ?action,
      ],
    ),
  );
}

class MapLoadingView extends StatelessWidget {
  const MapLoadingView({super.key});
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFEFF2F4),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          SizedBox(height: 14),
          Text(
            '正在加载校园地图…',
            style: TextStyle(fontSize: 13, color: MapPalette.secondary),
          ),
        ],
      ),
    ),
  );
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
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFEFF2F4),
    child: Align(
      alignment: wide ? const Alignment(.35, -.12) : const Alignment(0, -.3),
      child: Padding(
        padding: EdgeInsets.only(left: wide ? 352 : 28, right: wide ? 100 : 76),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .8),
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(
                Icons.map_outlined,
                size: 38,
                color: Color(0xFF9DAEBB),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                color: Color(0xFF556675),
                letterSpacing: -.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? '底图服务尚未配置',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: MapPalette.secondary),
            ),
            if (action != null) ...[const SizedBox(height: 10), action!],
          ],
        ),
      ),
    ),
  );
}

class CampusRoutePlanner extends StatefulWidget {
  const CampusRoutePlanner({
    super.key,
    required this.places,
    required this.destination,
    this.floor,
    this.room,
  });
  final List<CampusPlace> places;
  final CampusPlace destination;
  final CampusFloor? floor;
  final CampusRoom? room;
  @override
  State<CampusRoutePlanner> createState() => _CampusRoutePlannerState();
}

class _CampusRoutePlannerState extends State<CampusRoutePlanner> {
  String? _originId;
  bool _accessible = false;
  @override
  Widget build(BuildContext context) => SafeArea(
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
                  '路线规划',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
              MapIconButton(
                icon: Icons.close_rounded,
                label: '关闭路线规划',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _originId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '选择起点',
              prefixIcon: Icon(Icons.trip_origin_rounded),
              border: OutlineInputBorder(),
            ),
            items: [
              for (final place in widget.places)
                DropdownMenuItem(
                  value: place.id,
                  child: Text(place.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _originId = value),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_rounded, color: MapPalette.blue),
            title: Text(widget.room?.name ?? widget.destination.name),
            subtitle: widget.floor == null
                ? null
                : Text('${widget.destination.name} · ${widget.floor!.label}'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.accessible_rounded),
            title: const Text('无障碍优先'),
            value: _accessible,
            onChanged: (value) => setState(() => _accessible = value),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: MapAction(
              icon: Icons.alt_route_rounded,
              label: '规划路线',
              primary: true,
              onPressed: _originId == null
                  ? null
                  : () => Navigator.pop(
                      context,
                      CampusRouteRequest(
                        originPlaceId: _originId!,
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
  null => MapPalette.secondary,
  PlaceCategory.study => const Color(0xFF4C8BF5),
  PlaceCategory.food => const Color(0xFFF2994A),
  PlaceCategory.sports => const Color(0xFF35B26F),
  PlaceCategory.services => const Color(0xFF9B6BF3),
};

/// 搜索栏下方的分类入口：彩色圆角图标徽章 + 名称，选中时实心反白。
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
    final color = categoryColor(category);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? color : color.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(16),
              border: selected
                  ? Border.all(color: color.withValues(alpha: .45), width: 1.5)
                  : null,
            ),
            child: Icon(
              categoryIcon(category),
              size: 22,
              color: selected ? Colors.white : color,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            categoryName(category),
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? color : MapPalette.ink,
            ),
          ),
        ],
      ),
    );
  }
}
