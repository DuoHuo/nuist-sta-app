// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

/// 第 7 周（单周）：10/12–10/18；开学 2026-08-31。
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  String classId = '',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  classId: classId,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  TimetableSettings? settings,
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: settings ?? TimetableSettings(termStartDate: _termStart),
      syncedAt: syncedAt,
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

void _bigView(WidgetTester tester, {Size size = const Size(1080, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  int week = _week,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
      ),
    ),
  );
  await tester.pump();
}

Finder _cell(String name) => find.widgetWithText(CourseCell, name);

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ui');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 9);
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------- NW
  group('HP 拖动震动（§13.14）', () {
    Future<Size> pumpDraggable(WidgetTester tester) async {
      _bigView(tester);
      _load(manual: [_course('m', '测试课甲')]);
      await _pumpGrid(tester);
      final r = tester.getRect(_cell('测试课甲'));
      return Size(r.width + 3, r.height / 2 + 1.5);
    }

    testWidgets('HP01/HP02/HP03/HP04/HP05 拖起中震 1 次，换格不震，落格轻震 1 次，取消滑回不震', (
      tester,
    ) async {
      final haptics = _mockHaptics(tester);
      final step = await pumpDraggable(tester);
      final g = await tester.startGesture(tester.getCenter(_cell('测试课甲')));
      await tester.pump(const Duration(milliseconds: 900));
      // HP05：按住不动没有任何反馈。
      expect(haptics, isEmpty);
      await g.moveBy(const Offset(4, 0));
      await tester.pump();
      expect(find.byKey(const Key('week_grid_dragging_cell')), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
      // HP02：经过 5 个不同格不震。
      for (var i = 0; i < 5; i++) {
        await g.moveBy(Offset(i.isEven ? step.width : 0, step.height));
        await tester.pump();
      }
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
      await g.up();
      await tester.pump();
      expect(haptics, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('此更改应用范围？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drag_scope_cancel')));
      await tester.pumpAndSettle();
      expect(haptics, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      expect(_c.manualCourseById('m')!.slots.single.day, 1);
    });

    testWidgets('HP-1 拖回原位松手：只有拖起的中震，不轻震、不弹面板', (tester) async {
      final haptics = _mockHaptics(tester);
      final step = await pumpDraggable(tester);
      final g = await tester.startGesture(tester.getCenter(_cell('测试课甲')));
      await tester.pump(const Duration(milliseconds: 900));
      await g.moveBy(Offset(step.width, 0));
      await tester.pump();
      await g.moveBy(Offset(-step.width + 2, 0));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('此更改应用范围？'), findsNothing);
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
    });

    test('HP06 源码不用 Vibrator/VibrationEffect，清单无 VIBRATE', () {
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        expect(src.contains('VibrationEffect'), isFalse, reason: f.path);
        expect(src.contains('Vibrator'), isFalse, reason: f.path);
      }
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest.contains('VIBRATE'), isFalse);
    });
  });

  // ---------------------------------------------------------------- SN
}

/// 拦截 `SystemChannels.platform` 的 HapticFeedback.vibrate，记录参数。
List<String?> _mockHaptics(WidgetTester tester) {
  final calls = <String?>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String?);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}
