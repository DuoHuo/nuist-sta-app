// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_lifecycle.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ui');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 9);
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------- NW
  group('AS 生命周期与网络恢复接线（第 7 条）', () {
    test('NetworkRestoreDetector：只有无网 → 有网算恢复', () {
      final d = NetworkRestoreDetector();
      expect(d.update(true), isFalse); // 首次得知
      expect(d.update(true), isFalse); // wifi ↔ 移动
      expect(d.update(false), isFalse);
      expect(d.update(true), isTrue);
      expect(d.update(true), isFalse);
      final s = NetworkRestoreDetector()..seed(false);
      expect(s.update(true), isTrue);
    });

    testWidgets(
      '冷启动 onAppStart 1 次；回前台 onAppResumed；离线→在线 onNetworkRestored 1 次，'
      '在线间切换不触发；卸载后取消订阅',
      (tester) async {
        final net = _FakeReachability(initial: false);
        var start = 0, resumed = 0, restored = 0;
        await tester.pumpWidget(
          TimetableLifecycleScope(
            reachability: net,
            onAppStart: () async => ++start > 0,
            onAppResumed: () async => ++resumed > 0,
            onNetworkRestored: () async => ++restored > 0,
            child: const SizedBox(),
          ),
        );
        await tester.pump();
        expect(start, 1);
        expect(net.controller.hasListener, isTrue);
        net.controller.add(true); // 离线 → 在线
        await tester.pump();
        expect(restored, 1);
        net.controller.add(true); // wifi → 移动网络
        await tester.pump();
        expect(restored, 1);
        net.controller.add(false);
        await tester.pump();
        net.controller.add(true);
        await tester.pump();
        expect(restored, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(resumed, 1);
        await tester.pumpWidget(const SizedBox());
        expect(net.controller.hasListener, isFalse);
        expect(start, 1);
      },
    );

    testWidgets('一开始就在线：在线间切换不触发补同步', (tester) async {
      final net = _FakeReachability(initial: true);
      var restored = 0;
      await tester.pumpWidget(
        TimetableLifecycleScope(
          reachability: net,
          onAppStart: () async => false,
          onAppResumed: () async => false,
          onNetworkRestored: () async => ++restored > 0,
          child: const SizedBox(),
        ),
      );
      await tester.pump();
      net.controller.add(true);
      await tester.pump();
      net.controller.add(true);
      await tester.pump();
      expect(restored, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------------- EV
}

class _FakeReachability implements NetworkReachability {
  _FakeReachability({required this.initial});

  final bool initial;
  final controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onlineChanges => controller.stream;

  @override
  Future<bool> isOnline() async => initial;
}
