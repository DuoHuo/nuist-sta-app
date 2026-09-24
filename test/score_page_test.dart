import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/colors.dart';
import 'package:nuist_sta_app/mini_apps/score/score_page.dart';

void main() {
  testWidgets('成绩详情页在窄屏初始态正常布局', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: AppColors.pageBg,
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        home: const ScorePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '成绩查询'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            const {
              '未绑定统一门户',
              '暂无成绩数据',
              '正在获取成绩…',
            }.contains(widget.data),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
