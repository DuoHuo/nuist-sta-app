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
        // 四个分类入口等宽铺满整行、内容居中（各占 1/4）。
        // 原先靠左排 + 固定右间距，右侧会留出空白，看着像没对齐。
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
          leading: const Icon(
            Icons.my_location_rounded,
            color: MapPalette.blue,
          ),
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
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '没有匹配的地点',
            style: TextStyle(fontSize: 13, color: MapPalette.secondary),
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
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: MapPalette.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_editingOrigin)
                    ListTile(
                      leading: const Icon(
                        Icons.trip_origin_rounded,
                        color: MapPalette.blue,
                      ),
                      title: Text(
                        _originLabel.isEmpty ? '搜索起点' : _originLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: _originLabel.isEmpty
                              ? MapPalette.secondary
                              : MapPalette.ink,
                        ),
                      ),
                      subtitle: const Text('起点'),
                      trailing: const Icon(
                        Icons.search_rounded,
                        color: MapPalette.secondary,
                      ),
                      onTap: () => setState(() => _editingOrigin = true),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.trip_origin_rounded,
                            color: MapPalette.blue,
                          ),
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
  Widget build(BuildContext context) => Column(
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
            const Icon(
              Icons.directions_walk_rounded,
              color: MapPalette.blue,
              size: 34,
            ),
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
                    style: const TextStyle(
                      fontSize: 12,
                      color: MapPalette.secondary,
                    ),
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
                leading: const Icon(
                  Icons.turn_right_rounded,
                  color: MapPalette.blue,
                ),
                title: Text(instruction, style: const TextStyle(fontSize: 14)),
              ),
          ],
        ),
      ),
    ],
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
                      color: MapPalette.ink.withValues(alpha: .5),
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
              color: selected ? color : MapPalette.ink,
            ),
          ),
        ],
      ),
    );
  }
}
