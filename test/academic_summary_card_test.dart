import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_summary_card.dart';

Future<void> _pump(WidgetTester tester, Map<String, dynamic> json) {
  final summary = AcademicSummary.fromJson(
    json,
    fetchedAt: DateTime(2025, 9, 1),
  );
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AcademicSummaryBody(summary: summary)),
    ),
  );
}

void main() {
  for (final entry in {
    '全空': {'XH': '202512340001', 'XFJD': '', 'YHXF': '', 'YXZXF': ''},
    '全 0': {'XH': '202512340001', 'XFJD': '0', 'YHXF': '0', 'YXZXF': '0'},
    '缺字段': {'XH': '202512340001'},
  }.entries) {
    testWidgets('新生数据${entry.key}时学分进度条是确定态 0', (tester) async {
      await _pump(tester, entry.value);
      // indeterminate 进度条会一直动画，pumpAndSettle 将超时。
      await tester.pumpAndSettle();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0);
    });
  }

  testWidgets('全空数据各指标显示 --', (tester) async {
    await _pump(tester, {'XH': '202512340001'});
    await tester.pumpAndSettle();
    expect(find.text('已获 -- / 应修 --　--'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(7));
  });
}
