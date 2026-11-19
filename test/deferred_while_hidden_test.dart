import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/shell/deferred_while_hidden.dart';

void main() {
  Widget host({required bool visible, required VoidCallback onBuild}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: TickerMode(
          enabled: visible,
          child: DeferredWhileHidden(
            delay: const Duration(seconds: 1),
            builder: (_) {
              onBuild();
              return const Text('卡片');
            },
          ),
        ),
      );

  testWidgets('可见时与直接构建一致', (tester) async {
    var builds = 0;
    await tester.pumpWidget(host(visible: true, onBuild: () => builds++));
    expect(builds, 1);
    expect(find.text('卡片'), findsOneWidget);
  });

  testWidgets('不可见时等待后在后台构建，之后不再收起', (tester) async {
    var builds = 0;
    await tester.pumpWidget(host(visible: false, onBuild: () => builds++));
    expect(builds, 0);
    await tester.pump(const Duration(milliseconds: 900));
    expect(builds, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(builds, 1);
    await tester.pumpWidget(host(visible: false, onBuild: () => builds++));
    expect(find.text('卡片', skipOffstage: false), findsOneWidget);
  });

  testWidgets('等待期间变为可见立即构建，且不残留定时器', (tester) async {
    var builds = 0;
    await tester.pumpWidget(host(visible: false, onBuild: () => builds++));
    await tester.pumpWidget(host(visible: true, onBuild: () => builds++));
    expect(builds, 1);
    expect(find.text('卡片'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(builds, 1);
  });

  testWidgets('等待期间卸载取消定时器', (tester) async {
    await tester.pumpWidget(host(visible: false, onBuild: () {}));
    await tester.pumpWidget(const SizedBox.shrink());
    // 若定时器未取消，测试框架会报告挂起的 Timer。
  });
}
