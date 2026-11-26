import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_layout.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_widget_layout.dart';

void main() {
  group('v0.4 设置默认值与宽松读取', () {
    test('默认值与非法/未知类型回落（§13.3/§13.6）', () {
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
      expect(TimetableSettings.fromJson(const {}).toJson(), s.toJson());

      final bad = TimetableSettings.fromJson({
        'fontScale': 'huge',
        'paletteScheme': 'D',
        'showLocation': 'no',
        'showTeacher': 1,
        'showTomorrowOnHome': null,
        'reminderEnabled': 'true',
        'weekStartsOnMonday': 'nope',
      });
      expect(bad.fontScale, CellFontScale.standard);
      expect(bad.paletteScheme, 'A');
      expect(bad.showLocation, isTrue);
      expect(bad.showTeacher, isFalse);
      expect(bad.showTomorrowOnHome, isTrue);
      expect(bad.reminderEnabled, isFalse);
      expect(bad.weekStartsSunday, isFalse);

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

    test('4×6 设置与周末继承：保留 v1 偏好、仅未单独设置时继承外观、跨课表合并', () {
      const s = TimetableSettings();
      expect(s.widgetWeekCellHeight, 34);
      expect(s.widgetWeekFontSize, 10);
      expect(s.widgetWeekOpacity, 100);
      expect(s.widgetWeekWidgetOpacity, 100);
      expect(s.widgetWeekCompactRows, isTrue);
      expect(s.widgetWeekShowWeekend, isTrue);
      expect(TimetableSettings.sanitizeWeekCellHeight(20), 24);
      expect(TimetableSettings.sanitizeWeekCellHeight(80), 64);
      expect(TimetableSettings.sanitizeWeekCellHeight(34.6), 35);
      expect(TimetableSettings.sanitizeWeekCellHeight('40'), 34);
      expect(TimetableSettings.sanitizeWeekFontSize(8), 9);
      expect(TimetableSettings.sanitizeWeekFontSize(16), 14);
      expect(TimetableSettings.sanitizeWeekFontSize(12.4), 12);
      expect(TimetableSettings.sanitizeWeekFontSize(null), 10);

      final saved = s.copyWith(
        widgetWeekCellHeight: 40,
        widgetWeekFontSize: 12,
        widgetWeekOpacity: 60,
        widgetWeekWidgetOpacity: 80,
        widgetWeekCompactRows: false,
        widgetWeekShowWeekend: true,
      );
      final round = TimetableSettings.fromJson(saved.toJson());
      expect(round.widgetWeekCellHeight, 40);
      expect(round.widgetWeekFontSize, 12);
      expect(round.widgetWeekOpacity, 60);
      expect(round.widgetWeekWidgetOpacity, 80);
      expect(round.widgetWeekCompactRows, isFalse);
      expect(round.widgetWeekShowWeekend, isTrue);

      final merged = const TimetableSettings(termCode: '2026-2027-1')
          .withDisplayPrefsFrom(saved);
      expect(merged.termCode, '2026-2027-1');
      expect(merged.widgetWeekCellHeight, 40);
      expect(merged.widgetWeekShowWeekend, isTrue);
      expect(WeekWidgetPrefs.fromSettings(merged).toJson(), {
        'opacity': 60,
        'widgetOpacity': 80,
        'showWeekend': true,
        'showLocation': true,
        'showTeacher': true,
        'showPeriod': true,
        'nodesPerDay': 11,
        'weekStartsSunday': false,
        'showGridLines': true,
        'headerTextSize': 11,
        'fontScale': 1,
      });
      final clamped = TimetableSettings.fromJson({
        'widgetWeekCellHeight': 999,
        'widgetWeekFontSize': -1,
        'widgetWeekOpacity': 5,
      });
      expect(clamped.widgetWeekCellHeight, 64);
      expect(clamped.widgetWeekFontSize, 9);
      expect(clamped.widgetWeekOpacity, 30);

      // 4×6 周末：未单独设置时继承 showSaturday && showSunday
      for (final (sat, sun, override, expected) in [
        (true, true, null, true),
        (true, false, null, false),
        (false, true, null, false),
        (false, false, null, false),
        (true, true, false, false),
        (false, false, true, true),
      ]) {
        final settings = TimetableSettings.fromJson({
          'showSaturday': sat,
          'showSunday': sun,
          'widgetWeekShowWeekend': ?override,
        });
        expect(settings.widgetWeekShowWeekend, expected);
        final json = settings.toJson();
        expect(json.containsKey('widgetWeekShowWeekend'), override != null);
        expect(json['widgetWeekShowWeekend'], override);
        expect(
          TimetableSettings.fromJson(json).widgetWeekShowWeekend,
          expected,
        );
      }
      expect(
        TimetableSettings.fromJson({'widgetWeekShowWeekend': 'invalid'})
            .widgetWeekShowWeekend,
        isTrue,
      );
      expect(s.copyWith(showSaturday: false).widgetWeekShowWeekend, isFalse);
      final explicit = s.copyWith(widgetWeekShowWeekend: false);
      expect(s.withDisplayPrefsFrom(explicit).widgetWeekShowWeekend, isFalse);
      final resetToInherited = explicit.withDisplayPrefsFrom(s);
      expect(resetToInherited.widgetWeekShowWeekend, isTrue);
      expect(
        resetToInherited.toJson().containsKey('widgetWeekShowWeekend'),
        isFalse,
      );
      expect(
        resetToInherited.copyWith(showSunday: false).widgetWeekShowWeekend,
        isFalse,
      );
    });

    test('不透明度（30–100）、headerTextSize（10–14）与 showPeriodTimes 钳制', () {
      int op(Object? v) => TimetableSettings.sanitizeOpacity(v);
      expect(op(25), 30);
      expect(op(0), 30);
      expect(op(150), 100);
      expect(op(55.4), 55);
      expect(op(55.5), 56);
      expect(op(70), 70);
      expect(op('80'), 100);
      expect(op(null), 100);
      expect(op(double.nan), 100);
      expect(op(double.infinity), 100);

      expect(const TimetableSettings().headerTextSize, 11);
      expect(const TimetableSettings().showPeriodTimes, isTrue);
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
      const round = TimetableSettings(
        headerTextSize: 12,
        showPeriodTimes: false,
      );
      final back = TimetableSettings.fromJson(round.toJson());
      expect(back.headerTextSize, 12);
      expect(back.showPeriodTimes, isFalse);
    });

    test('homeMaxItems / homeMaxExams（1–4 回落 2）与提前时间（5/10/15/30 回落 15）', () {
      expect(const TimetableSettings().homeMaxItems, 2);
      expect(const TimetableSettings().homeMaxExams, 2);
      for (final (v, expected) in [
        (null, 2),
        ('x', 2),
        (0, 2),
        (5, 2),
        (1.2, 1),
        (4, 4),
      ]) {
        expect(TimetableSettings.sanitizeHomeMaxItems(v), expected);
        expect(TimetableSettings.sanitizeHomeMaxExams(v), expected);
      }
      expect(TimetableSettings.fromJson({'homeMaxItems': 3}).homeMaxItems, 3);
      expect(TimetableSettings.fromJson({'homeMaxItems': 9}).homeMaxItems, 2);
      expect(TimetableSettings.fromJson({'homeMaxExams': 3}).homeMaxExams, 3);
      expect(TimetableSettings.fromJson({'homeMaxExams': 9}).homeMaxExams, 2);
      final copied = const TimetableSettings().copyWith(homeMaxExams: 4);
      expect(copied.toJson()['homeMaxExams'], 4);
      expect(TimetableSettings.fromJson(copied.toJson()).homeMaxExams, 4);
      final withPrefs = const TimetableSettings(termCode: '2026-2027-1')
          .withDisplayPrefsFrom(copied);
      expect(withPrefs.homeMaxExams, 4);
      expect(withPrefs.termCode, '2026-2027-1');

      int lead(Object? v) => TimetableSettings.sanitizeLeadMinutes(v);
      expect(TimetableSettings.reminderLeadOptions, [5, 10, 15, 30]);
      for (final ok in [5, 10, 15, 30]) {
        expect(lead(ok), ok);
      }
      expect(lead(30.0), 30);
      for (final bad in [20, 12, 12.5, 25, 0, -3, 100, null, '15', 'x', true]) {
        expect(lead(bad), 15, reason: '$bad');
      }
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
      expect(weekMonthLabel(DateTime(2026, 9, 28)), 9);
    });

    test('控制器：周次仍按周一算，周日列自动出现时放第一列', () {
      final c = TimetableController.instance;
      final orig = TimetableController.clock;
      TimetableController.clock = () => DateTime(2026, 10, 18);
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
      expect(c.currentWeek, 7);
      expect(c.visibleDays(7), [7, 1, 2, 3, 4, 5]);
      expect(c.visibleDays(6), [1, 2, 3, 4, 5]);
      expect(c.dateOfColumn(7, 7), DateTime(2026, 10, 18));
      expect(c.monthLabelOf(5), 9);
    });
  });

  group('TX 细胞文字颜色 & ST10 最小字号 & S03b 格高钳制', () {
    test('TX01/TX02 cellTextColor 序列化往返与缺省回退 auto', () {
      for (final mode in CellTextColorMode.values) {
        final s = TimetableSettings(cellTextColor: mode);
        final back = TimetableSettings.fromJson(s.toJson());
        expect(back.cellTextColor, mode);
        expect(s.toJson()['cellTextColor'], mode.name);
      }
      final json = const TimetableSettings().toJson()..remove('cellTextColor');
      expect(
        TimetableSettings.fromJson(json).cellTextColor,
        CellTextColorMode.auto,
      );
      json['cellTextColor'] = 'purple';
      expect(
        TimetableSettings.fromJson(json).cellTextColor,
        CellTextColorMode.auto,
      );
    });

    test('ST10 最小 10sp 夹紧后取整', () {
      const scaler = TextScaler.linear(0.85);
      final v = CourseCell.cellFontSize(12, 0.9, scaler);
      expect(v, 12);
      expect(v * 0.85, closeTo(10.2, 0.001));
      expect(v * 0.85, greaterThanOrEqualTo(10 - 1e-9));
    });

    test('S03b periodHeight 默认 64 且读取时钳到 52–90', () {
      TimetableSettings parse(Object? v) =>
          TimetableSettings.fromJson({'periodHeight': v});
      expect(const TimetableSettings().periodHeight, 64);
      expect(parse(44).periodHeight, 52);
      expect(parse(200).periodHeight, 90);
      expect(parse('abc').periodHeight, 64);
      expect(parse(null).periodHeight, 64);
      expect(parse('70').periodHeight, 70);
    });
  });

  group('设置持久化、合并写入与 20 周边界', () {
    late Directory tmp;
    final c = TimetableController.instance;
    File settingsFile() => File('${tmp.path}/settings.json');
    Future<Map<String, dynamic>> readFile() async =>
        jsonDecode(await settingsFile().readAsString()) as Map<String, dynamic>;

    void fakeOkFetch() {
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(settings: baseSettings!);
    }

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_settings');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
    });

    tearDown(() async {
      TimetableStore.debugBeforeBatchReplace = null;
      TimetableController.bindingCheck = () async => false;
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

    test('连续滑杆调整只保存最新值，其他设置键和恢复原值均保留', () async {
      c.debugSetSnapshot(
        const TimetableSnapshot(settings: TimetableSettings()),
      );
      var replacements = 0;
      TimetableStore.debugBeforeBatchReplace = (_) => replacements++;
      final changes = [
        for (var index = 0; index < 40; index++)
          c.updateSettings(
            c.settingsForEditing.copyWith(periodHeight: 52 + index % 38),
          ),
        c.updateSettings(c.settingsForEditing.copyWith(showTeacher: false)),
        c.updateSettings(c.settingsForEditing.copyWith(periodHeight: 64)),
      ];
      await Future.wait(changes);
      expect(
        replacements,
        lessThanOrEqualTo(4),
        reason: '中间高度均不落盘；恢复原值无变化的文件也不重写',
      );
      expect(c.settings.periodHeight, 64);
      expect(c.settings.showTeacher, isFalse);
      c.debugReset();
      await c.ensureStarted();
      expect(c.settings.periodHeight, 64);
      expect(c.settings.showTeacher, isFalse);
    });

    test(
      'successful sync does not rewrite settings.json (periodHeight 44 kept)',
      () async {
        await settingsFile().writeAsString(jsonEncode({'periodHeight': 44}));
        final before = await settingsFile().readAsString();

        fakeOkFetch();
        await c.ensureStarted();
        await c.syncFromJwxt();

        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.settings.periodHeight, 52);
        final after = jsonDecode(await settingsFile().readAsString()) as Map;
        final orig = jsonDecode(before) as Map;
        after.removeWhere((k, _) => TimetableStore.termSettingKeys.contains(k));
        expect(after, orig);
        expect(after['periodHeight'], 44);
      },
    );

    test(
      'S03c: sync, unbind, re-login+sync keep periodHeight 44 and switches',
      () async {
        final stored = {
          'periodHeight': 44,
          'showSaturday': false,
          'showSunday': false,
          'showNonCurrentWeek': true,
          'showGridLines': false,
          'termCode': '2025-2026-2',
        };
        await settingsFile().writeAsString(jsonEncode(stored));
        fakeOkFetch();

        void expectUserFields(Map<String, dynamic> f) {
          for (final k in [
            'periodHeight',
            'showSaturday',
            'showSunday',
            'showNonCurrentWeek',
            'showGridLines',
          ]) {
            expect(f[k], stored[k], reason: k);
          }
        }

        await c.ensureStarted();
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.settings.periodHeight, 52);
        expectUserFields(await readFile());

        final displayBefore = c.settings;
        await c.handleLogout();
        final m = c.settings;
        expect(m.periodHeight, displayBefore.periodHeight);
        expect(m.periodHeight, 52);
        expect(m.showSaturday, isFalse);
        expect(m.showSunday, isFalse);
        expect(m.showNonCurrentWeek, isTrue);
        expect(m.showGridLines, isFalse);
        expect(m.cellRadius, displayBefore.cellRadius);
        expect(m.nodesPerDay, displayBefore.nodesPerDay);
        expect(m.weekStartsOnMonday, displayBefore.weekStartsOnMonday);
        expect(m.scheduleName, displayBefore.scheduleName);
        expect(m.termStartFromJwxt, isFalse);
        final afterUnbind = await readFile();
        expectUserFields(afterUnbind);
        expect(afterUnbind.containsKey('termCode'), isFalse);

        c.debugReset();
        fakeOkFetch();
        await c.ensureStarted();
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expectUserFields(await readFile());
      },
    );

    test(
      'S03e: unknown key futureKey preserved through sync and unbind',
      () async {
        await settingsFile().writeAsString(
          jsonEncode({
            'periodHeight': 44,
            'futureKey': {'a': 1},
          }),
        );
        fakeOkFetch();
        await c.ensureStarted();
        await c.syncFromJwxt();
        expect((await readFile())['futureKey'], {'a': 1});
        await c.handleLogout();
        final f = await readFile();
        expect(f['futureKey'], {'a': 1});
        expect(f['periodHeight'], 44);
      },
    );

    test(
      'S03e: updateSettings merges only changed keys into raw file',
      () async {
        await settingsFile().writeAsString(
          jsonEncode({'periodHeight': 44, 'futureKey': 1}),
        );
        await c.ensureStarted();
        expect(c.settings.showSaturday, isTrue);
        await c.updateSettings(c.settings.copyWith(showSaturday: false));
        final f = await readFile();
        expect(f['futureKey'], 1);
        expect(f['periodHeight'], 44);
        expect(f['showSaturday'], isFalse);
        expect(c.settings.showSaturday, isFalse);
      },
    );

    group('term keys on sync', () {
      final termKeys = TimetableStore.termSettingKeys;
      final origClock = TimetableController.clock;
      tearDown(() => TimetableController.clock = origClock);

      Course jwxtCourse(String weeks) => Course(
        id: 'j1',
        name: '高数',
        source: CourseSource.jwxt,
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
      );

      void fakeTermFetch({required int maxWeeks, String? weeks}) {
        TimetableController.bindingCheck = () async => true;
        TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
            TimetableSnapshot(
              settings: baseSettings!.copyWith(
                termCode: '2026-2027-1',
                termStartDate: DateTime(2026, 8, 31),
                termStartFromJwxt: true,
                maxWeeks: maxWeeks,
              ),
              courses: [if (weeks != null) jwxtCourse(weeks)],
            );
      }

      test(
        '(a) sync without changed term data keeps settings.json bytes',
        () async {
          TimetableController.clock = () => DateTime(2026, 10, 11);
          final file = settingsFile();
          await file.writeAsString(
            jsonEncode({
              'periodHeight': 44,
              'showSaturday': false,
              'futureKey': 'x',
              'termCode': '2026-2027-1',
              'termStartDate': '2026-08-31',
              'maxWeeks': 30,
              'termStartFromJwxt': true,
            }),
          );
          final before = await file.readAsBytes();
          final mtime = await file.lastModified();
          fakeTermFetch(maxWeeks: 30);
          await c.ensureStarted();
          await c.syncFromJwxt();
          expect(c.syncStatus, TimetableSyncStatus.success);
          expect(await file.readAsBytes(), before);
          expect(await file.lastModified(), mtime);
        },
      );

      test('(b) sync with term data changes only the 4 term keys', () async {
        TimetableController.clock = () => DateTime(2026, 10, 11);
        final orig = {
          'periodHeight': 44,
          'showSaturday': false,
          'showSunday': false,
          'showNonCurrentWeek': true,
          'futureKey': {'n': 1},
        };
        await settingsFile().writeAsString(jsonEncode(orig));
        fakeTermFetch(maxWeeks: 30);
        await c.ensureStarted();
        await c.syncFromJwxt();
        final f = await readFile();
        for (final e in orig.entries) {
          expect(f[e.key], e.value, reason: e.key);
        }
        expect(f.keys.toSet(), {...orig.keys, ...termKeys});
        expect(f['termCode'], '2026-2027-1');
        expect(f['termStartDate'], '2026-08-31');
        expect(f['maxWeeks'], 30);
        expect(f['termStartFromJwxt'], isTrue);
        expect(c.settings.termCode, '2026-2027-1');
        expect(c.settings.termStartFromJwxt, isTrue);
      });

      test('(c) 解绑后重新同步：本周第 6 周，总周数仍为 20', () async {
        TimetableController.clock = () => DateTime(2026, 10, 11);
        await settingsFile().writeAsString(jsonEncode({'periodHeight': 44}));
        fakeTermFetch(maxWeeks: 30, weeks: '${'1' * 10}${'0' * 20}');
        await c.ensureStarted();
        await c.syncFromJwxt();
        await c.handleLogout();
        expect(c.settings.termStartFromJwxt, isFalse);
        expect(c.totalWeeks, 20);

        fakeTermFetch(maxWeeks: 30, weeks: '${'0' * 17}1${'0' * 12}');
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.settings.termStartDate, DateTime(2026, 8, 31));
        expect(c.settings.termStartFromJwxt, isTrue);
        expect(c.totalWeeks, 20);
        expect(c.currentWeek, 6);
        final f = await readFile();
        expect(f['termStartFromJwxt'], isTrue);
        expect(f['periodHeight'], 44);
      });
    });

    group('W02 学期固定 20 周', () {
      final origClock = TimetableController.clock;
      tearDown(() => TimetableController.clock = origClock);
      setUp(() => TimetableController.clock = () => DateTime(2026, 10, 11));

      String bits(int lastWeek) => '${'1' * lastWeek}${'0' * (30 - lastWeek)}';
      Course course(String id, String weeks, CourseSource src) => Course(
        id: id,
        name: id,
        source: src,
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
      );
      TimetableSnapshot snap(List<Course> courses) => TimetableSnapshot(
        settings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 31),
          termStartFromJwxt: true,
        ),
        periods: TimetableController.defaultPeriods(),
        courses: courses,
      );

      test('各类课程组合（18周/20周/空课表/未排课或无时段）总周数固定为 20', () {
        final scenarios = <(String, List<Course>, List<Course>)>[
          ('仅教务课到第18周', [course('j', bits(18), CourseSource.jwxt)], const []),
          (
            '教务18周+手动20周',
            [course('j', bits(18), CourseSource.jwxt)],
            [course('m', bits(20), CourseSource.manual)],
          ),
          ('无课程', const [], const []),
          (
            '含未排课和无时段',
            [
              course('j', bits(12), CourseSource.jwxt),
              const Course(
                id: 'other',
                name: '其他',
                source: CourseSource.jwxt,
                slots: [
                  CourseSlot(
                    day: 0,
                    startNode: 0,
                    endNode: 0,
                    weeks: '',
                    weeksLabel: '2-25周',
                  ),
                ],
              ),
              const Course(id: 'noslot', name: 'x', source: CourseSource.jwxt),
            ],
            const [],
          ),
          (
            '仅无时段课程',
            const [Course(id: 'noslot', name: 'x', source: CourseSource.jwxt)],
            const [],
          ),
        ];
        for (final (label, jwxt, manual) in scenarios) {
          c.debugSetSnapshot(snap(jwxt), manualCourses: manual);
          expect(c.totalWeeks, 20, reason: label);
        }
      });

      test('删除第 20 周手动课程后仍停留在第 20 周', () async {
        c.debugSetSnapshot(
          snap([course('j', bits(18), CourseSource.jwxt)]),
          manualCourses: [course('m', bits(20), CourseSource.manual)],
        );
        c.setViewingWeek(20);
        expect(c.viewingWeek, 20);
        expect(await c.deleteManualCourse('m'), isTrue);
        expect(c.totalWeeks, 20);
        expect(c.viewingWeek, 20);
        await c.addManualCourse(course('m2', bits(20), CourseSource.manual));
        expect(c.totalWeeks, 20);
        expect(c.viewingWeek, 20);
      });

      test('浏览周固定钳到 20，解绑前后保持边界，原始课程周次保留', () async {
        c.debugSetSnapshot(
          snap([course('j', bits(25), CourseSource.jwxt)]),
          manualCourses: const [],
        );
        c.setViewingWeek(25);
        expect(c.totalWeeks, 20);
        expect(c.viewingWeek, 20);
        expect(c.cellsForDay(25, 1).single.activeThisWeek, isTrue);
        expect(c.cellsForDay(26, 1), isEmpty);
        await c.handleLogout();
        expect(c.totalWeeks, 20);
        expect(c.viewingWeek, 20);
      });

      test('W02h 开学前边界：当日无课无提醒，前一日次日命中第1周，翻周与回本周正常', () {
        TimetableController.clock = () => DateTime(2026, 8, 30);
        c.debugSetSnapshot(
          snap([course('j', bits(18), CourseSource.jwxt)]),
          manualCourses: const [],
        );
        expect(c.actualWeek(DateTime(2026, 8, 30)), 0);
        final items = c.todayCourses(now: DateTime(2026, 8, 30, 7));
        expect(items, isEmpty);
        expect(items.where((i) => i.minutesUntilStart != null), isEmpty);
        final firstDay = DateTime(2026, 8, 31);
        expect(c.actualWeek(firstDay), 1);
        expect(c.coursesOnDate(firstDay).map((i) => i.course.id), ['j']);

        TimetableController.clock = () => DateTime(2026, 8, 24);
        c.debugSetSnapshot(
          snap([course('j', bits(18), CourseSource.jwxt)]),
          manualCourses: const [],
        );
        expect(c.actualWeek(DateTime(2026, 8, 24)), 0);
        expect(c.todayCourses(now: DateTime(2026, 8, 24, 7)), isEmpty);
        expect(c.coursesOnDate(DateTime(2026, 8, 24)), isEmpty);
        expect(c.currentWeek, 1);
        expect(c.viewingWeek, 1);
        c.setViewingWeek(0);
        expect(c.viewingWeek, 1);
        c.setViewingWeek(5);
        expect(c.viewingWeek, 5);
        c.goToCurrentWeek();
        expect(c.viewingWeek, 1);
      });

      test('W02f 课程只到第 18 周时第 19 周无课，默认浏览第 19 周且可翻到第 20 周', () {
        TimetableController.clock = () => DateTime(2027, 1, 4);
        c.debugSetSnapshot(
          snap([course('j', bits(18), CourseSource.jwxt)]),
          manualCourses: const [],
        );
        expect(c.actualWeek(DateTime(2027, 1, 4)), 19);
        expect(c.totalWeeks, 20);
        expect(c.todayCourses(now: DateTime(2027, 1, 4, 7)), isEmpty);
        expect(c.coursesOnDate(DateTime(2027, 1, 4)), isEmpty);
        expect(c.coursesOnDate(DateTime(2026, 12, 28)), isNotEmpty);

        TimetableController.clock = () => DateTime(2027, 1, 6);
        c.debugSetSnapshot(
          snap([course('j', bits(18), CourseSource.jwxt)]),
          manualCourses: const [],
        );
        expect(c.currentWeek, 19);
        expect(c.viewingWeek, 19);
        c.setViewingWeek(20);
        expect(c.viewingWeek, 20);
        c.goToCurrentWeek();
        expect(c.viewingWeek, 19);
        expect(c.isViewingCurrentWeek, isTrue);
      });
    });
  });
}
