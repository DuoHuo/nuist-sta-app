import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/api_endpoints.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exam_parser.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_multi_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_layout.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_switcher_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object data, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );

Course _jwxtCourse(String id, String name) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: const [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '1111111111111111',
      location: '揽江楼 N101',
      teacher: '张老师',
    ),
  ],
);

void main() {
  final c = TimetableController.instance;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_multi_');
    TimetableStore.debugDirectory = tmp;
    TimetableController.bindingCheck = () async => false;
    TimetableController.enrollmentYearCheck = () async => null;
    TimetableController.fetchAvailableTerms = () async => const [];
    TimetableController.fetchExams = (_) async => null;
    c.debugReset();
  });

  tearDown(() {
    TimetableController.bindingCheck = () async => false;
    TimetableController.enrollmentYearCheck = () async => null;
    TimetableController.fetchAvailableTerms = () async => const [];
    TimetableController.fetchExams = (_) async => null;
    TimetableController.fetchSnapshot = (term, {baseSettings}) => Future.value(
      TimetableSnapshot(settings: baseSettings ?? const TimetableSettings()),
    );
    TimetableController.fetchHistoricalSnapshot = (term, {baseSettings}) =>
        Future.value(
          TimetableSnapshot(
            settings: baseSettings ?? const TimetableSettings(),
          ),
        );
    c.debugReset();
    TimetableStore.debugDirectory = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('学期命名与时间先后', () {
    test('学年学期代码按校历格式化，未知格式原样兜底', () {
      expect(formatTermScheduleName('2025-2026-1'), '25秋');
      expect(formatTermScheduleName('2025-2026-2'), '26春');
      expect(formatTermScheduleName('2025-2026-3'), '26暑假学期');
      expect(formatTermScheduleName('2026-2027-1'), '26秋');
      expect(formatTermScheduleName('2026-2027-4'), '2026-2027-4');
      expect(formatTermScheduleName('custom'), 'custom');
    });

    test('判断往年历史学期', () {
      expect(
        isHistoricalTerm('2025-2026-2', currentTermCode: '2026-2027-1'),
        isTrue,
      );
      expect(
        isHistoricalTerm('2026-2027-1', currentTermCode: '2026-2027-1'),
        isFalse,
      );
      expect(
        isHistoricalTerm('2026-2027-2', currentTermCode: '2026-2027-1'),
        isFalse,
      );
    });

    test('cxxljc 教历元数据解析开学日与总周数', () {
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': {
          'cxxszhxqkb': {'rows': const []},
          'cxxljc': {
            'rows': [
              {'XQKSRQ': '2026-02-23 00:00:00', 'ZZC': 19},
            ],
          },
        },
      }, baseSettings: const TimetableSettings(termCode: '2025-2026-2'));
      expect(snap.settings.termStartDate, DateTime(2026, 2, 23));
      expect(snap.settings.termStartFromJwxt, isTrue);
      expect(snap.settings.maxWeeks, 19);
    });

    test('学号前四位解析入学年份并过滤入学前学期', () {
      expect(enrollmentYearFromStudentId('202512340001'), 2025);
      expect(enrollmentYearFromStudentId('invalid'), isNull);
      expect(
        isTermAtOrAfterEnrollment('2025-2026-1', enrollmentYear: 2025),
        isTrue,
      );
      expect(
        isTermAtOrAfterEnrollment('2024-2025-2', enrollmentYear: 2025),
        isFalse,
      );
    });
  });

  group('WakeUp 口令提取与解析', () {
    test('支持从分享全文提取 32 位十六进制口令', () {
      const text =
          '这是来自「WakeUp课程表」的课表分享，分享口令为「A02B3A50F6A74FA49EC592597CEF8162」，请打开查看';
      expect(extractWakeupShareKey(text), 'a02b3a50f6a74fa49ec592597cef8162');
      expect(
        () => extractWakeupShareKey('   '),
        throwsA(isA<TimetableImportException>()),
      );
      expect(
        () => extractWakeupShareKey('没有口令的一段话！'),
        throwsA(isA<TimetableImportException>()),
      );
    });

    test('解析 courses 格式（单双周 + 跳过无效时段 + 颜色）', () {
      final res = WakeupImportParser.parsePayload({
        'name': '室友的课表',
        'startDate': '2026-08-31',
        'maxWeeks': 20,
        'courses': [
          {
            'name': '线性代数',
            'color': '#3B82F6',
            'slots': [
              {
                'day': 2,
                'startNode': 1,
                'endNode': 2,
                'startWeek': 1,
                'endWeek': 10,
                'type': 1,
                'teacher': '李老师',
                'location': '明德楼 S102',
              },
              {
                'day': 9, // 无效星期，应跳过
                'startNode': 1,
                'endNode': 2,
                'startWeek': 1,
                'endWeek': 10,
              },
            ],
          },
        ],
      });
      expect(res.defaultName, '室友的课表');
      expect(res.courseCount, 1);
      expect(res.slotCount, 1);
      expect(res.skippedCount, 1);
      final course = res.snapshot.courses.single;
      expect(course.source, CourseSource.manual);
      expect(course.slots.single.occursInWeek(1), isTrue);
      expect(course.slots.single.occursInWeek(2), isFalse);
      expect(res.userColors[course.id], 0xFF3B82F6);
    });

    test('API 支持内置 Mock 口令、真实 getv2 接口格式与 404 错误区分', () async {
      RequestOptions? captured;
      final dio = Dio()
        ..httpClientAdapter = _StubAdapter((options) async {
          captured = options;
          final code = (options.data as Map)['code'];
          if (code == 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') {
            return _jsonResponse({
              'code': 0,
              'data': {
                'table': {
                  'tableName': '远端解析课表',
                  'startDate': '2026-08-31',
                  'maxWeek': 18,
                  'nodes': 11,
                },
                'courses': [
                  {
                    'id': 1,
                    'courseName': '大学物理',
                    'color': '#3B82F6',
                    'credit': 3.5,
                  },
                ],
                'details': [
                  {
                    'id': 1,
                    'day': 3,
                    'startNode': 3,
                    'step': 2,
                    'startWeek': 1,
                    'endWeek': 8,
                    'type': 0,
                    'room': '文德楼 N201',
                    'teacher': '陈老师',
                  },
                ],
              },
            });
          }
          if (code == 'dddddddddddddddddddddddddddddddd') {
            return _jsonResponse({
              'code': 1,
              'message': '口令无效或已过期，请让朋友重新分享',
            }, statusCode: 404);
          }
          return _jsonResponse({'detail': 'Not Found'}, statusCode: 404);
        });
      final api = TimetableImportApi(dio: dio);

      final mockRes = await api.fetchByShareText(
        TimetableImportApi.demoShareText,
      );
      expect(mockRes.isMock, isTrue);
      expect(mockRes.courseCount, greaterThan(0));
      expect(captured, isNull);

      final remoteRes = await api.fetchByShareText(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      expect(captured?.uri.toString(), kTimetableWakeupImportEndpoint);
      expect(
        (captured?.data as Map)['code'],
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      expect(remoteRes.isMock, isFalse);
      expect(remoteRes.defaultName, '远端解析课表');
      final phys = remoteRes.snapshot.courses.single;
      expect(phys.name, '大学物理');
      expect(phys.slots.single.startNode, 3);
      expect(phys.slots.single.endNode, 4);
      expect(phys.slots.single.location, '文德楼 N201');
      expect(phys.slots.single.teacher, '陈老师');

      await expectLater(
        () => api.fetchByShareText('dddddddddddddddddddddddddddddddd'),
        throwsA(
          isA<TimetableImportException>()
              .having((e) => e.message, 'message', '口令无效或已过期，请让朋友重新分享')
              .having((e) => e.mockSupported, 'mockSupported', isFalse),
        ),
      );

      await expectLater(
        () => api.fetchByShareText('cccccccccccccccccccccccccccccccc'),
        throwsA(
          isA<TimetableImportException>().having(
            (e) => e.mockSupported,
            'mockSupported',
            isTrue,
          ),
        ),
      );
      api.close();
    });
  });

  group('多课表切换、主课表、往年学期与 DIY 配置保留', () {
    test('区分我的课表与导入课表；切换浏览不影响主课表；设为主课表才更新主控制器', () async {
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxtCourse('C1', '当前高数')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
          );

      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(c.ownSchedules.single.name, '26秋');
      expect(c.primaryScheduleId, kDefaultScheduleId);
      expect(c.viewingScheduleId, kDefaultScheduleId);

      // 导入他人 WakeUp 课表，可自定义命名，且默认不覆盖主课表。
      final api = TimetableImportApi();
      final wakeupRes = await api.fetchByShareText(
        TimetableImportApi.demoShareText,
      );
      api.close();

      final importedMeta = await c.importWakeupSchedule(
        wakeupRes,
        name: '室友课表',
        setAsPrimary: false,
      );
      expect(importedMeta.isImportedSchedule, isTrue);
      expect(c.importedSchedules.map((s) => s.name), ['室友课表']);
      expect(c.ownSchedules.map((s) => s.name), ['26秋']);

      // 当前浏览切到「室友课表」，主课表仍保留「当前高数」。
      expect(c.viewingScheduleId, importedMeta.id);
      expect(c.isViewingPrimary, isFalse);
      expect(c.courses.map((e) => e.name), ['当前高数']);
      expect(
        c.viewingController.courses.any((e) => e.name == '数据结构与算法'),
        isTrue,
      );

      // DIY 外观设置更改后全局保留并同步。
      await c.viewingController.updateSettings(
        c.viewingController.settingsForEditing.copyWith(periodHeight: 74),
      );
      expect(c.settings.periodHeight, 74);

      // 将「室友课表」设为主课表后，主控制器加载该课表。
      await c.setPrimarySchedule(importedMeta.id);
      expect(c.primaryScheduleId, importedMeta.id);
      expect(c.isViewingPrimary, isTrue);
      expect(c.courses.any((e) => e.name == '数据结构与算法'), isTrue);

      // 重启后仍保留主课表、列表区分与 DIY 设置。
      c.debugReset();
      await c.ensureStarted();
      expect(c.primaryScheduleId, importedMeta.id);
      expect(c.courses.any((e) => e.name == '数据结构与算法'), isTrue);
      expect(c.settings.periodHeight, 74);
      expect(c.ownSchedules.length, 1);
      expect(c.importedSchedules.length, 1);
    });

    test('往年学期自动发现、重命名保留及历史学期不自动拉取更新', () async {
      TimetableController.bindingCheck = () async => true;
      var currentFetchCount = 0;
      var historyFetchCount = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        currentFetchCount++;
        return TimetableSnapshot(
          courses: [_jwxtCourse('CUR', '本学期课程')],
          periods: TimetableController.defaultPeriods(),
          settings: (baseSettings ?? const TimetableSettings()).copyWith(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        );
      };
      TimetableController.fetchAvailableTerms = () async => const [
        JwxtTermOption(termCode: '2026-2027-1'),
        JwxtTermOption(termCode: '2025-2026-2'),
        JwxtTermOption(termCode: '2025-2026-1'),
        JwxtTermOption(termCode: '2024-2025-2'),
      ];
      TimetableController.fetchHistoricalSnapshot =
          (term, {baseSettings}) async {
            historyFetchCount++;
            if (term == '2025-2026-2') {
              return TimetableSnapshot(
                courses: [_jwxtCourse('H1', '大一下课程')],
                periods: TimetableController.defaultPeriods(),
                settings: (baseSettings ?? const TimetableSettings()).copyWith(
                  termCode: term,
                  termStartDate: DateTime(2026, 3, 2),
                  termStartFromJwxt: true,
                ),
              );
            }
            return TimetableSnapshot(
              courses: const [],
              periods: TimetableController.defaultPeriods(),
              settings: (baseSettings ?? const TimetableSettings()).copyWith(
                termCode: term,
              ),
            );
          };

      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(currentFetchCount, 1);

      await c.triggerHistoricalDiscoveryIfNeeded();
      await c.discoverHistoricalTerms();
      expect(c.ownSchedules.map((m) => m.name), ['26秋', '26春']);
      final springId = c.ownSchedules
          .firstWhere((m) => m.termCode == '2025-2026-2')
          .id;
      expect(c.isHistoricalSchedule(springId), isTrue);

      // 重命名往年课表并切为主课表：重名保留且不再自动同步。
      await c.renameSchedule(springId, '大一下');
      await c.setPrimarySchedule(springId);
      final beforeAuto = historyFetchCount;
      await c.autoSyncIfNeeded();
      expect(historyFetchCount, beforeAuto);

      // 手动刷新该历史学期：只更新它本身，且保留自定义名称。
      await c.syncHistoricalTerm('2025-2026-2');
      expect(historyFetchCount, beforeAuto + 1);
      expect(c.scheduleMetaOf(springId)?.name, '大一下');

      // 导入课表在退出登录时保留，教务当前及往年课表清理。
      final api = TimetableImportApi();
      final wk = await api.fetchByShareText(TimetableImportApi.demoShareText);
      api.close();
      final wkMeta = await c.importWakeupSchedule(wk, name: '好友课表');

      await c.handleLogout(clearJwxt: true);
      expect(c.importedSchedules.map((s) => s.id), [wkMeta.id]);
      expect(c.ownSchedules.any((s) => s.id == springId), isFalse);
      expect(c.primaryScheduleId, kDefaultScheduleId);
    });

    test('跨学期同步自动将上一学期归档到往年课表', () async {
      TimetableController.bindingCheck = () async => true;
      var term = '2025-2026-2';
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [
              _jwxtCourse('C_$term', term == '2025-2026-2' ? '旧课' : '新课'),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: term,
              termStartDate: term == '2025-2026-2'
                  ? DateTime(2026, 3, 2)
                  : DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
          );

      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(c.ownSchedules.map((m) => m.name), ['26春']);

      term = '2026-2027-1';
      await c.syncFromJwxt();
      expect(c.ownSchedules.map((m) => m.name), containsAll(['26秋', '26春']));
    });

    test('按入学年份过滤学期且不显示拉取不到的学期', () async {
      TimetableController.bindingCheck = () async => true;
      TimetableController.enrollmentYearCheck = () async => 2025;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxtCourse('CUR', '当前课程')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
          );
      TimetableController.fetchAvailableTerms = () async => const [
        JwxtTermOption(termCode: '2026-2027-2'), // 未来学期，应过滤
        JwxtTermOption(termCode: '2026-2027-1'), // 当前学期
        JwxtTermOption(termCode: '2025-2026-3'), // 无课暑假，应过滤
        JwxtTermOption(termCode: '2025-2026-2'), // 接口报错拉取不到，应过滤
        JwxtTermOption(termCode: '2025-2026-1'), // 正常有课往年学期
        JwxtTermOption(termCode: '2024-2025-2'), // 入学前学期，不得探测或显示
      ];
      final probed = <String>[];
      TimetableController.fetchHistoricalSnapshot =
          (term, {baseSettings}) async {
            probed.add(term);
            if (term == '2025-2026-2') {
              throw StateError('unscheduled term');
            }
            if (term == '2025-2026-1') {
              return TimetableSnapshot(
                courses: [_jwxtCourse('FALL25', '程序设计基础')],
                periods: TimetableController.defaultPeriods(),
                settings: (baseSettings ?? const TimetableSettings()).copyWith(
                  termCode: term,
                  termStartDate: DateTime(2025, 9, 1),
                  termStartFromJwxt: true,
                ),
              );
            }
            return TimetableSnapshot(
              courses: const [],
              periods: TimetableController.defaultPeriods(),
              settings: (baseSettings ?? const TimetableSettings()).copyWith(
                termCode: term,
              ),
            );
          };

      await c.ensureStarted();
      await c.syncFromJwxt();
      final available = await c.fetchAvailableJwxtTerms();

      expect(available.map((e) => e.termCode), ['2026-2027-1', '2025-2026-1']);
      expect(probed, isNot(contains('2024-2025-2')));
      expect(probed, isNot(contains('2026-2027-2')));
    });

    test('历史课表过滤跨学期考试且教学周不投射期末幽灵考试', () async {
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxtCourse('CUR', '当前课程')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
          );
      TimetableController.fetchHistoricalSnapshot =
          (term, {baseSettings}) async => TimetableSnapshot(
            courses: [_jwxtCourse('FALL25', '高等数学')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: term,
              termStartDate: DateTime(2025, 9, 1),
              termStartFromJwxt: true,
              showNonCurrentWeek: true,
              showExams: true,
            ),
          );
      TimetableController.fetchExams = (term) async {
        // 模拟教务返回混杂了 25秋 与 25春 考试的结果。
        final parsed = ExamParser.parse({
          'code': '0',
          'datas': {
            'cxxsksap': {
              'rows': [
                {
                  'KCH': 'MATH1',
                  'KCM': '高等数学',
                  'KSRQ': '2026-01-07',
                  'KSKSSJ': '13:30',
                  'KSJSSJ': '14:15',
                  'JASMC': '长望楼S204',
                  'SFAPSJ': '1',
                  'XNXQDM': '2025-2026-1',
                },
                {
                  'KCH': 'PHYS2',
                  'KCM': '下学期考试',
                  'KSRQ': '2026-06-24',
                  'KSKSSJ': '13:30',
                  'KSJSSJ': '15:30',
                  'JASMC': '明德N101',
                  'SFAPSJ': '1',
                  'XNXQDM': '2025-2026-2',
                },
              ],
            },
          },
        }, expectedTermCode: term);
        return parsed.exams;
      };

      await c.ensureStarted();
      await c.syncFromJwxt();
      final meta = await c.syncHistoricalTerm('2025-2026-1');
      await c.switchViewingSchedule(meta.id);

      final viewing = c.viewingController;
      // 跨学期 2025-2026-2 考试应被剔除，只保留本学期 2025-2026-1 考试。
      expect(viewing.scheduleEvents.map((e) => e.title), ['高等数学']);
      // 第 4 周（2025-09-22..28）的周三第 5-6 节不应被期末幽灵考试占据。
      expect(scheduleItemsForColumn(viewing, 4, 3), isEmpty);
      // 实际考试周（2026-01-07 所在第 19 周周三）仍正常显示考试本身。
      final actualExamWeek = viewing.actualWeek(DateTime(2026, 1, 7))!;
      expect(
        scheduleItemsForColumn(
          viewing,
          actualExamWeek,
          3,
        ).map((i) => i.event.title),
        ['高等数学'],
      );
    });

    test('往期课表按从新到旧排序，同步后自动拉取往期学期', () async {
      TimetableController.bindingCheck = () async => true;
      TimetableController.enrollmentYearCheck = () async => 2025;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxtCourse('CUR', '当前课程')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
          );
      TimetableController.fetchAvailableTerms = () async => const [
        JwxtTermOption(termCode: '2025-2026-1'),
        JwxtTermOption(termCode: '2026-2027-1'),
        JwxtTermOption(termCode: '2025-2026-2'),
      ];
      TimetableController.fetchHistoricalSnapshot =
          (term, {baseSettings}) async => TimetableSnapshot(
            courses: [_jwxtCourse('H_$term', '课程_$term')],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: term,
              termStartDate: term == '2025-2026-2'
                  ? DateTime(2026, 3, 2)
                  : DateTime(2025, 9, 1),
              termStartFromJwxt: true,
            ),
          );

      await c.ensureStarted();
      await c.syncFromJwxt();
      for (var i = 0; i < 20; i++) {
        if (c.ownSchedules.length == 3) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(c.ownSchedules.map((s) => s.name), ['26秋', '26春', '25秋']);

      await c.syncHistoricalTerm('2025-2026-1');
      await c.syncHistoricalTerm('2025-2026-2');
      expect(c.ownSchedules.map((s) => s.name), ['26秋', '26春', '25秋']);
    });
  });

  group('UI 交互：WakeUp 导入页、切换面板与课表管理', () {
    testWidgets('WakeUp 口令导入支持 Mock 示例、自定义命名与独立区分展示', (tester) async {
      await tester.runAsync(c.ensureStarted);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [_jwxtCourse('OWN1', '我的高数')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        ),
        viewingWeek: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: TimetableImportPage(controller: c),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tt_import_demo_chip')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tt_import_parse_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tt_import_preview')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tt_import_name_input')),
        '学霸同学课表',
      );
      await tester.ensureVisible(
        find.byKey(const Key('tt_import_confirm_btn')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_import_confirm_btn')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(c.importedSchedules.map((e) => e.name), ['学霸同学课表']);
      expect(c.viewingScheduleId, c.importedSchedules.single.id);
      expect(c.primaryScheduleId, kDefaultScheduleId);
    });

    testWidgets('TimetablePage 顶栏切换器无仅查看横幅并支持设为主课表', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.runAsync(c.ensureStarted);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [_jwxtCourse('OWN1', '我的高数')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        ),
        viewingWeek: 1,
      );
      final api = TimetableImportApi();
      final wk = await tester.runAsync(
        () => api.fetchByShareText(TimetableImportApi.demoShareText),
      );
      api.close();
      final imported = (await tester.runAsync(
        () => c.importWakeupSchedule(wk!, name: '同学课表'),
      ))!;
      await tester.runAsync(() => c.switchViewingSchedule(kDefaultScheduleId));

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(
        find.byKey(const Key('timetable_schedule_switcher_button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tt_switcher_sheet')), findsOneWidget);
      expect(find.text('我的课表'), findsOneWidget);
      expect(find.text('导入的课表'), findsOneWidget);
      expect(find.text('同学课表'), findsOneWidget);

      await tester.tap(find.text('同学课表'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('timetable_viewing_banner')), findsNothing);
      expect(find.text('操作系统'), findsOneWidget);

      await tester.runAsync(() => c.setPrimarySchedule(imported.id));
      await tester.pumpAndSettle();
      expect(c.primaryScheduleId, imported.id);
    });

    testWidgets('已结束课表顶栏显示简洁结束文案，且纯考试周与其他周不被跨周单节大课锁死行高', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.runAsync(c.ensureStarted);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            const Course(
              id: 'TALL',
              name: '超长实验课程名称测试对齐高度（一）',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(
                  day: 1,
                  startNode: 1,
                  endNode: 1,
                  weeks: '1000000000000000',
                  location: '长望楼 N101',
                  teacher: '张老师、李老师',
                ),
              ],
            ),
            const Course(
              id: 'EXAM_COURSE',
              name: '【考试】超长思想政治理论课期中测试安排',
              source: CourseSource.manual,
              slots: [
                CourseSlot(
                  day: 3,
                  startNode: 1,
                  endNode: 1,
                  weeks: '0000000000001000',
                  location: '长望楼 N502',
                ),
              ],
            ),
            const Course(
              id: 'TWO',
              name: '对比课程',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(
                  day: 1,
                  startNode: 2,
                  endNode: 3,
                  weeks: '1111111111111111',
                ),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2025-2026-1',
            scheduleName: '25秋',
            termStartDate: DateTime(2025, 9, 1),
            termStartFromJwxt: true,
            periodHeight: 52,
            showExams: true,
          ),
        ),
        viewingWeek: 13,
      );
      await tester.runAsync(
        () => c.addScheduleEvent(
          ScheduleEvent(
            id: 'exam_w19',
            kind: ScheduleKind.exam,
            source: ScheduleSource.jwxt,
            title: '高等数学期末考试',
            date: DateTime(2026, 1, 7),
            start: const TimeOfDayMinutes(9, 0),
            end: const TimeOfDayMinutes(11, 0),
            location: '明德 N503',
            courseCode: 'MATH1',
          ),
        ),
      );

      // 第 13 周没有第 1 周的超长单节课，且「【考试】」导入项不撑大整周行高，应遵循 settings.periodHeight=52。
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(body: WeekGrid(week: 13, controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final w13RectAt52 = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is CourseCell && w.cell.course.id == 'TWO',
        ),
      );
      expect(
        (w13RectAt52.height + TimetableTheme.cellMargin * 2) / 2,
        closeTo(52, 0.5),
      );

      // 调高 settings.periodHeight 到 78 后，第 13 周和纯考试第 19 周都应随设置同步变化到 78。
      await tester.runAsync(
        () => c.updateSettings(c.settings.copyWith(periodHeight: 78)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(body: WeekGrid(week: 13, controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final w13RectAt78 = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is CourseCell && w.cell.course.id == 'TWO',
        ),
      );
      expect(
        (w13RectAt78.height + TimetableTheme.cellMargin * 2) / 2,
        closeTo(78, 0.5),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(body: WeekGrid(week: 19, controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final examRect = tester.getRect(find.byType(ScheduleEventCell));
      expect(
        (examRect.height + TimetableTheme.cellMargin * 2) / 2,
        closeTo(78, 0.5),
      );

      // TimetablePage 顶栏已结束文案不含「本周第 X 周」，只展示简洁的「课程已结束」。
      await tester.pumpWidget(
        MaterialApp(theme: appDarkTheme(), home: const TimetablePage()),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('timetable_term_ended')), findsOneWidget);
      expect(find.textContaining('课程已结束'), findsOneWidget);
      expect(find.textContaining('本周第'), findsNothing);
    });

    testWidgets('TimetableManagementPage 已精简导入与多课表项；切换面板支持确认删除与重命名', (
      tester,
    ) async {
      await tester.runAsync(c.ensureStarted);
      final api = TimetableImportApi();
      final wk = await tester.runAsync(
        () => api.fetchByShareText(TimetableImportApi.demoShareText),
      );
      api.close();
      final meta = (await tester.runAsync(
        () => c.importWakeupSchedule(wk!, name: '待改名课表'),
      ))!;

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: TimetableManagementPage(controller: c),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('tt_settings_group_own_schedules')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('tt_settings_group_imported_schedules')),
        findsNothing,
      );
      expect(find.byKey(const Key('tt_mgmt_import_wakeup')), findsNothing);
      expect(find.byKey(const Key('tt_mgmt_fetch_history')), findsNothing);
      expect(find.byKey(const Key('tt_settings_day_swaps')), findsOneWidget);
      expect(find.byKey(const Key('tt_settings_change_log')), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showTimetableSwitcherSheet(context, controller: c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('待改名课表'), findsOneWidget);
      await tester.tap(find.byKey(Key('tt_schedule_menu_${meta.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tt_rename_schedule_input')),
        '改名后课表',
      );
      await tester.tap(find.byKey(const Key('tt_rename_schedule_confirm')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('改名后课表'), findsOneWidget);

      await tester.tap(find.byKey(Key('tt_schedule_menu_${meta.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_delete_schedule_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tt_delete_schedule_confirm')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('改名后课表'), findsNothing);
    });

    testWidgets('单节考试周格子高度随格子高度设置变化，不被考试卡片撑死', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.runAsync(c.ensureStarted);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            const Course(
              id: 'SHORT',
              name: '高数',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(
                  day: 1,
                  startNode: 1,
                  endNode: 2,
                  weeks: '1111111111111111',
                  location: 'N101',
                ),
              ],
            ),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2025-2026-1',
            scheduleName: '25秋',
            termStartDate: DateTime(2025, 9, 1),
            termStartFromJwxt: true,
            periodHeight: 52,
            showExams: true,
          ),
        ),
        viewingWeek: 19,
      );
      await tester.runAsync(
        () => c.addScheduleEvent(
          ScheduleEvent(
            id: 'exam_1p',
            kind: ScheduleKind.exam,
            source: ScheduleSource.jwxt,
            title: '思想道德与法治期末考试',
            date: DateTime(2026, 1, 7),
            start: const TimeOfDayMinutes(13, 30),
            end: const TimeOfDayMinutes(14, 15),
            location: '长望楼S204',
            courseCode: 'ETHIC1',
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(body: WeekGrid(week: 19, controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final rectAt52 = tester.getRect(find.byType(ScheduleEventCell));
      final heightAt52 = rectAt52.height + TimetableTheme.cellMargin * 2;
      expect(heightAt52, closeTo(52, 0.5));

      await tester.runAsync(
        () => c.updateSettings(c.settings.copyWith(periodHeight: 80)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(body: WeekGrid(week: 19, controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final rectAt80 = tester.getRect(find.byType(ScheduleEventCell));
      final heightAt80 = rectAt80.height + TimetableTheme.cellMargin * 2;
      expect(heightAt80, closeTo(80, 0.5));
    });

    testWidgets('切换面板中往期课表无删除项，支持单学期与批量重新拉取', (tester) async {
      var resyncCalls = 0;
      TimetableController.bindingCheck = () async => true;
      TimetableController.enrollmentYearCheck = () async => 2025;
      TimetableController.fetchAvailableTerms = () async => const [
        JwxtTermOption(termCode: '2025-2026-1'),
      ];
      TimetableController.fetchHistoricalSnapshot =
          (term, {baseSettings}) async {
            resyncCalls++;
            return TimetableSnapshot(
              courses: [_jwxtCourse('H_$term', '高数_$resyncCalls')],
              periods: TimetableController.defaultPeriods(),
              settings: (baseSettings ?? const TimetableSettings()).copyWith(
                termCode: term,
                termStartDate: DateTime(2025, 9, 1),
                termStartFromJwxt: true,
              ),
            );
          };

      await tester.runAsync(c.ensureStarted);
      final histMeta = await tester.runAsync(
        () => c.syncHistoricalTerm('2025-2026-1'),
      );
      expect(histMeta, isNotNull);
      expect(resyncCalls, 1);

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showTimetableSwitcherSheet(context, controller: c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tt_switcher_fetch_history')), findsNothing);
      expect(find.byKey(const Key('tt_switcher_resync_own')), findsOneWidget);

      await tester.tap(find.byKey(Key('tt_schedule_menu_${histMeta!.id}')));
      await tester.pumpAndSettle();
      expect(find.text('重新拉取'), findsAtLeastNWidgets(2));
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除'), findsNothing);

      await tester.tap(find.text('重新拉取').last);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(resyncCalls, 2);

      await tester.tap(find.byKey(const Key('tt_switcher_resync_own')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(resyncCalls, 3);
    });

    test('支持解析 WakeUp share_schedule/getv2 返回的 shareData 五段换行格式并合并拆分周次', () {
      final line0 = jsonEncode({
        'courseLen': 45,
        'id': 1,
        'name': '作息',
        'sameBreakLen': false,
      });
      final line1 = jsonEncode([
        {'node': 1, 'startTime': '08:00', 'endTime': '08:45', 'timeTable': 1},
        {'node': 2, 'startTime': '08:55', 'endTime': '09:40', 'timeTable': 1},
        {'node': 3, 'startTime': '10:10', 'endTime': '10:55', 'timeTable': 1},
        {'node': 4, 'startTime': '11:05', 'endTime': '11:50', 'timeTable': 1},
      ]);
      final line2 = jsonEncode({
        'id': 1,
        'tableName': '好友课表',
        'startDate': '2026-08-31',
        'maxWeek': 20,
        'nodes': 11,
      });
      final line3 = jsonEncode([
        {
          'id': 1,
          'courseName': '大学物理',
          'credit': 3.0,
          'note': '',
          'color': '#fff0c7',
          'tableId': 1,
        },
        {
          'id': 2,
          'courseName': '高数期中测验',
          'credit': 0,
          'note': '',
          'color': '#c62828',
          'tableId': 1,
        },
      ]);
      final line4 = jsonEncode([
        {
          'id': 1,
          'day': 2,
          'startWeek': 2,
          'endWeek': 2,
          'type': 0,
          'startNode': 1,
          'step': 2,
          'room': '明德楼N101',
          'teacher': '张老师',
          'courseNote': '',
          'tableId': 1,
        },
        {
          'id': 1,
          'day': 2,
          'startWeek': 4,
          'endWeek': 4,
          'type': 0,
          'startNode': 1,
          'step': 2,
          'room': '明德楼N101',
          'teacher': '张老师',
          'courseNote': '',
          'tableId': 1,
        },
        {
          'id': 2,
          'day': 3,
          'startWeek': 10,
          'endWeek': 10,
          'type': 0,
          'ownTime': true,
          'startTime': '10:10',
          'endTime': '11:50',
          'startNode': 3,
          'step': 2,
          'room': '长望楼S202',
          'teacher': '',
          'courseNote': '考试申请审核通过生成',
          'tableId': 1,
        },
      ]);

      final result = WakeupImportParser.parsePayload({
        'shareData': '$line0\n$line1\n$line2\n$line3\n$line4',
      });

      expect(result.defaultName, '好友课表');
      expect(result.courseCount, 1);
      // id=1 的两条第 2 周和第 4 周同节次记录应合并为 1 条 slot；id=2 识别为考试日程。
      expect(result.slotCount, 1);
      expect(result.examCount, 1);
      final physics = result.snapshot.courses.firstWhere(
        (course) => course.name == '大学物理',
      );
      expect(physics.slots.length, 1);
      expect(physics.slots.single.startNode, 1);
      expect(physics.slots.single.endNode, 2);
      expect(physics.slots.single.location, '明德楼N101');
      expect(physics.slots.single.weeks[1], '1');
      expect(physics.slots.single.weeks[2], '0');
      expect(physics.slots.single.weeks[3], '1');

      final quiz = result.exams.single;
      expect(quiz.kind, ScheduleKind.exam);
      expect(quiz.title, '高数期中测验');
      expect(quiz.date, DateTime(2026, 11, 4));
      expect(quiz.start, const TimeOfDayMinutes(10, 10));
      expect(quiz.end, const TimeOfDayMinutes(11, 50));
      expect(quiz.location, '长望楼S202');
      expect(quiz.note, '考试申请审核通过生成');
    });

    testWidgets('点击顶栏周数直接展示周数与课表切换，三个点菜单支持默认 WakeUp 导出指定课表', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.runAsync(c.ensureStarted);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [_jwxtCourse('MAIN', '当前主课表课程')],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            scheduleName: '26秋',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        ),
        viewingWeek: 1,
      );
      final api = TimetableImportApi();
      final wk = await tester.runAsync(
        () => api.fetchByShareText(TimetableImportApi.demoShareText),
      );
      api.close();
      final imported = (await tester.runAsync(
        () => c.importWakeupSchedule(wk!, name: '室友导出的课表'),
      ))!;
      await tester.runAsync(() => c.switchViewingSchedule(kDefaultScheduleId));

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 直接点顶栏周数即弹出包含「切换周数」与「我的课表 / 导入的课表」的底部弹窗。
      await tester.tap(find.textContaining('第 1 周'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const Key('timetable_week_strip')), findsOneWidget);
      expect(find.byKey(const Key('tt_switcher_sheet')), findsOneWidget);
      expect(find.text('切换周数与课表'), findsOneWidget);
      expect(find.text('切换周数'), findsOneWidget);
      expect(find.byKey(const Key('timetable_week_slider')), findsOneWidget);
      expect(find.text('我的课表'), findsOneWidget);
      expect(find.text('导入的课表'), findsOneWidget);
      expect(find.text('室友导出的课表'), findsOneWidget);
      expect(find.textContaining('来自 WakeUp'), findsNothing);
      expect(find.text('从口令导入'), findsOneWidget);

      // 当前在浏览「26秋」时，点非当前查看的「室友导出的课表」⋮ 菜单中的「导出到 WakeUp」，
      // 应打开导出页并导出「室友导出的课表」。
      await tester.ensureVisible(
        find.byKey(Key('tt_schedule_menu_${imported.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('tt_schedule_menu_${imported.id}')));
      await tester.pumpAndSettle();
      expect(find.text('导出到 WakeUp'), findsOneWidget);
      await tester.tap(find.text('导出到 WakeUp'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(TimetableExportPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TimetableExportPage),
          matching: find.text('室友导出的课表'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('timetable_export_generate')),
        findsOneWidget,
      );
    });

    test('导入课表根据原颜色自动适配为 16 色配色方案', () async {
      expect(adaptedPaletteIndexForArgb(0xFF3B82F6), 0); // 蓝色 → 晴空蓝 0
      expect(adaptedPaletteIndexForArgb(0xFFC62828), 12); // 深红 → 莓果红 12
      expect(adaptedPaletteIndexForArgb(0xFFFFDEDE), 12); // 近似浅底精确命中 12
      expect(adaptedPaletteIndexForArgb(0xFF10B981), anyOf(2, 10)); // 绿色系

      await c.ensureStarted();
      final wk = WakeupImportParser.parsePayload({
        'name': '配色适配课表',
        'courses': [
          {
            'name': '高数',
            'color': '#3B82F6',
            'slots': [
              {'day': 1, 'startNode': 1, 'endNode': 2, 'weeks': '1111'},
            ],
          },
          {
            'name': '物理实验',
            'color': '#C62828',
            'slots': [
              {'day': 2, 'startNode': 3, 'endNode': 4, 'weeks': '1111'},
            ],
          },
          {
            'name': '无原色课程',
            'slots': [
              {'day': 3, 'startNode': 5, 'endNode': 6, 'weeks': '1111'},
            ],
          },
        ],
      });
      await c.importWakeupSchedule(wk, name: '配色适配课表');
      final viewing = c.viewingController;
      final math = viewing.courses.firstWhere((e) => e.name == '高数');
      final lab = viewing.courses.firstWhere((e) => e.name == '物理实验');
      final plain = viewing.courses.firstWhere((e) => e.name == '无原色课程');

      expect(viewing.userColorOf(math), isNull);
      expect(viewing.userColorOf(lab), isNull);
      expect(math.colorIndex, 0);
      expect(lab.colorIndex, 12);
      expect(viewing.colorIndexOf(math), 0);
      expect(viewing.colorIndexOf(lab), 12);
      expect(viewing.colorIndexOf(plain), isNot(anyOf(0, 12)));
    });

    testWidgets('导入课表的「【考试】」与考试日程以主课表 ScheduleEventCell 一致样式渲染', (
      tester,
    ) async {
      await tester.runAsync(c.ensureStarted);
      final line0 = jsonEncode({'courseLen': 45, 'id': 1, 'name': '作息'});
      final line1 = jsonEncode([
        {'node': 1, 'startTime': '08:00', 'endTime': '08:45', 'timeTable': 1},
        {'node': 2, 'startTime': '08:55', 'endTime': '09:40', 'timeTable': 1},
        {'node': 3, 'startTime': '10:10', 'endTime': '10:55', 'timeTable': 1},
        {'node': 4, 'startTime': '11:05', 'endTime': '11:50', 'timeTable': 1},
      ]);
      final line2 = jsonEncode({
        'id': 1,
        'tableName': '导入含考试课表',
        'startDate': '2026-03-02',
        'maxWeek': 20,
        'nodes': 11,
      });
      final line3 = jsonEncode([
        {'id': 1, 'courseName': '高等数学Ⅰ(2)', 'credit': 4.0, 'color': '#fff0c7'},
        {
          'id': 2,
          'courseName': '【考试】中国近现代史纲要',
          'credit': 0,
          'color': '#c62828',
        },
      ]);
      final line4 = jsonEncode([
        {
          'id': 1,
          'day': 1,
          'startWeek': 1,
          'endWeek': 16,
          'type': 0,
          'startNode': 1,
          'step': 2,
          'room': '明德S206',
          'teacher': '刘老师',
        },
        {
          'id': 2,
          'day': 3,
          'startWeek': 15,
          'endWeek': 15,
          'type': 0,
          'ownTime': false,
          'startNode': 3,
          'step': 2,
          'room': '长望楼S402',
          'teacher': '',
        },
      ]);
      final wk = WakeupImportParser.parsePayload({
        'shareData': '$line0\n$line1\n$line2\n$line3\n$line4',
      });
      expect(wk.courseCount, 1);
      expect(wk.examCount, 1);
      await tester.runAsync(() => c.importWakeupSchedule(wk, name: '导入含考试课表'));
      await tester.runAsync(
        () => c.viewingController.updateSettings(
          c.viewingController.settings.copyWith(showNonCurrentWeek: true),
        ),
      );

      // 更早的第 13 周应与主课表一致显示「考试」+「非本周」幽灵考；第 15 周显示正式红底考格。
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(
            body: WeekGrid(week: 13, controller: c.viewingController),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEventCell), findsOneWidget);
      expect(find.text('中国近现代史纲要'), findsOneWidget);
      expect(find.text('考试'), findsOneWidget);
      expect(find.text('非本周'), findsOneWidget);
      expect(find.textContaining('【考试】'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(
            body: WeekGrid(week: 15, controller: c.viewingController),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEventCell), findsOneWidget);
      expect(find.text('中国近现代史纲要'), findsOneWidget);
      expect(find.text('考试'), findsOneWidget);
      expect(find.text('非本周'), findsNothing);
    });
  });
}
