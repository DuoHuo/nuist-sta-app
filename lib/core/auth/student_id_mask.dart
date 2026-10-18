/// 学号脱敏：长度大于 6 时保留前 4 位和后 2 位，中间每位换成 `*`
/// （`202312345601` → `2023******01`）；长度不超过 6 时只保留首位，
/// 免得短串几乎原样露出来。空串原样返回。
String maskStudentId(String id) {
  if (id.isEmpty) return id;
  if (id.length <= 6) return id[0] + '*' * (id.length - 1);
  return id.substring(0, 4) +
      '*' * (id.length - 6) +
      id.substring(id.length - 2);
}
