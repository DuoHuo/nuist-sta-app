import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_layout.dart';

void main() {
  group('v0.4 设置默认值与宽松读取', () {
    test('默认值（§13.3/§13.6）', () {
      const s = TimetableSettings();
      expect(s.showLocation, isTrue);
      expect(s.showTeacher, isFalse);
      expect(s.fontScale, CellFontScale.standard);
      expect(s.fontScale.factor, 1.0);
      expect(s.cellOpacity, 100);
      expect(s.paletteScheme, 'A');
      expect(s.weekStartsSunday, isFalse);
      expect(s.showTomorrowOnHome, isTrue);
      expect(s.reminderEnabled, isFalse);
      expect(s.reminderLeadMinutes, 15);
      final r = TimetableSettings.fromJson(const {});
      expect(r.toJson(), s.toJson());
    });

    test('不透明度钳到 30–100 并取整；类型不对 → 100', () {
      int f(Object? v) => TimetableSettings.sanitizeOpacity(v);
      expect(f(25), 30);
      expect(f(0), 30);
      expect(f(150), 100);
      expect(f(55.4), 55);
      expect(f(55.5), 56);
      expect(f(70), 70);
      expect(f('80'), 100);
      expect(f(null), 100);
      expect(f(double.nan), 100);
      expect(f(double.infinity), 100);
    });

    test('headerTextSize / showPeriodTimes：缺省与钳制', () {
      expect(TimetableSettings().headerTextSize, 11);
      expect(TimetableSettings().showPeriodTimes, isTrue);
      expect(TimetableSettings.sanitizeHeaderTextSize(null), 11);
      expect(TimetableSettings.sanitizeHeaderTextSize(9), 10);
      expect(TimetableSettings.sanitizeHeaderTextSize(15), 14);
      expect(TimetableSettings.sanitizeHeaderTextSize(12.4), 12.4);
      expect(
        TimetableSettings.fromJson({'headerTextSize': 13}).headerTextSize,
        13,
      );
      expect(
        TimetableSettings.fromJson({'showPeriodTimes': false}).showPeriodTimes,
        isFalse,
      );
      expect(TimetableSettings.fromJson(const {}).showPeriodTimes, isTrue);
      final round = TimetableSettings(
        headerTextSize: 12,
        showPeriodTimes: false,
      );
      expect(TimetableSettings.fromJson(round.toJson()).headerTextSize, 12);
      expect(
        TimetableSettings.fromJson(round.toJson()).showPeriodTimes,
        isFalse,
      );
    });

    test('homeMaxItems：缺省/非法回落 2，1–4 保留', () {
      expect(TimetableSettings().homeMaxItems, 2);
      expect(TimetableSettings.sanitizeHomeMaxItems(null), 2);
      expect(TimetableSettings.sanitizeHomeMaxItems('x'), 2);
      expect(TimetableSettings.sanitizeHomeMaxItems(0), 2);
      expect(TimetableSettings.sanitizeHomeMaxItems(5), 2);
      expect(TimetableSettings.sanitizeHomeMaxItems(1.2), 1);
      expect(TimetableSettings.sanitizeHomeMaxItems(4), 4);
      expect(TimetableSettings.fromJson({'homeMaxItems': 3}).homeMaxItems, 3);
      expect(TimetableSettings.fromJson({'homeMaxItems': 9}).homeMaxItems, 2);
    });

    test('提前时间只接受 5/10/15/30，其他回落 15', () {
      int f(Object? v) => TimetableSettings.sanitizeLeadMinutes(v);
      expect(TimetableSettings.reminderLeadOptions, [5, 10, 15, 30]);
      expect(f(5), 5);
      expect(f(10), 10);
      expect(f(15), 15);
      expect(f(30), 30);
      expect(f(30.0), 30);
      expect(f(20), 15);
      expect(f(12), 15);
      expect(f(12.5), 15);
      expect(f(25), 15);
      expect(f(0), 15);
      expect(f(-3), 15);
      expect(f(100), 15);
      expect(f(null), 15);
      expect(f('15'), 15);
      expect(f('x'), 15);
      expect(f(true), 15);
    });

    test('未知文字大小 → 标准；未知方案 → A；类型不对 → 默认', () {
      final s = TimetableSettings.fromJson({
        'fontScale': 'huge',
        'paletteScheme': 'D',
        'showLocation': 'no',
        'showTeacher': 1,
        'showTomorrowOnHome': null,
        'reminderEnabled': 'true',
        'weekStartsOnMonday': 'nope',
      });
      expect(s.fontScale, CellFontScale.standard);
      expect(s.paletteScheme, 'A');
      expect(s.showLocation, isTrue);
      expect(s.showTeacher, isFalse);
      expect(s.showTomorrowOnHome, isTrue);
      expect(s.reminderEnabled, isFalse);
      expect(s.weekStartsSunday, isFalse);
      final ok = TimetableSettings.fromJson({
        'fontScale': 'large',
        'paletteScheme': 'C',
        'showTeacher': true,
        'weekStartsOnMonday': false,
        'reminderLeadMinutes': 30,
      });
      expect(ok.fontScale, CellFontScale.large);
      expect(ok.paletteScheme, 'C');
      expect(ok.showTeacher, isTrue);
      expect(ok.weekStartsSunday, isTrue);
      expect(ok.reminderLeadMinutes, 30);
    });
  });

  group('持久化（合并写、读时不回写）', () {
    late Directory tmp;
    final c = TimetableController.instance;
    File settingsFile() => File('${tmp.path}/settings.json');

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_set04');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
    });
    tearDown(() async {
      TimetableStore.debugDirectory = null;
      c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('启动读到坏值只在内存纠正，不改文件', () async {
      final raw = jsonEncode({
        'cellOpacity': 999,
        'reminderLeadMinutes': 12,
        'fontScale': 'huge',
        'unknownKey': [1, 2],
      });
      settingsFile().writeAsStringSync(raw);
      await c.ensureStarted();
      expect(c.settings.cellOpacity, 100);
      expect(c.settings.reminderLeadMinutes, 15);
      expect(c.settings.fontScale, CellFontScale.standard);
      expect(settingsFile().readAsStringSync(), raw);
    });

    test('改一个设置只写这个键，未知键与坏原值保留', () async {
      settingsFile().writeAsStringSync(
        jsonEncode({'cellOpacity': 999, 'unknownKey': 'keep'}),
      );
      await c.ensureStarted();
      await c.updateSettings(
        c.settings.copyWith(showTeacher: true, weekStartsOnMonday: false),
      );
      final json = jsonDecode(settingsFile().readAsStringSync()) as Map;
      expect(json['showTeacher'], true);
      expect(json['weekStartsOnMonday'], false);
      expect(json['unknownKey'], 'keep');
      expect(json['cellOpacity'], 999);
      expect(json.containsKey('paletteScheme'), isFalse);
    });

    test('有教务缓存时也从 settings.json 读新设置', () async {
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        ),
      );
      settingsFile().writeAsStringSync(
        jsonEncode({
          'showTomorrowOnHome': false,
          'paletteScheme': 'B',
          'cellOpacity': 60,
          'weekStartsOnMonday': false,
        }),
      );
      await c.ensureStarted();
      expect(c.settings.showTomorrowOnHome, isFalse);
      expect(c.settings.paletteScheme, 'B');
      expect(c.settings.cellOpacity, 60);
      expect(c.settings.weekStartsSunday, isTrue);
      expect(c.settings.termCode, '2026-2027-1');
    });
  });

  group('每周第一天（设置 9）', () {
    test('列顺序', () {
      List<int> f(
        bool sun1,
        bool sat,
        bool sun, {
        bool satC = false,
        bool sunC = false,
      }) => weekColumnDays(
        weekStartsSunday: sun1,
        showSaturday: sat,
        showSunday: sun,
        saturdayHasClass: satC,
        sundayHasClass: sunC,
      );
      expect(f(false, true, true), [1, 2, 3, 4, 5, 6, 7]);
      expect(f(true, true, true), [7, 1, 2, 3, 4, 5, 6]);
      expect(f(true, true, false), [1, 2, 3, 4, 5, 6]);
      expect(f(true, false, false), [1, 2, 3, 4, 5]);
      expect(f(true, false, false, sunC: true), [7, 1, 2, 3, 4, 5]);
      expect(f(false, false, false, satC: true), [1, 2, 3, 4, 5, 6]);
    });

    test('周日列是本教学周的周日；月份取周一', () {
      final monday = DateTime(2026, 10, 12);
      expect(weekColumnDate(monday, 7), DateTime(2026, 10, 18));
      expect(weekColumnDate(monday, 1), monday);
      expect(weekMonthLabel(DateTime(2026, 9, 28)), 9); // 周日是 10/4
    });

    test('控制器：周次仍按周一算，周日列自动出现时放第一列', () {
      final c = TimetableController.instance;
      final orig = TimetableController.clock;
      TimetableController.clock = () => DateTime(2026, 10, 18); // 周日
      addTearDown(() {
        TimetableController.clock = orig;
        c.debugReset();
      });
      c.debugReset();
      c.debugSetSnapshot(
        TimetableSnapshot(
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
            showSaturday: false,
            showSunday: false,
            weekStartsOnMonday: false,
          ),
          courses: const [
            Course(
              id: 'k',
              name: '周日课',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(day: 7, startNode: 1, endNode: 2, weeks: '0000001'),
              ],
            ),
          ],
        ),
      );
      expect(c.currentWeek, 7); // 10/18 周日仍属第 7 周
      expect(c.visibleDays(7), [7, 1, 2, 3, 4, 5]);
      expect(c.visibleDays(6), [1, 2, 3, 4, 5]);
      expect(c.dateOfColumn(7, 7), DateTime(2026, 10, 18));
      expect(c.monthLabelOf(5), 9); // 第 5 周周一 9/28
    });
  });
}
