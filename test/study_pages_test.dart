import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/navigation/app_navigation.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_controller.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_summary_card.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_controller.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_page.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_sheets.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_card.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_controller.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_page.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_card.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_controller.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_card.dart';
import 'package:nuist_sta_app/mini_apps/score/score_controller.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_page.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_card.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_controller.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';
import 'package:nuist_sta_app/router.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_controller.dart';
import 'package:nuist_sta_app/shell/deferred_while_hidden.dart';

void main() {
  group('学习页懒加载与状态恢复', () {
    testWidgets('窄屏冷启动停留在首页仅预挂载学习缓存且 0 次远端请求，切到学习页签后触发 5 路刷新', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1800);
      addTearDown(tester.view.reset);

      final fixture = _StudyFixture();
      final navigation = AppNavigationController();
      final announcements = AnnouncementController.test(
        fetch: ({etag, lastModified}) async =>
            const AnnouncementFetchResult(notModified: false, items: []),
      );
      final router = buildRouter(
        navigation: navigation,
        registry: fixture.registry,
        announcementController: announcements,
        ignorePlatformInitialRoute: true,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        navigation.dispose();
        router.dispose();
        announcements.dispose();
        fixture.dispose();
      });

      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );
      await tester.pump();
      expect(fixture.totalReads, 0);
      expect(fixture.totalFetches, 0);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(fixture.reads, {
        'student-info': 1,
        'academic': 1,
        'scores': 1,
        'innovation-credit': 1,
        'labor-score': 1,
      });
      expect(fixture.totalFetches, 0);
      for (final text in _StudyFixture.cachedTexts) {
        expect(find.text(text, skipOffstage: false), findsOneWidget);
      }

      await tester.tap(find.text('学习'));
      await tester.pumpAndSettle();

      expect(fixture.reads, {
        'student-info': 1,
        'academic': 1,
        'scores': 1,
        'innovation-credit': 1,
        'labor-score': 1,
      });
      expect(fixture.fetches, {
        'student-info': 1,
        'academic': 1,
        'scores': 1,
        'innovation-credit': 1,
        'labor-score': 1,
      });
      for (final text in _StudyFixture.freshTexts) {
        expect(find.text(text), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('无缓存卡片切到可见后失败可重试恢复，DeferredWhileHidden 与零数据进度状态正确', (
      tester,
    ) async {
      var fetches = 0;
      var failFirst = true;
      final fresh = AcademicSummary.fromJson({
        'XH': '202512340001',
        'GPA': '3.880',
        'PJJD': '4.120',
        'PJF': '91.5',
      }, fetchedAt: DateTime.now());
      final controller = AcademicController.forTesting(
        readCache: () async => null,
        saveCache: (_) async {},
        fetch: () async {
          fetches++;
          if (failFirst) {
            failFirst = false;
            throw const PortalCredentialError('登录凭据已失效');
          }
          return fresh;
        },
        bindingCheck: () async => true,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: TickerMode(
            enabled: false,
            child: Scaffold(body: AcademicSummaryCard(controller: controller)),
          ),
        ),
      );
      await tester.pump();
      expect(fetches, 0);

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: TickerMode(
            enabled: true,
            child: Scaffold(body: AcademicSummaryCard(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fetches, 1);
      expect(find.text('登录凭据已失效'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(fetches, 2);
      expect(find.text('3.880'), findsOneWidget);

      var builds = 0;
      Widget deferredHost({required bool visible}) => Directionality(
        textDirection: TextDirection.ltr,
        child: TickerMode(
          enabled: visible,
          child: DeferredWhileHidden(
            delay: const Duration(seconds: 1),
            builder: (_) {
              builds++;
              return const Text('延迟卡片');
            },
          ),
        ),
      );
      await tester.pumpWidget(deferredHost(visible: false));
      expect(builds, 0);
      await tester.pump(const Duration(milliseconds: 900));
      expect(builds, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(builds, 1);
      await tester.pumpWidget(deferredHost(visible: false));
      expect(find.text('延迟卡片', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());

      final empty = AcademicSummary.fromJson({
        'XH': '202512340001',
      }, fetchedAt: DateTime(2025, 9, 1));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AcademicSummaryBody(summary: empty)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0,
      );
      expect(find.text('已获 -- / 应修 --　0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('成绩与双创页面', () {
    testWidgets('窄屏初始态布局与成绩/双创空记录卡片正确渲染', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const ScorePage()),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '成绩查询'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              const {'未绑定统一门户', '暂无成绩数据', '正在获取成绩…'}.contains(widget.data),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      final score = _scoreController(
        ScoreReport(records: const [], fetchedAt: DateTime.now()),
      );
      final innovation = _innovationController(
        InnovationCredit(
          total: '0',
          grade: '',
          items: const [],
          fetchedAt: DateTime.now(),
        ),
      );
      addTearDown(score.dispose);
      addTearDown(innovation.dispose);

      await _pumpNarrowPage(tester, ScorePage(controller: score));
      expect(find.text('这个学期还没有成绩记录'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpNarrowPage(
        tester,
        InnovationCreditPage(controller: innovation),
      );
      expect(find.text('暂无已认定的双创学分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('200 门成绩与 200 项双创学分按可视范围懒加载并可滚动至末行', (tester) async {
      final report = ScoreReport(
        records: [
          for (var index = 0; index < 200; index++)
            ScoreRecord.fromJson({
              'term': '2026-2027-1',
              'courseName': '测试课程 $index',
              'score': '80',
              'credit': '1',
            }),
        ],
        fetchedAt: DateTime.now(),
      );
      final scoreController = _scoreController(report);
      addTearDown(scoreController.dispose);
      await _pumpNarrowPage(tester, ScorePage(controller: scoreController));
      expect(find.text('200 门'), findsNWidgets(2));
      await _expectLazyRows(tester, '测试课程');
      expect(tester.takeException(), isNull);

      final credit = InnovationCredit(
        total: '200',
        grade: '合格',
        items: [
          for (var index = 0; index < 200; index++)
            InnovationCreditItem.fromJson({
              'name': '测试项目 $index',
              'score': '1',
              'date': '2026-10-01',
              'status': '审核通过',
            }),
        ],
        fetchedAt: DateTime.now(),
      );
      final innovationController = _innovationController(credit);
      addTearDown(innovationController.dispose);
      await _pumpNarrowPage(
        tester,
        InnovationCreditPage(controller: innovationController),
      );
      await _expectLazyRows(tester, '测试项目');
      expect(tester.takeException(), isNull);
    });
  });

  group('空教室页面与筛选交互', () {
    testWidgets('360 宽布局、吸顶滚动、时段点击、分区筛选与单选面板交互无溢出', (tester) async {
      const options = [
        SheetOption<String>(value: null, label: '全部教室'),
        SheetOption<String>(value: '实验室', label: '实验室', hint: '3 间'),
      ];
      SheetOption<String>? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showOptionSheet<String>(
                    context,
                    title: '房间类型',
                    options: options,
                    current: '实验室',
                  );
                },
                child: const Text('选择类型'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择类型'));
      await tester.pumpAndSettle();
      expect(find.text('3 间'), findsOneWidget);
      await tester.tap(find.text('全部教室'));
      await tester.pumpAndSettle();
      expect(picked, same(options.first));

      await tester.tap(find.text('选择类型'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(picked, isNull);
      expect(tester.takeException(), isNull);

      await _pumpFreeClassroomPage(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('文德楼'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      for (final label in ['1-2', '3-4', '5-6', '7-8', '9-11']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('所选时段全部空闲'), findsOneWidget);
      expect(find.text('文德S401'), findsNothing);
      expect(find.textContaining('间可用'), findsOneWidget);

      expect(find.text('N 区'), findsOneWidget);
      expect(find.text('C 区'), findsOneWidget);
      expect(find.text('S 区'), findsOneWidget);
      await tester.tap(find.text('C 区'));
      await tester.pumpAndSettle();
      expect(find.text('文德C104'), findsOneWidget);
      expect(find.text('文德N201'), findsNothing);
      expect(find.text('文德N101A'), findsNothing);

      await tester.tap(find.text('C 区'));
      await tester.pumpAndSettle();
      final list = find.byType(CustomScrollView);
      await tester.drag(list, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('间可用'), findsOneWidget);
      expect(find.text('1-2').hitTestable(), findsOneWidget);

      await tester.tap(find.text('1-2'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('全占用的教室默认折叠在最底部，点段标题可展开与收起', (tester) async {
      await _pumpFreeClassroomPage(tester);
      final list = find.byType(CustomScrollView);
      await tester.drag(list, const Offset(0, -2000));
      await tester.pumpAndSettle();
      final busyHeader = find.text('所选时段全部占用');
      expect(busyHeader, findsOneWidget);
      expect(find.text('文德N203'), findsNothing);

      await tester.tap(busyHeader);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(list, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('文德N203'), findsOneWidget);

      await tester.drag(list, const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所选时段全部空闲'));
      await tester.pumpAndSettle();
      expect(find.text('文德N201'), findsNothing);
    });
  });
}

ScoreController _scoreController(ScoreReport report) =>
    ScoreController.forTesting(
      readCache: () async => report,
      saveCache: (_) async {},
      fetch: () async => report,
      bindingCheck: () async => true,
    );

InnovationCreditController _innovationController(InnovationCredit credit) =>
    InnovationCreditController.forTesting(
      readCache: () async => credit,
      saveCache: (_) async {},
      fetch: () async => credit,
      bindingCheck: () async => true,
    );

Future<void> _pumpNarrowPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(MaterialApp(theme: appLightTheme(), home: page));
  await tester.pumpAndSettle();
}

Future<void> _expectLazyRows(WidgetTester tester, String prefix) async {
  expect(find.text('$prefix 0'), findsOneWidget);
  expect(find.text('$prefix 199', skipOffstage: false), findsNothing);
  expect(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.startsWith(prefix) ?? false),
          skipOffstage: false,
        )
        .evaluate()
        .length,
    lessThan(30),
  );
  await tester.scrollUntilVisible(
    find.text('$prefix 199'),
    600,
    scrollable: find.byType(Scrollable),
    maxScrolls: 80,
  );
  await tester.pumpAndSettle();
  expect(find.text('$prefix 199').hitTestable(), findsOneWidget);
  expect(find.text('$prefix 0', skipOffstage: false), findsNothing);
}

Future<void> _pumpFreeClassroomPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
  final day = _fakeClassroomDay();
  final c = FreeClassroomController.instance;
  c.debugSetResult(
    day,
    buildings: [
      day.building,
      const Building(code: '1-202', name: '明德楼'),
    ],
  );
  c.setZone(null);
  c.setFloor(null);
  c.setType(null);
  c.setMinSeats(0);
  await tester.pumpWidget(const MaterialApp(home: FreeClassroomPage()));
  await tester.pumpAndSettle();
}

ClassroomDay _fakeClassroomDay() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  const building = Building(code: '1-120', name: '文德楼');
  final calendar = TermCalendar(
    termCode: '2026-2027-1',
    week: 4,
    weekday: today.weekday,
    groups: PeriodGroup.defaults,
  );
  Map<String, dynamic> row(
    String name,
    String type,
    int floor,
    int seats,
    List<String?> jc,
  ) => {
    'JASMC': name,
    'JASLXDM_DISPLAY': type,
    'LC': floor,
    'SKZWS': seats,
    for (var i = 0; i < jc.length; i++) 'JC${i + 1}': jc[i],
  };
  const free = <String?>[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
  ];
  final rows = <Map<String, dynamic>>[
    row('文德N101A', '多媒体教室', 1, 180, [
      '0_01',
      '0_01',
      '0_01',
      '0_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '1_01',
      '0_01',
    ]),
    row('文德N102', '多媒体教室', 1, 120, [
      '1_01',
      '1_01',
      null,
      null,
      null,
      null,
      '1_04',
      '1_04',
      null,
      null,
      null,
    ]),
    row('文德C104', '实验室', 1, 36, free),
    row('文德N201', '多媒体教室', 2, 90, free),
    row('文德N202', '考研自习室', 2, 60, [
      null,
      null,
      null,
      null,
      null,
      '1_01',
      null,
      null,
      null,
      null,
      null,
    ]),
    row('文德N203', '多媒体教室', 2, 90, List<String?>.filled(11, '1_02')),
    row('文德N301', '大外部语音室', 3, 48, free),
    row('文德N302', '多媒体教室', 3, 150, [
      null,
      null,
      '1_01',
      '1_01',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
    ]),
    row('文德S401', '教师办公室', 4, 0, free),
    row('室外教室-雷丁', '实验室', 0, 0, free),
    for (var i = 1; i <= 12; i++)
      row('文德N5${i.toString().padLeft(2, '0')}', '多媒体教室', 5, 60, free),
  ];
  return ClassroomDay(
    date: today,
    building: building,
    calendar: calendar,
    rooms: [for (final r in rows) Classroom.fromRow(r, 11)],
    fetchedAt: now,
  );
}

class _StudyFixture {
  _StudyFixture() {
    final now = DateTime.now();
    final staleAt = now.subtract(const Duration(days: 1));

    studentInfo = StudentInfoController.forTesting(
      readCache: () async {
        reads['student-info'] = (reads['student-info'] ?? 0) + 1;
        return _studentInfo(2025, '1', staleAt);
      },
      saveCache: (_) async {},
      fetch: () async {
        fetches['student-info'] = (fetches['student-info'] ?? 0) + 1;
        return _studentInfo(2026, '2', DateTime.now());
      },
      bindingCheck: () async => true,
    );
    academic = AcademicController.forTesting(
      readCache: () async {
        reads['academic'] = (reads['academic'] ?? 0) + 1;
        return _academicSummary('3.500', staleAt);
      },
      saveCache: (_) async {},
      fetch: () async {
        fetches['academic'] = (fetches['academic'] ?? 0) + 1;
        return _academicSummary('3.950', DateTime.now());
      },
      bindingCheck: () async => true,
    );
    score = ScoreController.forTesting(
      readCache: () async {
        reads['scores'] = (reads['scores'] ?? 0) + 1;
        return _scoreReport('2025-2026-2', '缓存课程', staleAt);
      },
      saveCache: (_) async {},
      fetch: () async {
        fetches['scores'] = (fetches['scores'] ?? 0) + 1;
        return _scoreReport('2026-2027-1', '最新课程', DateTime.now());
      },
      bindingCheck: () async => true,
    );
    innovation = InnovationCreditController.forTesting(
      readCache: () async {
        reads['innovation-credit'] = (reads['innovation-credit'] ?? 0) + 1;
        return _innovationCredit('12.0', '缓存双创项目', staleAt);
      },
      saveCache: (_) async {},
      fetch: () async {
        fetches['innovation-credit'] = (fetches['innovation-credit'] ?? 0) + 1;
        return _innovationCredit('18.5', '最新双创项目', DateTime.now());
      },
      bindingCheck: () async => true,
    );
    labor = LaborScoreController.forTesting(
      readCache: () async {
        reads['labor-score'] = (reads['labor-score'] ?? 0) + 1;
        return _laborScore('88', '2026-10-01', staleAt);
      },
      saveCache: (_) async {},
      fetch: () async {
        fetches['labor-score'] = (fetches['labor-score'] ?? 0) + 1;
        return _laborScore('96', '2026-11-20', DateTime.now());
      },
      bindingCheck: () async => true,
    );

    registry = AppRegistry([
      AppManifest.cardOnly(
        id: 'student-info',
        label: '本学期',
        studyCard: StudyCardContribution(
          builder: (_) => StudentInfoCard(controller: studentInfo),
          order: 10,
          onRefresh: studentInfo.refresh,
        ),
      ),
      AppManifest.cardOnly(
        id: 'academic',
        label: '学业概览',
        studyCard: StudyCardContribution(
          builder: (_) => AcademicSummaryCard(controller: academic),
          order: 20,
          onRefresh: academic.refresh,
        ),
      ),
      AppManifest(
        id: 'scores',
        label: '成绩查询',
        color: kScoreColor,
        icon: Icons.assessment_outlined,
        entry: (_) => ScorePage(controller: score),
        showInHomeGrid: false,
        studyCard: StudyCardContribution(
          builder: (_) => ScoreCard(controller: score),
          order: 30,
          onRefresh: score.refresh,
        ),
      ),
      AppManifest(
        id: 'innovation-credit',
        label: '双创学分',
        color: kInnovationColor,
        icon: Icons.lightbulb_outline,
        entry: (_) => InnovationCreditPage(controller: innovation),
        showInHomeGrid: false,
        studyCard: StudyCardContribution(
          builder: (_) => InnovationCreditCard(controller: innovation),
          order: 40,
          onRefresh: innovation.refresh,
        ),
      ),
      AppManifest(
        id: 'labor-score',
        label: '劳动积分',
        color: kLaborColor,
        icon: Icons.volunteer_activism_outlined,
        entry: (_) => const SizedBox.shrink(),
        showInHomeGrid: false,
        studyCard: StudyCardContribution(
          builder: (_) => LaborScoreCard(controller: labor),
          order: 50,
          onRefresh: labor.refresh,
        ),
      ),
    ]);
  }

  static const cachedTexts = [
    '2025-2026-1',
    '3.500',
    '2025-2026-2',
    '缓存双创项目',
    '核算于 10-01',
  ];

  static const freshTexts = [
    '2026-2027-2',
    '3.950',
    '2026-2027-1',
    '最新双创项目',
    '核算于 11-20',
  ];

  final reads = <String, int>{};
  final fetches = <String, int>{};
  late final StudentInfoController studentInfo;
  late final AcademicController academic;
  late final ScoreController score;
  late final InnovationCreditController innovation;
  late final LaborScoreController labor;
  late final AppRegistry registry;

  int get totalReads => reads.values.fold(0, (a, b) => a + b);
  int get totalFetches => fetches.values.fold(0, (a, b) => a + b);

  void dispose() {
    studentInfo.dispose();
    academic.dispose();
    score.dispose();
    innovation.dispose();
    labor.dispose();
  }
}

StudentInfo _studentInfo(int year, String term, DateTime fetchedAt) =>
    StudentInfo(
      user: const PortalUser(
        name: '测试学生',
        studentId: '202512340001',
        categoryName: '本科生',
        deptName: '测试学院',
      ),
      semester: SemesterInfo(
        year: year,
        term: term,
        start: DateTime(year, 9, 1),
        end: DateTime(year + 1, 1, 20),
        maxWeeks: 20,
      ),
      fetchedAt: fetchedAt,
    );

AcademicSummary _academicSummary(String gpa, DateTime fetchedAt) =>
    AcademicSummary.fromJson({
      'XH': '202512340001',
      'YXZXF': '160',
      'YHXF': '80',
      'PJJD': '4.000',
      'GPA': gpa,
      'PJF': '90.0',
      'JQPJF': '89.5',
      'BJPM': '5 / 30',
      'ZYPM': '10 / 120',
      'KCTGL': '1',
      'XFJD': '50%',
    }, fetchedAt: fetchedAt);

ScoreReport _scoreReport(String term, String courseName, DateTime fetchedAt) =>
    ScoreReport(
      records: [
        ScoreRecord(
          term: term,
          courseName: courseName,
          courseCode: 'TEST-01',
          score: '92',
          credit: '3',
          gradePoint: '4.2',
          passStatus: '通过',
          examType: '',
          usualScore: '',
          finalScore: '',
          retakeType: '',
        ),
      ],
      fetchedAt: fetchedAt,
    );

InnovationCredit _innovationCredit(
  String total,
  String projectName,
  DateTime fetchedAt,
) => InnovationCredit(
  total: total,
  grade: '合格',
  items: [
    InnovationCreditItem(
      name: projectName,
      date: '2026-10-01',
      category1: '',
      category2: '',
      level: '',
      standardScore: '',
      score: '2',
      batch: '',
      status: '学校审核学分通过',
    ),
  ],
  fetchedAt: fetchedAt,
);

LaborScore _laborScore(String total, String updatedAt, DateTime fetchedAt) =>
    LaborScore(
      official: LaborResult(
        theory: '20',
        life: '20',
        service: '24',
        majorCourse: '12',
        majorContest: '12',
        majorTotal: '24',
        total: total,
        confirmed: '是',
        updatedAt: updatedAt,
        filed: '否',
        filedAt: '',
      ),
      liveLife: null,
      liveService: null,
      liveMajor: null,
      fetchedAt: fetchedAt,
    );
