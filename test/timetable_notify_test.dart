import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

NotifyClass _c(String name, DateTime s, {int minutes = 95, String loc = ''}) =>
    NotifyClass(
      name: name,
      location: loc,
      start: s,
      end: s.add(Duration(minutes: minutes)),
    );

/// 记录调用、不碰平台的桥。
class _FakeBridge extends TimetableNotifyBridge {
  final scheduled = <List<Map<String, Object?>>>[];
  final widgets = <Map<String, Object?>>[];
  int cancels = 0;

  @override
  Future<void> scheduleReminders(List<Map<String, Object?>> alarms) async =>
      scheduled.add(alarms);

  @override
  Future<void> cancelReminders() async => cancels++;

  @override
  Future<void> updateWidget(Map<String, Object?> payload) async =>
      widgets.add(jsonDecode(jsonEncode(payload)) as Map<String, Object?>);

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<NotifyPermissionStatus> permissionStatus() async =>
      NotifyPermissionStatus.unsupported;
}

void main() {
  group('planReminders', () {
    final now = DateTime(2026, 10, 20, 7, 0); // 周二

    test('提前量：开课前 N 分钟', () {
      final plan = planReminders(
        now: now,
        leadMinutes: 15,
        days: 1,
        classesOn: (d) =>
            d.day == 20 ? [_c('高数', DateTime(2026, 10, 20, 8))] : [],
      );
      expect(plan, hasLength(1));
      expect(plan.single.fireAt, DateTime(2026, 10, 20, 7, 45));
      expect(plan.single.toJson()['fireAt'], '2026-10-20T07:45');
      expect(plan.single.toJson()['classStart'], '2026-10-20T08:00');
      expect(plan.single.title, '高数 即将上课');
    });

    test('同一时间两门课合并为一条', () {
      final s = DateTime(2026, 10, 20, 10, 10);
      final plan = planReminders(
        now: now,
        leadMinutes: 10,
        days: 1,
        classesOn: (d) => d.day == 20
            ? [_c('英语', s, loc: 'A101'), _c('物理', s, loc: 'B202')]
            : [],
      );
      expect(plan, hasLength(1));
      expect(plan.single.names, ['英语', '物理']);
      expect(plan.single.title, '2 门课即将上课');
      expect(plan.single.body, contains('A101 / B202'));
    });

    test('已过的提醒不补发', () {
      final plan = planReminders(
        now: DateTime(2026, 10, 20, 7, 50),
        leadMinutes: 15,
        days: 1,
        classesOn: (d) => [_c('高数', DateTime(d.year, d.month, d.day, 8))],
      );
      expect(plan, isEmpty);
    });

    test('7 天窗口：只排今天起 7 天', () {
      final plan = planReminders(
        now: now,
        leadMinutes: 5,
        classesOn: (d) => [_c('课', DateTime(d.year, d.month, d.day, 9))],
      );
      expect(plan, hasLength(7));
      expect(plan.first.classStart, DateTime(2026, 10, 20, 9));
      expect(plan.last.classStart, DateTime(2026, 10, 26, 9));
    });

    test('跨日：次日 0:10 的课提前 30 分钟落在今天', () {
      final plan = planReminders(
        now: DateTime(2026, 10, 20, 23, 0),
        leadMinutes: 30,
        days: 1,
        classesOn: (d) =>
            d.day == 21 ? [_c('夜课', DateTime(2026, 10, 21, 0, 10))] : [],
      );
      expect(plan, hasLength(1));
      expect(plan.single.fireAt, DateTime(2026, 10, 20, 23, 40));
    });

    test('时区：输出本地墙上时间，与时区偏移无关', () {
      final plan = planReminders(
        now: now,
        leadMinutes: 20,
        days: 1,
        classesOn: (d) =>
            d.day == 20 ? [_c('高数', DateTime(2026, 10, 20, 8))] : [],
      );
      // 原生端按当时的时区解析这个字符串；改时区后重排仍是 07:40 本地时间。
      expect(plan.single.toJson()['fireAt'], '2026-10-20T07:40');
      expect(
        RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d$')
            .hasMatch(plan.single.toJson()['classStart']! as String),
        isTrue,
      );
    });
  });

  group('小组件 payload', () {
    test('包含 8 天、状态、颜色与节次', () {
      final now = DateTime(2026, 10, 20, 9);
      final p = buildWidgetPayload(
        now: now,
        weekOf: (d) => 8,
        lastSyncedAt: DateTime(2026, 10, 20, 7),
        classesOn: (d) => d.day == 20
            ? [
                NotifyClass(
                  name: '数据结构',
                  location: '明德楼B201',
                  start: DateTime(2026, 10, 20, 10, 10),
                  end: DateTime(2026, 10, 20, 11, 50),
                  courseId: 'DS|01',
                  teachers: const ['张老师', '李老师'],
                  startNode: 3,
                  endNode: 4,
                  barColor: 0xFFE91E63,
                  barColorDark: 0xFFAA1144,
                ),
              ]
            : [],
      );
      final json = jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
      expect(json['state'], 'ok');
      expect(json['hasCache'], true);
      final days = json['days'] as List;
      expect(days, hasLength(8));
      expect(days.first['date'], '2026-10-20');
      expect(days.first['week'], 8);
      expect(days[1]['date'], '2026-10-21');
      final item = (days.first['items'] as List).single as Map;
      expect(item['nodes'], '第3-4节');
      expect(item['start'], '2026-10-20T10:10');
      expect(item['end'], '2026-10-20T11:50');
      expect(item['color'], 0xFFE91E63);
      expect(item['colorDark'], 0xFFAA1144);
      expect(item['courseId'], 'DS|01');
      expect(item['teachers'], ['张老师', '李老师']);
      expect(item['teacherFirst'], '张老师');
      expect(item['periodTime'], '第3-4节 10:10-11:50');
    });

    test('教师：中英文逗号都能拆分并去空白、丢空项', () {
      expect(splitTeachers('张三,李四，王五'), ['张三', '李四', '王五']);
      expect(splitTeachers(' 张三 ， , 李四 ,'), ['张三', '李四']);
      expect(widgetTeachers('张三，李四'), ['张三', '李四']);
    });

    test('教师：网络教师不进小组件', () {
      expect(widgetTeachers('网络教师'), isEmpty);
      expect(widgetTeachers('网络教师,张三'), ['张三']);
      expect(widgetTeachers(' 网络教师 ，李四'), ['李四']);
    });

    test('教师：单个教师与空值', () {
      expect(widgetTeachers('张三'), ['张三']);
      expect(widgetTeachers(''), isEmpty);
      expect(widgetTeachers(' , ，'), isEmpty);
    });

    test('教师：payload 中只剩网络教师时为空列表与空串', () {
      final now = DateTime(2026, 10, 20, 9);
      Map item(String raw) {
        final p = buildWidgetPayload(
          now: now,
          days: 1,
          classesOn: (d) => [
            NotifyClass(
              name: '网课',
              location: '',
              start: DateTime(2026, 10, 20, 10),
              end: DateTime(2026, 10, 20, 11),
              teachers: widgetTeachers(raw),
            ),
          ],
        );
        final json = jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
        return ((json['days'] as List).first['items'] as List).single as Map;
      }

      expect(item('网络教师')['teachers'], isEmpty);
      expect(item('网络教师')['teacherFirst'], '');
      expect(item('网络教师，张三')['teachers'], ['张三']);
      expect(item('网络教师，张三')['teacherFirst'], '张三');
      expect(item('李四')['teacherFirst'], '李四');
      expect(item('')['teachers'], isEmpty);
      expect(item('')['teacherFirst'], '');
    });

    final d0 = DateTime(2026, 10, 20);
    final six = [
      for (var h = 8; h <= 18; h += 2) _c('课$h', d0.add(Duration(hours: h))),
    ];
    final at9 = DateTime(2026, 10, 20, 9);

    const p2 = WidgetPrefs();
    const p3 = WidgetPrefs(courseCount: 3);
    const offUp = WidgetPrefs(courseCount: 1);
    ({int rows, int more, int badge}) lay(
      int remaining,
      WidgetPrefs prefs, [
      int h = 168,
    ]) => widgetLayout(remaining: remaining, heightDp: h, prefs: prefs);

    test('下一节保留完整详情，额外课程使用轻量行与表头数量', () {
      expect(p2.slotStyles, [WidgetItemStyle.main, WidgetItemStyle.main]);
      expect(p3.slotStyles, [
        WidgetItemStyle.main,
        WidgetItemStyle.main,
        WidgetItemStyle.compact,
      ]);
      expect(offUp.slotStyles, [WidgetItemStyle.main]);
      final two = selectWidgetRows(six, at9);
      expect(two.rows.map((c) => c.name), ['课10']);
      expect(two.styles, [WidgetItemStyle.main]);
      expect(two.more, 0);
      expect(two.badge, 4);
      final three = selectWidgetRows(six, at9, prefs: p3);
      expect(three.rows.map((c) => c.name), ['课10']);
      expect(three.more, 0);
      expect(three.badge, 4);
      expect(lay(5, offUp), (rows: 0, more: 0, badge: 5));
      expect(lay(0, p2), (rows: 0, more: 0, badge: 0));
      expect(lay(1, p2), (rows: 1, more: 0, badge: 0));
      expect(lay(2, p3), (rows: 1, more: 0, badge: 1));
      expect(lay(5, const WidgetPrefs(courseCount: 3, showCount: false)), (
        rows: 1,
        more: 0,
        badge: 0,
      ));
    });

    test('小尺寸优先保留当前课与下一节，极小尺寸才减少后续行', () {
      expect(lay(5, p3, 108), (rows: 0, more: 0, badge: 5));
      expect(lay(5, p3, 110), (rows: 1, more: 0, badge: 4));
      expect(lay(5, p3, 120), (rows: 1, more: 0, badge: 4));
      expect(lay(5, p3, 158), (rows: 1, more: 0, badge: 4));
      expect(lay(5, p3, 159), (rows: 1, more: 0, badge: 4));
      expect(lay(5, p3, 187), (rows: 1, more: 0, badge: 4));
      expect(lay(5, p3, 188), (rows: 2, more: 0, badge: 3));
      expect(widgetLayout(remaining: 5, widthDp: 250, prefs: p3), (
        rows: 1,
        more: 0,
        badge: 4,
      ));
      expect(widgetLayout(remaining: 5, fontScale: 1.5, prefs: p3), (
        rows: 1,
        more: 0,
        badge: 4,
      ));
      expect(
        widgetLayout(remaining: 5, heightDp: 260, fontScale: 1.5, prefs: p3),
        (rows: 2, more: 0, badge: 3),
      );
      expect(lay(5, const WidgetPrefs(showCount: false), 120), (
        rows: 1,
        more: 0,
        badge: 0,
      ));
      final done = selectWidgetRows(six, DateTime(2026, 10, 20, 23));
      expect(done.main, isNull);
      expect(done.rows, isEmpty);
    });

    test('剩余课少于课程数：不渲染空块，不出现 +0', () {
      final two = six.take(2).toList();
      final r3 = selectWidgetRows(two, at9, prefs: p3);
      expect(r3.rows, hasLength(1));
      expect(r3.styles, [WidgetItemStyle.main]);
      expect(r3.more, 0);
      expect(r3.badge, 0);
      final one = six.take(1).toList();
      for (final prefs in [p2, p3]) {
        for (final h in [120, 145, 168]) {
          final r = selectWidgetRows(one, at9, prefs: prefs, heightDp: h);
          expect(r.rows, isEmpty);
          expect(r.more, 0);
          expect(r.badge, 0);
        }
      }
    });

    test('第 1 块是当前或下一节，其后按时间顺序', () {
      final shuffled = [six[4], six[0], six[3], six[1], six[5], six[2]];
      // 10:30 正在上「课10」（10:00-11:35），「课8」已结束。
      final r = selectWidgetRows(
        shuffled,
        DateTime(2026, 10, 20, 10, 30),
        prefs: p3,
      );
      expect(r.main!.name, '课10');
      expect(r.rows.map((c) => c.name), ['课12']);
      expect(r.more, 0);
      expect(r.badge, 3);
      // 课间 11:50：下一节「课12」。
      final b = selectWidgetRows(shuffled, DateTime(2026, 10, 20, 11, 50));
      expect(b.main!.name, '课12');
      expect(b.rows.map((c) => c.name), ['课14']);
      for (final height in [110, 120, 139, 158, 168]) {
        final during = selectWidgetRows(
          shuffled,
          DateTime(2026, 10, 20, 10, 30),
          heightDp: height,
        );
        expect(during.main!.name, '课10');
        expect(during.rows.map((c) => c.name), ['课12']);
      }
    });

    test('2×2：主课与之后课程按开始时间选择', () {
      final r = selectWidget2x2(six, at9);
      expect(r.main!.name, '课8');
      expect(r.after, same(six[1]));
      // 上课中取当前课。
      final during = selectWidget2x2([
        six[4],
        six[0],
        six[3],
        six[1],
        six[5],
        six[2],
      ], DateTime(2026, 10, 20, 10, 30));
      expect(during.main!.name, '课10');
      expect(during.after, same(six[2]));
      // 课间取下一节。
      final brk = selectWidget2x2(six, DateTime(2026, 10, 20, 11, 50));
      expect(brk.main!.name, '课12');
      expect(brk.after, same(six[3]));
      // 今日已结束 / 无课。
      final done = selectWidget2x2(six, DateTime(2026, 10, 20, 23));
      expect(done.main, isNull);
      expect(done.afterText, '明天没课');
      expect(selectWidget2x2(const [], at9).main, isNull);
      expect(selectWidget2x2(const [], at9).mainText, '今天没有课程');
    });

    test('2×2：上下课边界与最后一节的之后状态', () {
      final first = six.first;
      final atStart = selectWidget2x2(six, first.start);
      expect(atStart.main, same(first));
      expect(atStart.after, same(six[1]));
      // 下课瞬间立即排除已结束课程；仍取下一门，而非保留上一门。
      final atEnd = selectWidget2x2(six, first.end);
      expect(atEnd.main, same(six[1]));
      expect(atEnd.after, same(six[2]));
      final last = six.last;
      final beforeEnd = selectWidget2x2(
        six.reversed.toList(),
        last.end.subtract(const Duration(milliseconds: 1)),
      );
      expect(beforeEnd.main, same(last));
      expect(beforeEnd.afterText, '今天最后一节');
      expect(selectWidget2x2(six, last.end).main, isNull);
      expect(selectWidget2x2(const [], at9).after, isNull);
    });

    test('payload：今天各课带生成时刻的 style 标记', () {
      Map<String, dynamic> gen(WidgetPrefs prefs) => jsonDecode(
        jsonEncode(
          buildWidgetPayload(
            now: at9,
            days: 2,
            prefs: prefs,
            classesOn: (d) => d.day == 20 ? six : [],
          ),
        ),
      ) as Map<String, dynamic>;
      List styles(Map<String, dynamic> j) => [
        for (final i in (j['days'] as List).first['items'] as List) i['style'],
      ];
      expect(styles(gen(p2)), ['main', 'main', null, null, null, null]);
      expect(styles(gen(p3)), ['main', 'main', null, null, null, null]);
      expect(styles(gen(offUp)), ['main', null, null, null, null, null]);
    });

    test('节次关：nodes 为空、periodTime 只剩时间段', () {
      final p = buildWidgetPayload(
        now: at9,
        days: 1,
        prefs: const WidgetPrefs(showPeriod: false, courseCount: 3),
        classesOn: (d) => [
          NotifyClass(
            name: '高数',
            location: '教一-101',
            start: DateTime(2026, 10, 20, 10, 10),
            end: DateTime(2026, 10, 20, 11, 50),
            startNode: 3,
            endNode: 4,
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
      final item = ((json['days'] as List).first['items'] as List).single;
      expect(item['nodes'], '');
      expect(item['periodTime'], '10:10-11:50');
      expect(item['location'], '教一-101');
      expect((json['prefs'] as Map)['showPeriod'], false);
      expect((json['prefs'] as Map)['courseCount'], 3);
    });

    test('prefs：教师 / 地点关闭时 payload 置空，开关写入 prefs', () {
      final p = buildWidgetPayload(
        now: at9,
        days: 1,
        prefs: const WidgetPrefs(
          showTeacher: false,
          showLocation: false,
          showCountdown: false,
          showCount: false,
          courseCount: 1,
        ),
        classesOn: (d) => [
          NotifyClass(
            name: '高数',
            location: '教一-101',
            start: DateTime(2026, 10, 20, 10, 10),
            end: DateTime(2026, 10, 20, 11, 50),
            startNode: 3,
            endNode: 4,
            teachers: const ['张三'],
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
      expect(json['prefs'], {
        'showTeacher': false,
        'showLocation': false,
        'showCountdown': false,
        'showCount': false,
        'showPeriod': true,
        'courseCount': 1,
        'slotStyles': ['main'],
      });
      final item = ((json['days'] as List).first['items'] as List).single;
      expect(item['location'], '');
      expect(item['teachers'], isEmpty);
      expect(item['teacherFirst'], '');
      expect(item['periodTime'], '第3-4节 10:10-11:50');
      expect(item['staticBefore'], {'label': '上课', 'time': '10:10'});
      expect(item['staticDuring'], {'label': '下课', 'time': '11:50'});
      // 默认全开。
      final def = buildWidgetPayload(now: at9, days: 1, classesOn: (d) => []);
      expect(def['prefs'], const WidgetPrefs().toJson());
    });

    test('joinDot：只拼接非空字段', () {
      expect(
        joinDot(['教一-101', '张三', '第3-4节 10:10-11:50']),
        '教一-101 · 张三 · 第3-4节 10:10-11:50',
      );
      expect(joinDot(['', '张三', '']), '张三');
      expect(joinDot(['', ' ', '第1节 08:00-08:45']), '第1节 08:00-08:45');
      expect(joinDot(['', '']), '');
    });
  });

  group('小组件之后行与跨日刷新', () {
    final evening = _c('晚课', DateTime(2026, 10, 20, 18), loc: '教一-101');
    final morning = NotifyClass(
      name: '高数',
      location: '明德楼B210',
      start: DateTime(2026, 10, 21, 8),
      end: DateTime(2026, 10, 21, 9, 35),
      barColor: 0xFF12AB34,
      barColorDark: 0xFF89CDAB,
    );
    final late = DateTime(2026, 10, 20, 23, 59);

    test('4×2 之后① 有下一节', () {
      final first = _c('英语', DateTime(2026, 10, 20, 8));
      expect(widgetAfterText([evening, first], first.start), '18:00 晚课');
    });

    test('4×2 之后② 今天最后一节', () {
      expect(widgetAfterText([evening], evening.start), '今天最后一节');
    });

    test('2×2 ① 有下一节', () {
      final first = _c('英语', DateTime(2026, 10, 20, 8));
      final plan = selectWidget2x2([evening, first], first.start);
      expect(plan.main, same(first));
      expect(plan.mainText, '英语');
      expect(plan.main!.barColor, first.barColor);
      expect(plan.after, same(evening));
      expect(plan.after!.barColorDark, evening.barColorDark);
      expect(plan.afterText, '晚课');
      expect(plan.afterDetail, '18:00 教一-101');
    });

    test('2×2 ② 今天最后一节', () {
      final plan = selectWidget2x2([evening], evening.start);
      expect(plan.main, same(evening));
      expect(plan.after, isNull); // 无课程即无竖条。
      expect(plan.afterText, '今天最后一节');
      expect(plan.afterDetail, isEmpty);
    });

    test('2×2 ③ 明天第一节(注入)', () {
      final plan = selectWidget2x2([evening], late, tomorrowFirst: morning);
      expect(plan.main, isNull);
      expect(plan.mainText, '今天的课上完了');
      expect(plan.after, same(morning));
      expect(plan.after!.barColor, morning.barColor);
      expect(plan.after!.barColorDark, morning.barColorDark);
      expect(plan.afterText, '明天 08:00 高数');
      expect(plan.afterDetail, morning.location);
    });

    test('2×2 ④ 明天没课', () {
      final plan = selectWidget2x2([evening], late, tomorrowFirst: null);
      expect(plan.main, isNull);
      expect(plan.mainText, '今天的课上完了');
      expect(plan.after, isNull);
      expect(plan.afterText, '明天没课');
      expect(plan.afterDetail, isEmpty);
    });

    test('4×2 之后③ 明天第一节(注入)', () {
      expect(
        widgetAfterText([evening], late, tomorrowFirst: morning),
        '明天 08:00 高数',
      );
    });

    test('4×2 之后④ 明天没课', () {
      expect(widgetAfterText([evening], late, tomorrowFirst: null), '明天没课');
      final payload = buildWidgetPayload(
        now: late,
        classesOn: (d) => d.day == 20 ? [evening] : [morning],
      );
      expect(payload['tomorrowFirst'], isNull);
      expect(((payload['days'] as List)[1]['items'] as List), isNotEmpty);
    });

    test('payload 注入首节：JSON 往返保留课程与显示开关', () {
      final payload = jsonDecode(
        jsonEncode(
          buildWidgetPayload(
            now: late,
            classesOn: (d) => [],
            tomorrowFirst: NotifyClass(
              name: morning.name,
              location: '教一-101',
              start: morning.start,
              end: morning.end,
              teachers: const ['张老师'],
              startNode: 1,
              endNode: 2,
            ),
            prefs: const WidgetPrefs(showLocation: false, showTeacher: false),
          ),
        ),
      ) as Map;
      final first = payload['tomorrowFirst'] as Map;
      expect(first['name'], '高数');
      expect(first['start'], '2026-10-21T08:00');
      expect(first['end'], '2026-10-21T09:35');
      expect(first['location'], '');
      expect(first['teachers'], isEmpty);
      expect(first['teacherFirst'], '');
      expect(first['nodes'], '第1-2节');
    });

    test('今天还有后续课 / 最后一节：优先今天，忽略明天注入值', () {
      final first = _c('英语', DateTime(2026, 10, 20, 8));
      for (final injected in <NotifyClass?>[null, morning]) {
        expect(
          widgetAfterText(
            [evening, first],
            first.start,
            tomorrowFirst: injected,
          ),
          '18:00 晚课',
        );
        expect(
          widgetAfterText([evening, first], first.end, tomorrowFirst: injected),
          '今天最后一节',
        );
        expect(
          widgetAfterText([evening], evening.start, tomorrowFirst: injected),
          '今天最后一节',
        );
      }
    });

    test('23:59 下一次刷新为次日 00:01（原生排闹钟另加 1 秒）', () {
      expect(
        nextWidgetRefreshAt(late, [evening, morning]),
        DateTime(2026, 10, 21, 0, 1),
      );
      expect(nextWidgetRefreshAt(late, []), DateTime(2026, 10, 21, 0, 1));
    });

    test('刷新候选：上下课及其前 1 小时，严格排除当前边界', () {
      final c = _c('高数', DateTime(2026, 10, 20, 8), minutes: 120);
      final boundaries = [
        DateTime(2026, 10, 20, 7),
        c.start,
        DateTime(2026, 10, 20, 9),
        c.end,
        DateTime(2026, 10, 21, 0, 1),
      ];
      var now = DateTime(2026, 10, 20, 6);
      for (final expected in boundaries) {
        expect(nextWidgetRefreshAt(now, [c], showCountdown: false), expected);
        now = expected;
      }
    });

    test('距上课按课程时刻计算：17:56 到 18:45 为 49 分钟，并在分钟变化后刷新', () {
      final now = DateTime(2026, 10, 28, 17, 56);
      final course = _c('示例晚课', DateTime(2026, 10, 28, 18, 45));
      expect(widgetCountdownMinutes(now, course.start), 49);
      expect(
        widgetCountdownMinutes(
          now.add(const Duration(seconds: 30)),
          course.start,
        ),
        49,
      );
      expect(
        widgetCountdownMinutes(
          now.add(const Duration(minutes: 1)),
          course.start,
        ),
        48,
      );
      expect(widgetCountdownMinutes(course.start, course.start), 0);
      expect(widgetCountdownMinutes(course.end, course.start), 0);
      expect(
        nextWidgetRefreshAt(now, [course]),
        DateTime(2026, 10, 28, 17, 57),
      );
      expect(
        nextWidgetRefreshAt(now, [course], showCountdown: false),
        course.start,
      );
    });

    test('跨零点：23:59 明天早八，00:02 重新选为今天主课', () {
      List<NotifyClass> classesOn(DateTime d) =>
          d.day == 20 ? [evening] : [morning];
      DateTime dateOf(DateTime t) => DateTime(t.year, t.month, t.day);
      final before = classesOn(dateOf(late));
      expect(selectWidgetRows(before, late).main, isNull);
      expect(selectWidget2x2(before, late).main, isNull);
      expect(
        selectWidget2x2(before, late, tomorrowFirst: morning).after,
        same(morning),
      );
      expect(
        widgetAfterText(before, late, tomorrowFirst: morning),
        '明天 08:00 高数',
      );
      final after = DateTime(2026, 10, 21, 0, 2);
      final today = classesOn(dateOf(after));
      expect(selectWidgetRows(today, after).main, same(morning));
      expect(selectWidget2x2(today, after).main, same(morning));
      expect(
        selectWidget2x2(today, morning.end, tomorrowFirst: morning).afterText,
        '明天没课',
      );
      expect(widgetAfterText(today, after), '今天最后一节');
      // 原生同样按日期拒绝旧注入值，避免第二天结束后又把当天课称为明天。
      expect(
        widgetAfterText(today, morning.end, tomorrowFirst: morning),
        '明天没课',
      );
    });
  });

  group('与课表控制器联动', () {
    late Directory tmp;
    final c = TimetableController.instance;
    final termStart = DateTime(2026, 8, 31); // 周一，第 1 周
    final mon2 = DateTime(2026, 9, 7, 6);
    final wed2 = DateTime(2026, 9, 9);

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_notify');
      TimetableStore.debugDirectory = tmp;
      TimetableController.clock = () => mon2;
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchExams = (term) async => null;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: const [
              Course(
                id: 'MATH|01',
                name: '高数',
                source: CourseSource.jwxt,
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: '1111111111111111',
                    location: '教一-101',
                  ),
                ],
              ),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: const TimetableSettings(termCode: '2026-2027-1')
                .copyWith(termStartDate: termStart, termStartFromJwxt: true),
          );
      c.debugReset();
      await c.ensureStarted();
      await c.syncFromJwxt();
    });

    tearDown(() async {
      TimetableStore.debugDirectory = null;
      TimetableController.clock = TimetableApi.shanghaiToday;
      TimetableController.fetchSnapshot = (term, {baseSettings}) =>
          TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
      c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    TimetableNotifyService svc(_FakeBridge b) =>
        TimetableNotifyService(controller: c, bridge: b, clock: () => mon2);

    test('默认关闭：不排提醒', () {
      expect(c.settings.reminderEnabled, isFalse);
      expect(svc(_FakeBridge()).currentPlan(), isEmpty);
    });

    test('开启后按作息开始时间提前提醒，并尊重整天调课', () async {
      final b = _FakeBridge();
      final s = svc(b);
      await s.setReminderEnabled(true);
      await s.setReminderLeadMinutes(20);
      expect(c.settings.reminderLeadMinutes, 15);
      await s.setReminderLeadMinutes(30);
      expect(c.settings.reminderLeadMinutes, 30);
      expect(
        TimetableSettings.fromJson({'reminderLeadMinutes': 20})
            .reminderLeadMinutes,
        15,
      );
      await s.setReminderLeadMinutes(10);
      expect(c.settings.reminderLeadMinutes, 10);
      var plan = s.currentPlan();
      final start = c.periodStart(1)!.split(':').map(int.parse).toList();
      expect(plan.first.classStart, DateTime(2026, 9, 7, start[0], start[1]));
      expect(
        plan.first.fireAt,
        plan.first.classStart.subtract(const Duration(minutes: 10)),
      );
      // 7 天窗口内只有本周一一节。
      expect(plan, hasLength(1));

      // 周一与周三对调：周一的课挪到周三。
      expect(await c.addDaySwap(DateTime(2026, 9, 7), wed2), isNotNull);
      plan = s.currentPlan();
      expect(plan, hasLength(1));
      expect(plan.single.classStart.day, 9);
    });

    test('小组件开关：默认全开，setter 持久化并立即刷新', () async {
      final b = _FakeBridge();
      final s = svc(b);
      expect(s.widgetPrefs(), const WidgetPrefs());
      await s.setWidgetShowTeacher(false);
      await s.setWidgetShowLocation(false);
      await s.setWidgetShowCountdown(false);
      await s.setWidgetShowCount(false);
      await s.setWidgetShowPeriod(false);
      await s.setWidgetCourseCount(3);
      expect(b.widgets, hasLength(6));
      expect(b.widgets.last['prefs'], {
        'showTeacher': false,
        'showLocation': false,
        'showCountdown': false,
        'showCount': false,
        'showPeriod': false,
        'courseCount': 3,
        'slotStyles': ['main', 'main', 'compact'],
      });
      expect(s.widgetPrefs().courseCount, 3);
      await s.setWidgetCourseCount(1);
      expect(c.settings.widgetCourseCount, 1);
      // 1–3 之外回落到 2，不就近取值。
      await s.setWidgetCourseCount(7);
      expect(c.settings.widgetCourseCount, 2);
      await s.setWidgetCourseCount(0);
      expect(c.settings.widgetCourseCount, 2);
      expect(s.widgetShowTeacher, isFalse);
      expect(c.settings.widgetShowCount, isFalse);
      final json = c.settings.toJson();
      expect(json.containsKey('widgetShowUpcoming'), isFalse);
      expect(TimetableSettings.fromJson(json).widgetShowCountdown, isFalse);
    });

    test('widgetCourseCount 读取：1–3 原样，其他回落 2；旧 widgetShowUpcoming 忽略', () {
      TimetableSettings parse(Object? v) => TimetableSettings.fromJson({
        'widgetCourseCount': v,
        'widgetShowUpcoming': false,
      });
      expect(parse(1).widgetCourseCount, 1);
      expect(parse(2).widgetCourseCount, 2);
      expect(parse(3).widgetCourseCount, 3);
      expect(parse(0).widgetCourseCount, 2);
      expect(parse(4).widgetCourseCount, 2);
      expect(parse(-1).widgetCourseCount, 2);
      expect(parse(2.5).widgetCourseCount, 2);
      expect(parse('3').widgetCourseCount, 2);
      expect(parse(null).widgetCourseCount, 2);
      expect(parse(1).toJson().containsKey('widgetShowUpcoming'), isFalse);
    });

    test('首课接口接线：体育显示名、实验体育实际时刻及离线跨日', () {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: const [
            Course(
              id: 'pe',
              name: '体育(3)',
              buildingDisplay: '体育板块场地',
              projectName: '篮球',
              slots: [
                CourseSlot(day: 2, startNode: 9, endNode: 11, weeks: '11'),
              ],
            ),
            Course(
              id: 'lab',
              name: '实验',
              slots: [
                CourseSlot(
                  day: 3,
                  startNode: 1,
                  endNode: 2,
                  weeks: '11',
                  isLab: true,
                ),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          syncedAt: mon2,
          settings: TimetableSettings(
            termStartDate: termStart,
            showTomorrowOnHome: false,
          ),
        ),
      );
      final service = svc(_FakeBridge());
      final payload = service.currentWidgetPayload();
      final first = payload['tomorrowFirst'] as Map;
      expect(first['name'], '体育·篮球');
      expect(first['start'], '2026-09-08T18:45');
      expect(first['end'], '2026-09-08T21:00');
      expect(
        widgetAfterText(
          [],
          mon2,
          tomorrowFirst: service.classesOn(DateTime(2026, 9, 8)).single,
        ),
        '明天 18:45 体育·篮球',
      );
      final days = payload['days'] as List;
      // 原生在 00:01 改读新一天的 tomorrowFirst，无需 Flutter 再生成 payload。
      final next = days[1]['tomorrowFirst'] as Map;
      expect(next['name'], '实验');
      expect(next['start'], '2026-09-09T08:00');
      expect(next['end'], '2026-09-09T09:30');
      expect(days[2]['tomorrowFirst'], isNull);
      expect(
        service.classesOn(DateTime(2026, 9, 9)).single.end,
        DateTime(2026, 9, 9, 9, 30),
      );
    });

    test('小组件 payload 来自控制器', () {
      final p = svc(_FakeBridge()).currentWidgetPayload();
      final today = (p['days'] as List).first as Map;
      expect(today['date'], '2026-09-07');
      expect(today['week'], 2);
      final item = (today['items'] as List).single as Map;
      expect(item['name'], '高数');
      expect(item['nodes'], '第1-2节');
      expect(item['teachers'], isEmpty);
      expect(item['teacherFirst'], '');
      expect(p['state'], 'ok');
    });
  });
}
