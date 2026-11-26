import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_next_day_reminder.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
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
  bool scheduleResult = true;
  bool widgetResult = true;
  bool failNextWidget = false;
  Completer<void>? scheduleGate;
  Completer<void>? scheduleEntered;
  void Function(Map<String, Object?>)? onWidgetUpdate;

  @override
  Future<bool> scheduleReminders(List<Map<String, Object?>> alarms) async {
    if (scheduleEntered != null && !scheduleEntered!.isCompleted) {
      scheduleEntered!.complete();
    }
    if (scheduleGate != null) await scheduleGate!.future;
    scheduled.add(alarms);
    return scheduleResult;
  }

  @override
  Future<void> cancelReminders() async => cancels++;

  @override
  Future<bool> updateWidget(Map<String, Object?> payload) async {
    if (failNextWidget) {
      failNextWidget = false;
      return false;
    }
    final decoded = jsonDecode(jsonEncode(payload)) as Map<String, Object?>;
    widgets.add(decoded);
    onWidgetUpdate?.call(decoded);
    return widgetResult;
  }

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<NotifyPermissionStatus> permissionStatus() async =>
      NotifyPermissionStatus.unsupported;
}

void main() {
  group('小组件原生通道', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('widget_pin_bridge_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = TimetableNotifyBridge(channel: channel);
    setUp(() => TimetableNotifyBridge.debugIsAndroid = true);
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      TimetableNotifyBridge.debugIsAndroid = null;
    });

    test('传递尺寸并区分添加请求、设置跳转与手动指引', () async {
      for (final result in WidgetPinResult.values) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pinWidget');
          expect(call.arguments, {'size': 'square'});
          return result.name;
        });
        expect(await bridge.pinWidget(size: WidgetPinSize.square), result);
      }
    });

    test('4×6 当周课表传递 week 尺寸', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pinWidget');
        expect(call.arguments, {'size': 'week'});
        return WidgetPinResult.requested.name;
      });
      expect(
        await bridge.pinWidget(size: WidgetPinSize.week),
        WidgetPinResult.requested,
      );
    });

    test('原生失败保留方法与原因，且不记录小组件正文', () async {
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      addTearDown(() => AppLog.recordListenerForTesting = null);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'widget_update_failed',
          details: {
            'native_type': 'java.lang.IllegalStateException',
            'message': '合成小组件更新失败',
            'stack': 'SyntheticWidget.update(SyntheticWidget.kt:42)',
            'causes': [
              {'type': 'java.io.IOException', 'message': '合成底层写入失败'},
            ],
          },
        );
      });
      expect(await bridge.updateWidget({'title': '合成课程隐私文本'}), isFalse);
      final failed = records.singleWhere((r) => r['event'] == 'native.failed');
      expect((failed['attrs'] as Map)['endpoint'], 'notify.updateWidget');
      expect((failed['attrs'] as Map)['error_type'], 'PlatformException');
      expect(jsonEncode(records), isNot(contains('合成课程隐私文本')));
      expect(jsonEncode(records), contains('java.lang.IllegalStateException'));
      expect(jsonEncode(records), contains('SyntheticWidget.kt:42'));
      expect(jsonEncode(records), contains('合成底层写入失败'));
    });

    test('原生调度降级通过现有回执保留原因和异常栈', () async {
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      addTearDown(() => AppLog.recordListenerForTesting = null);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'scheduled_count': 1,
          'diagnostics': [
            {
              'reason_code': 'exact_alarm_permission_revoked',
              'stage': 'reminder.schedule',
              'native_type': 'java.lang.SecurityException',
              'stack': 'SyntheticAlarm.schedule(SyntheticAlarm.kt:10)',
            },
          ],
        },
      );
      expect(await bridge.scheduleReminders([]), isTrue);
      final event = records.singleWhere((r) => r['event'] == 'native.degraded');
      expect(event.toString(), contains('exact_alarm_permission_revoked'));
      expect(event.toString(), contains('SyntheticAlarm.kt:10'));
    });

    test('未知结果、通道缺失或平台错误退化为通用手动指引', () async {
      for (final response in [
        'newVendorResult',
        null,
        PlatformException(code: 'notify_failed'),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (response is PlatformException) throw response;
          return response;
        });
        expect(
          await bridge.pinWidget(size: WidgetPinSize.wide),
          WidgetPinResult.manual,
        );
      }
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        await bridge.pinWidget(size: WidgetPinSize.wide),
        WidgetPinResult.manual,
      );
      TimetableNotifyBridge.debugIsAndroid = false;
      expect(
        await bridge.pinWidget(size: WidgetPinSize.wide),
        WidgetPinResult.manual,
      );
    });
  });

  group('桌面快捷方式权限跳转', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('widget_shortcut_settings_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = TimetableNotifyBridge(channel: channel);
    setUp(() => TimetableNotifyBridge.debugIsAndroid = true);
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      TimetableNotifyBridge.debugIsAndroid = null;
    });
    test('确认后的独立方法返回是否打开，通道缺失和平台错误返回失败', () async {
      for (final opened in [true, false]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openWidgetShortcutSettings');
          return opened;
        });
        expect(await bridge.openWidgetShortcutSettings(), opened);
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'notify_failed'),
      );
      expect(await bridge.openWidgetShortcutSettings(), isFalse);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await bridge.openWidgetShortcutSettings(), isFalse);
      TimetableNotifyBridge.debugIsAndroid = false;
      expect(await bridge.openWidgetShortcutSettings(), isFalse);
    });
  });

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
      expect(plan.single.body, '08:00 上课');

      final withLoc = planReminders(
        now: now,
        leadMinutes: 15,
        days: 1,
        classesOn: (d) => d.day == 20
            ? [_c('高数', DateTime(2026, 10, 20, 8), loc: 'A101')]
            : [],
      );
      expect(withLoc.single.body, '08:00 · A101');
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
      expect(plan.single.body, '10:10 · 英语、物理 · A101 / B202');

      final noLoc = planReminders(
        now: now,
        leadMinutes: 10,
        days: 1,
        classesOn: (d) => d.day == 20 ? [_c('英语', s), _c('物理', s)] : [],
      );
      expect(noLoc.single.body, '10:10 · 英语、物理');
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
      expect(json.containsKey('jwxtExpiresAt'), isFalse);
      expect(json.containsKey('hasIndependentLocalData'), isFalse);
      expect(json.containsKey('reason'), isFalse);
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
      expect(item.containsKey('origin'), isFalse);
      expect(item['teachers'], ['张老师', '李老师']);
      expect(item['teacherFirst'], '张老师');
      expect(item['periodTime'], '第3-4节 10:10-11:50');
    });

    test('教师拆分与过滤：中英文逗号去空白、过滤网络教师、空值及 payload 映射', () {
      expect(splitTeachers('张三,李四，王五'), ['张三', '李四', '王五']);
      expect(splitTeachers(' 张三 ， , 李四 ,'), ['张三', '李四']);
      expect(widgetTeachers('张三，李四'), ['张三', '李四']);
      expect(widgetTeachers('张三'), ['张三']);
      expect(widgetTeachers(''), isEmpty);
      expect(widgetTeachers(' , ，'), isEmpty);
      expect(widgetTeachers('网络教师'), isEmpty);
      expect(widgetTeachers('网络教师,张三'), ['张三']);
      expect(widgetTeachers(' 网络教师 ，李四'), ['李四']);

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

    test('2×2 之后行四种状态：有下一节、最后一节、明日首节与明日没课', () {
      final first = _c('英语', DateTime(2026, 10, 20, 8));
      final hasNext = selectWidget2x2([evening, first], first.start);
      expect(hasNext.main, same(first));
      expect(hasNext.mainText, '英语');
      expect(hasNext.main!.barColor, first.barColor);
      expect(hasNext.after, same(evening));
      expect(hasNext.after!.barColorDark, evening.barColorDark);
      expect(hasNext.afterText, '晚课');
      expect(hasNext.afterDetail, '18:00 教一-101');

      final lastClass = selectWidget2x2([evening], evening.start);
      expect(lastClass.main, same(evening));
      expect(lastClass.after, isNull);
      expect(lastClass.afterText, '今天最后一节');
      expect(lastClass.afterDetail, isEmpty);

      final tomorrow = selectWidget2x2([evening], late, tomorrowFirst: morning);
      expect(tomorrow.main, isNull);
      expect(tomorrow.mainText, '今天的课上完了');
      expect(tomorrow.after, same(morning));
      expect(tomorrow.after!.barColor, morning.barColor);
      expect(tomorrow.after!.barColorDark, morning.barColorDark);
      expect(tomorrow.afterText, '明天 08:00 高数');
      expect(tomorrow.afterDetail, morning.location);

      final noneTomorrow = selectWidget2x2(
        [evening],
        late,
        tomorrowFirst: null,
      );
      expect(noneTomorrow.main, isNull);
      expect(noneTomorrow.mainText, '今天的课上完了');
      expect(noneTomorrow.after, isNull);
      expect(noneTomorrow.afterText, '明天没课');
      expect(noneTomorrow.afterDetail, isEmpty);
    });

    test('4×2 之后行：今日优先忽略明日注入，今日结束后显示明日首节或明日没课', () {
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
      expect(
        widgetAfterText([evening], late, tomorrowFirst: morning),
        '明天 08:00 高数',
      );
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
      TimetableController.debugBuildNextDayReminderInBackground = false;
      TimetableController.bindingCheck = () async => false;
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

    test('4×6 周末 payload 只在未单独设置时跟随外观', () async {
      final b = _FakeBridge();
      final s = svc(b);
      Object? weekend(Map<String, Object?> payload) =>
          ((payload['week'] as Map)['prefs'] as Map)['showWeekend'];

      addTearDown(s.dispose);
      await s.ensureStarted();
      expect(weekend(b.widgets.single), isTrue);
      final refresh = Completer<Map<String, Object?>>();
      b.onWidgetUpdate = refresh.complete;
      await c.updateSettings(c.settings.copyWith(showSaturday: false));
      expect(
        weekend(await refresh.future.timeout(const Duration(seconds: 5))),
        isFalse,
      );
      b.onWidgetUpdate = null;
      final savedDefault = await TimetableStore.readRawSettings();
      expect(savedDefault.containsKey('widgetWeekShowWeekend'), isFalse);

      await s.setWeekWidgetShowWeekend(true);
      expect(weekend(b.widgets.last), isTrue);
      final version = c.scheduleVersion;
      await c.updateSettings(c.settings.copyWith(showSunday: false));
      expect(c.scheduleVersion, version);
      final savedOn = await TimetableStore.readSettings();
      expect(savedOn.toJson()['widgetWeekShowWeekend'], isTrue);
      expect(weekend(s.currentWidgetPayload()), isTrue);

      await s.setWeekWidgetShowWeekend(false);
      final versionAfterSwitch = c.scheduleVersion;
      await c.updateSettings(
        c.settings.copyWith(showSaturday: true, showSunday: true),
      );
      expect(c.scheduleVersion, versionAfterSwitch);
      final savedOff = await TimetableStore.readSettings();
      expect(savedOff.toJson()['widgetWeekShowWeekend'], isFalse);
      expect(weekend(b.widgets.last), isFalse);

      await s.dispose();
      c.debugReset();
      await c.ensureStarted();
      expect(weekend(s.currentWidgetPayload()), isFalse);
    });

    test('4×6 设置保存后立即刷新共享 payload 的 week 段', () async {
      await c.updateSettings(c.settings.copyWith(showSunday: false));
      final b = _FakeBridge();
      final s = svc(b);
      final old = s.currentWidgetPayload();
      await s.setWeekWidgetOpacity(60);
      await s.setWeekWidgetSurfaceOpacity(70);
      await s.setWeekWidgetShowWeekend(true);
      expect(b.widgets, hasLength(3));
      Map weekPrefs(Map payload) => (payload['week'] as Map)['prefs'] as Map;
      expect(weekPrefs(b.widgets.first)['opacity'], 60);
      expect(weekPrefs(b.widgets.first)['showWeekend'], isFalse);
      expect(weekPrefs(b.widgets.first)['widgetOpacity'], 100);
      expect(weekPrefs(b.widgets.last)['showWeekend'], isTrue);
      expect(weekPrefs(b.widgets.last)['opacity'], 60);
      expect(weekPrefs(b.widgets.last)['widgetOpacity'], 70);
      expect(c.settings.widgetWeekOpacity, 60);
      expect(c.settings.widgetWeekWidgetOpacity, 70);
      expect(c.settings.widgetWeekShowWeekend, isTrue);
      expect(b.widgets.last['version'], old['version']);
      expect(b.widgets.last['days'], old['days']);
      expect(b.widgets.last['prefs'], old['prefs']);
      await s.setWeekWidgetOpacity(5);
      await s.setWeekWidgetShowWeekend(false);
      expect(c.settings.widgetWeekOpacity, 30);
      expect(weekPrefs(b.widgets.last)['opacity'], 30);
      expect(weekPrefs(b.widgets.last)['widgetOpacity'], 70);
      expect(weekPrefs(b.widgets.last)['showWeekend'], isFalse);

      await s.setWidgetShowLocation(false);
      final payload = b.widgets.last;
      final today = (payload['days'] as List).first as Map;
      final week = ((payload['week'] as Map)['weeks'] as List).first as Map;
      final monday = (week['days'] as List).first as Map;
      expect((payload['prefs'] as Map)['showLocation'], isFalse);
      expect((today['items'] as List).single['location'], isEmpty);
      expect(weekPrefs(payload)['showLocation'], isTrue);
      expect((monday['items'] as List).single['location'], '教一-101');
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

    test('课程类型覆盖同步用于小组件名称与实际结束时间', () {
      const kinds = [CourseKind.standard, CourseKind.lab, CourseKind.pe];
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            Course(
              id: 'pe-overridden',
              name: '体育（3）',
              buildingDisplay: '体育板块场地',
              projectName: '篮球',
              slots: [
                for (final (i, kind) in kinds.indexed)
                  CourseSlot(
                    day: i + 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: '11',
                    kind: kind,
                  ),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: termStart),
        ),
      );
      final service = svc(_FakeBridge());
      for (final (i, kind) in kinds.indexed) {
        final date = DateTime(2026, 9, 7 + i);
        final item = service.classesOn(date).single;
        expect(item.name, kind == CourseKind.pe ? '体育·篮球' : '体育（3）');
        expect(
          item.end,
          DateTime(2026, 9, 7 + i, 9, kind == CourseKind.standard ? 40 : 30),
        );
      }
    });

    List<Map> weekItemsOn(Map<String, Object?> payload, String date) {
      final weeks = (payload['week'] as Map)['weeks'] as List;
      final day = weeks
          .expand((week) => (week['days'] as List).cast<Map>())
          .singleWhere((day) => day['date'] == date);
      return (day['items'] as List).cast<Map>();
    }

    test('小组件 payload 来自控制器并包含 week 段：顶层版本不变，本周与下周各一份', () {
      final p = svc(_FakeBridge()).currentWidgetPayload();
      expect(p['state'], 'ok');
      expect(p['version'], 1);
      final today = (p['days'] as List).first as Map;
      expect(today['date'], '2026-09-07');
      expect(today['week'], 2);
      final todayItem = (today['items'] as List).single as Map;
      expect(todayItem['name'], '高数');
      expect(todayItem['nodes'], '第1-2节');
      expect(todayItem['teachers'], isEmpty);
      expect(todayItem['teacherFirst'], '');

      final week = p['week'] as Map;
      expect((week['prefs'] as Map)['showWeekend'], isTrue);
      expect(week['termStartMissing'], isFalse);
      expect(week['periods'], isNotEmpty);
      final weeks = week['weeks'] as List;
      expect(weeks, hasLength(2));
      expect((weeks.first as Map)['start'], '2026-09-07');
      expect((weeks.last as Map)['start'], '2026-09-14');
      final days = (weeks.first as Map)['days'] as List;
      expect(days, hasLength(7));
      final monday = days.first as Map;
      expect(monday['date'], '2026-09-07');
      final item = (monday['items'] as List).first as Map;
      expect(item['name'], '高数');
      expect(item['nodes'], '第1-2节');
      expect(item['start'], '2026-09-07T08:00');
      expect(item['weekTag'], isNull);
      expect(item['origin'], 'jwxt');
    });

    test('周组件标签按课程性质和单双周生成，不显示周段', () {
      const cases = [
        ('物理实验', CourseKind.standard, '0000011111111', null),
        ('大学物理', CourseKind.lab, '1010101010101', '实验'),
        ('通识课', CourseKind.pe, '0000011111111', '体育'),
        ('线性代数', CourseKind.exam, '0000011111111', '考试'),
        ('高数', CourseKind.standard, '1010101010101', '单周'),
        ('大学英语', CourseKind.standard, '0101010101010', '双周'),
      ];
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            for (final (i, (name, kind, weeks, _)) in cases.indexed)
              Course(
                id: 'course-$i',
                name: name,
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: weeks,
                    kind: kind,
                  ),
                ],
              ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: termStart),
        ),
      );
      final service = TimetableNotifyService(
        controller: c,
        clock: () => DateTime(2026, 10, 12, 6), // 第 7 周周一
      );
      final payload = service.currentWidgetPayload();
      final items = [
        ...weekItemsOn(payload, '2026-10-12'),
        ...weekItemsOn(payload, '2026-10-19'),
      ];
      for (final (name, _, _, tag) in cases) {
        final item = items.firstWhere((item) => item['name'] == name);
        expect(item['weekTag'], tag, reason: name);
      }
    });

    test('无开学日不是无课：只在 week 段明确标记', () {
      c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          syncedAt: mon2,
        ),
      );
      final p = svc(_FakeBridge()).currentWidgetPayload();
      final week = p['week'] as Map;
      expect(week['termStartMissing'], isTrue);
      expect((week['weeks'] as List).first['week'], isNull);
      expect(p.containsKey('termStartMissing'), isFalse);
      expect(p['state'], 'ok');
    });

    test('共享教务缓存带毫秒到期时间，满七天时过期', () {
      final sevenDaysAgo = mon2.subtract(const Duration(days: 7));
      Map<String, Object?> currentPayload(DateTime syncedAt) {
        c.debugSetSnapshot(
          TimetableSnapshot(
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(termStartDate: termStart),
            syncedAt: syncedAt,
          ),
        );
        return svc(_FakeBridge()).currentWidgetPayload();
      }

      final fresh = currentPayload(
        sevenDaysAgo.add(const Duration(milliseconds: 1)),
      );
      final stale = currentPayload(sevenDaysAgo);
      expect(fresh['state'], 'ok');
      expect(fresh['jwxtExpiresAt'], mon2.millisecondsSinceEpoch + 1);
      expect(weekItemsOn(fresh, '2026-09-07'), isEmpty);
      expect(stale['state'], 'needsUpdate');
      expect(stale['reason'], 'jwxtExpired');
      expect(stale['hasCache'], isTrue);
      expect(stale['lastSyncedAt'], sevenDaysAgo.millisecondsSinceEpoch);
      final week = stale['week'] as Map;
      expect(week['termStartMissing'], isFalse);
      expect((week['weeks'] as List).first['start'], '2026-09-07');
    });

    test('小组件按时间混排课程、考试与其他日程，并携带类型', () async {
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'morning-event',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '晨会',
          date: mon2,
          start: const TimeOfDayMinutes(7, 30),
          end: const TimeOfDayMinutes(7, 50),
          location: '社团活动室',
        ),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '高数考试',
          date: mon2,
          start: const TimeOfDayMinutes(10, 0),
          end: const TimeOfDayMinutes(11, 30),
          location: '教二-201',
        ),
      );

      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final today = (payload['days'] as List).first as Map;
      final items = (today['items'] as List).cast<Map>();

      expect(items.map((e) => e['name']), ['晨会', '高数', '高数考试']);
      expect(items.map((e) => e['kind']), ['schedule', 'course', 'exam']);
      expect(items.first['location'], '社团活动室');
      expect(items.first['nodes'], isEmpty);
      expect(items.last['location'], '教二-201');
      final week = (payload['week'] as Map)['weeks'] as List;
      final monday = (week.first['days'] as List).first as Map;
      final weekItems = (monday['items'] as List).cast<Map>();
      expect(
        weekItems.map((item) => item['name']),
        items.map((item) => item['name']),
      );
      expect(
        [weekItems.first['startNode'], weekItems.first['endNode']],
        [0, 0],
      );
      expect([weekItems.last['startNode'], weekItems.last['endNode']], [3, 4]);
      expect(weekItems.map((item) => item['kind']), [
        'schedule',
        'course',
        'exam',
      ]);
      expect(weekItems.first['weekTag'], isNull);
      expect(weekItems.last['weekTag'], isNull);
    });

    test('周组件落格日程携带节次与 schedule 类型，不依赖 weekTag', () async {
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'study-group',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '小组讨论',
          date: mon2,
          start: const TimeOfDayMinutes(13, 45),
          end: const TimeOfDayMinutes(15, 25),
          location: '示例教室 C102',
        ),
      );
      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final item = weekItemsOn(
        payload,
        formatDate(mon2),
      ).singleWhere((item) => item['name'] == '小组讨论');
      expect(item['kind'], 'schedule');
      expect([item['startNode'], item['endNode']], [5, 6]);
      expect(item['weekTag'], isNull);
    });

    test('关闭显示考试只隐藏考试，其他日程仍进入小组件', () async {
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'other',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '开组会',
          date: mon2,
          start: const TimeOfDayMinutes(10, 0),
          end: const TimeOfDayMinutes(11, 0),
        ),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '期中考试',
          date: mon2,
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(15, 30),
        ),
      );
      await c.updateSettings(c.settingsForEditing.copyWith(showExams: false));

      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final today = (payload['days'] as List).first as Map;
      final items = (today['items'] as List).cast<Map>();

      expect(items.map((e) => e['name']), ['高数', '开组会']);
      expect(items.map((e) => e['kind']), ['course', 'schedule']);
    });

    test('显示考试开关关闭时，只有隐藏考试也不会误报有缓存', () async {
      c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          syncedAt: mon2,
          settings: TimetableSettings(
            termStartDate: termStart,
            showExams: false,
          ),
        ),
      );
      await c.replaceJwxtExams([
        ScheduleEvent(
          id: 'hidden-exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.jwxt,
          title: '隐藏考试',
          date: mon2,
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(15, 30),
          courseCode: 'HIDDEN',
        ),
      ]);

      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final today = (payload['days'] as List).first as Map;

      expect(payload['state'], 'ok');
      expect(payload['hasCache'], isTrue);
      expect(today['items'], isEmpty);
    });

    test('明天只有日程时仍注入明天首项', () async {
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'tomorrow-event',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '明天开会',
          date: DateTime(2026, 9, 8),
          start: const TimeOfDayMinutes(9, 15),
          end: const TimeOfDayMinutes(10, 0),
          location: '会议室',
        ),
      );

      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final tomorrowFirst = payload['tomorrowFirst'] as Map;
      final today = (payload['days'] as List).first as Map;

      expect(tomorrowFirst['name'], '明天开会');
      expect(tomorrowFirst['kind'], 'schedule');
      expect(tomorrowFirst['start'], '2026-09-08T09:15');
      expect((today['tomorrowFirst'] as Map)['name'], '明天开会');
    });

    test('没有课程但有可见日程时小组件缓存仍可用', () async {
      c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          syncedAt: mon2,
          settings: TimetableSettings(termStartDate: termStart),
        ),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'only-event',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '唯一日程',
          date: mon2,
          start: const TimeOfDayMinutes(12, 0),
          end: const TimeOfDayMinutes(13, 0),
        ),
      );

      final payload = svc(_FakeBridge()).currentWidgetPayload();
      final today = (payload['days'] as List).first as Map;

      expect(payload['state'], 'ok');
      expect(payload['hasCache'], isTrue);
      expect((today['items'] as List).single['name'], '唯一日程');
    });

    test('未绑定且开学日待定时仍显示本地手动课程与日程；混合课表在教务过期或解绑后退回仅显示本地', () async {
      // 1) 未绑定且开学日待定时，本地手动课与日程仍可正常展示
      await c.handleLogout(clearJwxt: true);
      expect(c.weekPending, isTrue);
      await c.addManualCourse(
        const Course(
          id: 'manual-only',
          name: '本地课程',
          slots: [CourseSlot(day: 1, startNode: 3, endNode: 4, weeks: '11')],
        ),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'local-event',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '本地日程',
          date: mon2,
          start: const TimeOfDayMinutes(12, 0),
          end: const TimeOfDayMinutes(13, 0),
        ),
      );
      final localPayload = svc(_FakeBridge()).currentWidgetPayload();
      final localItems = ((localPayload['days'] as List).first['items'] as List)
          .cast<Map>();
      expect(localPayload['state'], 'ok');
      expect(localPayload['hasCache'], isTrue);
      expect(localItems.map((item) => item['name']), ['本地课程', '本地日程']);
      expect(localItems.map((item) => item['origin']), everyElement('local'));
      expect(localPayload['hasIndependentLocalData'], isTrue);
      expect(localPayload['lastSyncedAt'], isNull);
      expect((localPayload['week'] as Map)['termStartMissing'], isTrue);
      final localWeekItems = weekItemsOn(localPayload, '2026-09-07');
      expect(localWeekItems.map((item) => item['name']), ['本地课程', '本地日程']);
      expect(
        localWeekItems.map((item) => item['origin']),
        everyElement('local'),
      );

      // 2) 混合课表：有效期内合并展示，满 7 天过期或解绑保留缓存时只显示本地
      await c.deleteManualCourse('manual-only');
      await c.deleteScheduleEvent('local-event');
      await c.refreshPortalBound();
      await c.syncFromJwxt();
      final synced = mon2.subtract(const Duration(days: 7));
      final tuesday = DateTime(2026, 9, 8);
      c.debugSetSnapshot(c.snapshot.copyWith(syncedAt: synced));
      await c.addManualCourse(
        const Course(
          id: 'local-tuesday',
          name: '本地编程课',
          slots: [CourseSlot(day: 2, startNode: 5, endNode: 6, weeks: '11')],
        ),
      );
      await c.replaceJwxtExams([
        ScheduleEvent(
          id: 'remote-exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.jwxt,
          title: '教务考试',
          date: tuesday,
          start: const TimeOfDayMinutes(9, 0),
          end: const TimeOfDayMinutes(10, 0),
          courseCode: 'REMOTE',
        ),
      ]);
      var now = mon2.subtract(const Duration(milliseconds: 1));
      final service = TimetableNotifyService(controller: c, clock: () => now);
      final fresh = service.currentWidgetPayload();
      expect(fresh['state'], 'ok');
      expect(fresh['jwxtExpiresAt'], mon2.millisecondsSinceEpoch);
      expect(fresh['lastSyncedAt'], synced.millisecondsSinceEpoch);
      expect((fresh['tomorrowFirst'] as Map)['origin'], 'jwxt');
      final freshDays = fresh['days'] as List;
      expect(freshDays.first['localTomorrowFirst']['name'], '本地编程课');
      expect(weekItemsOn(fresh, '2026-09-07').single['origin'], 'jwxt');
      final tuesdayItems = weekItemsOn(fresh, '2026-09-08');
      expect(tuesdayItems.first['origin'], 'jwxt');
      expect(tuesdayItems.last['origin'], 'local');

      void expectOnlyLocal(Map<String, Object?> payload) {
        expect(payload['state'], 'ok');
        expect(payload['reason'], isNull);
        expect(payload['hasIndependentLocalData'], isTrue);
        final days = payload['days'] as List;
        expect(days.first['items'], isEmpty);
        final tomorrow = payload['tomorrowFirst'] as Map;
        expect(tomorrow['name'], '本地编程课');
        expect(tomorrow['origin'], 'local');
        expect(days.first['tomorrowFirst'], tomorrow);
        expect(weekItemsOn(payload, '2026-09-07'), isEmpty);
        expect(weekItemsOn(payload, '2026-09-08').single['origin'], 'local');
        expect(jsonEncode(payload), isNot(contains('教务考试')));
        expect(jsonEncode(payload), isNot(contains('高数')));
      }

      now = mon2;
      expectOnlyLocal(service.currentWidgetPayload());
      now = mon2.subtract(const Duration(milliseconds: 1));
      await c.handleLogout(clearJwxt: false);
      expectOnlyLocal(service.currentWidgetPayload());
    });

    test('纯教务缓存可用性：空课表/仅有教务考试可用，过期/解绑/清空后分别报对应 reason', () async {
      // 成功同步的空课表和仅有教务考试均为可用缓存
      c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          syncedAt: mon2,
          settings: TimetableSettings(termStartDate: termStart),
        ),
      );
      var payload = svc(_FakeBridge()).currentWidgetPayload();
      expect(payload['state'], 'ok');
      expect(payload['hasCache'], isTrue);
      expect(((payload['days'] as List).first as Map)['items'], isEmpty);

      await c.replaceJwxtExams([
        ScheduleEvent(
          id: 'jwxt-exam',
          kind: ScheduleKind.exam,
          source: ScheduleSource.jwxt,
          title: '教务考试',
          date: mon2,
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(15, 30),
          location: '考场101',
          courseCode: 'EXAM001',
        ),
      ]);
      payload = svc(_FakeBridge()).currentWidgetPayload();
      final examItem =
          (((payload['days'] as List).first as Map)['items'] as List).single
              as Map;
      expect(payload['state'], 'ok');
      expect(payload['hasCache'], isTrue);
      expect(examItem['name'], '教务考试');
      expect(examItem['kind'], 'exam');

      // 过期 / 解绑 / 清空后不可用
      var now = mon2.add(const Duration(days: 7));
      final service = TimetableNotifyService(controller: c, clock: () => now);
      void expectUnavailable(String reason) {
        final p = service.currentWidgetPayload();
        expect(p['state'], 'needsUpdate');
        expect(p['reason'], reason);
        expect(p['hasIndependentLocalData'], isFalse);
        expect(p['tomorrowFirst'], isNull);
        expect(
          (p['days'] as List).map((day) => day['items']),
          everyElement(isEmpty),
        );
      }

      expectUnavailable('jwxtExpired');
      now = mon2;
      expect(service.currentWidgetPayload()['state'], 'ok');
      await c.handleLogout(clearJwxt: false);
      expectUnavailable('jwxtUnbound');
      await c.handleLogout(clearJwxt: true);
      expectUnavailable('noSchedule');
    });

    test('考试与其他日程不进入上课提醒计划', () async {
      await c.updateSettings(
        c.settingsForEditing.copyWith(reminderEnabled: true),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'event-before-class',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '课前日程',
          date: mon2,
          start: const TimeOfDayMinutes(7, 30),
          end: const TimeOfDayMinutes(7, 50),
        ),
      );
      await c.addScheduleEvent(
        ScheduleEvent(
          id: 'exam-after-class',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '课后考试',
          date: mon2,
          start: const TimeOfDayMinutes(10, 0),
          end: const TimeOfDayMinutes(11, 0),
        ),
      );

      final plan = svc(_FakeBridge()).currentPlan();

      expect(plan, hasLength(1));
      expect(plan.single.names, ['高数']);
    });

    test(
      'reschedule 在 scheduleReminders 或 updateWidget 返回 false 时不缓存指纹并重试',
      () async {
        final b = _FakeBridge();
        final s = svc(b);
        addTearDown(s.dispose);

        // 1) scheduleReminders 返回 false：不写入指纹，下次调用重试。
        b.scheduleResult = false;
        await s.reschedule();
        expect(b.scheduled, hasLength(1));
        expect(b.widgets, hasLength(1));

        b.scheduleResult = true;
        await s.reschedule();
        expect(b.scheduled, hasLength(2));
        expect(b.widgets, hasLength(2));

        // 2) 两次均成功后命中指纹去重。
        await s.reschedule();
        expect(b.scheduled, hasLength(2));
        expect(b.widgets, hasLength(2));

        // 3) 条件变化后 updateWidget 返回 false：同样不写入指纹，下次重试。
        await c.updateSettings(
          c.settingsForEditing.copyWith(reminderEnabled: true),
        );
        b.widgetResult = false;
        await s.reschedule();
        expect(b.scheduled, hasLength(3));
        expect(b.widgets, hasLength(3));

        b.widgetResult = true;
        await s.reschedule();
        expect(b.scheduled, hasLength(4));
        expect(b.widgets, hasLength(4));

        await s.reschedule();
        expect(b.scheduled, hasLength(4));
        expect(b.widgets, hasLength(4));
      },
    );

    test('导入主课表无门户绑定也可生成上课提醒，且解绑门户不取消其提醒', () async {
      TimetableController.bindingCheck = () async => false;
      await c.handleLogout(clearJwxt: true);
      expect(c.portalBound, isFalse);

      final imported = await c.importWakeupSchedule(
        WakeupImportResult(
          defaultName: '好友导入课表',
          snapshot: TimetableSnapshot(
            courses: const [
              Course(
                id: 'WAKEUP|01',
                name: '线性代数',
                source: CourseSource.manual,
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 3,
                    endNode: 4,
                    weeks: '1111111111111111',
                    location: '教二-202',
                  ),
                ],
              ),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termCode: '2026-2027-1',
              termStartDate: termStart,
              termStartFromJwxt: true,
            ),
            syncedAt: termStart,
          ),
          courseCount: 1,
          slotCount: 1,
          exams: [
            ScheduleEvent(
              id: 'imported-exam',
              kind: ScheduleKind.exam,
              source: ScheduleSource.jwxt,
              title: '导入考试',
              date: mon2,
              start: const TimeOfDayMinutes(14, 0),
              end: const TimeOfDayMinutes(15, 0),
            ),
          ],
        ),
        name: '好友导入课表',
        setAsPrimary: true,
      );
      await c.updateSettings(
        c.settingsForEditing.copyWith(reminderEnabled: true),
      );

      final b = _FakeBridge();
      final s = svc(b);
      addTearDown(s.dispose);
      expect(imported.syncedAt, isNull);
      expect(c.snapshot.syncedAt, isNull);
      expect(c.portalBound, isFalse);

      void expectImportedWidget(
        TimetableNotifyService service,
        List<String> names,
      ) {
        final payload = service.currentWidgetPayload();
        expect(payload['state'], 'ok');
        expect(payload['hasIndependentLocalData'], isTrue);
        expect(payload['lastSyncedAt'], isNull);
        expect(payload.containsKey('jwxtExpiresAt'), isFalse);
        final items = ((payload['days'] as List).first['items'] as List)
            .cast<Map>();
        expect(items.map((item) => item['name']), names);
        expect(items.map((item) => item['origin']), everyElement('local'));
        final weekItems = weekItemsOn(
          payload,
          (payload['days'] as List).first['date'] as String,
        );
        expect(weekItems.map((item) => item['name']), names);
        expect(weekItems.map((item) => item['origin']), everyElement('local'));
      }

      expectImportedWidget(s, ['线性代数', '导入考试']);
      expect(c.hasReminderScheduleSource, isTrue);

      final planBeforeUnbind = s.currentPlan();
      expect(planBeforeUnbind, hasLength(1));
      expect(planBeforeUnbind.single.names, ['线性代数']);

      // 解绑门户时主课表为导入课表：不立即取消提醒，且计划仍保留。
      await c.handleLogout(clearJwxt: true);
      await pumpEventQueue();
      expect(b.cancels, 0);
      expect(c.hasReminderScheduleSource, isTrue);
      final planAfterUnbind = s.currentPlan();
      expect(planAfterUnbind, hasLength(1));
      expect(planAfterUnbind.single.names, ['线性代数']);
      expectImportedWidget(s, ['线性代数', '导入考试']);

      // 模拟旧版本已经把导入时间写入快照，重启后不应当作过期的教务缓存。
      final legacySnapshot = c.snapshot.copyWith(syncedAt: termStart);
      await TimetableStore.withScheduleScope(
        imported.id,
        () => TimetableStore.saveSnapshot(legacySnapshot),
      );
      c.debugReset();
      await c.ensureStarted();
      expect(c.primaryScheduleId, imported.id);
      expect(c.snapshot.syncedAt, isNull);
      expect(c.portalBound, isFalse);
      final later = TimetableNotifyService(
        controller: c,
        clock: () => mon2.add(const Duration(days: 7)),
      );
      expectImportedWidget(later, ['线性代数']);
    });

    test('跨自然日与失败恢复后重排；同日权限跳转清指纹缓存', () async {
      var now = DateTime(2026, 9, 7, 8);
      final b = _FakeBridge();
      final s = TimetableNotifyService(
        controller: c,
        bridge: b,
        clock: () => now,
      );
      addTearDown(s.dispose);

      await s.reschedule();
      await s.reschedule();
      expect(b.scheduled, hasLength(1));
      expect(b.widgets, hasLength(1));

      now = DateTime(2026, 9, 8, 8);
      await s.reschedule();
      expect(b.scheduled, hasLength(2));
      expect(b.widgets, hasLength(2));

      now = DateTime(2026, 9, 9, 8);
      b.failNextWidget = true;
      await s.reschedule();
      expect(b.scheduled, hasLength(3));
      expect(b.widgets, hasLength(2));

      await s.reschedule();
      expect(b.scheduled, hasLength(4));
      expect(b.widgets, hasLength(3));

      await s.openExactAlarmSettings();
      await s.reschedule();
      expect(b.scheduled, hasLength(5));
      expect(b.widgets, hasLength(4));

      await s.openNotificationSettings();
      await s.reschedule();
      expect(b.scheduled, hasLength(6));
      expect(b.widgets, hasLength(5));
    });

    test('同日跨过 syncedAt + 7 天过期边界时重排并更新小组件为 needsUpdate', () async {
      final syncedAt = DateTime(2026, 9, 7, 8);
      c.debugSetSnapshot(c.snapshot.copyWith(syncedAt: syncedAt));
      await c.refreshPortalBound();

      var now = DateTime(2026, 9, 14, 7, 59);
      final b = _FakeBridge();
      final s = TimetableNotifyService(
        controller: c,
        bridge: b,
        clock: () => now,
      );
      addTearDown(s.dispose);

      await s.reschedule();
      expect(b.widgets, hasLength(1));
      expect(b.widgets.last['state'], 'ok');

      now = DateTime(2026, 9, 14, 8, 1);
      await s.reschedule();
      expect(b.scheduled, hasLength(2));
      expect(b.widgets, hasLength(2));
      expect(b.widgets.last['state'], 'needsUpdate');
    });

    test('并发 reschedule 在途发生设置变更时，不会写入过时指纹覆盖新状态', () async {
      final b = _FakeBridge();
      final gate = Completer<void>();
      final entered = Completer<void>();
      b.scheduleGate = gate;
      b.scheduleEntered = entered;

      final s = svc(b);
      addTearDown(s.dispose);

      final first = s.reschedule();
      await entered.future;

      await c.updateSettings(
        c.settingsForEditing.copyWith(reminderEnabled: true),
      );
      gate.complete();
      b.scheduleGate = null;
      b.scheduleEntered = null;
      await first;

      await s.reschedule();
      expect(b.scheduled, hasLength(2));
      expect(b.widgets, hasLength(2));
    });

    test('开启后台 Isolate 计算明日提醒时生成 400 天且不扰动缓存', () async {
      const channel = MethodChannel('nuist/timetable_next_day');
      Map<Object?, Object?>? sent;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'update') {
              sent = call.arguments as Map<Object?, Object?>;
            }
            return {'diagnostics': <Object?>[]};
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      TimetableController.debugBuildNextDayReminderInBackground = true;
      await c.refreshPortalBound();
      final dayCells = c.cellsForDay(2, 1);

      await c.updateNextDayReminder();
      expect(sent?['enabled'], isTrue);
      final payloads = sent?['payloads'] as Map<Object?, Object?>;
      expect(payloads, hasLength(400));
      expect(c.cellsForDay(2, 1), same(dayCells));
    });
  });

  group('明日提醒与 400 天冷启动排程', () {
    TodayCourseItem reminderCourse(
      int node, {
      String name = '测试课程',
      String location = '',
    }) => TodayCourseItem(
      course: Course(id: 'mock-$node', name: name),
      slot: CourseSlot(
        day: 2,
        startNode: node,
        endNode: node + 1,
        weeks: '1',
        location: location,
      ),
      status: TodayCourseStatus.upcoming,
    );

    const reminderPeriods = [
      PeriodTime(node: 1, start: '08:00', end: '08:45'),
      PeriodTime(node: 3, start: '10:10', end: '10:55'),
      PeriodTime(node: 5, start: '13:45', end: '14:30'),
      PeriodTime(node: 7, start: '15:25', end: '16:10'),
    ];
    final weekday = DateTime(2026, 10, 27);
    final saturday = DateTime(2026, 10, 31);

    NextDayReminderPayload? payload(
      List<TodayCourseItem> courses, {
      DateTime? date,
      bool loggedIn = true,
      bool hasCache = true,
      bool outsideTerm = false,
    }) => buildNextDayReminder(
      tomorrow: date ?? weekday,
      courses: courses,
      periods: reminderPeriods,
      loggedIn: loggedIn,
      hasCache: hasCache,
      outsideTerm: outsideTerm,
    );

    test('冷启动本地课程先就绪，400天排程与未回执原生任务不阻塞数据入口', () async {
      final c = TimetableController.instance;
      final tmp = await Directory.systemTemp.createTemp('tt_start_ready');
      final originalBinding = TimetableController.bindingCheck;
      final originalClock = TimetableController.syncClock;
      const channel = MethodChannel('nuist/timetable_next_day');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeDone = Completer<void>();
      var channelCalls = 0;
      final readyCalls = <int>[];
      messenger.setMockMethodCallHandler(channel, (_) async {
        channelCalls++;
        await nativeDone.future;
        return {'diagnostics': <Object?>[]};
      });
      void ready() {
        if (c.hasCourses) readyCalls.add(channelCalls);
      }

      addTearDown(() async {
        c.removeListener(ready);
        c.debugReset();
        if (!nativeDone.isCompleted) nativeDone.complete();
        messenger.setMockMethodCallHandler(channel, null);
        TimetableController.bindingCheck = originalBinding;
        TimetableController.syncClock = originalClock;
        TimetableStore.debugDirectory = null;
        await tmp.delete(recursive: true);
      });
      TimetableStore.debugDirectory = tmp;
      TimetableController.bindingCheck = () async => true;
      TimetableController.syncClock = () => DateTime(2026, 8, 31);
      c.debugReset();
      expect(c.isInitialized, isFalse);
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(
          courses: [
            Course(
              id: 'local',
              name: '本地合成课',
              slots: [
                CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
          syncedAt: DateTime(2026, 8, 31),
        ),
      );
      c.addListener(ready);
      await c.ensureStarted();
      expect(c.isInitialized, isTrue);
      expect(c.hasCourses, isTrue);
      expect(readyCalls, [0]);
      expect(channelCalls, 0);
      await c.updateNextDayReminder();
      expect(channelCalls, 1);
      expect(nativeDone.isCompleted, isFalse);
      nativeDone.complete();
      await pumpEventQueue();
      await c.updateNextDayReminder();
      expect(channelCalls, 1);
    });

    test('启动未完成时保持未初始化，绑定准备失败不会把冷数据当成可直接展示', () async {
      final c = TimetableController.instance;
      final tmp = await Directory.systemTemp.createTemp('tt_init_gate');
      final originalBinding = TimetableController.bindingCheck;
      final reached = Completer<void>();
      final gate = Completer<bool>();
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
      TimetableController.bindingCheck = () {
        reached.complete();
        return gate.future;
      };
      addTearDown(() async {
        c.debugReset();
        TimetableController.bindingCheck = originalBinding;
        TimetableStore.debugDirectory = null;
        if (!gate.isCompleted) gate.complete(false);
        await tmp.delete(recursive: true);
      });
      final startup = c.ensureStarted();
      final failed = expectLater(startup, throwsA(isA<StateError>()));
      await reached.future;
      expect(c.isInitialized, isFalse);
      gate.completeError(StateError('合成绑定读取失败'));
      await failed;
      expect(c.isInitialized, isFalse);
      TimetableController.bindingCheck = () async => false;
      await c.ensureStarted();
      expect(c.isInitialized, isTrue);
      c.debugReset();
      expect(c.isInitialized, isFalse);
    });

    test('明日提醒设置默认值、JSON/偏好合并及 21:00–23:30 档位校验', () {
      for (final s in [
        const TimetableSettings(),
        TimetableSettings.fromJson({}),
      ]) {
        expect(s.nextDayReminderEnabled, isTrue);
        expect(s.nextDayReminderMinute, 1320);
        expect(s.reminderEnabled, isFalse);
      }

      final s = const TimetableSettings().copyWith(
        nextDayReminderEnabled: false,
        nextDayReminderMinute: 1410,
        reminderEnabled: true,
      );
      final decoded = TimetableSettings.fromJson(s.toJson());
      expect(decoded.toJson(), s.toJson());
      final merged = const TimetableSettings(termCode: 'mock')
          .withDisplayPrefsFrom(decoded);
      expect(merged.termCode, 'mock');
      expect(merged.nextDayReminderEnabled, isFalse);
      expect(merged.nextDayReminderMinute, 1410);
      expect(merged.reminderEnabled, isTrue);

      for (final v in TimetableSettings.nextDayReminderOptions) {
        expect(
          TimetableSettings.fromJson({'nextDayReminderMinute': v})
              .nextDayReminderMinute,
          v,
        );
      }
      for (final v in [null, '22:00', 1259, 1261, 1440, 1320.5]) {
        expect(
          TimetableSettings.fromJson({'nextDayReminderMinute': v})
              .nextDayReminderMinute,
          1320,
        );
      }
    });

    test('明日提醒空态、周末与假期文案（不含冗余页脚与暖心文案）', () {
      expect(payload([], loggedIn: false), isNull);
      expect(payload([], hasCache: false), isNull);
      expect(payload([], hasCache: false, outsideTerm: true), isNull);

      final empty = payload([])!;
      expect(empty.title, '明天没课');
      expect(empty.body, '好好休息');

      final weekendEmpty = payload([], date: saturday)!;
      expect(weekendEmpty.title, '周末没课');

      final weekendSingle = payload([reminderCourse(3)], date: saturday)!;
      expect(weekendSingle.title, '周末有课');
      expect(weekendSingle.body, '10:10 · 测试课程');
      expect(
        payload([reminderCourse(3), reminderCourse(7)], date: saturday)!.body,
        '首节 10:10 · 测试课程；还有 1 节',
      );

      final holiday = payload([], outsideTerm: true)!;
      expect(holiday.title, '明天没课');
      expect(holiday.body, '假期模式');

      for (final p in [empty, weekendEmpty, weekendSingle, holiday]) {
        expect(p.title.runes.length, lessThanOrEqualTo(8));
        expect(p.warmLine, isNull);
        expect(p.toJson().containsKey('footer'), isFalse);
        expect(p.toJson().containsKey('warmLine'), isFalse);
      }
    });

    test('明日提醒早八、非早八首节、多门课排序与正文格式', () {
      final early = payload([reminderCourse(1, location: '测试教室')])!;
      expect(early.title, '明天早八');
      expect(early.body, '第1–2节 · 测试课程 · 测试教室');
      expect(payload([reminderCourse(2)])!.title, '明天早八');

      for (final node in [3, 5, 7]) {
        final p = payload([reminderCourse(node)])!;
        expect(p.title, '明天第$node节开始');
        expect(
          p.body,
          '${reminderPeriods.firstWhere((p) => p.node == node).start} · 测试课程',
        );
        expect(p.warmLine, isNull);
      }
      expect(payload([reminderCourse(9)])!.body, '第9节 · 测试课程');

      final multiEarly = payload([
        reminderCourse(7),
        reminderCourse(1, name: '第一门'),
      ])!;
      expect(multiEarly.title, '明天早八');
      expect(multiEarly.body, '第1–2节 · 第一门；还有 1 节');
      expect(multiEarly.toJson().containsKey('footer'), isFalse);
      expect(multiEarly.toJson().containsKey('warmLine'), isFalse);

      final multiEarlyWithLoc = payload([
        reminderCourse(5),
        reminderCourse(1, location: '测试教室'),
      ])!;
      expect(multiEarlyWithLoc.title, '明天早八');
      expect(multiEarlyWithLoc.body, '第1–2节 · 测试课程 · 测试教室；还有 1 节');

      final multiNonEarly = payload([reminderCourse(7), reminderCourse(3)])!;
      expect(multiNonEarly.title, '明天有 2 节课');
      expect(multiNonEarly.body, '首节 10:10 · 测试课程；还有 1 节');
      expect(multiNonEarly.title.runes.length, lessThanOrEqualTo(8));
    });

    test('明日提醒体育项目按课程类型显示，长课名截断且折叠换行', () {
      final item = reminderCourse(3, name: '体育（3）');
      final pe = item.course.copyWith(projectName: '射箭');
      final named = TodayCourseItem(
        course: pe,
        slot: item.slot,
        status: item.status,
      );
      expect(payload([named])!.body, '10:10 · 体育·射箭');
      expect(payload([item])!.body, '10:10 · 体育（3）');
      expect(pe.name, '体育（3）');

      for (final kind in CourseKind.values) {
        final changed = TodayCourseItem(
          course: item.course.copyWith(projectName: '篮球'),
          slot: item.slot.copyWith(kind: kind),
          status: item.status,
        );
        expect(
          payload([changed])!.body,
          kind == CourseKind.pe ? '10:10 · 体育·篮球' : '10:10 · 体育（3）',
        );
      }

      final longLine = payload([
        reminderCourse(3, name: '${'长' * 30}\n课程', location: '测试\n教室'),
      ])!;
      expect(longLine.body, contains('…'));
      expect(longLine.body, isNot(contains('\n')));
    });

    test('所选时间起至23:59补推，同一自然日去重，午夜不补昨天', () {
      bool due(
        DateTime now, {
        String? last,
        bool enabled = true,
        int minute = 1320,
      }) => nextDayReminderDue(
        now: now,
        enabled: enabled,
        minuteOfDay: minute,
        lastEveNotifyDate: last,
      );
      expect(due(DateTime(2026, 10, 27, 21, 59)), isFalse);
      expect(due(DateTime(2026, 10, 27, 22)), isTrue);
      expect(due(DateTime(2026, 10, 27, 23, 59, 59)), isTrue);
      expect(due(DateTime(2026, 10, 27, 23), last: '2026-10-27'), isFalse);
      expect(due(DateTime(2026, 10, 27, 23), enabled: false), isFalse);
      expect(due(DateTime(2026, 10, 28), last: '2026-10-27'), isFalse);
      expect(due(DateTime(2026, 10, 28, 22), last: '2026-10-27'), isTrue);
      expect(due(DateTime(2026, 10, 27, 21), minute: 1260), isTrue);
      expect(nextDayReminderDateKey(DateTime(2026, 1, 2, 23)), '2026-01-02');
    });

    test('400 天提醒保留学期末调课，假期不查询课程或挤掉近期网格缓存', () async {
      final c = TimetableController.instance;
      final tmp = await Directory.systemTemp.createTemp('tt_reminder');
      final originalBindingCheck = TimetableController.bindingCheck;
      final originalClock = TimetableController.syncClock;
      const channel = MethodChannel('nuist/timetable_next_day');
      Map<Object?, Object?>? configuration;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'update') {
              configuration = call.arguments as Map<Object?, Object?>;
            }
            return null;
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TimetableController.bindingCheck = originalBindingCheck;
        TimetableController.syncClock = originalClock;
        TimetableStore.debugDirectory = null;
        c.debugReset();
        await tmp.delete(recursive: true);
      });
      TimetableStore.debugDirectory = tmp;
      TimetableController.bindingCheck = () async => true;
      TimetableController.syncClock = () => DateTime(2027, 1, 16);
      c.debugReset();
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            Course(
              id: 'reminder-course',
              name: '调课后的课程',
              slots: [
                CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
      );
      await c.addDaySwap(DateTime(2027, 1, 11), DateTime(2027, 1, 17));
      final lastDayCells = c.cellsForDay(20, 7);
      expect(lastDayCells.single.course.name, '调课后的课程');
      await c.refreshPortalBound();
      await c.updateNextDayReminder();
      expect(configuration?['enabled'], isTrue);
      final payloads = configuration!['payloads'] as Map<Object?, Object?>;
      expect(payloads.length, 400);
      final lastDay = payloads['2027-01-16'] as Map<Object?, Object?>;
      expect(lastDay['title'], '周末有课');
      expect(lastDay['body'], contains('调课后的课程'));
      final holiday = payloads['2027-01-17'] as Map<Object?, Object?>;
      expect(holiday['title'], '明天没课');
      expect(holiday['body'], '假期模式');
      expect(c.cellsForDay(20, 7), same(lastDayCells));
    });

    test('提醒排程分批让出 UI、合并变更并保留缓存，次日和关闭及时更新', () async {
      final c = TimetableController.instance;
      final tmp = await Directory.systemTemp.createTemp('tt_reminder_batch');
      final originalBindingCheck = TimetableController.bindingCheck;
      final originalClock = TimetableController.syncClock;
      var now = DateTime(2026, 8, 31);
      const channel = MethodChannel('nuist/timetable_next_day');
      final configurations = <Map<Object?, Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'update') {
          configurations.add(call.arguments as Map<Object?, Object?>);
        }
        return {'diagnostics': <Object?>[]};
      });
      addTearDown(() async {
        c.debugReset();
        messenger.setMockMethodCallHandler(channel, null);
        TimetableController.bindingCheck = originalBindingCheck;
        TimetableController.syncClock = originalClock;
        TimetableStore.debugDirectory = null;
        await tmp.delete(recursive: true);
      });
      TimetableStore.debugDirectory = tmp;
      TimetableController.bindingCheck = () async => true;
      TimetableController.syncClock = () => now;
      c.debugReset();
      TimetableSnapshot snapshot(String name) => TimetableSnapshot(
        courses: [
          Course(
            id: 'batch-course',
            name: name,
            slots: [
              CourseSlot(day: 2, startNode: 1, endNode: 2, weeks: '1' * 20),
            ],
          ),
        ],
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: now),
      );
      c.debugSetSnapshot(snapshot('更新前的课程'));
      await c.refreshPortalBound();
      final initial = c.updateNextDayReminder();
      expect(c.updateNextDayReminder(), same(initial));
      var yielded = false;
      await Future<void>.delayed(Duration.zero, () {
        yielded = true;
        c.debugSetSnapshot(snapshot('更新后的课程'));
      });
      await initial;
      await pumpEventQueue();
      expect(yielded, isTrue);
      expect(configurations, hasLength(1));
      final payloads = configurations.single['payloads'] as Map;
      expect(payloads, hasLength(400));
      expect((payloads['2026-08-31'] as Map)['body'], contains('更新后的课程'));
      final visibleCells = c.cellsForDay(1, 2);
      await c.updateNextDayReminder();
      await c.updateSettings(c.settingsForEditing.copyWith(showTeacher: false));
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations.last['payloads'], equals(payloads));
      expect(configurations, hasLength(1));
      expect(c.cellsForDay(1, 2), same(visibleCells));

      now = DateTime(2026, 9, 1);
      final beforeDateChange = configurations.length;
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations, hasLength(beforeDateChange + 1));
      expect((configurations.last['payloads'] as Map).keys.first, '2026-09-01');
      expect(c.cellsForDay(1, 2), same(visibleCells));

      final beforeDisable = configurations.length;
      await c.updateSettings(
        c.settingsForEditing.copyWith(nextDayReminderEnabled: false),
      );
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations, hasLength(beforeDisable + 1));
      expect(configurations.last['enabled'], isFalse);
      expect(configurations.last['payloads'], isEmpty);
    });

    test('提醒原生失败后可重试，成功后相同配置不再重复发送', () async {
      final c = TimetableController.instance;
      const channel = MethodChannel('nuist/timetable_next_day');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        if (calls == 1) {
          throw PlatformException(code: 'storage', message: '合成保存失败');
        }
        return {'diagnostics': <Object?>[]};
      });
      addTearDown(() {
        c.debugReset();
        messenger.setMockMethodCallHandler(channel, null);
      });
      c.debugReset();
      c.debugSetSnapshot(const TimetableSnapshot());
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(calls, 1);
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(calls, 2);
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(calls, 2);
    });

    test('修改 settings.maxWeeks 会失效 400 天明日提醒缓存并重算', () async {
      final c = TimetableController.instance;
      final tmp = await Directory.systemTemp.createTemp('tt_reminder_maxweeks');
      final originalBindingCheck = TimetableController.bindingCheck;
      final originalClock = TimetableController.syncClock;
      const channel = MethodChannel('nuist/timetable_next_day');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final configurations = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'update') {
          configurations.add(call.arguments as Map<Object?, Object?>);
        }
        return {'diagnostics': <Object?>[]};
      });
      addTearDown(() async {
        c.debugReset();
        messenger.setMockMethodCallHandler(channel, null);
        TimetableController.bindingCheck = originalBindingCheck;
        TimetableController.syncClock = originalClock;
        TimetableStore.debugDirectory = null;
        await tmp.delete(recursive: true);
      });
      TimetableStore.debugDirectory = tmp;
      TimetableController.bindingCheck = () async => true;
      TimetableController.syncClock = () => DateTime(2027, 1, 16);
      c.debugReset();
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            Course(
              id: 'week21-course',
              name: '第21周课程',
              slots: [
                CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 22),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 8, 31),
            maxWeeks: 20,
          ),
        ),
      );
      await c.refreshPortalBound();
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations, hasLength(1));

      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations, hasLength(1));

      await c.updateSettings(c.settingsForEditing.copyWith(maxWeeks: 22));
      await c.updateNextDayReminder();
      await pumpEventQueue();
      expect(configurations, hasLength(2));
    });
  });
}
