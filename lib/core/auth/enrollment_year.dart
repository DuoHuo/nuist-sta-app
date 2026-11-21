/// 从学号前 4 位提取入学年份；保留课表现有的年份解析规则。
///
/// 本方法只解析年份。用于识别学生身份时，调用方还应校验完整学号与绑定账号。
int? enrollmentYearFromStudentId(String? studentId) {
  if (studentId == null) return null;
  final match = RegExp(r'^(\d{4})').firstMatch(studentId.trim());
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  if (year == null || year < 1990 || year > 2100) return null;
  return year;
}
