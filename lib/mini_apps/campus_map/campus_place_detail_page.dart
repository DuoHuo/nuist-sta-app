import 'package:flutter/material.dart';

import 'campus_building_model.dart';
import 'campus_building_model_page.dart';
import 'campus_map_api.dart';
import 'campus_map_data.dart';
import 'campus_map_panels.dart';
import 'campus_map_photos.dart';
import 'campus_map_source.dart';
import 'campus_map_widgets.dart';
import 'campus_photo_gallery_page.dart';

/// 地物详情页：建筑、地点 POI、通用地物共用同一个页面。
///
/// 三类地物各有稳定编号（建筑 `building_id` / POI `poi_id` / 通用地物
/// `feature_id`），因此都能被单独打开、分享与深链（路由 `/place/:placeId`）。
/// 页面按编号自行取数，不依赖地图页是否已经打开；建筑专有的 3D 模型与实景
/// 照片模块按数据源能力显示。
///
/// 注意：只有进了业务库的地物才有详情页。底图瓦片里的道路、绿地等要素没有
/// 业务编号，点不开——要让某类地物能被点开，得先在管理台把它提交进库。
class CampusPlaceDetailPage extends StatefulWidget {
  const CampusPlaceDetailPage({super.key, required this.placeId, this.source});

  /// 地物编号：`feature:3`、`poi:8` 或建筑编号（如 `OSM-Way862952692`）。
  final String placeId;

  /// 从地图页进来时复用同一个数据源实例；为空时自建并在销毁时关闭。
  final CampusMapSource? source;

  @override
  State<CampusPlaceDetailPage> createState() => _CampusPlaceDetailPageState();
}

class _CampusPlaceDetailPageState extends State<CampusPlaceDetailPage> {
  CampusMapApi? _owned;
  late final CampusMapSource _source;
  CampusPlace? _place;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final provided = widget.source;
    if (provided != null) {
      _source = provided;
    } else {
      _source = _owned = CampusMapApi();
    }
    _load();
  }

  @override
  void dispose() {
    _owned?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final remote = _source is CampusMapRemoteSource
        ? _source as CampusMapRemoteSource
        : null;
    if (remote == null) {
      setState(() {
        _loading = false;
        _error = '当前数据源不支持读取地物详情';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final place = await remote.loadPlace(
        CampusPlace(id: widget.placeId, name: ''),
      );
      if (!mounted) return;
      setState(() {
        _place = place;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is CampusMapApiException
            ? error.message
            : '地物详情加载失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final place = _place;
    return Scaffold(
      backgroundColor: MapPalette.surface,
      appBar: AppBar(
        title: Text(
          place != null && place.name.isNotEmpty ? place.name : '地物详情',
        ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : _content(place!),
    );
  }

  Widget _content(CampusPlace place) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
    children: [
      _header(place),
      if (place.description.isNotEmpty) ...[
        const SizedBox(height: 22),
        const MapSectionTitle('说明'),
        const SizedBox(height: 10),
        MapSurface(
          padding: const EdgeInsets.all(16),
          child: Text(
            place.description,
            style: const TextStyle(
              fontSize: 14.5,
              height: 1.65,
              color: MapPalette.ink,
            ),
          ),
        ),
      ],
      const SizedBox(height: 22),
      const MapSectionTitle('基本信息'),
      const SizedBox(height: 10),
      MapSurface(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(children: _facts(place)),
      ),
      ..._buildingResources(place),
    ],
  );

  Widget _header(CampusPlace place) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        place.name.isEmpty ? '未命名地物' : place.name,
        style: const TextStyle(
          fontSize: 27,
          fontWeight: FontWeight.w700,
          letterSpacing: -.8,
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(_kindLabel(place), MapPalette.blue),
          if (place.hasIndoor) _chip('有室内图', MapPalette.green),
        ],
      ),
    ],
  );

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );

  /// 类别文案：通用地物用后端 kind 的中文名，其余沿用 App 的四类分类。
  String _kindLabel(CampusPlace place) {
    if (place.kind != null) return featureKindLabel(place.kind);
    if (place.poiId != null) return categoryName(place.category);
    return place.category == null ? '建筑' : categoryName(place.category);
  }

  List<Widget> _facts(CampusPlace place) => [
    _fact('编号', place.id),
    _fact('类别', _kindLabel(place)),
    if (place.center != null)
      _fact(
        '坐标',
        '${place.center!.longitude.toStringAsFixed(5)}, '
            '${place.center!.latitude.toStringAsFixed(5)}',
      ),
    if (place.floors.isNotEmpty) _fact('楼层', '${place.floors.length} 层'),
    if (place.entrance != null) _fact('出入口', '已标注'),
  ];

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 11),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13.5, color: MapPalette.secondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13.5,
              color: MapPalette.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );

  /// 建筑专有模块：3D 模型与实景照片。通用地物与 POI 没有这些资源，
  /// 因此整块按 buildingId 是否存在决定是否出现。
  List<Widget> _buildingResources(CampusPlace place) {
    final buildingId = place.buildingId;
    if (buildingId == null) return const [];
    final model = _source is CampusBuildingModelSource
        ? _source as CampusBuildingModelSource
        : null;
    final photos = _source is CampusBuildingPhotosSource
        ? _source as CampusBuildingPhotosSource
        : null;
    return [
      const SizedBox(height: 22),
      const MapSectionTitle('楼宇资料'),
      const SizedBox(height: 10),
      MapSurface(
        child: Column(
          children: [
            CampusBuildingModelEntry(
              source: model,
              buildingId: buildingId,
              buildingName: place.name,
            ),
            if (photos != null)
              CampusBuildingPhotosEntry(
                source: photos,
                buildingId: buildingId,
                buildingName: place.name,
              ),
          ],
        ),
      ),
    ];
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 40,
            color: MapPalette.secondary,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: MapPalette.secondary, height: 1.6),
          ),
          const SizedBox(height: 16),
          MapAction(
            icon: Icons.refresh_rounded,
            label: '重试',
            primary: true,
            onPressed: onRetry,
          ),
        ],
      ),
    ),
  );
}
