import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';

void main() {
  test('教务成绩行兼容 display 字段并识别通过状态', () {
    final record = ScoreRecord.fromRow({
      'XNXQDM': '2025-2026-2',
      'KCM': '程序设计',
      'KCH': 'CS1001',
      'ZCJ_DISPLAY': '88',
      'XF': '3',
      'XFJD': '4.0',
      'SFJG_DISPLAY': '及格',
      'KSLXDM_DISPLAY': '期末考试',
    });

    expect(record.term, '2025-2026-2');
    expect(record.courseName, '程序设计');
    expect(record.numericScore, 88);
    expect(record.passed, isTrue);
    expect(record.failed, isFalse);
  });

  test('单科成绩学分不四舍五入', () {
    final record = ScoreRecord.fromRow({'KCM': '程序设计', 'XF': '2.678'});
    expect(record.creditText, '2.67');

    final integerRecord = ScoreRecord.fromRow({'KCM': '高等数学', 'XF': '3.0'});
    expect(integerRecord.creditText, '3');
  });

  test('成绩报告按学期倒序，并计算学期概览', () {
    final report = ScoreReport(
      records: [
        ScoreRecord.fromRow({
          'XNXQDM': '2024-2025-2',
          'KCM': '旧课',
          'ZCJ': '59',
          'XF': '2',
        }),
        ScoreRecord.fromRow({
          'XNXQDM': '2025-2026-1',
          'KCM': '高数',
          'ZCJ': '90',
          'XF': '4',
        }),
        ScoreRecord.fromRow({
          'XNXQDM': '2025-2026-1',
          'KCM': '英语',
          'ZCJ': '80',
          'XF': '2',
        }),
      ],
      fetchedAt: DateTime(2026, 9, 23),
    );

    expect(report.latestTerm, '2025-2026-1');
    final summary = report.summaryFor(report.latestTerm);
    expect(summary.total, 2);
    expect(summary.passed, 2);
    expect(summary.credits, 6);
    expect(summary.averageScore, 85);
  });

  test('优良中及格等等级成绩也能判断通过', () {
    final record = ScoreRecord.fromRow({'KCM': '体育', 'ZCJ_DISPLAY': '优秀'});
    expect(record.passed, isTrue);
    expect(record.numericScore, 95);
  });

  test('credit formatting keeps integers and truncates decimals', () {
    final summary = ScoreTermSummary(
      term: '2025-2026-1',
      total: 3,
      passed: 3,
      failed: 0,
      credits: 6,
      averageScore: 90,
    );
    expect(summary.creditsText, '6');

    final decimalSummary = ScoreTermSummary(
      term: '2025-2026-1',
      total: 3,
      passed: 3,
      failed: 0,
      credits: 2.678,
      averageScore: 90,
    );
    expect(decimalSummary.creditsText, '2.67');

    final shortDecimalSummary = ScoreTermSummary(
      term: '2025-2026-1',
      total: 3,
      passed: 3,
      failed: 0,
      credits: 4.1,
      averageScore: 90,
    );
    expect(shortDecimalSummary.creditsText, '4.10');
  });
}
