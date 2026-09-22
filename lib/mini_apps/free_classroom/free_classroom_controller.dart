import 'package:flutter/foundation.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import 'free_classroom_api.dart';
import 'free_classroom_models.dart';
import 'free_classroom_store.dart';

/// 空教室查询的页面状态：日期 + 教学楼决定去教务拉哪份数据，时段 / 楼层 /
/// 分区 / 类型 / 座位是纯本地筛选，改动不发请求。
///
/// 结果按「日期|楼」在内存里缓存，校历按日期缓存，所以来回切楼、切日期基本
/// 是秒开；只有点刷新才无视缓存重拉。
class FreeClassroomController extends ChangeNotifier {
  FreeClassroomController._();

  static final FreeClassroomController instance = FreeClassroomController._();

  bool _portalBound = true;
  bool _started = false;
  Future<void>? _starting;

  List<Building>? _buildings;
  bool _buildingsLoading = false;
  String? _buildingsError;
  Map<String, String> _occupationNames = kOccupationNames;

  Building? _building;
  DateTime _date = _today();

  ClassroomDay? _result;
  bool _loading = false;
  String? _error;

  /// 已选时段在 [ClassroomDay.groups] 里的下标，以及这份选择属于哪一天：
  /// 换楼不动它，换日期才回到默认。
  Set<int> _selectedGroups = {};
  String? _selectionDate;
  int? _floor;

  /// 楼内分区（N / C / S 之类）筛选；null = 全部。
  String? _zone;

  /// 房间类型筛选；null = 全部（但不含办公室之类的非教室）。
  String? _type;

  /// 最少座位数，0 = 不限。
  int _minSeats = 0;

  final Map<String, ClassroomDay> _cache = {};
  final Map<String, TermCalendar> _calendars = {};

  /// 正在进行的查询编号，切换条件后旧查询的结果直接丢弃。
  int _querySeq = 0;

  // ==================== 只读状态 ====================

  bool get portalBound => _portalBound;
  List<Building>? get buildings => _buildings;
  bool get buildingsLoading => _buildingsLoading;
  String? get buildingsError => _buildingsError;
  Map<String, String> get occupationNames => _occupationNames;

  Building? get building => _building;
  DateTime get date => _date;

  /// 当前日期 + 教学楼对应的结果；条件变了还没拉到时为 null。
  ClassroomDay? get result => _result;
  bool get loading => _loading;
  String? get error => _error;

  Set<int> get selectedGroups => _selectedGroups;
  int? get floor => _floor;
  String? get zone => _zone;
  String? get type => _type;
  int get minSeats => _minSeats;

  bool get isToday => dateKeyOf(_date) == dateKeyOf(_today());

  /// 今天已经结束的时段下标（用于把它们画淡）；非今天为空。
  Set<int> overGroups(ClassroomDay day) {
    if (dateKeyOf(day.date) != dateKeyOf(_today())) return const {};
    final now = DateTime.now();
    final groups = day.groups;
    return {
      for (var i = 0; i < groups.length; i++)
        if (groups[i].isOver(now)) i,
    };
  }

  /// 按当前楼层 + 分区 + 类型 + 座位筛选后的教室，先「所选时段全空」再
  /// 「部分空闲」，最后是「一节都不空」的，组内按空闲节数多 → 普通教室优先
  /// → 楼层低 → 名称排。全占用的也返回，页面折叠着放在最底下。
  List<RoomMatch> matches() {
    final day = _result;
    if (day == null) return const [];
    final groups = day.groups;
    final selected = [
      for (final i in _selectedGroups)
        if (i >= 0 && i < groups.length) groups[i],
    ];
    if (selected.isEmpty) return const [];
    final total = selected.fold<int>(0, (n, g) => n + g.periods.length);
    final list = <RoomMatch>[];
    for (final room in day.rooms) {
      if (_floor != null && room.floor != _floor) continue;
      if (_zone != null && room.zone != _zone) continue;
      if (_type != null ? room.type != _type : room.isNonClassroom) continue;
      if (_minSeats > 0 && (room.seats ?? 0) < _minSeats) continue;
      final free = selected.fold<int>(0, (n, g) => n + room.freeCountIn(g));
      list.add(RoomMatch(room: room, freeCount: free, totalCount: total));
    }
    list.sort((a, b) {
      if (a.fullyFree != b.fullyFree) return a.fullyFree ? -1 : 1;
      if (a.freeCount != b.freeCount) return b.freeCount - a.freeCount;
      if (a.room.typeRank != b.room.typeRank) {
        return a.room.typeRank - b.room.typeRank;
      }
      if (a.room.floor != b.room.floor) return a.room.floor - b.room.floor;
      return a.room.name.compareTo(b.room.name);
    });
    return list;
  }

