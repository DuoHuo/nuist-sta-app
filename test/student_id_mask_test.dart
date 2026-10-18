import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/student_id_mask.dart';

void main() {
  test('12 位学号保留前 4 后 2', () {
    expect(maskStudentId('202312345601'), '2023******01');
  });

  test('10 位学号', () {
    expect(maskStudentId('2023123401'), '2023****01');
  });

  test('短串只留首位', () {
    expect(maskStudentId('123456'), '1*****');
    expect(maskStudentId('1'), '1');
  });

  test('空串原样返回', () {
    expect(maskStudentId(''), '');
  });
}
