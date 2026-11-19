// 冷启动课表页的两阶段启动：本地课表读完即可显示，门户绑定读取在后台完成。
// 全部为构造数据，不读真实样例。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

TimetableSnapshot _snapshot({required bool withCourse}) => TimetableSnapshot(
  courses: [
    if (withCourse)
      Course(
        id: 'local-ready',
        name: '本地测试课',
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20)],
      ),
  ],
  periods: TimetableController.defaultPeriods(),
  settings: TimetableSettings(
    termStartDate: DateTime(2026, 8, 31),
    termCode: '2026-2027-1',
  ),
);

/// 真实文件 IO 需在 runAsync 中推进；条件满足即停，避免等待挂起的绑定读取。
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory tmp;
  late Completer<bool> binding;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_local_ready');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    binding = Completer<bool>();
    TimetableController.bindingCheck = () => binding.future;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 9, 1, 9);
  });

  tearDown(() {
    if (!binding.isCompleted) binding.complete(false);
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  for (final dark in [false, true]) {
    final theme = dark ? '深色' : '浅色';
    testWidgets('$theme：有课时读完本地课表即显示，不等待门户绑定读取', (tester) async {
      await tester.runAsync(
        () => TimetableStore.saveSnapshot(_snapshot(withCourse: true)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: const TimetablePage(),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(WeekGrid).evaluate().isNotEmpty,
      );

      expect(find.text('本地测试课'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(binding.isCompleted, isFalse, reason: '安全存储仍在读取');
      expect(_c.isInitialized, isFalse);

      // 绑定为 false 时不启动 400 天明日提醒排程，测试结束不残留定时器。
      binding.complete(false);
      await _pumpUntil(tester, () => _c.isInitialized);
      expect(_c.isInitialized, isTrue);
      expect(_c.portalBound, isFalse);
      expect(find.text('本地测试课'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('空课表等绑定状态读完再显示登录引导，不闪错误入口', (tester) async {
    await tester.runAsync(
      () => TimetableStore.saveSnapshot(_snapshot(withCourse: false)),
    );
    await tester.pumpWidget(
      MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
    );
    await _pumpUntil(tester, () => false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('去登录'), findsNothing);

    binding.complete(false);
    await _pumpUntil(tester, () => find.text('去登录').evaluate().isNotEmpty);
    expect(find.text('还没有课程'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('无存储时按空数据降级，本地阶段与完整启动依次完成', () async {
    TimetableStore.debugDirectory = null;
    // 无存储目录时按“没有存储”降级，启动应正常完成。
    await _c.ensureLocalReady();
    binding.complete(false);
    await _c.ensureStarted();
    expect(_c.isInitialized, isTrue);
    expect(_c.ensureLocalReady(), completes);
  });
}