  // ==================== 生命周期 ====================

  /// 读本地偏好、拉教学楼列表；记得上次的楼就顺手把今天查出来。
  Future<void> ensureStarted() {
    if (_started) return _starting ?? Future.value();
    _started = true;
    return _starting = _start();
  }

  /// 仅供 widget 测试：不走门户和网络，直接把 [day] 当作当前查询结果，
  /// 让页面能在测试环境里渲染出有数据的列表。
  @visibleForTesting
  void debugSetResult(ClassroomDay day, {List<Building>? buildings}) {
    _started = true;
    _starting = Future.value();
    _portalBound = true;
    if (buildings != null) _buildings = buildings;
    _building = day.building;
    _date = DateTime(day.date.year, day.date.month, day.date.day);
    _cache[_cacheKey(_date, day.building)] = day;
    _setResult(day);
    notifyListeners();
  }

  Future<void> _start() async {
    _portalBound = await PasskeyStore.read() != null;
    _buildings = await FreeClassroomStore.readBuildings();
    _building = await FreeClassroomStore.readBuilding();
    // 首次打开且没有缓存时，日期回到今天，避免跨天后停在昨天。
    _date = _today();
    notifyListeners();
    if (!_portalBound) return;
    await Future.wait([refreshBuildings(), if (_building != null) query()]);
  }

  /// 重新检查门户绑定状态（从绑定页返回后调用）。
  Future<void> recheckPortal() async {
    final bound = await PasskeyStore.read() != null;
    if (bound == _portalBound) return;
    _portalBound = bound;
    notifyListeners();
    if (bound) {
      await Future.wait([refreshBuildings(), if (_building != null) query()]);
    }
  }

  Future<void> refreshBuildings() async {
    if (_buildingsLoading) return;
    _buildingsLoading = true;
    _buildingsError = null;
    notifyListeners();
    try {
      final list = await FreeClassroomApi.listBuildings();
      if (list.isNotEmpty) {
        _buildings = list;
        await FreeClassroomStore.saveBuildings(list);
        // 记住的楼已经不在列表里（改名 / 下线）就清掉。
        if (_building != null && !list.contains(_building)) {
          _building = null;
          _result = null;
        }
      }
      // 字典是锦上添花，拉不到就用内置表，不影响主流程。
      try {
        _occupationNames = await FreeClassroomApi.occupationNames();
      } catch (_) {}
    } on PortalException catch (e) {
      _buildingsError = e.message;
    } catch (e) {
      _buildingsError = '加载教学楼失败：$e';
    } finally {
      _buildingsLoading = false;
      notifyListeners();
    }
  }

  // ==================== 用户操作 ====================

  Future<void> selectBuilding(Building building) async {
    if (building == _building) return;
    _building = building;
    _error = null;
    // 先给缓存里的结果，让切换立刻有反应。
    _applyCached();
    notifyListeners();
    await FreeClassroomStore.saveBuilding(building);
    if (_result == null) await query();
  }

  Future<void> selectDate(DateTime date) async {
    final normalized = DateTime(date.year, date.month, date.day);
    if (dateKeyOf(normalized) == dateKeyOf(_date)) return;
    _date = normalized;
    _error = null;
    _applyCached();
    notifyListeners();
    if (_result == null && _building != null) await query();
  }

