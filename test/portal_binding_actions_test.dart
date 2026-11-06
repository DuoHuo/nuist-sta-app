import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/passkey_bundle.dart';
import 'package:nuist_sta_app/shell/profile/portal_bind/portal_binding_actions.dart';

void main() {
  final bundle = PasskeyBundle(
    rpId: 'portal.test',
    credentialId: 'synthetic-credential',
    privateKeyPkcs8Pem: 'synthetic-key',
    userId: '',
    anonbiometricsd: 'synthetic-device',
    deviceName: '测试设备',
    createdAt: DateTime(2026, 11, 6),
  );

  test('凭据保存与会话清理完成后只通知一次，后台刷新不阻塞绑定完成', () async {
    final events = <String>[];
    final saved = Completer<void>();
    final cleared = Completer<void>();
    final refreshed = Completer<bool>();
    final actions = PortalBindingActions.forTesting(
      saveCredential: (_) {
        events.add('save');
        return saved.future;
      },
      deleteCredential: () async => events.add('delete'),
      clearSession: (webView) {
        expect(webView, isFalse);
        events.add('clear');
        return cleared.future;
      },
      notifyApps: ({required bound}) {
        expect(bound, isTrue);
        events.add('notify');
        return refreshed.future;
      },
    );
    final binding = actions.bind(bundle);
    await pumpEventQueue();
    expect(events, ['save']);
    saved.complete();
    await pumpEventQueue();
    expect(events, ['save', 'clear']);
    cleared.complete();
    await binding;
    expect(events, ['save', 'clear', 'notify']);
    expect(refreshed.isCompleted, isFalse);
    refreshed.complete(true);
    await pumpEventQueue();
  });

  for (final failedStep in ['save', 'clear']) {
    test('$failedStep 失败时不会通知绑定成功', () async {
      final events = <String>[];
      final actions = PortalBindingActions.forTesting(
        saveCredential: (_) async {
          events.add('save');
          if (failedStep == 'save') throw StateError('合成保存失败');
        },
        deleteCredential: () async {},
        clearSession: (_) async {
          events.add('clear');
          throw StateError('合成会话清理失败');
        },
        notifyApps: ({required bound}) async {
          events.add('notify');
          return true;
        },
      );
      await expectLater(actions.bind(bundle), throwsStateError);
      expect(events, failedStep == 'save' ? ['save'] : ['save', 'clear']);
    });
  }

  test('解绑删除凭据并清 WebView，等待所有模块并反馈清理失败', () async {
    final events = <String>[];
    final cleaned = Completer<bool>();
    final actions = PortalBindingActions.forTesting(
      saveCredential: (_) async {},
      deleteCredential: () async => events.add('delete'),
      clearSession: (webView) async {
        expect(webView, isTrue);
        events.add('clear');
      },
      notifyApps: ({required bound}) {
        expect(bound, isFalse);
        events.add('notify');
        return cleaned.future;
      },
    );
    var finished = false;
    final unbinding = actions.unbind().then((result) {
      finished = true;
      return result;
    });
    await pumpEventQueue();
    expect(events, ['delete', 'clear', 'notify']);
    expect(finished, isFalse);
    cleaned.complete(false);
    expect(await unbinding, isFalse);
  });

  test('后台模块意外抛错不会变成未处理异常或把绑定判为失败', () async {
    final actions = PortalBindingActions.forTesting(
      saveCredential: (_) async {},
      deleteCredential: () async {},
      clearSession: (_) async {},
      notifyApps: ({required bound}) async => throw StateError('合成通知失败'),
    );
    await actions.bind(bundle);
    await pumpEventQueue();
  });

  test('保存过程中解绑会排队，迟到的保存不会恢复已解绑凭据', () async {
    final saved = Completer<void>();
    final events = <String>[];
    final actions = PortalBindingActions.forTesting(
      saveCredential: (_) async {
        events.add('save.started');
        await saved.future;
        events.add('save.finished');
      },
      deleteCredential: () async => events.add('delete'),
      clearSession: (webView) async => events.add('clear.$webView'),
      notifyApps: ({required bound}) async {
        events.add('notify.$bound');
        return true;
      },
    );
    final binding = actions.bind(bundle);
    await pumpEventQueue();
    final unbinding = actions.unbind();
    await pumpEventQueue();
    expect(events, ['save.started']);
    saved.complete();
    await binding;
    expect(await unbinding, isTrue);
    expect(events, [
      'save.started',
      'save.finished',
      'clear.false',
      'notify.true',
      'delete',
      'clear.true',
      'notify.false',
    ]);
  });
}
