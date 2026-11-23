import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('S9 Android MainActivity 主线程减负与 Glance 依赖精简', () {
    test('clearLegacyShortcuts 通过 TimetableNativeWork.background 异步执行并记录一次性标记', () {
      final source = File(
        'android/app/src/main/kotlin/dev/duohuo/nuist_sta_app/MainActivity.kt',
      ).readAsStringSync();

      final startIndex = source.indexOf('private fun clearLegacyShortcuts()');
      expect(startIndex, isNonNegative);
      final clearBody = source.substring(startIndex);

      expect(
        clearBody,
        contains(
          'TimetableNativeWork.background(context, "shortcut.clear_legacy", "legacy_shortcut_clear_failed")',
        ),
      );
      expect(
        clearBody,
        contains(
          'getSharedPreferences("timetable_legacy_cleanup", MODE_PRIVATE)',
        ),
      );
      expect(
        clearBody,
        contains('getBoolean("legacy_shortcuts_cleared_v1", false)'),
      );
      expect(
        clearBody,
        contains('putBoolean("legacy_shortcuts_cleared_v1", true).apply()'),
      );
      expect(
        clearBody,
        contains('removeDynamicShortcuts(listOf("add_timetable_widget"))'),
      );
      expect(
        clearBody,
        contains('disableShortcuts(listOf("add_timetable_widget"))'),
      );
    });

    test('nuist/diagnostic_logging 队列读写与清理通过 TimetableNativeWork.reply 移出主线程', () {
      final source = File(
        'android/app/src/main/kotlin/dev/duohuo/nuist_sta_app/MainActivity.kt',
      ).readAsStringSync();

      final channelStart = source.indexOf('"nuist/diagnostic_logging"');
      final nextChannelStart = source.indexOf('"nuist/timetable_next_day"');
      expect(channelStart, isNonNegative);
      expect(nextChannelStart, greaterThan(channelStart));

      final channelBody = source.substring(channelStart, nextChannelStart);
      expect(
        channelBody,
        contains(
          'setOf("readNativeDiagnostics", "acknowledgeNativeDiagnostics", "clearNativeDiagnostics")',
        ),
      );
      expect(channelBody, contains('TimetableNativeWork.reply('));
      expect(channelBody, contains('"native_diagnostics_unavailable"'));
      expect(channelBody, contains('"原生诊断队列暂不可用"'));
      expect(channelBody, contains('"diagnostics.\$method"'));
      expect(
        channelBody,
        contains(
          '"readNativeDiagnostics" -> NativeBackgroundDiagnostics.read(appContext)',
        ),
      );
      expect(
        channelBody,
        contains('NativeBackgroundDiagnostics.acknowledge(appContext, ids)'),
      );
      expect(
        channelBody,
        contains('NativeBackgroundDiagnostics.clear(appContext)'),
      );
      expect(
        channelBody,
        isNot(contains('NativeBackgroundDiagnostics.read(this)')),
      );
      expect(
        channelBody,
        isNot(contains('NativeBackgroundDiagnostics.acknowledge(this')),
      );
      expect(
        channelBody,
        isNot(contains('NativeBackgroundDiagnostics.clear(this)')),
      );
      expect(
        channelBody,
        contains('Log.println(priority, "flutter.NUIST++", it)'),
      );
    });

    test('build.gradle.kts 保留 Glance 运行时依赖并移除未使用的 preview 依赖', () {
      final gradleSource = File('android/app/build.gradle.kts')
          .readAsStringSync();

      expect(
        gradleSource,
        contains('implementation("androidx.glance:glance-appwidget:1.2.0")'),
      );
      expect(
        gradleSource,
        contains('implementation("androidx.glance:glance-material3:1.2.0")'),
      );
      expect(gradleSource, isNot(contains('glance-appwidget-preview')));
      expect(gradleSource, isNot(contains('glance-preview')));
    });
  });
}
