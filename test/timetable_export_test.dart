import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/api_endpoints.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;
final _start = DateTime(2026, 9, 7);
const _shareId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void _load({bool pending = false}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      settings: TimetableSettings(
        termStartDate: pending ? null : _start,
        showExams: false,
      ),
      periods: TimetableController.defaultPeriods(),
      courses: [
        Course(
          id: 'internal-id',
          code: 'private-course-code',
          classId: 'private-class-id',
          name: '测试课程',
          source: CourseSource.jwxt,
          slots: const [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: '1101',
              note: '带计算器',
            ),
          ],
        ),
      ],
    ),
  );
}

List<Map<String, Object?>> _items(TimetableExportSnapshot snapshot) =>
    snapshot.payload['items'] as List<Map<String, Object?>>;

class _FakeApi extends TimetableExportApi {
  final completion = Completer<TimetableWakeupShare>();
  int requests = 0;

  @override
  Future<TimetableWakeupShare> generate(
    TimetableExportSnapshot snapshot, {
    CancelToken? cancelToken,
  }) {
    requests++;
    return completion.future;
  }
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_export_');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _load();
  });
  tearDown(() {
    _c.debugReset();
    TimetableStore.debugDirectory = null;
    tmp.deleteSync(recursive: true);
  });

  test('快照保留跳周、单次修改、整天调课，移除教务编号', () async {
    final cell = _c.cellsForDay(2, 1).single;
    await _c.editOccurrence(cell, location: '临时教室', note: '临时备注');
    await _c.addDaySwap(_start, _start.add(const Duration(days: 1)));
    final snapshot = TimetableExportSnapshot.fromController(_c);
    final items = _items(snapshot);
    expect(items.map((item) => item['date']), [
      '2026-09-08',
      '2026-09-14',
      '2026-09-28',
    ]);
    expect(items[1]['location'], '临时教室');
    expect(items[1]['note'], '临时备注');
    expect(snapshot.courseCount, 1);
    final encoded = jsonEncode(snapshot.payload);
    for (final private in [
      'internal-id',
      'private-course-code',
      'private-class-id',
      'classId',
      'source',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
  });

  test('隐藏考试仍导出，夜间日程保留精确时间并扩展日期范围', () async {
    for (final kind in ScheduleKind.values) {
      await _c.addScheduleEvent(
        ScheduleEvent(
          id: '',
          kind: kind,
          source: ScheduleSource.manual,
          title: kind == ScheduleKind.exam ? '测试考试' : '测试日程',
          date: _start.add(const Duration(days: 140)),
          start: const TimeOfDayMinutes(21, 30),
          end: const TimeOfDayMinutes(22, 30),
          note: '测试备注',
        ),
      );
    }
    final snapshot = TimetableExportSnapshot.fromController(_c);
    expect(snapshot.examCount, 1);
    expect(snapshot.otherCount, 1);
    expect(snapshot.payload['maxWeeks'], 21);
    final events = _items(snapshot).where((item) => item['kind'] != 'course');
    expect(events.length, 2);
    for (final event in events) {
      expect(event['startTime'], '21:30');
      expect(event['endTime'], '22:30');
      expect(event['note'], '测试备注');
    }
  });

  test('删除课程不再导出，缺失开学日期明确报错', () async {
    await _c.deleteOccurrence(_c.cellsForDay(1, 1).single);
    expect(_items(TimetableExportSnapshot.fromController(_c)).length, 2);
    _load(pending: true);
    expect(
      () => TimetableExportSnapshot.fromController(_c),
      throwsA(isA<TimetableExportException>()),
    );
  });

  test('公网 API 只上传导出快照，处理成功和上游错误', () async {
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    var fail = false;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.toString(), kTimetableWakeupEndpoint);
          expect(options.method, 'POST');
          expect(
            options.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('cookie')),
          );
          expect(
            options.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('authorization')),
          );
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: options,
                  statusCode: 502,
                  data: {'message': 'WakeUp 暂不可用'},
                ),
              ),
            );
          } else {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'code': 0,
                  'data': {
                    'shareId': _shareId,
                    'shareText': '分享口令为「$_shareId」',
                  },
                },
              ),
            );
          }
        },
      ),
    );
    final api = TimetableExportApi(dio: dio);
    final snapshot = TimetableExportSnapshot.fromController(_c);
    expect((await api.generate(snapshot)).shareText, '分享口令为「$_shareId」');
    fail = true;
    await expectLater(
      api.generate(snapshot),
      throwsA(
        isA<TimetableExportException>().having(
          (e) => e.message,
          'message',
          'WakeUp 暂不可用',
        ),
      ),
    );
  });

  testWidgets('顶部直接进入导出页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出到 WakeUp'));
    await tester.pumpAndSettle();
    expect(find.byType(TimetableExportPage), findsOneWidget);
    expect(find.text('生成 WakeUp 口令'), findsOneWidget);
  });

  testWidgets('生成期间禁用按钮，成功后自动复制带文案的口令', (tester) async {
    final api = _FakeApi();
    addTearDown(api.close);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme(),
        home: TimetableExportPage(controller: _c, api: api),
      ),
    );
    await tester.tap(find.text('生成 WakeUp 口令'));
    await tester.pump();
    expect(find.text('正在生成…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('timetable_export_generate')),
          )
          .onPressed,
      isNull,
    );
    expect(api.requests, 1);
    api.completion.complete(
      const TimetableWakeupShare(shareText: '分享口令为「$_shareId」'),
    );
    await tester.pumpAndSettle();
    expect(clipboard, '分享口令为「$_shareId」');

    await tester.tap(find.text('复制口令'));
    await tester.pump();
    expect(clipboard, '分享口令为「$_shareId」');
  });
}
