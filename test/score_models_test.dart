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
}
