// spec-next-1019 item 3（回到本周 / 选周动画时长）与 item 5（顶栏周条）。
// 全部为构造数据，不读真实样例。
// ignore_for_file: unused_element

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/router.dart';

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
  String weeksLabel = '',
  String location = '测试楼 A101',
  String teacher = '张老师',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      weeksLabel: weeksLabel,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _io(WidgetTester tester, [int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void _setUpController() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_next');
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
}

void main() {
  _setUpController();

  group('item 3 weekJumpDuration', () {
    test('NAV01 1→250、2→300、6→500、10→500（上限），负数按绝对值', () {
      expect(weekJumpDuration(1), const Duration(milliseconds: 250));
      expect(weekJumpDuration(2), const Duration(milliseconds: 300));
      expect(weekJumpDuration(6), const Duration(milliseconds: 500));
      expect(weekJumpDuration(10), const Duration(milliseconds: 500));
      expect(weekJumpDuration(-2), const Duration(milliseconds: 300));
      expect(weekJumpDuration(0), const Duration(milliseconds: 250));
    });
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: const TimetablePage(),
      ),
    );
    await _io(tester, 5);
  }

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name}：实际课表退出清除浏览周，取消返回和设置返回保留状态', (tester) async {
      _load(manual: [_course('a', '测试课甲')]);
      final router = buildRouter()..go('/profile');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          theme: brightness == Brightness.dark
              ? appDarkTheme()
              : appLightTheme(),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      router.push<void>('/apps/timetable');
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week + 1);
      await tester.tap(find.byKey(const Key('timetable_settings_button')));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week + 1);

      await tester.tap(find.textContaining('第 8 周', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_week_strip')), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_week_strip')), findsNothing);

      final route =
          ModalRoute.of(tester.element(find.byType(TimetablePage)))!
              as PageRoute;
      final edge = brightness == Brightness.light ? 0 : 1;
      Future<void> gesture(String method, {double progress = 0}) async {
        ByteData? response;
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': [edge == 0 ? 5.0 : 795.0, 300.0],
              'progress': progress,
              'swipeEdge': edge,
            }),
          ),
          (data) => response = data,
        );
        expect(response, isNotNull);
        final result = const StandardMethodCodec().decodeEnvelope(response!);
        if (method == 'startBackGesture') expect(result, isTrue);
        await tester.pumpAndSettle();
      }

      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', progress: 0.4);
      expect(route.animation!.value, closeTo(0.6, 0.001));
      await gesture('cancelBackGesture');
      expect(route.isCurrent, isTrue);
      expect(_c.viewingWeek, _week + 1);

      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', progress: 0.4);
      await gesture('commitBackGesture');
      expect(find.byType(TimetablePage), findsNothing);
      expect(_c.viewingWeek, _week);
      expect(router.routeInformationProvider.value.uri.path, '/profile');

      router.push<void>('/apps/timetable');
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week);
      expect(find.textContaining('第 7 周', findRichText: true), findsOneWidget);
      expect(find.byKey(const Key('timetable_week_strip')), findsNothing);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        6,
      );

      router.pop();
      await tester.pumpAndSettle();
      TimetableController.clock = () => DateTime(2026, 10, 19, 9);
      router.push<void>('/apps/timetable');
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week + 1);
      expect(find.textContaining('第 8 周', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  group('item 6 周条回本周', () {
    testWidgets('NAV02 跨 10 周：点周条「本周」直接动画（不先瞬移），500ms 内到本周', (tester) async {
      _load(manual: [_course('a', '测试课甲')], week: 17);
      await pumpPage(tester);
      expect(_c.viewingWeek, 17);
      expect(find.text('回到本周'), findsNothing);
      await tester.tap(find.textContaining('第 17 周'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('timetable_week_strip_current')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 没有先瞬移到第 8 周：动画刚开始仍在第 17 周附近。
      expect(_c.viewingWeek, greaterThan(_week + 5));
      await tester.pump(const Duration(milliseconds: 520));
      expect(_c.viewingWeek, _week);
      await tester.pumpAndSettle();
    });
  });

  group('item 5 顶栏周滑条', () {
    final strip = find.byKey(const Key('timetable_week_strip'));
    final sliderFinder = find.byKey(const Key('timetable_week_slider'));

    Future<void> slideToWeek(WidgetTester tester, int week) async {
      final slider = tester.widget<Slider>(sliderFinder);
      slider.onChanged?.call(week.toDouble());
      await tester.pump();
      slider.onChangeEnd?.call(week.toDouble());
    }

    testWidgets('NAV03 点周数弹出滑条，再点外部收起；读屏「第 N 周，本周」', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester);
      expect(strip, findsNothing);
      await tester.tap(find.textContaining('第 7 周', findRichText: true));
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget);
      expect(sliderFinder, findsOneWidget);
      expect(find.bySemanticsLabel('第 7 周，本周'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(strip, findsNothing);
      semantics.dispose();
    });

    testWidgets('NAV04 滑条默认定位选中周；松手后在背景翻到目标周且弹窗不自动关闭以便微调', (tester) async {
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester);
      await tester.tap(find.textContaining('第 7 周', findRichText: true));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(sliderFinder).value, 7);
      await slideToWeek(tester, 5);
      await tester.pump();
      // 翻周动画刚开始（2 周 → 300ms），还没到第 5 周。
      expect(_c.viewingWeek, isNot(5));
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget, reason: '松手后弹窗暂不关闭，方便继续微调');
      expect(_c.viewingWeek, 5);
      expect(tester.widget<Slider>(sliderFinder).value, 5);

      // 不关闭弹窗直接继续拖动微调到第 9 周。
      await slideToWeek(tester, 9);
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget);
      expect(_c.viewingWeek, 9);
      expect(tester.widget<Slider>(sliderFinder).value, 9);

      // 点外部关闭弹窗后再次打开，滑条仍定位在最新第 9 周。
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(strip, findsNothing);
      await tester.tap(find.textContaining('第 9 周'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(sliderFinder).value, 9);
      expect(
        find.byKey(const Key('timetable_week_strip_current')),
        findsOneWidget,
      );
    });

    testWidgets('NAV05 减少动画：滑条选周直接跳转', (tester) async {
      _load(manual: [_course('a', '测试课甲')]);
      await pumpPage(tester, disableAnimations: true);
      await tester.tap(find.textContaining('第 7 周', findRichText: true));
      await tester.pumpAndSettle();
      await slideToWeek(tester, 5);
      await tester.pump();
      expect(_c.viewingWeek, 5);
    });
  });
}
