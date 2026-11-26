import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/core/ui/miuix_dialog.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'} Miuix 对话框系统返回播放退场动画而非 0ms 硬切', (
      tester,
    ) async {
      bool? result = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  showMiuixConfirmDialog(
                    context,
                    title: '确认操作',
                    message: '系统返回应播放 Miuix 退场动画',
                  ).then((value) => result = value);
                },
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();
      expect(find.text('确认操作'), findsOneWidget);

      await tester.binding.handlePopRoute();
      // 触发返回后一帧内仍处于 Miuix 退场动画中，未 0ms 瞬移消失。
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('确认操作'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('确认操作'), findsNothing);
      expect(result, isFalse);
    });
  }

  testWidgets('Miuix 对话框 dismissible=false 时系统返回被拦截', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showMiuixInfoDialog(
                  context,
                  title: '强制提示',
                  message: '不能直接返回',
                  dismissible: false,
                );
              },
              child: const Text('打开不可关闭弹窗'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开不可关闭弹窗'));
    await tester.pumpAndSettle();
    expect(find.text('强制提示'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('强制提示'), findsOneWidget);

    await tester.tap(find.byKey(const Key('miuix_info_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('强制提示'), findsNothing);
  });
}
