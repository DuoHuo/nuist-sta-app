import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_alert.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_sync_diff.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

void main() {
  test('变动胶囊 token：浅/深成对且走 TimetableColors', () {
    final light = TimetableColors.light;
    final dark = TimetableColors.dark;

    expect(light.changeAddedBg, TimetableTheme.changeAddedBg);
    expect(light.changeAddedFg, TimetableTheme.changeAddedFg);
    expect(dark.changeAddedBg, TimetableTheme.changeAddedBgDark);
    expect(dark.changeAddedFg, TimetableTheme.changeAddedFgDark);

    expect(light.changeRemovedBg, TimetableTheme.changeRemovedBg);
    expect(dark.changeRemovedFg, TimetableTheme.changeRemovedFgDark);
    expect(light.changeTimeBg, TimetableTheme.changeTimeBg);
    expect(dark.changeTimeFg, TimetableTheme.changeTimeFgDark);
    expect(light.changeLocationFg, TimetableTheme.changeLocationFg);
    expect(dark.changeLocationBg, TimetableTheme.changeLocationBgDark);
    expect(light.changeTeacherBg, TimetableTheme.changeTeacherBg);
    expect(dark.changeTeacherFg, TimetableTheme.changeTeacherFgDark);
    expect(light.changeRetakeFg, TimetableTheme.changeRetakeFg);
    expect(dark.changeRetakeBg, TimetableTheme.changeRetakeBgDark);

    // 明暗必须不同（漏配深色会挂）。
    expect(dark.changeAddedBg, isNot(light.changeAddedBg));
    expect(dark.changeAddedFg, isNot(light.changeAddedFg));
    expect(dark.changeRemovedBg, isNot(light.changeRemovedBg));
    expect(dark.changeRemovedFg, isNot(light.changeRemovedFg));
    expect(dark.changeTimeBg, isNot(light.changeTimeBg));
    expect(dark.changeTimeFg, isNot(light.changeTimeFg));
    expect(dark.changeLocationBg, isNot(light.changeLocationBg));
    expect(dark.changeLocationFg, isNot(light.changeLocationFg));
    expect(dark.changeTeacherBg, isNot(light.changeTeacherBg));
    expect(dark.changeTeacherFg, isNot(light.changeTeacherFg));
    expect(dark.changeRetakeBg, isNot(light.changeRetakeBg));
    expect(dark.changeRetakeFg, isNot(light.changeRetakeFg));
  });

  test('变动胶囊色值：设计师定稿', () {
    final light = TimetableColors.light;
    final dark = TimetableColors.dark;

    expect(light.changeAddedBg.toARGB32(), 0xFFE8F5E9);
    expect(light.changeAddedFg.toARGB32(), 0xFF2E7D32);
    expect(dark.changeAddedBg.toARGB32(), 0xFF1F3A24);
    expect(dark.changeAddedFg.toARGB32(), 0xFF81C784);

    expect(light.changeRemovedBg.toARGB32(), 0xFFFDECEA);
    expect(light.changeRemovedFg.toARGB32(), 0xFFC62828);
    expect(dark.changeRemovedBg.toARGB32(), 0xFF3D1F1F);
    expect(dark.changeRemovedFg.toARGB32(), 0xFFEF9A9A);

    expect(light.changeTimeBg.toARGB32(), 0xFFFFF3E0);
    expect(light.changeTimeFg.toARGB32(), 0xFFE65100);
    expect(dark.changeTimeBg.toARGB32(), 0xFF3D2C14);
    expect(dark.changeTimeFg.toARGB32(), 0xFFFFB74D);

    expect(light.changeLocationBg.toARGB32(), 0xFFE3F2FD);
    expect(light.changeLocationFg.toARGB32(), 0xFF1565C0);
    expect(dark.changeLocationBg.toARGB32(), 0xFF1A2C3D);
    expect(dark.changeLocationFg.toARGB32(), 0xFF90CAF9);

    expect(light.changeTeacherBg.toARGB32(), 0xFFF3E5F5);
    expect(light.changeTeacherFg.toARGB32(), 0xFF6A1B9A);
    expect(dark.changeTeacherBg.toARGB32(), 0xFF2E1F36);
    expect(dark.changeTeacherFg.toARGB32(), 0xFFCE93D8);

    expect(light.changeRetakeBg.toARGB32(), 0xFFECEFF1);
    expect(light.changeRetakeFg.toARGB32(), 0xFF455A64);
    expect(dark.changeRetakeBg.toARGB32(), 0xFF263238);
    expect(dark.changeRetakeFg.toARGB32(), 0xFFB0BEC5);
  });

  test('changeTypeChipStyle 按类型取 token，不硬编码', () {
    final light = TimetableColors.light;
    final dark = TimetableColors.dark;

    expect(changeTypeChipStyle(TimetableChangeType.added, light), (
      bg: light.changeAddedBg,
      fg: light.changeAddedFg,
    ));
    expect(changeTypeChipStyle(TimetableChangeType.removed, dark), (
      bg: dark.changeRemovedBg,
      fg: dark.changeRemovedFg,
    ));
    expect(changeTypeChipStyle(TimetableChangeType.timeChanged, light), (
      bg: light.changeTimeBg,
      fg: light.changeTimeFg,
    ));
    expect(changeTypeChipStyle(TimetableChangeType.locationChanged, dark), (
      bg: dark.changeLocationBg,
      fg: dark.changeLocationFg,
    ));
    expect(changeTypeChipStyle(TimetableChangeType.teacherChanged, light), (
      bg: light.changeTeacherBg,
      fg: light.changeTeacherFg,
    ));
    expect(changeTypeChipStyle(TimetableChangeType.retakeFlagChanged, dark), (
      bg: dark.changeRetakeBg,
      fg: dark.changeRetakeFg,
    ));
  });

  test('labelZh 文案保持不变', () {
    expect(TimetableChangeType.added.labelZh, '新增');
    expect(TimetableChangeType.removed.labelZh, '删除');
    expect(TimetableChangeType.locationChanged.labelZh, '地点变动');
    expect(TimetableChangeType.teacherChanged.labelZh, '教师变动');
    expect(TimetableChangeType.timeChanged.labelZh, '时间变动');
    expect(TimetableChangeType.retakeFlagChanged.labelZh, '调课标记变动');
  });
}
