import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_summary_card.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_controller.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_home_card.dart';
import 'package:nuist_sta_app/mini_apps/electricity/electricity_models.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_card.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_controller.dart';
import 'package:nuist_sta_app/mini_apps/innovation_credit/innovation_credit_models.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_card.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_controller.dart';
import 'package:nuist_sta_app/mini_apps/labor_score/labor_score_models.dart';
import 'package:nuist_sta_app/mini_apps/score/score_card.dart';
import 'package:nuist_sta_app/mini_apps/score/score_controller.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_card.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_controller.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${dark ? '深色' : '浅色'} 320 dp 已加载卡片在 $scale 倍字体下保留完整指标', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.reset);
        final now = DateTime.now();
        final student = StudentInfo(
          user: const PortalUser(
            name: '测试学生',
            studentId: '202512340001',
            categoryName: '合成班级',
            deptName: '合成学院',
          ),
          semester: SemesterInfo(
            year: 2026,
            term: '1',
            start: now.subtract(const Duration(days: 40)),
            end: now.add(const Duration(days: 100)),
            maxWeeks: 20,
          ),
          fetchedAt: now,
        );
        final labor = LaborScore(
          official: const LaborResult(
            theory: '12.5',
            life: '34.5',
            service: '56.5',
            majorCourse: '7',
            majorContest: '8',
            majorTotal: '78.5',
            total: '182',
            confirmed: '是',
            updatedAt: '2026-11-20',
            filed: '否',
            filedAt: '',
          ),
          liveLife: null,
          liveService: null,
          liveMajor: null,
          fetchedAt: now,
        );
        final scores = ScoreReport(
          records: [
            for (var i = 0; i < 12; i++)
              ScoreRecord(
                term: '2026-2027-1',
                courseName: '合成课程$i',
                courseCode: 'test-$i',
                score: '98',
                credit: '3.25',
                gradePoint: '4',
                passStatus: '通过',
                examType: '',
                usualScore: '',
                finalScore: '',
                retakeType: '',
              ),
          ],
          fetchedAt: now,
        );
        const projectName = '用于验证窄栏与大字体下完整展示的合成创新实践项目';
        final innovation = InnovationCredit(
          total: '123.5',
          grade: '合格',
          items: const [
            InnovationCreditItem(
              name: projectName,
              date: '2026-11-20',
              category1: '',
              category2: '',
              level: '',
              standardScore: '',
              score: '12.5',
              batch: '',
              status: '学校审核学分通过',
            ),
          ],
          fetchedAt: now,
        );
        const room = ElecRoom(
          campus: ElecOption(name: '合成校区', value: 'test-campus'),
          building: ElecOption(name: '测试楼', value: 'test-building'),
          room: ElecOption(name: '测试房间', value: 'test-room'),
        );
        final studentController = StudentInfoController.forTesting(
          readCache: () async => student,
          saveCache: (_) async {},
          fetch: () async => student,
          bindingCheck: () async => true,
        );
        final laborController = LaborScoreController.forTesting(
          readCache: () async => labor,
          saveCache: (_) async {},
          fetch: () async => labor,
          bindingCheck: () async => true,
        );
        final scoreController = ScoreController.forTesting(
          readCache: () async => scores,
          saveCache: (_) async {},
          fetch: () async => scores,
          bindingCheck: () async => true,
        );
        final innovationController = InnovationCreditController.forTesting(
          readCache: () async => innovation,
          saveCache: (_) async {},
          fetch: () async => innovation,
          bindingCheck: () async => true,
        );
        final electricityController = ElectricityController.forTesting(
          bindingCheck: () async => true,
          readRoom: () async => room,
          readLatest: (_) async => ElecReading(time: now, kwh: 123.45),
          queryBalance: (_) async => 123.45,
          appendReading: (_, _) async {},
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          for (final controller in <ChangeNotifier>[
            studentController,
            laborController,
            scoreController,
            innovationController,
            electricityController,
          ]) {
            controller.dispose();
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? appDarkTheme() : appLightTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      StudentInfoCard(controller: studentController),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: AcademicSummaryBody(
                          summary: AcademicSummary.fromJson({
                            'XH': '202512340001',
                            'YXZXF': '180',
                            'YHXF': '123.5',
                            'PJJD': '4.321',
                            'GPA': '3.875',
                            'PJF': '98.75',
                            'JQPJF': '97.625',
                            'BJPM': '123 / 4567',
                            'ZYPM': '234 / 5678',
                            'KCTGL': '0.999',
                            'XFJD': '68.6%',
                          }, fetchedAt: now),
                        ),
                      ),
                      LaborScoreCard(controller: laborController),
                      const SizedBox(height: 12),
                      ScoreCard(controller: scoreController),
                      const SizedBox(height: 12),
                      InnovationCreditCard(controller: innovationController),
                      const SizedBox(height: 12),
                      ElectricityHomeCard(controller: electricityController),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final value in [
          '4.321',
          '3.875',
          '98.75',
          '97.625',
          '123 / 4567',
          '234 / 5678',
          '课程通过率',
          '学分加权平均分',
          '已确认',
          '78.5',
          '12 门',
          '39',
          projectName,
        ]) {
          final finder = find.text(value);
          expect(finder, findsWidgets, reason: value);
          for (final element in finder.evaluate()) {
            final paragraph = element.findRenderObject()! as RenderParagraph;
            expect(paragraph.didExceedMaxLines, isFalse, reason: value);
          }
        }
        await tester.ensureVisible(find.byType(ElectricityHomeCard));
        await tester.pumpAndSettle();
        expect(find.byType(FittedBox), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
