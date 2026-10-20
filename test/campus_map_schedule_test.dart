import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_schedule.dart';

WeeklyClass lesson(String location, {int day = 2, int start = 3}) =>
    WeeklyClass(
      courseName: '高等数学',
      location: location,
      weekday: day,
      startNode: start,
      endNode: start + 1,
    );

void main() {
  test('地点以楼名开头才算这栋楼，空白与大小写不影响', () {
    expect(locationInBuilding('明德楼A101', '明德楼'), isTrue);
    expect(locationInBuilding('明德楼 a101', '明德楼'), isTrue);
    expect(locationInBuilding('揽江楼 N407', '明德楼'), isFalse);
    // 楼名出现在中间不算（不做模糊匹配）。
    expect(locationInBuilding('东区明德楼A101', '明德楼'), isFalse);
    // 单字楼名不参与匹配。
    expect(locationInBuilding('北101', '北'), isFalse);
  });

  test('取楼名后面的门牌号', () {
    expect(roomCodeIn('明德楼A101', '明德楼'), 'A101');
    expect(roomCodeIn('揽江楼 N407', '揽江楼'), 'N407');
    expect(roomCodeIn('学而楼C303多媒体教室', '学而楼'), 'C303');
    expect(roomCodeIn('明德楼-205', '明德楼'), '205');
    expect(roomCodeIn('明德楼', '明德楼'), isNull);
    expect(roomCodeIn('体育馆', '明德楼'), isNull);
  });

  test('门牌匹配支持单间与合并区间', () {
    expect(roomCodeMatches('N102', 'N102'), isTrue);
    expect(roomCodeMatches('n102', 'N102'), isTrue);
    expect(roomCodeMatches('N101-103', 'N102'), isTrue);
    expect(roomCodeMatches('N101-103', 'N103'), isTrue);
    expect(roomCodeMatches('N101-103', 'N104'), isFalse);
    expect(roomCodeMatches('N108-10', 'N109'), isTrue);
    expect(roomCodeMatches('N101-103', 'S102'), isFalse);
    expect(roomCodeMatches(null, 'N102'), isFalse);
    expect(roomCodeMatches('N102', 'N1020'), isFalse);
  });

  test('按楼筛出本周的课', () {
    const place = CampusPlace(id: 'b1', name: '明德楼');
    final classes = [
      lesson('明德楼A101'),
      lesson('揽江楼N407'),
      lesson('明德楼 B202', day: 4),
    ];
    final mine = classesInBuilding(classes, place);
    expect(mine.map((c) => c.location), ['明德楼A101', '明德楼 B202']);
  });

  test('按门牌猜楼层只影响查找顺序', () {
    const floors = [
      CampusFloor(id: 'f1', label: '1F', number: 1),
      CampusFloor(id: 'f2', label: '2F', number: 2),
      CampusFloor(id: 'f4', label: '4F', number: 4),
    ];
    expect(floorsToSearch(floors, 'N407').map((f) => f.id), ['f4', 'f1', 'f2']);
    expect(floorsToSearch(floors, 'A12').map((f) => f.id), ['f1', 'f2', 'f4']);
  });

  test('时间标签', () {
    expect(classTimeLabel(lesson('x')), '周二 3-4 节');
  });
}