  void toggleGroup(int index) {
    final next = Set<int>.of(_selectedGroups);
    if (!next.remove(index)) next.add(index);
    // 至少留一个，否则列表空得莫名其妙。
    if (next.isEmpty) return;
    _selectedGroups = next;
    notifyListeners();
  }

  void selectAllGroups() {
    final day = _result;
    if (day == null) return;
    _selectedGroups = {for (var i = 0; i < day.groups.length; i++) i};
    notifyListeners();
  }

  /// 今天：只选还没结束的时段；其他日期等价于全选。
  void selectUpcomingGroups() {
    final day = _result;
    if (day == null) return;
    _selectedGroups = _defaultGroups(day);
    notifyListeners();
  }

  void setFloor(int? floor) {
    if (floor == _floor) return;
    _floor = floor;
    notifyListeners();
  }

  void setZone(String? zone) {
    if (zone == _zone) return;
    _zone = zone;
    notifyListeners();
  }

  void setType(String? type) {
    if (type == _type) return;
    _type = type;
    notifyListeners();
  }

  void setMinSeats(int seats) {
    if (seats == _minSeats) return;
    _minSeats = seats;
    notifyListeners();
  }

  /// 拉当前日期 + 楼的数据；[force] 无视缓存。
  Future<void> query({bool force = false}) async {
    final building = _building;
    if (building == null) return;
    _portalBound = await PasskeyStore.read() != null;
    if (!_portalBound) {
      notifyListeners();
      return;
    }
    final date = _date;
    final key = _cacheKey(date, building);
    if (!force) {
      final cached = _cache[key];
      if (cached != null) {
        _setResult(cached);
        notifyListeners();
        return;
      }
    }
    final seq = ++_querySeq;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final dateKey = dateKeyOf(date);
      var calendar = force ? null : _calendars[dateKey];
      calendar ??= await FreeClassroomApi.calendar(date);
      _calendars[dateKey] = calendar;
      final rooms = await FreeClassroomApi.classrooms(
        date: date,
        calendar: calendar,
        building: building,
      );
      final day = ClassroomDay(
        date: date,
        building: building,
        calendar: calendar,
        rooms: rooms,
        fetchedAt: DateTime.now(),
      );
      _cache[key] = day;
      if (seq != _querySeq) return; // 用户已经切走了
      _setResult(day);
    } on PortalException catch (e) {
      if (seq == _querySeq) _error = e.message;
    } catch (e) {
      if (seq == _querySeq) _error = '查询失败：$e';
    } finally {
      if (seq == _querySeq) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  // ==================== 内部 ====================

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static String _cacheKey(DateTime date, Building b) =>
      '${dateKeyOf(date)}|${b.code}';

  void _applyCached() {
    final building = _building;
    final cached = building == null ? null : _cache[_cacheKey(_date, building)];
    if (cached != null) {
      _setResult(cached);
    } else {
      _result = null;
    }
  }

  /// 换结果时保留用户的时段 / 楼层选择；只有跨天或选择已不成立时才重置。
  void _setResult(ClassroomDay day) {
    _result = day;
    final dateKey = dateKeyOf(day.date);
    final groupCount = day.groups.length;
    final valid = _selectedGroups.where((i) => i < groupCount).toSet();
    if (_selectionDate != dateKey || valid.isEmpty) {
      _selectedGroups = _defaultGroups(day);
      _selectionDate = dateKey;
    } else {
      _selectedGroups = valid;
    }
    if (_floor != null && !day.floors.contains(_floor)) _floor = null;
    if (_zone != null && !day.zones.contains(_zone)) _zone = null;
    if (_type != null && !day.types.any((t) => t.key == _type)) _type = null;
  }

  Set<int> _defaultGroups(ClassroomDay day) {
    final groups = day.groups;
    final all = {for (var i = 0; i < groups.length; i++) i};
    final upcoming = all.difference(overGroups(day));
    // 今天的课全结束了就全选，总得让人看点什么。
    return upcoming.isEmpty ? all : upcoming;
  }
}
