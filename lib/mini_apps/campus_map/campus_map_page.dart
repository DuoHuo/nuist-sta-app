import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'campus_map_photos.dart';
import 'campus_photo_gallery_page.dart';
import 'campus_map_api.dart';
import 'campus_map_canvas.dart';
import 'campus_map_data.dart';
import 'campus_map_location.dart';
import 'campus_map_panels.dart';
import 'campus_map_source.dart';
import 'campus_map_widgets.dart';
import 'campus_place_detail_page.dart';
import 'campus_street_view_page.dart';

class CampusMapPage extends StatefulWidget {
  const CampusMapPage({
    super.key,
    this.styleUrl = const String.fromEnvironment('CAMPUS_MAP_STYLE_URL'),
    this.source = const UnconfiguredCampusMapSource(),
    this.useNativeMap = true,
    this.location = const DeviceUserLocation(),
  });
  final String styleUrl;
  final CampusMapSource source;
  final bool useNativeMap;
  final UserLocationSource location;
  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  final _search = TextEditingController();
  final _sheet = DraggableScrollableController();
  CampusMapSnapshot _campus = const CampusMapSnapshot();
  CampusFloorSnapshot _floorData = const CampusFloorSnapshot();
  // 整栋楼各层几何（按楼层 id），用于分层叠放。
  Map<String, Map<String, dynamic>> _ghostFloors = const {};
  CampusPlace? _place;
  CampusFloor? _floor;
  CampusRoom? _room;
  PlaceCategory? _category;
  CampusRouteResult? _route;
  // 导航结果页：起点名（坐标起点时显示「我的位置」）。
  String _routeOriginLabel = '我的位置';
  bool _loading = false;
  bool _floorLoading = false;
  // 底图图层模式（街景覆盖是其中一档，不再是独立开关）。
  CampusMapLayer _layer = CampusMapLayer.standard;
  bool _routing = false;
  String? _error;
  String? _floorError;
  int _floorRevision = 0;
  int _campusRevision = 0;
  int _routeRevision = 0;
  int _resetToken = 0;
  Timer? _searchTimer;
  int _searchRevision = 0;
  int _placeRevision = 0;
  List<CampusPlace>? _searchResults;
  // 「探索校园」的随机样本（每次加载校园后抽 10 个）。
  List<CampusPlace> _explore = const [];
  final _random = Random();
  bool _searchLoading = false;
  bool _placeLoading = false;
  String? _searchError;
  String? _placeError;
  String get _style => widget.styleUrl.trim().isNotEmpty
      ? widget.styleUrl
      : _campus.styleString ?? '';
  CampusMapRemoteSource? get _remote => widget.source is CampusMapRemoteSource
      ? widget.source as CampusMapRemoteSource
      : null;
  int _zoomDelta = 0;
  GeoPoint? _userPoint;
  int _focusToken = 0;
  bool _locating = false;
  // 面板实际遮挡的高度（逻辑像素，按 24px 量化以减少重建）。
  double _sheetInset = 0;

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
    _sheet.addListener(_sheetChanged);
    unawaited(_loadCampus());
  }

  void _sheetChanged() {
    if (!_sheet.isAttached) return;
    final inset =
        (_sheet.size * MediaQuery.sizeOf(context).height / 24).round() * 24.0;
    if (inset == _sheetInset) return;
    setState(() => _sheetInset = inset);
  }

  @override
  void didUpdateWidget(covariant CampusMapPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _clearSelection();
      _campus = const CampusMapSnapshot();
      unawaited(_loadCampus());
    }
  }

  void _searchChanged() {
    _searchTimer?.cancel();
    final revision = ++_searchRevision;
    final query = _search.text.trim();
    final remote = _remote;
    setState(() {
      _searchError = null;
      _searchResults = null;
      _searchLoading = remote != null && query.isNotEmpty;
    });
    if (remote == null || query.isEmpty) return;
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final results = await remote.searchPlaces(query);
        if (!mounted || revision != _searchRevision) return;
        setState(() {
          _searchResults = results;
          _searchLoading = false;
        });
      } catch (error) {
        if (!mounted || revision != _searchRevision) return;
        setState(() {
          _searchError = _errorMessage(error, '地点搜索失败，请重试');
          _searchLoading = false;
        });
      }
    });
  }

  String _errorMessage(Object error, String fallback) =>
      error is CampusMapApiException ? error.toString() : fallback;
  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchRevision++;
    _sheet.removeListener(_sheetChanged);
    _placeRevision++;
    _floorRevision++;
    _campusRevision++;
    _routeRevision++;
    _search.dispose();
    _sheet.dispose();
    super.dispose();
  }

  Future<void> _loadCampus() async {
    final revision = ++_campusRevision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.source.loadCampus();
      if (!mounted || revision != _campusRevision) return;
      setState(() {
        _campus = data;
        _loading = false;
        // 「探索校园」每次加载后随机抽 10 个地点，不再平铺全部建筑；
        // 刷新按钮同时起到「换一批」的作用。
        _explore =
            (List<CampusPlace>.of(data.places)..shuffle(_random))
                .take(10)
                .toList();
      });
    } catch (error) {
      if (!mounted || revision != _campusRevision) return;
      setState(() {
        _loading = false;
        _error = _errorMessage(error, '地点暂时加载失败');
      });
    }
  }

  Future<void> _selectPlace(CampusPlace place) async {
    final revision = ++_placeRevision;
    final remote = _remote;
    _floorRevision++;
    _routeRevision++;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _place = place;
      _placeLoading = remote != null;
      _placeError = null;
      _floor = null;
      _room = null;
      _floorData = const CampusFloorSnapshot();
      _ghostFloors = const {};
      _floorError = null;
      _floorLoading = false;
      _route = null;
      _routing = false;
    });
    _expandSheet(.43);
    if (remote == null) return;
    try {
      final detail = await remote.loadPlace(place);
      if (!mounted || revision != _placeRevision) return;
      setState(() {
        _place = detail;
        _placeLoading = false;
      });
    } catch (error) {
      if (!mounted || revision != _placeRevision) return;
      setState(() {
        _placeLoading = false;
        _placeError = _errorMessage(error, '地点详情加载失败');
      });
    }
  }

  void _clearSelection() {
    _placeRevision++;
    _placeLoading = false;
    _placeError = null;
    _floorRevision++;
    _routeRevision++;
    setState(() {
      _place = null;
      _floor = null;
      _room = null;
      _route = null;
      _routing = false;
      _floorData = const CampusFloorSnapshot();
      _ghostFloors = const {};
      _floorError = null;
      _floorLoading = false;
    });
  }

  Future<void> _selectFloor(CampusFloor floor) async {
    final place = _place;
    if (place == null) return;
    final revision = ++_floorRevision;
    _routeRevision++;
    setState(() {
      _floor = floor;
      _room = null;
      _route = null;
      _routing = false;
      _floorLoading = true;
      _floorError = null;
      _floorData = const CampusFloorSnapshot();
    });
    final buildingId = place.buildingId ?? place.id;
    try {
      final data = await widget.source.loadFloor(buildingId, floor.id);
      if (!mounted || revision != _floorRevision) return;
      setState(() {
        _floorData = data;
        _floorLoading = false;
      });
    } catch (_) {
      if (!mounted || revision != _floorRevision) return;
      setState(() {
        _floorLoading = false;
        _floorError = '该楼层暂时加载失败';
      });
      return;
    }
    // 分层视图需要当前层及以下各层的几何（当前层上色，下方楼层半透明托底；
    // 上方楼层不渲染，也就不必拉取）。
    final floorsBelow =
        place.floors.where((f) => f.number <= floor.number).toList();
    unawaited(_loadBuildingFloors(buildingId, floorsBelow, revision));
  }

  Future<void> _loadBuildingFloors(
    String buildingId,
    List<CampusFloor> floors,
    int revision,
  ) async {
    final loaded = <String, Map<String, dynamic>>{};
    final pending = [...floors];
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final floor = pending.removeAt(0);
        try {
          final snapshot = await widget.source.loadFloor(buildingId, floor.id);
          final geoJson = snapshot.geoJson;
          if (geoJson != null) loaded[floor.id] = geoJson;
        } catch (_) {
          // 单层失败不影响其余楼层叠放。
        }
      }
    }

    await Future.wait(
      List.generate(floors.length.clamp(0, 4), (_) => worker()),
    );
    if (!mounted || revision != _floorRevision) return;
    setState(() => _ghostFloors = loaded);
  }

  void _leaveIndoor() {
    _floorRevision++;
    _routeRevision++;
    setState(() {
      _floor = null;
      _room = null;
      _route = null;
      _routing = false;
      _floorLoading = false;
      _floorError = null;
      _floorData = const CampusFloorSnapshot();
      _ghostFloors = const {};
    });
  }

  void _expandSheet(double size) {
    if (!_sheet.isAttached) return;
    unawaited(
      _sheet.animateTo(
        size,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// 打开地物详情页：建筑、POI、通用地物走同一个页面，按编号取数。
  /// 复用当前数据源，因此不会重复建连接；地址与深链路由 `/place/:placeId`
  /// 使用同一套编号。
  void _openDetail(CampusPlace place) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CampusPlaceDetailPage(placeId: place.id, source: widget.source),
      ),
    );
  }

  void _openStreet(CampusPlace place) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusStreetViewPage(
          request: StreetViewRequest(
            buildingId: place.id,
            sceneId: place.sceneId,
            entry: place.entrance,
          ),
          placeName: place.name,
        ),
      ),
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final point = await widget.location.current();
      if (!mounted) return;
      setState(() {
        _userPoint = point;
        _focusToken++;
        _locating = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _locating = false);
      _message(error.toString());
    }
  }

  Future<void> _showRoutePlanner() async {
    final destination = _place;
    if (destination == null || _routing) return;
    // 百度流程：起点默认「我的位置」，直接规划进入导航页；
    // 拿不到定位才退回起点选择弹层。
    var user = _userPoint;
    if (user == null || !user.isValid) {
      // 静默取一次定位（不移动相机），取不到再走手动选起点。
      try {
        final point = await widget.location.current();
        if (!mounted) return;
        if (point.isValid) setState(() => _userPoint = point);
        user = point;
      } catch (_) {
        user = null;
      }
    }
    if (!mounted) return;
    CampusRouteRequest? request;
    if (user != null && user.isValid) {
      request = CampusRouteRequest(
        originPoint: user,
        destinationPlaceId: destination.id,
        destinationFloorId: _floor?.id,
        destinationRoomId: _room?.id,
      );
    } else {
      request = await showModalBottomSheet<CampusRouteRequest>(
        context: context,
        isScrollControlled: true,
        backgroundColor: MapPalette.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (_) => CampusRoutePlanner(
          places: _campus.places,
          destination: destination,
          floor: _floor,
          room: _room,
          userPoint: _userPoint,
        ),
      );
    }
    // 提升为非空局部变量：闭包内使用可空变量会失去类型提升。
    final routeRequest = request;
    if (routeRequest == null || !mounted) return;
    final revision = ++_routeRevision;
    setState(() => _routing = true);
    try {
      final result = await widget.source.planRoute(routeRequest);
      if (!mounted || revision != _routeRevision) return;
      setState(() {
        _routing = false;
        _route = result;
        _routeOriginLabel = routeRequest.originPoint != null
            ? '我的位置'
            : _placeName(routeRequest.originPlaceId) ?? '起点';
      });
      if (result == null) {
        _message('暂无可用路线，请稍后再试');
      } else {
        _expandSheet(.55);
      }
    } catch (error) {
      if (!mounted || revision != _routeRevision) return;
      setState(() => _routing = false);
      _message(_errorMessage(error, '路线规划失败，请重试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData.light(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: MapPalette.blue,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: MapPalette.surface,
      textTheme: Theme.of(context).textTheme
          .apply(bodyColor: MapPalette.ink, displayColor: MapPalette.ink),
      dividerColor: MapPalette.line,
    );
    return Theme(
      data: theme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: PopScope<Object?>(
          canPop: _place == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_floor != null) {
                _leaveIndoor();
              } else {
                _clearSelection();
              }
            }
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 700;
                final safe = MediaQuery.paddingOf(context);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: _style.trim().isEmpty
                          ? (_loading
                                ? const MapLoadingView()
                                : _error != null
                                ? MapUnconfiguredView(
                                    wide: wide,
                                    title: _error!,
                                    message: '检查网络连接后，再试一次。',
                                    action: TextButton(
                                      onPressed: _loadCampus,
                                      child: const Text('重新加载'),
                                    ),
                                  )
                                : MapUnconfiguredView(
                                    wide: wide,
                                    message: _campus.warning,
                                  ))
                          : CampusMapCanvas(
                              styleUrl: _style,
                              useNativeMap: widget.useNativeMap,
                              places: _campus.places,
                              selectedPlace: _place,
                              floor: _floor,
                              selectedRoom: _room,
                              rooms: _floorData.rooms,
                              buildingGeoJson: _campus.buildingGeoJson,
                              featuresGeoJson: _campus.featuresGeoJson,
                              floorGeoJson: _floorData.geoJson,
                              ghostFloorsGeoJson: _ghostFloors,
                              streetCoverageGeoJson:
                                  _campus.streetCoverageGeoJson,
                              routeGeoJson: _route?.geoJson,
                              streetCoverage:
                                  _layer == CampusMapLayer.streetView,
                              mapLayer: _layer,
                              showRoute: _route != null,
                              category: _category,
                              resetToken: _resetToken,
                              zoomDelta: _zoomDelta,
                              userPoint: _userPoint,
                              focusToken: _focusToken,
                              viewportInsets: wide
                                  ? const EdgeInsets.only(left: 352 + 32)
                                  : EdgeInsets.only(
                                      bottom: _place == null ? 0 : _sheetInset,
                                    ),
                              onPlaceSelected: _selectPlace,
                              onRoomSelected: (room) {
                                _routeRevision++;
                                setState(() {
                                  _room = room;
                                  _route = null;
                                  _routing = false;
                                });
                                _expandSheet(.43);
                              },
                              onStreetEntry: _openStreet,
                            ),
                    ),
                    Positioned(
                      top: safe.top + 16,
                      left: 16,
                      right: 80,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MapSurface(
                            radius: 16,
                            child: MapIconButton(
                              icon: Icons.chevron_left_rounded,
                              label: _floor != null
                                  ? '退出室内'
                                  : _place != null
                                  ? '返回校园总览'
                                  : '返回应用',
                              onPressed: () {
                                if (_floor != null) {
                                  _leaveIndoor();
                                } else if (_place != null) {
                                  _clearSelection();
                                } else {
                                  Navigator.of(context).maybePop();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: safe.top + 16,
                      right: 16,
                      child: _tools(wide),
                    ),
                    if (_floor != null)
                      Positioned(
                        right: 16,
                        top: safe.top + 120,
                        bottom:
                            (wide ? 24.0 : constraints.maxHeight * .43) + 16,
                        child: LayoutBuilder(
                          builder: (context, band) => Align(
                            alignment: Alignment.center,
                            child: _floorSelector(band.maxHeight),
                          ),
                        ),
                      ),
                    if (_layer == CampusMapLayer.streetView)
                      Positioned(
                        top: safe.top + 94,
                        left: wide ? 392 : 16,
                        right: 80,
                        child: MapSurface(
                          radius: 14,
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.streetview_rounded,
                                size: 19,
                                color: MapPalette.blue,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _campus.streetCoverageGeoJson == null
                                      ? '街景暂未开放'
                                      : '点击蓝色覆盖点，进入街景',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: MapPalette.secondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (wide)
                      Positioned(
                        left: 16,
                        top: safe.top + 100,
                        bottom: safe.bottom + 24,
                        width: 352,
                        child: MapSurface(
                          radius: 26,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: _panel(),
                          ),
                        ),
                      )
                    else
                      DraggableScrollableSheet(
                        controller: _sheet,
                        initialChildSize: .33,
                        minChildSize: 0,
                        maxChildSize: .88,
                        snap: true,
                        snapSizes: const [.33, .55, .88],
                        builder: (context, controller) => Container(
                          decoration: const BoxDecoration(
                            color: MapPalette.surface,
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(28),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x1A243447),
                                blurRadius: 32,
                                offset: Offset(0, -4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(28),
                            ),
                            child: Material(
                              color: MapPalette.surface,
                              child: ListView(
                                controller: controller,
                                padding: EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  safe.bottom +
                                      MediaQuery.viewInsetsOf(context).bottom +
                                      24,
                                ),
                                children: [
                                  Center(
                                    child: Semantics(
                                      label: '展开地图面板',
                                      button: true,
                                      child: InkWell(
                                        onTap: () => _expandSheet(
                                          _sheet.size < .5 ? .88 : .33,
                                        ),
                                        child: SizedBox(
                                          width: 64,
                                          height: 28,
                                          child: Center(
                                            child: Container(
                                              width: 36,
                                              height: 5,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFC8CBD0),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  _panel(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (wide)
                      Positioned(
                        left: 384,
                        bottom: safe.bottom + 24,
                        child: _locateButton(),
                      )
                    else
                      AnimatedBuilder(
                        animation: _sheet,
                        builder: (context, _) {
                          final size = _sheet.isAttached ? _sheet.size : .33;
                          final collapsed = size < .02;
                          return Positioned(
                            left: 16,
                            bottom:
                                safe.bottom +
                                12 +
                                (collapsed ? 0 : size * constraints.maxHeight),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _locateButton(),
                                if (collapsed) ...[
                                  const SizedBox(height: 10),
                                  _collapsedSearchPill(),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                      // 导航中/预览时的顶部起终点条（仿百度导航页顶栏）。
                      if (_route != null)
                        Positioned(
                          top: safe.top + 12,
                          left: wide ? 384 : 16,
                          right: 16,
                          child: MapSurface(
                            radius: 18,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                MapIconButton(
                                  icon: Icons.arrow_back_rounded,
                                  label: '结束路线',
                                  onPressed: _endRoute,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.circle,
                                            size: 10,
                                            color: Color(0xFF34A853),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _routeOriginLabel,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                color: MapPalette.secondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.place_rounded,
                                            size: 14,
                                            color: Color(0xFFE15A4E),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              _room?.name ??
                                                  _place?.name ??
                                                  '目的地',
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String? _placeName(String? id) {
    for (final place in _campus.places) {
      if (place.id == id) return place.name;
    }
    return null;
  }

  /// 开始导航：收起面板，地图全屏呈现路线与顶部起终点条（仿百度导航页）。
  void _startNavigation() {
    if (_sheet.isAttached) {
      unawaited(
        _sheet.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  /// 结束路线：清除路线并恢复地点面板。
  void _endRoute() {
    _routeRevision++;
    setState(() {
      _route = null;
      _routing = false;
    });
    _expandSheet(_place == null ? .33 : .43);
  }

  Widget _panel() {
    final route = _route;
    if (route != null) {
      return CampusRoutePreview(
        route: route,
        destinationLabel: _room?.name ?? _place?.name ?? '目的地',
        destinationSubtitle: _floor != null
            ? '${_place?.name ?? ''} · ${_floor!.label}'
            : null,
        onStart: _startNavigation,
        onClose: _endRoute,
      );
    }
    return _place == null
      ? CampusExplorePanel(
          search: _search,
          category: _category,
          // 未搜索且未选分类时只展示随机抽样的 10 个地点。
          places: _searchResults ??
              (_category == null ? _explore : _campus.places),
          loading: _loading || _searchLoading,
          error: _searchError ?? _error,
          onSearchFocus: () => _expandSheet(.88),
          onCategory: (value) {
            setState(() => _category = value);
            _expandSheet(.55);
          },
          onRefresh: _loadCampus,
          onSelect: _selectPlace,
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_placeLoading) const LinearProgressIndicator(minHeight: 2),
            if (_placeError != null)
              MapEmptyState(
                icon: Icons.cloud_off_outlined,
                title: _placeError!,
                description: '可重试加载地点详情',
                action: TextButton(
                  onPressed: () => _selectPlace(_place!),
                  child: const Text('重试'),
                ),
              ),
            CampusPlacePanel(
              place: _place!,
              onDetail: _place!.hasDetail && _room == null
                  ? () => _openDetail(_place!)
                  : null,
              mediaEntry:
                  _place!.poiId == null && !_place!.id.startsWith('poi:')
                  ? CampusBuildingPhotosEntry(
                      source: widget.source is CampusBuildingPhotosSource
                          ? widget.source as CampusBuildingPhotosSource
                          : null,
                      buildingId: _place!.buildingId ?? _place!.id,
                      buildingName: _place!.name,
                    )
                  : null,
              floor: _floor,
              room: _room,
              floorData: _floorData,
              floorLoading: _floorLoading,
              floorError: _floorError,
              route: _route,
              routing: _routing,
              onClose: () {
                if (_room != null) {
                  setState(() => _room = null);
                } else {
                  _clearSelection();
                }
              },
              onRoute:
                  widget.source.isConfigured &&
                      !_placeLoading &&
                      _placeError == null
                  ? _showRoutePlanner
                  : null,
              onIndoor: _floor != null
                  ? _leaveIndoor
                  : _place!.hasIndoor && _place!.floors.isNotEmpty
                  ? () => _selectFloor(_place!.floors.first)
                  : null,
              onStreet: () => _openStreet(_place!),
              onRetryFloor: () => _selectFloor(_floor!),
              onRoom: (room) {
                _routeRevision++;
                setState(() {
                  _room = room;
                  _route = null;
                  _routing = false;
                });
              },
              onCloseRoute: () => setState(() => _route = null),
            ),
          ],
        );
  }

  Widget _tools(bool wide) => Column(
    children: [
      MapSurface(
        radius: 16,
        child: MapIconButton(
          icon: Icons.layers_outlined,
          label: '地图图层',
          // 图层入口仅作导航，永远不高亮（当前图层在弹层里体现）。
          active: false,
          onPressed: _showLayers,
        ),
      ),
      if (wide) ...[
        const SizedBox(height: 12),
        MapSurface(
          radius: 16,
          child: Column(
            children: [
              MapIconButton(
                icon: Icons.add_rounded,
                label: '放大地图',
                onPressed: _style.isEmpty
                    ? null
                    : () => setState(() => _zoomDelta++),
              ),
              MapIconButton(
                icon: Icons.remove_rounded,
                label: '缩小地图',
                onPressed: _style.isEmpty
                    ? null
                    : () => setState(() => _zoomDelta--),
              ),
            ],
          ),
        ),
      ],
    ],
  );

  Widget _locateButton() => MapSurface(
    radius: 16,
    child: MapIconButton(
      // 点击后保持黑色常态，不做选中高亮（定位是动作，不是开关）。
      icon: Icons.my_location_rounded,
      label: '定位到我的位置',
      onPressed: _locating ? null : _locate,
      busy: _locating,
    ),
  );

  Widget _collapsedSearchPill() => MapSurface(
    radius: 16,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: InkWell(
      onTap: () => _expandSheet(.88),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, size: 20, color: MapPalette.secondary),
          SizedBox(width: 8),
          Text(
            '搜索地点、楼宇',
            style: TextStyle(fontSize: 13, color: MapPalette.secondary),
          ),
          SizedBox(width: 14),
        ],
      ),
    ),
  );

  /// 楼层选择器：等高条目、统一间距、垂直居中于可用区域，超出可滚动。
  Widget _floorSelector(double bandHeight) {
    final floors = [..._place!.floors]
      ..sort((a, b) => b.number.compareTo(a.number));
    // 固定宽度：垂直 ListView 需要确定的横向约束。
    return SizedBox(
      width: 48,
      child: MapSurface(
        radius: 15,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: bandHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 3),
                child: Icon(
                  Icons.layers_outlined,
                  size: 15,
                  color: MapPalette.secondary,
                ),
              ),
              const Divider(height: 1, indent: 8, endIndent: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  itemCount: floors.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final floor = floors[index];
                    final selected = _floor!.id == floor.id;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Semantics(
                        selected: selected,
                        button: true,
                        label: '${floor.label}${selected ? '，当前楼层' : ''}',
                        child: SizedBox(
                          width: 38,
                          height: 34,
                          child: TextButton(
                            onPressed: () => _selectFloor(floor),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(38, 34),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              backgroundColor: selected
                                  ? MapPalette.blue
                                  : Colors.transparent,
                              foregroundColor: selected
                                  ? Colors.white
                                  : MapPalette.ink,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: Text(
                              floor.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.1,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasTransitStops() => _campus.places.any(
    (p) => const {'bus_stop', '公交站', '轨道交通'}.contains(p.kind),
  );

  Future<void> _showLayers() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: MapPalette.surface,
      showDragHandle: true,
      builder: (context) {
        // 图层卡片：百度地图式缩略图 + 名称；选中项蓝色描边，卫星图预留（灰置）。
        Widget layerCard(
          CampusMapLayer layer,
          String thumbnail,
          String label, {
          bool reserved = false,
        }) {
          final selected = _layer == layer && !reserved;
          final fg = reserved
              ? MapPalette.secondary
              : (selected ? MapPalette.blue : MapPalette.ink);
          return GestureDetector(
            onTap: () {
              if (reserved) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('卫星图暂未接入，接口已预留')),
                );
                return;
              }
              if (layer == CampusMapLayer.transit && !_hasTransitStops()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('校园暂无公共交通覆盖数据')),
                );
              }
              setState(() => _layer = layer);
              Navigator.pop(context);
            },
            child: Opacity(
              opacity: reserved ? 0.5 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? MapPalette.blue : MapPalette.line,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        selected ? 14 : 15,
                      ),
                      child: Image.asset(
                        thumbnail,
                        width: 58,
                        height: 58,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '图层',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    MapIconButton(
                      icon: Icons.close_rounded,
                      label: '关闭图层',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      layerCard(
                        CampusMapLayer.standard,
                        'assets/map_layers/layer_standard.png',
                        '标准地图',
                      ),
                      const SizedBox(width: 14),
                      layerCard(
                        CampusMapLayer.city3d,
                        'assets/map_layers/layer_3d.png',
                        '3D地图',
                      ),
                      const SizedBox(width: 14),
                      layerCard(
                        CampusMapLayer.satellite,
                        'assets/map_layers/layer_satellite.png',
                        '卫星图',
                        reserved: true,
                      ),
                      const SizedBox(width: 14),
                      layerCard(
                        CampusMapLayer.transit,
                        'assets/map_layers/layer_transit.png',
                        '公共交通',
                      ),
                      const SizedBox(width: 14),
                      layerCard(
                        CampusMapLayer.streetView,
                        'assets/map_layers/layer_street.png',
                        '街景地图',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.center_focus_strong_outlined,
                    color: MapPalette.blue,
                  ),
                  title: const Text('重置地图视角'),
                  onTap: _style.isEmpty
                      ? null
                      : () {
                          setState(() => _resetToken++);
                          Navigator.pop(context);
                        },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
