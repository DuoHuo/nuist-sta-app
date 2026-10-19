import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';

AcademicSummary _parse(Map<String, dynamic> json) =>
    AcademicSummary.fromJson(json, fetchedAt: DateTime(2025, 9, 1));

Map<String, dynamic> _all(Object? value) => {
  'XH': '202512340001',
  for (final k in [
    'YXZXF',
    'YHXF',
    'PJJD',
    'GPA',
    'PJF',
    'JQPJF',
    'BJPM',
    'ZYPM',
    'KCTGL',
    'XFJD',
  ])
    k: value,
};

void main() {
  test('新生全部字段为空串：进度为 0，通过率显示 --', () {
    final s = _parse(_all(''));
    expect(s.creditProgressRatio, 0);
    expect(s.passRateText, '--');
    expect(s.gpa, '');
  });

  test('新生全部字段为 "0"：进度为 0，通过率 0%', () {
    final s = _parse(_all('0'));
    expect(s.creditProgressRatio, 0);
    expect(s.passRateText, '0%');
  });

  test('JSON null 与字符串 "null" 统一归为空串', () {
    for (final v in [null, 'null', 'NULL']) {
      final s = _parse(_all(v));
      expect(s.requiredCredits, '');
      expect(s.creditProgress, '');
      expect(s.creditProgressRatio, 0);
      expect(s.passRateText, '--');
    }
  });

  test('字段缺失不崩溃', () {
    final s = _parse({'XH': '202512340001'});
    expect(s.creditProgressRatio, 0);
    expect(s.passRateText, '--');
  });

  test('XFJD 各种写法', () {
    double ratio(String xfjd) =>
        _parse({'XH': '202512340001', 'XFJD': xfjd}).creditProgressRatio;
    expect(ratio('32.9%'), closeTo(0.329, 1e-9));
    expect(ratio('32.9'), closeTo(0.329, 1e-9));
    expect(ratio('0.5'), 0.5);
    expect(ratio('0'), 0);
    expect(ratio('NaN%'), 0);
    expect(ratio('150%'), 1);
  });

  test('XFJD 为空时用已获 / 应修推算，应修为 0 不除零', () {
    expect(
      _parse({'YHXF': '30', 'YXZXF': '120', 'XFJD': ''}).creditProgressRatio,
      0.25,
    );
    expect(
      _parse({'YHXF': '0', 'YXZXF': '0', 'XFJD': ''}).creditProgressRatio,
      0,
    );
    expect(
      _parse({'YHXF': '', 'YXZXF': '0', 'XFJD': ''}).creditProgressRatio,
      0,
    );
  });

  test('passRateText 兼容空 / NaN / 正常比例', () {
    String text(String v) => _parse({'KCTGL': v}).passRateText;
    expect(text(''), '--');
    expect(text('NaN'), '--');
    expect(text('1'), '100%');
    expect(text('0.875'), '87.5%');
  });
}
