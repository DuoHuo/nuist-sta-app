import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_schedule.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';

/// 用课表的 mock（kb_mock_2026-1.json，地点已改成「明德楼N101」这类真实门牌）
/// 走一遍「教务数据 → 课表解析 → 本周课程 → 地图楼宇 / 教室匹配」整条链路。
void main() {
  late List<WeeklyClass> allWeeks;

  setUpAll(() {
    final json = jsonDecode(
      File('test/fixtures/timetable/kb_mock_2026-1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = (json['datas'] as Map)['cxxszhxqkb']['rows'] as List;
    final courses = TimetableParser.parseKbRows(rows).courses;
    // 不依赖「今天是第几周」：把每节课在任意一周出现过的时段都拿出来。
    allWeeks = [
      for (final course in courses)
        for (final slot in course.slots)
          if (slot.location.trim().isNotEmpty && slot.weeks.contains('1'))
            WeeklyClass(
              courseName: course.name,
              location: slot.location,
              weekday: slot.day,
              startNode: slot.startNode,
              endNode: slot.endNode,
            ),
    ];
  });

  const mingde = CampusPlace(
    id: 'OSM-Way862952692',
    name: '明德楼',
    floors: [
      CampusFloor(id: '8', label: '1F', number: 1),
      CampusFloor(id: '9', label: '2F', number: 2),
      CampusFloor(id: '10', label: '3F', number: 3),
    ],
  );

  test('mock 里明德楼的课都能归到明德楼，别的楼不混进来', () {
    final mine = classesInBuilding(allWeeks, mingde);
    expect(mine, isNotEmpty);
    expect(mine.every((c) => c.location.startsWith('明德楼')), isTrue);
    expect(
      classesInBuilding(
        allWeeks,
        const CampusPlace(id: 'x', name: '文德楼'),
      ).every((c) => c.location.startsWith('文德楼')),
      isTrue,
    );
  });

  test('mock 门牌能对上明德楼真实房间（含合并门牌 N101-103）', () {
    final codes = {
      for (final c in classesInBuilding(allWeeks, mingde))
        roomCodeIn(c.location, mingde.name),
    };
    expect(codes, containsAll(['N101', 'N305']));
    // 明德楼一层真实数据里 N101 属于合并房间「N101-103」。
    expect(roomCodeMatches('N101-103', 'N101'), isTrue);
    expect(roomCodeMatches('N305', 'N305'), isTrue);
    // 查找顺序：N305 先查 3 层。
    expect(floorsToSearch(mingde.floors, 'N305').first.number, 3);
    expect(floorsToSearch(mingde.floors, 'N101').first.number, 1);
  });
}
