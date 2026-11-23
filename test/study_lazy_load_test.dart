import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/navigation/app_navigation.dart';
import 'package:nuist_sta_app/core/pull_to_refresh.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_controller.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_summary_card.dart';
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
import 'package:nuist_sta_app/shell/study/study_page.dart';

void main() {
  group('学习页不可见态懒加载远端刷新', () {
    testWidgets(
      'TickerMode(enabled: false) 等待超 3 秒仅预渲染 5 卡缓存且 0 次远端请求，切换可见后触发刷新且不重复读盘',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 1800);
        addTearDown(tester.view.reset);

        final fixture = _StudyFixture();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          fixture.dispose();
        });

        Widget host({required bool visible}) => MaterialApp(
          theme: appLightTheme(),
          home: TickerMode(
            enabled: visible,
            child: StudyPage(registry: fixture.registry),
          ),
        );

        await tester.pumpWidget(host(visible: false));
        expect(fixture.totalReads, 0);
        expect(fixture.totalFetches, 0);

        // 超过 2000 + 4 * 200 = 2800ms 的预挂载延迟，5 张卡片全部挂载并仅读本地缓存。
        await tester.pump(const Duration(milliseconds: 3500));
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

        // 继续停留在不可见态仍不发远端请求。
        await tester.pump(const Duration(seconds: 5));
        expect(fixture.totalFetches, 0);

        // 切换为可见态：立即触发 5 路远端刷新，且不重复读盘。
        await tester.pumpWidget(host(visible: true));
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

        // 切走再切回可见态不重复触发自动刷新。
        await tester.pumpWidget(host(visible: false));
        await tester.pump();
        await tester.pumpWidget(host(visible: true));
        await tester.pumpAndSettle();
        expect(fixture.totalFetches, 5);

        // 下拉刷新照常触发全部 5 张卡片。
        await tester
            .widget<PullToRefresh>(find.byType(PullToRefresh))
            .onRefresh();
        await tester.pumpAndSettle();
        expect(fixture.fetches, {
          'student-info': 2,
          'academic': 2,
          'scores': 2,
          'innovation-credit': 2,
          'labor-score': 2,
        });
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('窄屏 RootPage 冷启动停留在首页超 3 秒仅预渲染学习缓存且 0 次远端请求，切到学习页签后触发 5 路刷新', (
      tester,
    ) async {
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

      // 停留在首页超过 3 秒：学习页在后台预挂载 5 张卡片，只加载缓存，0 次远端请求。
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

      // 切到「学习」页签：触发 5 张卡片远端刷新，且不重复读盘。
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

    testWidgets('宽屏双栏初始可见时 5 张学习卡片立即触发远端刷新', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
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

    testWidgets('无缓存卡片切到可见后拉取失败仍可通过重试按钮恢复', (tester) async {
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
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(fetches, 2);
      expect(find.text('3.880'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏详情页在学习页仅读过缓存后直接打开仍触发远端刷新且不重复读盘', (tester) async {
      final staleAt = DateTime.now().subtract(const Duration(days: 1));
      var scoreReads = 0;
      var scoreFetches = 0;
      var innovationReads = 0;
      var innovationFetches = 0;

      final scoreController = ScoreController.forTesting(
        readCache: () async {
          scoreReads++;
          return _scoreReport('2025-2026-2', '旧成绩课程', staleAt);
        },
        saveCache: (_) async {},
        fetch: () async {
          scoreFetches++;
          return _scoreReport('2026-2027-1', '新成绩课程', DateTime.now());
        },
        bindingCheck: () async => true,
      );
      final innovationController = InnovationCreditController.forTesting(
        readCache: () async {
          innovationReads++;
          return _innovationCredit('12.0', '旧双创项目', staleAt);
        },
        saveCache: (_) async {},
        fetch: () async {
          innovationFetches++;
          return _innovationCredit('18.5', '新双创项目', DateTime.now());
        },
        bindingCheck: () async => true,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        scoreController.dispose();
        innovationController.dispose();
      });

      await scoreController.ensureCacheLoaded();
      await innovationController.ensureCacheLoaded();
      expect(scoreReads, 1);
      expect(scoreFetches, 0);
      expect(innovationReads, 1);
      expect(innovationFetches, 0);

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: ScorePage(controller: scoreController),
        ),
      );
      await tester.pumpAndSettle();
      expect(scoreReads, 1);
      expect(scoreFetches, 1);
      expect(find.text('新成绩课程'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: InnovationCreditPage(controller: innovationController),
        ),
      );
      await tester.pumpAndSettle();
      expect(innovationReads, 1);
      expect(innovationFetches, 1);
      expect(find.text('新双创项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
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
