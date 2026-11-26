import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent.dart';
import 'package:nuist_sta_app/core/privacy/privacy_consent_dialog.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/shell/privacy/privacy_policy_page.dart';
import 'package:nuist_sta_app/shell/profile/about/about_page.dart';
import 'package:nuist_sta_app/shell/profile/about/native_licenses.dart';
import 'package:nuist_sta_app/shell/profile/settings/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  PrivacyConsent store() => PrivacyConsent(directory: () async => tmp);

  setUp(() => tmp = Directory.systemTemp.createTempSync('privacy_'));
  tearDown(() {
    PrivacyConsent.instance.value = PrivacyDecision.undecided;
    PrivacyConsent.openPolicy = null;
    tmp.deleteSync(recursive: true);
  });

  group('PrivacyConsent', () {
    test('没有记录时是未选择，选择落盘后重启可读回且仅 accepted 算已同意', () async {
      final first = store();
      await first.load();
      expect(first.value, PrivacyDecision.undecided);
      expect(first.accepted, isFalse);
      await first.set(PrivacyDecision.accepted);
      expect(first.accepted, isTrue);
      final second = store();
      await second.load();
      expect(second.value, PrivacyDecision.accepted);
      await second.set(PrivacyDecision.declined);
      expect(first.accepted, isTrue);
      expect(second.accepted, isFalse);
      final third = store();
      await third.load();
      expect(third.value, PrivacyDecision.declined);
    });

    test('旧版本或损坏记录均按未选择处理', () async {
      File('${tmp.path}/privacy_consent').writeAsStringSync(
        '{"version":${kPrivacyPolicyVersion - 1},"decision":"accepted"}',
      );
      final outdated = store();
      await outdated.load();
      expect(outdated.value, PrivacyDecision.undecided);

      File('${tmp.path}/privacy_consent').writeAsStringSync('not json');
      final corrupt = store();
      await corrupt.load();
      expect(corrupt.value, PrivacyDecision.undecided);
    });

    test('匿名标识是 UUID v4，生成后落盘复用，损坏时重新生成', () async {
      final first = store();
      final id = await first.anonymousId();
      expect(PrivacyConsent.isUuid(id), isTrue);
      expect(await store().anonymousId(), id);
      File('${tmp.path}/anonymous_id').writeAsStringSync('garbage');
      final regenerated = await store().anonymousId();
      expect(PrivacyConsent.isUuid(regenerated), isTrue);
      expect(regenerated, isNot(id));
    });

    test('UUID 格式校验拒绝非 v4 和 64 位 hex', () {
      expect(
        PrivacyConsent.isUuid('3f2b8c1e-5a47-4d9e-9b1c-0a6d7e8f9a10'),
        isTrue,
      );
      expect(
        PrivacyConsent.isUuid('3f2b8c1e-5a47-1d9e-9b1c-0a6d7e8f9a10'),
        isFalse,
      );
      expect(PrivacyConsent.isUuid('ab' * 32), isFalse);
    });
  });

  group('弹窗', () {
    Future<void> open(
      WidgetTester tester,
      Future<void> Function(BuildContext) run,
    ) {
      return tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => run(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('首次弹窗：同意与拒绝都会记录并关闭', (tester) async {
      for (final (label, expected) in [
        ('同意', PrivacyDecision.accepted),
        ('拒绝', PrivacyDecision.declined),
      ]) {
        final consent = PrivacyConsent(directory: () async => null);
        await open(
          tester,
          (context) => showPrivacyConsentDialog(context, consent: consent),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.textContaining('欢迎使用 NUIST++'), findsOneWidget);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(consent.value, expected);
        expect(find.textContaining('欢迎使用'), findsNothing);
      }
    });

    testWidgets('首次弹窗不可关闭：点遮罩和系统返回都没有反应，只能同意或拒绝', (tester) async {
      final consent = PrivacyConsent(directory: () async => null);
      await open(
        tester,
        (context) => showPrivacyConsentDialog(context, consent: consent),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('欢迎使用'), findsOneWidget);

      // 点遮罩（对话框之外的左上角）。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.textContaining('欢迎使用'), findsOneWidget);

      // 系统返回。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('欢迎使用'), findsOneWidget);
      expect(consent.value, PrivacyDecision.undecided);

      // 点按钮后正常关闭。
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(find.textContaining('欢迎使用'), findsNothing);
      expect(consent.value, PrivacyDecision.declined);
    });

    testWidgets('撤回弹窗点遮罩或取消均不改变选择', (tester) async {
      final consent = PrivacyConsent(directory: () async => null)
        ..value = PrivacyDecision.accepted;
      await open(
        tester,
        (context) => confirmWithdrawPrivacyConsent(context, consent: consent),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('撤回同意'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('撤回同意'), findsNothing);
      expect(consent.accepted, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('撤回同意'), findsNothing);
      expect(consent.accepted, isTrue);
    });
    testWidgets('首次弹窗正文里的《隐私政策》可点击打开政策页', (tester) async {
      var opened = 0;
      PrivacyConsent.openPolicy = (_) => opened++;
      final consent = PrivacyConsent(directory: () async => null);
      await open(
        tester,
        (context) => showPrivacyConsentDialog(context, consent: consent),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapOnText(find.textRange.ofSubstring('《隐私政策》'));
      expect(opened, 1);
    });

    testWidgets('ensurePrivacyConsent：已同意直接放行，不弹窗', (tester) async {
      final consent = PrivacyConsent(directory: () async => null)
        ..value = PrivacyDecision.accepted;
      bool? result;
      await open(tester, (context) async {
        result = await ensurePrivacyConsent(
          context,
          reason: '原因',
          consent: consent,
        );
      });
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('需要同意隐私政策'), findsNothing);
    });

    testWidgets('ensurePrivacyConsent：同意并继续会记录，取消不改变选择', (tester) async {
      final consent = PrivacyConsent(directory: () async => null)
        ..value = PrivacyDecision.declined;
      bool? result;
      await open(tester, (context) async {
        result = await ensurePrivacyConsent(
          context,
          reason: '原因说明',
          consent: consent,
        );
      });
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('原因说明', findRichText: true), findsOneWidget);
      expect(find.text('查看隐私政策'), findsNothing);
      expect(find.textContaining('《隐私政策》', findRichText: true), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(consent.value, PrivacyDecision.declined);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并继续'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(consent.accepted, isTrue);
    });
  });

  group('页面', () {
    testWidgets('隐私政策页渲染正文，失败时可重试', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme(),
          home: PrivacyPolicyPage(
            loader: () async {
              if (++calls == 1) throw StateError('读取失败');
              return '# 标题\n\n正文内容';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('隐私政策暂时无法显示'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正文内容', findRichText: true), findsOneWidget);
    });

    testWidgets('关于页显示隐私政策与开源许可入口', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const AboutPage()),
      );
      await tester.pump();
      expect(find.byKey(const Key('about_privacy')), findsOneWidget);
      expect(find.byKey(const Key('about_licenses')), findsOneWidget);
      expect(find.text('隐私政策'), findsOneWidget);
      expect(find.text('开源许可'), findsOneWidget);
    });
    testWidgets('设置页撤回同意：10 秒倒计时后才能撤回，之后可重新同意', (tester) async {
      PrivacyConsent.instance.value = PrivacyDecision.accepted;
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const SettingsPage()),
      );
      final entry = find.byKey(const Key('settings_privacy_consent'));
      await tester.scrollUntilVisible(entry, 200);
      expect(find.text('撤回隐私政策同意'), findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.textContaining('如果您撤回对', findRichText: true), findsOneWidget);
      expect(find.textContaining('确认撤回？', findRichText: true), findsOneWidget);

      // 倒计时中：按钮显示剩余秒数且点不动。
      expect(find.text('撤回（10s）'), findsOneWidget);
      await tester.tap(find.text('撤回（10s）'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('撤回（9s）'), findsOneWidget);
      expect(PrivacyConsent.instance.accepted, isTrue);

      await tester.pump(const Duration(seconds: 9));
      expect(find.text('撤回'), findsOneWidget);
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(PrivacyConsent.instance.value, PrivacyDecision.declined);
      expect(find.text('同意隐私政策'), findsOneWidget);

      // 未同意时直接同意，不弹窗。
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(PrivacyConsent.instance.accepted, isTrue);
    });
  });
  group('静态资源与原生许可证', () {
    test('打包的 PRIVACY.md 可读取并包含匿名标识说明', () async {
      final text = await rootBundle.loadString(PrivacyPolicyPage.assetPath);
      expect(text, allOf(contains('random_uuid_v1'), contains('匿名标识')));
    });

    test('按分隔行解析，跳过空条目', () {
      final entries = parseNativeLicenses(
        '组件甲\n\n正文甲\n-----8<-----\n\n-----8<-----\n组件乙\n\n正文乙\n',
      );
      expect(entries.map((e) => e.packages.single), ['组件甲', '组件乙']);
      expect(entries.first.paragraphs.first.text, '正文甲');
    });

    test('打包的许可证资源覆盖 Rust、Gradle 与内置库', () async {
      final source = await rootBundle.loadString(nativeLicensesAsset);
      final names = parseNativeLicenses(source)
          .expand((e) => e.packages)
          .join('\n');
      for (final expected in [
        'smoltcp',
        'rustls',
        'ring',
        'webpki-roots',
        'Apache POI',
        'jxl',
        'odr-core-android',
        'MapLibre',
        'zxing-cpp',
      ]) {
        expect(names, contains(expected));
      }
      expect(source, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      expect(source, contains('Apache License'));
    });
  });
}
