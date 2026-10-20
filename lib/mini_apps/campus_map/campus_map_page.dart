import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/schedule/weekly_classes.dart';
import 'campus_map_photos.dart';
import 'campus_photo_gallery_page.dart';
import 'campus_map_api.dart';
import 'campus_map_cache.dart';
import 'campus_map_canvas.dart';
import 'campus_map_data.dart';
import 'campus_map_heading.dart';
import 'campus_map_location.dart';
import 'campus_map_panels.dart';
import 'campus_map_schedule.dart';
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
    this.heading = const DeviceHeading(),
  });
  final String styleUrl;
  final CampusMapSource source;
  final bool useNativeMap;
  final UserLocationSource location;

  /// 手机朝向（画蓝点的方向光束）；只在持续定位开着时订阅。
  final HeadingSource heading;

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  // 总览面板内容的实际高度（逻辑像素）：面板最多只能拉到正好露出全部内容，
  // 不再拉出一大片空白。搜索、分类列表这类可能很长的内容不受限。
  double? _homeContentHeight;
  double _sheetMaxSize = .88;
  // 课表联动：本周全部有地点的课（打开地图时读一次），以及正在查找教室的那节。
  List<WeeklyClass> _weekClasses = const [];
  WeeklyClass? _locatingClass;
  // 上次处理过的搜索词：控制器在光标/选区变化时也会通知，只有文字变了才重新搜索。
  String _lastQuery = '';
  Timer? _sheetTimer;
  // 地图标注缓存：输入不变时保持同一个列表引用，原生端据此跳过图层重建。
  List<CampusPlace> _markers = const [];
  (Object?, Object?, String)? _markerInputs;
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
  final CampusMapCache _cache = CampusMapCache();
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
  // 最近一次定位精度（米）：只用来过滤小幅抖动，地图上不画精度圈。
  double? _userAccuracy;
  // 地图打开期间的持续定位订阅（有权限才开）。
  StreamSubscription<LocationFix>? _locationSub;
  // 朝向订阅与当前朝向（度，0 = 正北）。
  StreamSubscription<double>? _headingSub;
  double? _userHeading;
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
    unawaited(_loadWeekClasses());
    // 已经授过权就直接显示蓝点，不弹权限框、不挪相机。
    unawaited(_startLiveLocation());
  }

  /// 随机去一个有名字、有坐标的地方（骰子按钮）。
  void _randomPlace() {
    final pool = [
      for (final place in _campus.places)
        if (place.center != null &&
            place.center!.isValid &&
            place.name.trim().isNotEmpty &&
            !place.name.startsWith('未命名'))
          place,
    ];
    if (pool.isEmpty) {
      _message('地点还没加载出来，稍后再试');
      return;
    }
    final place = pool[_random.nextInt(pool.length)];
    unawaited(_selectPlace(place));
    _message('就去这儿看看：${place.name}');
  }

  LiveUserLocationSource? get _live => widget.location is LiveUserLocationSource
      ? widget.location as LiveUserLocationSource
      : null;

  /// 订阅手机朝向；没有传感器（或测试环境）时静默不画光束。
  void _startHeading() {
    if (_headingSub != null) return;
    try {
      _headingSub = widget.heading.watch().listen(
        (degrees) {
          final current = _userHeading;
          // 转动 3° 以上才重建，地图端还会再节流一次。
          if (!mounted ||
              (current != null && headingDelta(current, degrees).abs() < 3)) {
            return;
          }
          setState(() => _userHeading = degrees);
        },
        onError: (Object _) {
          unawaited(_headingSub?.cancel());
          _headingSub = null;
          if (mounted) setState(() => _userHeading = null);
        },
        cancelOnError: true,
      );
    } catch (_) {
      _headingSub = null;
    }
  }

  void _applyFix(LocationFix fix, {bool focus = false}) {
    final previous = _userPoint;
    final accuracy = _userAccuracy;
    // 小幅抖动不重建定位图层：移动 2 米以上或精度变化 5 米以上才更新。
    if (!focus &&
        previous != null &&
        metersBetween(previous, fix.point) < 2 &&
        accuracy != null &&
        (accuracy - fix.accuracyM).abs() < 5) {
      return;
    }
    setState(() {
      _userPoint = fix.point;
      _userAccuracy = fix.accuracyM;
      if (focus) _focusToken++;
    });
  }

  /// 有权限时订阅持续定位；[requireReady] 为 false 表示刚刚已确认过权限。
  Future<void> _startLiveLocation({bool requireReady = true}) async {
    final live = _live;
    if (live == null || _locationSub != null) return;
    try {
      if (requireReady && !await live.ready()) return;
      if (!mounted || _locationSub != null) return;
      if (_userPoint == null) {
        final last = await live.lastKnown();
        if (mounted && last != null && _userPoint == null) _applyFix(last);
      }
      if (!mounted || _locationSub != null) return;
      _locationSub = live.watch().listen(
        (fix) {
          if (mounted) _applyFix(fix);
        },
        // 中途出错（如关掉了定位服务）就停掉，下次点定位再开。
        onError: (Object _) {
          unawaited(_locationSub?.cancel());
          unawaited(_headingSub?.cancel());
          _locationSub = null;
        },
        cancelOnError: true,
      );
      _startHeading();
    } catch (_) {
      // 测试环境没有定位插件，或系统定位异常：静默跳过，点定位按钮时再提示。
    }
  }

  /// 读本周课程（课表没登记或读取失败时当作没有课，不打扰用户）。
  Future<void> _loadWeekClasses() async {
    final source = WeeklyClasses.source;
    if (source == null) return;
    try {
      final classes = await source.thisWeek();
      if (!mounted) return;
      if (kDebugMode) {
        // 只打数量，不打课程与地点（日志规范）。
        debugPrint('[campus-map] 本周有地点的课 ${classes.length} 节');
      }
      setState(() => _weekClasses = classes);
    } catch (_) {
      // 课表不可用不影响地图。
    }
  }

  /// 点楼宇卡片里的一节课：按门牌号逐层查找教室，找到就进室内并选中它。
  Future<void> _openClass(WeeklyClass item) async {
    final place = _place;
    if (place == null || _locatingClass != null) return;
    final code = roomCodeIn(item.location, place.name);
    if (code == null) return;
    if (place.floors.isEmpty) {
      _message('这栋楼暂无室内图，教室在 $code');
      return;
    }
    setState(() => _locatingClass = item);
    final buildingId = place.buildingId ?? place.id;
    try {
      for (final floor in floorsToSearch(place.floors, code)) {
        final data = await widget.source.loadFloor(buildingId, floor.id);
        if (!mounted || _place?.id != place.id) return;
        CampusRoom? match;
        for (final room in data.rooms) {
          if (roomCodeMatches(room.roomCode ?? room.name, code)) {
            match = room;
            break;
          }
        }
        if (match == null) continue;
        await _selectFloor(floor);
        if (!mounted || _floor?.id != floor.id) return;
        final found = match;
        final room = _floorData.rooms.firstWhere(
          (r) => r.id == found.id,
          orElse: () => found,
        );
        _routeRevision++;
        setState(() {
          _room = room;
          _route = null;
          _routing = false;
        });
        _expandSheet(.43);
        return;
      }
      _message('室内图里还没有 $code');
    } catch (_) {
      if (mounted) _message('教室查找失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _locatingClass = null);
    }
  }

  /// 界面配色，随系统明暗切换；地图底图不受影响。
  MapPalette get colors => MapPalette.of(context);

  /// 面板拖动时不重建整页：等面板停稳（约 160ms 无变化）再把遮挡高度交给
  /// 地图做相机内缩，避免拖动过程中相机跟着反复动画、整页逐帧重建。
  void _sheetChanged() {
    _sheetTimer?.cancel();
    _sheetTimer = Timer(const Duration(milliseconds: 160), () {
      if (!mounted || !_sheet.isAttached) return;
      final inset =
          (_sheet.size * MediaQuery.sizeOf(context).height / 24).round() * 24.0;
      if (inset == _sheetInset) return;
      setState(() => _sheetInset = inset);
    });
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
    final query = _search.text.trim();
    if (query == _lastQuery) return;
    final startedTyping = _lastQuery.isEmpty && query.isNotEmpty;
    _lastQuery = query;
    // 开始输入后面板不再按总览内容限高：等这一帧放开上限后再展开。
    if (startedTyping) _expandSheetAfterFrame(.88);
    _searchTimer?.cancel();
    final revision = ++_searchRevision;
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
    _sheetTimer?.cancel();
    unawaited(_locationSub?.cancel());
    _searchRevision++;
    _sheet.removeListener(_sheetChanged);
    _placeRevision++;
    _floorRevision++;
    _campusRevision++;
    _routeRevision++;
    _search.dispose();
    _searchFocus.dispose();
    _sheet.dispose();
    super.dispose();
  }

  /// 应用一份校园快照并维护「探索校园」随机样本。
  ///
  /// 只在首次加载或用户点刷新（[resample]）时重新抽样；缓存秒开后网络数据
  /// 到达时沿用原来那批地点（换成新对象），列表不会在手指底下突然换一批。
  void _applyCampus(
    CampusMapSnapshot data, {
    bool loading = false,
    bool resample = false,
  }) {
    // 后端给没登记名称的楼宇填「未命名建筑 <编号>」占位名，不放进探索推荐。
    final named = [
      for (final place in data.places)
        if (place.name.trim().isNotEmpty && !place.name.startsWith('未命名'))
          place,
    ];
    final byId = {for (final place in named) place.id: place};
    final kept = [
      for (final place in _explore)
        if (byId[place.id] != null) byId[place.id]!,
    ];
    setState(() {
      _campus = data;
      _loading = loading;
      _explore =
          !resample && kept.isNotEmpty && kept.length >= min(10, named.length)
          ? kept
          : (List<CampusPlace>.of(named)..shuffle(_random)).take(10).toList();
    });
  }

  /// 刷新按钮：重新拉取校园数据，同时给「探索校园」换一批。
  Future<void> _refreshCampus() => _loadCampus(resample: true);

  Future<void> _loadCampus({bool resample = false}) async {
    final revision = ++_campusRevision;
    setState(() {
      _loading = true;
      _error = null;
    });
    // 缓存与网络并行：缓存先到就先渲染（秒开），网络返回后覆盖并落盘
    // （stale-while-revalidate）。缓存读不能挡在加载路径上——存储或插件异常时
    // 它会一直挂着（widget 测试里 path_provider 没有实现，读盘永不返回），
    // 那样整页数据都加载不出来。
    if (_campus.places.isEmpty) {
      unawaited(
        _cache.read('default').then((cached) {
          if (!mounted || revision != _campusRevision) return;
          if (!_loading) return; // 网络已先到，别再用缓存覆盖
          if (cached != null && cached.places.isNotEmpty) {
            _applyCampus(cached, loading: true);
          }
        }),
      );
    }
    try {
      final data = await widget.source.loadCampus();
      if (!mounted || revision != _campusRevision) return;
      _applyCampus(data, resample: resample);
      unawaited(_cache.write('default', data));
    } catch (error) {
      if (!mounted || revision != _campusRevision) return;
      // 已有缓存内容时保留数据，仅提示刷新失败。
      final hasCache = _campus.places.isNotEmpty;
      setState(() {
        _loading = false;
        if (!hasCache) _error = _errorMessage(error, '地点暂时加载失败');
      });
      if (hasCache) _message('您已离线');
    }
  }

  Future<void> _selectPlace(CampusPlace place) async {
    final revision = ++_placeRevision;
    final remote = _remote;
    _floorRevision++;
    _routeRevision++;
    FocusManager.instance.primaryFocus?.unfocus();
    if (place.poiId == null && place.featureId == null) {
      unawaited(_loadWeekClasses());
    }
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
    // 当前层已经在手里，只补拉下方楼层。
    final floorsBelow = place.floors
        .where((f) => f.number < floor.number)
        .toList();
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

  /// 先让这一帧按新状态算出面板上限，再展开（状态变化会放开总览限高时用）。
  void _expandSheetAfterFrame(double target) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expandSheet(target);
      });

  void _expandSheet(double target) {
    if (!_sheet.isAttached) return;
    final size = min(target, _sheetMaxSize);
    // 系统关闭动画时直接跳到位：animateTo 不接受零时长（会断言失败）。
    if (MediaQuery.disableAnimationsOf(context)) {
      _sheet.jumpTo(size);
      return;
    }
    unawaited(
      _sheet.animateTo(
        size,
        duration: const Duration(milliseconds: 280),
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
    final live = _live;
    if (live != null) {
      await _locateLive(live);
      return;
    }
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

  /// 定位按钮（真机）：先用最近位置立刻回中，再拿精确位置校正，最后开持续定位。
  Future<void> _locateLive(LiveUserLocationSource live) async {
    var centered = false;
    try {
      final last = await live.lastKnown();
      if (mounted && last != null) {
        _applyFix(last, focus: true);
        centered = true;
      }
      final fix = await live.currentFix();
      if (!mounted) return;
      final moved = _userPoint == null
          ? double.infinity
          : metersBetween(_userPoint!, fix.point);
      // 先前已经回中，且这次没偏多少：只更新点，不再拽相机。
      _applyFix(fix, focus: !centered || moved > max(30, fix.accuracyM));
      setState(() => _locating = false);
      unawaited(_startLiveLocation(requireReady: false));
    } catch (error) {
      if (!mounted) return;
      setState(() => _locating = false);
      _message(error.toString());
    }
  }

  Future<void> _showRoutePlanner() async {
    final destination = _place;
    if (destination == null || _routing) return;
    // 起点默认「我的位置」：已有定位就直接规划进入导航页；
    // 没有定位立即弹起点搜索，不做任何等待。
    final user = _userPoint;
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
        backgroundColor: colors.surface,
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 状态栏压在地图底图上，底图目前只有浅色素材，所以深色模式下也用深色图标。
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
                            streetCoverage: _layer == CampusMapLayer.streetView,
                            mapLayer: _layer,
                            showRoute: _route != null,
                            category: _category,
                            resetToken: _resetToken,
                            zoomDelta: _zoomDelta,
                            userPoint: _userPoint,
                            userHeading: _userPoint == null
                                ? null
                                : _userHeading,
                            focusToken: _focusToken,
                            markerPlaces: _markerPlaces(),
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
                        if (_place == null && _route == null) ...[
                          const SizedBox(width: 10),
                          Expanded(child: _topSearchBar()),
                        ],
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
                      bottom: (wide ? 24.0 : constraints.maxHeight * .43) + 16,
                      child: AnimatedBuilder(
                        animation: _sheet,
                        builder: (context, child) {
                          // 面板拉高时楼层用面板里的页签切换，侧边楼层条让位。
                          final hidden =
                              !wide && _sheet.isAttached && _sheet.size >= .2;
                          return IgnorePointer(
                            ignoring: hidden,
                            child: AnimatedOpacity(
                              opacity: hidden ? 0 : 1,
                              duration: const Duration(milliseconds: 150),
                              child: hidden ? const SizedBox.shrink() : child,
                            ),
                          );
                        },
                        child: LayoutBuilder(
                          builder: (context, band) => Align(
                            alignment: Alignment.center,
                            child: _floorSelector(band.maxHeight),
                          ),
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
                            Icon(
                              Icons.streetview_rounded,
                              size: 19,
                              color: colors.blue,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _campus.streetCoverageGeoJson == null
                                    ? '街景暂未开放'
                                    : '点击蓝色覆盖点，进入街景',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.secondary,
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
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: _panelChildren(),
                        ),
                      ),
                    )
                  else
                    DraggableScrollableSheet(
                      controller: _sheet,
                      initialChildSize: .33,
                      minChildSize: 0,
                      maxChildSize: _sheetMaxSize = _maxSheetSize(
                        constraints.maxHeight,
                        safe.bottom,
                      ),
                      snap: true,
                      snapSizes: [
                        for (final size in const [.33, .55, .88])
                          if (size <= _sheetMaxSize) size,
                      ],
                      builder: (context, controller) => Container(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: colors.shadow,
                              blurRadius: 32,
                              offset: const Offset(0, -4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28),
                          ),
                          child: Material(
                            color: colors.surface,
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
                                              color: colors.handle,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (_isHomePanel)
                                  _SizeReporter(
                                    onHeight: (height) {
                                      if ((height - (_homeContentHeight ?? 0))
                                              .abs() <
                                          1) {
                                        return;
                                      }
                                      setState(
                                        () => _homeContentHeight = height,
                                      );
                                    },
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: _panelChildren(),
                                    ),
                                  )
                                else
                                  ..._panelChildren(),
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
                        if (size > .5) return const SizedBox.shrink();
                        return Positioned(
                          left: 16,
                          bottom:
                              safe.bottom +
                              12 +
                              (size < .02 ? 0 : size * constraints.maxHeight),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [_locateButton()],
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
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: colors.secondary,
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
                                          _room?.name ?? _place?.name ?? '目的地',
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

  /// 是否是校园总览的「发现」面板（未选地点、无路线、未搜索、未选分类）。
  /// 这时内容很短，面板高度按内容来。
  bool get _isHomePanel =>
      _place == null &&
      _route == null &&
      _category == null &&
      _search.text.trim().isEmpty;

  /// 面板最大高度（占屏比例）：总览时 = 拖动条 + 内容 + 底部留白，
  /// 夹在 [.33, .88] 之间；其余情况保持 .88。
  double _maxSheetSize(double screenHeight, double bottomInset) {
    final content = _homeContentHeight;
    if (!_isHomePanel || content == null || screenHeight <= 0) return .88;
    const handle = 28.0, bottomPadding = 24.0;
    final fraction =
        (handle + content + bottomPadding + bottomInset) / screenHeight;
    return fraction.clamp(.33, .88);
  }

  /// 面板内容拆成列表项交给 ListView 懒构建：分类列表可能有几百个地点，
  /// 不能塞进一个 Column 一次性全部布局。
  List<Widget> _panelChildren() {
    if (_route == null && _place == null) {
      return _explorePanel().children(context);
    }
    return [_panel()];
  }

  CampusExplorePanel _explorePanel() => CampusExplorePanel(
    query: _search.text,
    category: _category,
    // 未搜索且未选分类时只展示随机抽样的 10 个地点。
    places: _searchResults ?? (_category == null ? _explore : _campus.places),
    allPlaces: _campus.places,
    userPoint: _userPoint,
    weekClasses: _weekClasses,
    onShuffle: _randomPlace,
    loading: _loading || _searchLoading,
    error: _searchError ?? _error,
    onCategory: (value) {
      setState(() => _category = value);
      _expandSheetAfterFrame(.55);
    },
    onRefresh: _refreshCampus,
    onSelect: _selectPlace,
  );

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
        ? _explorePanel()
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
                onFloor: _selectFloor,
                // 只有楼宇（不是 POI / 通用地物）才和课表联动。
                weekClasses: _place!.poiId == null && _place!.featureId == null
                    ? classesInBuilding(_weekClasses, _place!)
                    : const [],
                // 本周有课但不在这栋楼：卡片显示一句提示，而不是整块消失。
                hasWeekClasses:
                    _place!.poiId == null &&
                    _place!.featureId == null &&
                    _weekClasses.isNotEmpty,
                onClass: _openClass,
                locatingClass: _locatingClass,
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

  /// 地图顶部常驻的搜索框（全页唯一）：点一下就地变成输入框，结果出现在下方面板，
  /// 地图同步标出结果。
  Widget _topSearchBar() => MapSurface(
    radius: 16,
    child: SizedBox(
      height: 48,
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        onTap: () => _expandSheet(.88),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _expandSheet(.55),
        style: TextStyle(fontSize: 15, color: colors.ink),
        decoration: InputDecoration(
          hintText: '搜索地点、楼宇',
          hintStyle: TextStyle(color: colors.secondary, fontSize: 14),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 21,
            color: colors.secondary,
          ),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _search.clear();
                    _searchFocus.unfocus();
                  },
                  icon: const Icon(Icons.cancel_rounded, size: 20),
                ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    ),
  );

  /// 地图上的结果标注：有搜索词或选了分类时，把面板列表里的地点同步标到图上。
  /// 输入不变时返回同一个列表引用，避免原生端重复重建标注图层。
  List<CampusPlace> _markerPlaces() {
    final query = _search.text.trim();
    final source = _searchResults ?? _campus.places;
    final last = _markerInputs;
    if (last != null &&
        identical(last.$1, source) &&
        last.$2 == _category &&
        last.$3 == query) {
      return _markers;
    }
    _markerInputs = (source, _category, query);
    _markers = query.isEmpty && _category == null
        ? const []
        : filterPlaces(source, _category, query);
    return _markers;
  }

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
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 3),
                child: Icon(
                  Icons.layers_outlined,
                  size: 15,
                  color: colors.secondary,
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
                                  ? colors.blue
                                  : Colors.transparent,
                              foregroundColor: selected
                                  ? Colors.white
                                  : colors.ink,
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
      backgroundColor: colors.surface,
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
              ? colors.secondary
              : (selected ? colors.blue : colors.ink);
          return GestureDetector(
            onTap: () {
              if (reserved) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('卫星图暂未接入，接口已预留')));
                return;
              }
              if (layer == CampusMapLayer.transit && !_hasTransitStops()) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('校园暂无公共交通覆盖数据')));
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
                        color: selected ? colors.blue : colors.line,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(selected ? 14 : 15),
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
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
                  leading: Icon(
                    Icons.center_focus_strong_outlined,
                    color: colors.blue,
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

/// 布局后把子组件高度报给 [onHeight]（高度变化才回调）。
class _SizeReporter extends StatefulWidget {
  const _SizeReporter({required this.onHeight, required this.child});
  final ValueChanged<double> onHeight;
  final Widget child;

  @override
  State<_SizeReporter> createState() => _SizeReporterState();
}

class _SizeReporterState extends State<_SizeReporter> {
  double? _reported;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = context.size?.height;
      if (height == null || height == _reported) return;
      _reported = height;
      widget.onHeight(height);
    });
    return widget.child;
  }
}
