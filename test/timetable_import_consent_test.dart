import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_import_page.dart';

/// 只统计调用次数，不发网络请求。
class _CountingApi extends TimetableImportApi {
  int calls = 0;

  @override
  Future<WakeupImportResult> fetchByShareText(
    String rawInput, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    throw TimetableImportException('测试中止', code: 'test');
  }

  @override
  void close() {}
}

const _realKey = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

void main() {
  tearDown(() => PrivacyConsent.instance.value = PrivacyDecision.undecided);

  Future<TimetableImportApi> open(
    WidgetTester tester,
    PrivacyDecision decision, {
    TimetableImportApi? real,
  }) async {
    PrivacyConsent.instance.value = decision;
    final api = real ?? _CountingApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: TimetableImportPage(
          controller: TimetableController.instance,
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  for (final decision in [
    PrivacyDecision.undecided,
    PrivacyDecision.declined,
  ]) {
    testWidgets('${decision.name}：导入真实口令前要求同意，取消则不发送口令', (tester) async {
      final api = await open(tester, decision) as _CountingApi;
      await tester.enterText(
        find.byKey(const Key('tt_import_input')),
        _realKey,
      );
      await tester.tap(find.byKey(const Key('tt_import_parse_btn')));
      await tester.pumpAndSettle();
      expect(find.text('需要同意隐私政策'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.calls, 0);
      expect(PrivacyConsent.instance.value, decision);
    });
  }

  testWidgets('导入时同意后继续解析', (tester) async {
    final api = await open(tester, PrivacyDecision.declined) as _CountingApi;
    await tester.enterText(find.byKey(const Key('tt_import_input')), _realKey);
    await tester.tap(find.byKey(const Key('tt_import_parse_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(PrivacyConsent.instance.accepted, isTrue);
    expect(api.calls, 1);
  });

  testWidgets('已同意直接解析，不弹窗', (tester) async {
    final api = await open(tester, PrivacyDecision.accepted) as _CountingApi;
    await tester.enterText(find.byKey(const Key('tt_import_input')), _realKey);
    await tester.tap(find.byKey(const Key('tt_import_parse_btn')));
    await tester.pumpAndSettle();
    expect(find.text('需要同意隐私政策'), findsNothing);
    expect(api.calls, 1);
  });

  testWidgets('内置演示口令只在本地解析，不要求同意', (tester) async {
    final real = TimetableImportApi();
    addTearDown(real.close);
    await open(tester, PrivacyDecision.undecided, real: real);
    await tester.tap(find.byKey(const Key('tt_import_demo_chip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tt_import_parse_btn')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('需要同意隐私政策'), findsNothing);
    expect(find.byKey(const Key('tt_import_preview')), findsOneWidget);
  });
}
