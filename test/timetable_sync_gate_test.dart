import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

void main() {
  group('X23 classifySyncError', () {
    test('PortalNetworkError (DNS failure) -> network', () {
      expect(
        classifySyncError(
          const PortalNetworkError("Failed host lookup: 'jwxt.example.test'"),
        ),
        TimetableSyncFailure.network,
      );
    });
    test('other wrapped network errors', () {
      final ro = RequestOptions(path: '/');
      expect(
        classifySyncError(
          DioException(
            requestOptions: ro,
            error: const PortalNetworkError('Failed host lookup'),
          ),
        ),
        TimetableSyncFailure.network,
      );
      expect(
        classifySyncError(
          DioException(
            requestOptions: ro,
            error: const SocketException('Failed host lookup'),
          ),
        ),
        TimetableSyncFailure.network,
      );
      expect(
        classifySyncError(TimeoutException('t')),
        TimetableSyncFailure.network,
      );
      expect(
        classifySyncError(const PortalCredentialError('x')),
        TimetableSyncFailure.sessionExpired,
      );
      expect(
        classifySyncError(const PortalLoginError('x')),
        TimetableSyncFailure.unknown,
      );
    });
  });

  group('X24 unbound gating', () {
    late Directory tmp;
    final c = TimetableController.instance;
    var fetches = 0;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_gate');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
      fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw const PortalNetworkError('Failed host lookup');
      };
      TimetableController.bindingCheck = () async => false;
      await c.ensureStarted();
    });

    tearDown(() async {
      TimetableController.bindingCheck = () async => false;
      TimetableStore.debugDirectory = null;
      c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('unbound: auto sync and manual syncIfBound do nothing', () async {
      expect(c.needsSync, isTrue);
      await c.autoSyncIfNeeded();
      expect(await c.syncIfBound(), isFalse);
      expect(fetches, 0);
      expect(c.syncStatus, TimetableSyncStatus.idle);
      expect(c.syncFailure, TimetableSyncFailure.none);
    });

    test('logout clears stale failure state', () async {
      TimetableController.bindingCheck = () async => true;
      expect(await c.syncIfBound(), isTrue);
      expect(c.syncFailure, TimetableSyncFailure.network);
      await c.handleLogout();
      expect(c.syncStatus, TimetableSyncStatus.idle);
      expect(c.syncFailure, TimetableSyncFailure.none);
      expect(c.statusMessage, isNull);
    });
  });
}
