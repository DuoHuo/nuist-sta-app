import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/student_info/student_info_models.dart';

void main() {
  test('校历缺字段 / 空对象返回 null', () {
    expect(SemesterInfo.tryFromJson(null), isNull);
    expect(SemesterInfo.tryFromJson(const {}), isNull);
    expect(
      SemesterInfo.tryFromJson({
        'xn': '2025',
        'xq': '',
        'ksrq': '',
        'jsrq': '',
      }),
      isNull,
    );
  });

  test('maxWeeks 为 "0" / 空时进度为 0，不出现 NaN', () {
    for (final w in ['0', '', null]) {
      final s = SemesterInfo.tryFromJson({
        'xn': '2025',
        'xq': '1',
        'ksrq': '2025-09-01',
        'jsrq': '2026-01-18',
        'maxWeeks': w,
      })!;
      expect(s.maxWeeks, 0);
      expect(s.progressAt(DateTime(2025, 10, 1)), 0);
    }
  });

  test('开学前进度钳到 0', () {
    final s = SemesterInfo.tryFromJson({
      'xn': '2025',
      'xq': '1',
      'ksrq': '2025-09-01',
      'jsrq': '2026-01-18',
      'maxWeeks': '20',
    })!;
    expect(s.progressAt(DateTime(2025, 8, 1)), 0);
  });
}
