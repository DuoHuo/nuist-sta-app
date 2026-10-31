import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config/campus_config.dart';
import '../config/api_endpoints.dart';
import 'log_store.dart';

/// 应用日志级别。生产版默认只落盘 [info] 及以上级别。
enum AppLogLevel { debug, info, warning, error, fatal }

/// 统一日志入口。业务代码应通过 [logger] 获取带作用域的 [AppLogger]。
class AppLog {
  AppLog._();

  static const formatVersion = 1;
  static final String _sessionId = _randomHex(8);
  static final ValueNotifier<bool> verboseEnabled = ValueNotifier(kDebugMode);
  static final ValueNotifier<DateTime?> verboseExpiresAt = ValueNotifier(null);
  static final ValueNotifier<bool> storageAvailable = ValueNotifier(false);
  static final Object _contextKey = Object();

  static RotatingLogStore? _store;
  static DateTime? _verboseUntil;
  static Timer? _verboseTimer;
  static Timer? _maintenanceTimer;
  static Future<void>? _initialization;
  static int _sequence = 0;
  static int _hostSequence = 0;
  static final Map<String, String> _hostAliases = {};
  static bool _initialized = false;
  static bool _writingFallback = false;
  static bool _nativeConsoleAvailable = true;
  static const _consoleChannel = MethodChannel('nuist/diagnostic_logging');
  static final bool _inFlutterTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  @visibleForTesting
  static ValueChanged<Map<String, Object?>>? recordListenerForTesting;

  @visibleForTesting
  static bool consoleEnabledForTesting = false;

  /// 初始化缓存目录中的轮转日志。失败时退化为开发控制台日志。
  static Future<void> initialize({Directory? directory}) {
    if (_initialized) return Future.value();
    return _initialization ??= _initialize(directory);
  }

  static Future<void> _initialize(Directory? directory) async {
    try {
      final base = directory ?? await getTemporaryDirectory();
      final store = RotatingLogStore(
        Directory(
          '${base.path}${Platform.pathSeparator}nuist_sta_app'
          '${Platform.pathSeparator}logs',
        ),
        exportDirectory: Directory(
          '${base.path}${Platform.pathSeparator}nuist_sta_app'
          '${Platform.pathSeparator}exports',
        ),
        sanitizeRecord: _sanitizePersistedRecord,
      );
      await store.initialize();
      _store = store;
      storageAvailable.value = true;
      if (kDebugMode) {
        verboseEnabled.value = true;
        await store.writeVerboseUntil(null);
      } else {
        final until = await store.readVerboseUntil();
        if (until != null && until.isAfter(DateTime.now().toUtc())) {
          _setVerboseUntil(until, persist: false);
        } else if (until != null) {
          await store.writeVerboseUntil(null);
        }
      }
      _initialized = true;
      if (!_inFlutterTest) {
        _maintenanceTimer = Timer.periodic(const Duration(hours: 1), (_) {
          unawaited(store.maintain().catchError(_handleWriteError));
        });
      }
      logger(
        'app',
      ).info('session.started', fields: {'log_format_version': formatVersion});
    } catch (error) {
      storageAvailable.value = false;
      _consoleFallback('日志初始化失败', error);
    } finally {
      if (!_initialized) _initialization = null;
    }
  }

  /// 接管全局错误出口，异常对象不再交给 Flutter 的原始文本展示器。
  static void installErrorHandlers() {
    final log = logger('app.errors');
    FlutterError.onError = (details) => log.error(
      'flutter.unhandled',
      error: details.exception,
      stackTrace: details.stack,
      errorKind: 'flutter_framework',
      fields: {
        'framework_error': _frameworkErrorKind(details.exception),
        'framework_library': _frameworkLibrary(details.library),
        'silent': details.silent,
      },
    );
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      log.fatal(
        'platform.unhandled',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'uncaught_async',
      );
      return true;
    };
  }

  /// 获取固定作用域的日志器，例如 `free_classroom.controller`。
  static AppLogger logger(String scope) => AppLogger._(scope);

  static String _frameworkLibrary(String? library) => switch (library) {
    'rendering library' => 'rendering',
    'widgets library' => 'widgets',
    'animation library' => 'animation',
    'scheduler library' => 'scheduler',
    'services library' => 'services',
    'gestures library' => 'gestures',
    'painting library' => 'painting',
    'image resource service' => 'image',
    _ => 'other',
  };

  static String _frameworkErrorKind(Object error) {
    if (error is! FlutterError) return 'exception';
    // 仅匹配框架已知的固定摘要，不记录诊断对象、组件内容或原始异常正文。
    try {
      for (final summary in error.diagnostics.whereType<ErrorSummary>()) {
        final text = summary.toDescription();
        for (final entry in const {
          'A RenderFlex overflowed': 'flex_overflow',
          'Incorrect use of ParentDataWidget': 'invalid_parent_data',
          'setState() called after dispose': 'set_state_after_dispose',
          'setState() or markNeedsBuild() called during build':
              'build_during_build',
          'RenderBox was not laid out': 'render_box_not_laid_out',
          'Vertical viewport was given unbounded height': 'unbounded_viewport',
          'Horizontal viewport was given unbounded width': 'unbounded_viewport',
          'BoxConstraints forces an infinite': 'infinite_constraints',
          'RenderFlex children have non-zero flex': 'unbounded_flex',
          'A GlobalKey was used multiple times': 'duplicate_global_key',
          'Duplicate GlobalKey': 'duplicate_global_key',
        }.entries) {
          if (text.startsWith(entry.key)) return entry.value;
        }
      }
    } catch (_) {
      // 诊断节点本身损坏时也不能让全局错误出口再次抛错。
    }
    return 'unclassified';
  }

  /// 将已知出口映射为安全服务类别，不输出真实主机名或 URL。
  static String serviceForHost(String host) =>
      _serviceCategories[host.toLowerCase()] ?? 'external';

  static final Map<String?, String> _serviceCategories = {
    CampusHosts.authserver: 'cas',
    CampusHosts.jwxt: 'jwxt',
    CampusHosts.icard: 'icard',
    CampusHosts.iportal: 'portal',
    CampusHosts.bulletin: 'bulletin',
    CampusHosts.labor: 'labor',
    CampusHosts.cxcyjy: 'innovation',
    CampusHosts.cxxf: 'innovation',
    CampusHosts.vpnController: 'vpn',
    CampusHosts.shuttleApi: 'shuttle',
    Uri.tryParse(kCampusMapBaseUrl)?.host: 'campus_map',
    Uri.tryParse(kCampusShuttlePageUrl)?.host: 'shuttle',
    Uri.tryParse(kContributorsEndpoint)?.host: 'community',
  };

  /// 错误分类只依赖类型和网络枚举，不求值异常正文。
  static String errorKindFor(Object error) =>
      _errorFields(error)['error_kind']! as String;

  static Map<String, Object?> _errorFields(Object error, [int depth = 0]) {
    if (error is DioException) {
      final cause = error.error;
      return {
        'error_kind': 'network',
        if (cause != null && !identical(cause, error) && depth < 3)
          ..._errorFields(cause, depth + 1),
        'dio_type': error.type.name,
        'status_code': error.response?.statusCode,
      };
    }
    return {
      'error_kind': switch (error) {
        TimeoutException() => 'timeout',
        HandshakeException() => 'tls_handshake',
        SocketException() => 'connection_error',
        FileSystemException() => 'storage_io',
        FormatException() => 'invalid_format',
        MissingPluginException() => 'platform_unavailable',
        PlatformException() => 'platform_error',
        _ => switch (error.runtimeType.toString()) {
          'PortalCredentialError' => 'portal_credential',
          'PortalNetworkError' => 'portal_network',
          'PortalLoginError' || 'JwxtSessionExpiredError' => 'portal_login',
          'TimetablePersistenceException' => 'storage_write',
          _ => 'unexpected',
        },
      },
      if (error is SocketException && error.osError?.errorCode != null)
        'os_code': error.osError!.errorCode,
      if (error is FileSystemException && error.osError?.errorCode != null)
        'os_code': error.osError!.errorCode,
    };
  }

  /// 临时开启生产版 DEBUG 日志，默认三十分钟后自动关闭；debug 构建始终开启。
  static Future<void> enableVerbose({
    Duration duration = const Duration(minutes: 30),
  }) async {
    final until = DateTime.now().toUtc().add(duration);
    _setVerboseUntil(until, persist: true);
    logger(
      'app.logging',
    ).info('verbose.enabled', fields: {'duration_minutes': duration.inMinutes});
  }

  /// 立即关闭详细日志。
  static Future<void> disableVerbose() async {
    if (!verboseEnabled.value && _verboseUntil == null) return;
    logger('app.logging').info('verbose.disabled');
    _verboseTimer?.cancel();
    _verboseTimer = null;
    _verboseUntil = null;
    verboseExpiresAt.value = null;
    verboseEnabled.value = kDebugMode;
    await _store?.writeVerboseUntil(null);
  }

  static void _setVerboseUntil(DateTime until, {required bool persist}) {
    _verboseTimer?.cancel();
    _verboseUntil = until.toUtc();
    verboseExpiresAt.value = _verboseUntil;
    verboseEnabled.value = true;
    final delay = until.difference(DateTime.now().toUtc());
    _verboseTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(disableVerbose());
    });
    if (persist) unawaited(_store?.writeVerboseUntil(until) ?? Future.value());
  }

  /// 当前日志占用。
  static Future<LogStoreStats> stats() async =>
      (await _store?.stats()) ?? const LogStoreStats(bytes: 0, fileCount: 0);

  /// 生成一致的日志快照。
  static Future<LogSnapshot> snapshot() async =>
      await _store?.snapshot() ??
      const LogSnapshot(
        content: '',
        stats: LogStoreStats(bytes: 0, fileCount: 0),
      );

  /// 清除本地日志。
  static Future<void> clear() async => _store?.clear();

  /// 将安全元信息与日志快照写入受限的导出缓存。
  static Future<File> createExport(Map<String, Object?> metadata) async {
    await initialize();
    final store = _store;
    if (store == null) throw StateError('诊断日志存储暂不可用');
    return store.createExport(_sanitizeMetadata(metadata));
  }

  static Map<String, Object?> _sanitizeMetadata(Map<String, Object?> metadata) {
    final result = <String, Object?>{
      'record_type': 'diagnostics_metadata',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'log_format_version': formatVersion,
    };
    for (final key in [
      'app_version',
      'build_number',
      'platform',
      'platform_version',
      'locale',
    ]) {
      final value = metadata[key];
      if (value is! String) continue;
      final allowed = switch (key) {
        'app_version' => RegExp(
          r'^\d{1,3}(?:\.\d{1,3}){1,3}(?:[-+][A-Za-z0-9_.-]{1,32})?$',
        ).hasMatch(value),
        'build_number' => RegExp(r'^\d{1,9}$').hasMatch(value),
        'platform' => const {
          'android',
          'ios',
          'windows',
          'linux',
          'macos',
          'fuchsia',
        }.contains(value),
        'locale' => RegExp(
          r'^[a-zA-Z]{2,3}(?:[_-][a-zA-Z0-9]{2,8}){0,3}$',
        ).hasMatch(value),
        _ => true,
      };
      if (allowed) {
        result[key] = key == 'platform_version' ? _sanitizeText(value) : value;
      }
    }
    return result;
  }

  static bool _isEnabled(AppLogLevel level) {
    if (!kReleaseMode) return true;
    if (level.index >= AppLogLevel.info.index) return true;
    final until = _verboseUntil;
    return verboseEnabled.value &&
        until != null &&
        until.isAfter(DateTime.now().toUtc());
  }

  static void _write(
    String scope,
    AppLogLevel level,
    String event, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
    String? errorKind,
  }) {
    if (!_isEnabled(level)) return;
    try {
      final now = DateTime.now().toUtc();
      final context = Zone.current[_contextKey] as _LogContext?;
      final attrs = _sanitizeFields({
        ...?fields,
        if (error != null) ..._errorFields(error),
        if (error != null) 'error_type': error.runtimeType.toString(),
        'error_kind': ?errorKind,
      });
      if (stackTrace != null) {
        attrs['stack_trace'] = _sanitizeStack(stackTrace);
      }
      final record = <String, Object?>{
        'ts': now.toIso8601String(),
        'seq': ++_sequence,
        'level': level.name.toUpperCase(),
        'scope': _sanitizeName(scope),
        'event': _sanitizeName(event),
        'session_id': _sessionId,
        if (context != null) 'trace_id': context.traceId,
        if (context != null) 'span_id': context.spanId,
        if (context?.parentSpanId != null)
          'parent_span_id': context!.parentSpanId,
        if (attrs.isNotEmpty) 'attrs': attrs,
      };
      recordListenerForTesting?.call(Map.unmodifiable(record));
      final line = jsonEncode(record);
      if ((!kReleaseMode || verboseEnabled.value) &&
          (!_inFlutterTest || consoleEnabledForTesting)) {
        final summary = formatSummary(
          record,
          includeScope: true,
          includeLevel: true,
        );
        final stack = attrs['stack_trace'] as String?;
        final frames = stack == null ? const <String>[] : stack.split('\n');
        final preferred = frames
            .where((line) => line.contains('package:nuist_sta_app/'))
            .toList();
        final visibleFrames = (preferred.isEmpty ? frames : preferred).take(
          level.index >= AppLogLevel.error.index ? 8 : 3,
        );
        final message = [
          summary,
          if (level.index >= AppLogLevel.warning.index)
            for (final frame in visibleFrames) '  ↳ #${record['seq']} $frame',
        ].join('\n');
        _emitConsole(message, level, record, stack);
      }
      final shouldPersist =
          level.index >= AppLogLevel.info.index ||
          kDebugMode ||
          verboseEnabled.value;
      if (shouldPersist) {
        unawaited(
          _store
                  ?.append(line)
                  .then((_) {
                    storageAvailable.value = true;
                  })
                  .catchError(_handleWriteError) ??
              Future.value(),
        );
      }
    } catch (writeError) {
      _consoleFallback('日志编码失败', writeError);
    }
  }

  static void _handleWriteError(Object error) {
    storageAvailable.value = false;
    _consoleFallback('日志写入失败', error);
  }

  static void _emitConsole(
    String message,
    AppLogLevel level,
    Map<String, Object?> record,
    String? stack,
  ) {
    if ((!_inFlutterTest || consoleEnabledForTesting) && !kReleaseMode) {
      developer.log(
        formatSummary(record),
        name: record['scope']! as String,
        level: switch (level) {
          AppLogLevel.debug => 500,
          AppLogLevel.info => 800,
          AppLogLevel.warning => 900,
          AppLogLevel.error => 1000,
          AppLogLevel.fatal => 1200,
        },
        sequenceNumber: record['seq']! as int,
        // DevTools 支持将安全文本作为详情数据；缺少数据时会展示整条 VM 协议 JSON。
        error: [
          '事件：${record['event']} · 记录 #${'${record['seq']}'.padLeft(6, '0')}',
          if (record['trace_id'] case final String trace)
            '关联操作：${trace.substring(0, min(8, trace.length))}',
          if ((record['attrs'] as Map?)?['error_type'] case final String type)
            '异常类型：$type',
        ].join('\n'),
        stackTrace: stack == null ? null : StackTrace.fromString(stack),
      );
    }
    if (Platform.isAndroid && !_inFlutterTest && _nativeConsoleAvailable) {
      unawaited(
        _consoleChannel
            .invokeMethod<void>('write', {
              'level': level.index,
              // logcat 已有级别列；原生标签同时兼容独立 flutter logs。
              'message': message.replaceFirst(RegExp(r'^[A-Z]+\s+'), ''),
            })
            .catchError((Object _) {
              _nativeConsoleAvailable = false;
              debugPrint(message, wrapWidth: 1024);
            }),
      );
    } else {
      debugPrint(message, wrapWidth: 1024);
    }
  }

  static void _consoleFallback(String message, Object error) {
    if (kReleaseMode ||
        _writingFallback ||
        (_inFlutterTest && !consoleEnabledForTesting)) {
      return;
    }
    _writingFallback = true;
    try {
      debugPrint(
        'ERROR [app.logging] internal.failure | '
        'message=${jsonEncode(_sanitizeText(message))} '
        'error_type=${error.runtimeType}',
        wrapWidth: 1024,
      );
    } finally {
      _writingFallback = false;
    }
  }

  /// 首行只展示动作、结果和排障所需字段；完整记录通过详情查看。
  static String formatSummary(
    Map<String, Object?> record, {
    bool includeScope = false,
    bool includeLevel = false,
  }) {
    final attrs = (record['attrs'] as Map?)?.cast<String, Object?>() ?? {};
    final parts = <String>[_eventLabel(record, attrs)];
    final request = <String>[];
    for (final entry in const {
      'request_id': 'R',
      'connection_id': 'C',
      'attempt': 'S',
      'stage_id': 'P',
    }.entries) {
      if (attrs[entry.key] case final value?) {
        request.add('${entry.value}$value');
      }
    }
    if (attrs['method'] case final String method
        when RegExp(r'^[A-Z]+$').hasMatch(method)) {
      request.add(method);
    }
    if (attrs['service'] case final service?) {
      request.add(_label(service));
    }
    if (request.isNotEmpty) parts.add(request.join(' '));
    if (attrs['status_code'] case final status?) {
      final redirect = attrs['redirect_service'];
      parts.add(
        'HTTP $status${redirect == null ? '' : ' → ${_label(redirect)}'}',
      );
    }
    final failure = _failureLabel(attrs);
    if (failure != null) parts.add(failure);
    for (final entry in const {
      'native_stage': '阶段',
      'route': '出口',
      'file_kind': '文件',
      'reason': '原因',
      'os_code': '系统码',
      'course_count': '课程数',
      'exam_count': '考试数',
      'count': '条目数',
      'vehicle_count': '车辆数',
      'topic_count': '订阅项数',
      'app_id': '小程序',
      'state': '状态',
      'response_type': '响应类型',
      'response_code': '返回码',
    }.entries) {
      if (attrs[entry.key] case final value?) {
        parts.add('${entry.value} ${_label(value)}');
      }
    }
    if (attrs['connection_types'] case final Iterable types) {
      parts.add('网络 ${types.map(_label).join('、')}');
    }
    if (attrs['cache'] case final cache?) parts.add(_label(cache));
    if (attrs['outcome'] case final outcome?
        when !const {
          'success',
          'failure',
          'failed',
          'error',
        }.contains(outcome)) {
      final label = _label(outcome);
      if (!parts.first.contains(label)) parts.add(label);
    }
    if (attrs['offline'] == true && failure != '当前离线') parts.add('当前离线');
    if (attrs['force'] == true || attrs['force_refresh'] == true) {
      parts.add('强制刷新');
    }
    if (attrs['not_modified'] == true) parts.add('数据未变化');
    for (final entry in const {
      'enabled': ('已开启', '已关闭'),
      'alive': ('运行中', '已停止'),
      'healthy': ('隧道正常', '隧道异常'),
      'recovering': ('恢复中', null),
      'cancelled': ('已取消', null),
    }.entries) {
      final value = attrs[entry.key];
      final label = value == true
          ? entry.value.$1
          : value == false
          ? entry.value.$2
          : null;
      if (label != null) parts.add(label);
    }
    for (final key in ['preparation_ms', 'stage_elapsed_ms', 'duration_ms']) {
      if (attrs[key] case final value?) {
        final label = switch (key) {
          'preparation_ms' => '准备',
          'stage_elapsed_ms' => '本阶段',
          _ => '耗时',
        };
        parts.add('$label ${_formatDuration(value)}');
      }
    }
    if (attrs['native_timeout_ms'] ?? attrs['timeout_ms'] case final timeout?) {
      parts.add('期限 ${_formatDuration(timeout)}');
    }
    final scope = '${record['scope']}'.replaceFirst(
      RegExp(r'^(?:core|shell)\.'),
      '',
    );
    final sequence = '${record['seq']}'.padLeft(6, '0');
    final trace = record['trace_id'];
    final context = (includeScope || includeLevel) && trace is String
        ? ' trace=${trace.substring(0, min(8, trace.length))}'
        : '';
    return '${includeLevel ? '${record['level']} ' : ''}'
        '${includeScope ? '[$scope] ' : ''}${parts.join(' · ')}'
        '${includeScope || includeLevel ? ' #$sequence' : ''}$context';
  }

  static String _eventLabel(
    Map<String, Object?> record,
    Map<String, Object?> attrs,
  ) {
    final event = '${record['event']}';
    if (_labels[event] case final label?) return label;
    for (final entry in const {
      '.failed_using_cache': '失败，沿用缓存',
      '_failed_using_cache': '失败，沿用缓存',
      '_failed_using_memory': '失败，沿用内存数据',
      '.started': '开始',
      '.completed': '完成',
      '.failed': '失败',
      '_failed': '失败',
      '.waiting': '仍在等待',
      '.progress': '进行中',
      '.ready': '就绪',
      '.cancelled': '已取消',
    }.entries) {
      if (!event.endsWith(entry.key)) continue;
      final base = event.substring(0, event.length - entry.key.length);
      var label = base == 'stage'
          ? _label(attrs['stage'] ?? '内部阶段')
          : _labels[base];
      if (base == 'refresh') {
        final module = '${record['scope']}'
            .replaceFirst(RegExp(r'^(?:core|shell)\.'), '')
            .split('.')
            .first;
        if (_labels[module] case final moduleLabel?) label = '$moduleLabel刷新';
      }
      if (base == 'sync' || base == 'sync.run') {
        label = switch (attrs['automatic']) {
          true => '自动同步课表',
          false => '手动同步课表',
          _ => '课表同步',
        };
      }
      if (label == null) return event;
      final failedResult = const {
        'failure',
        'failed',
        'error',
      }.contains(attrs['outcome']);
      return '$label${entry.key == '.completed' && failedResult ? '失败' : entry.value}';
    }
    return event;
  }

  static String? _failureLabel(Map<String, Object?> attrs) {
    final failure = attrs['failure_kind'];
    final framework = attrs['framework_error'];
    final error = attrs['error_kind'];
    final dio = attrs['dio_type'];
    final kind =
        framework != null &&
            framework != 'exception' &&
            framework != 'unclassified'
        ? framework
        : failure != null &&
              !const {'none', 'unknown', 'network'}.contains(failure)
        ? failure
        : (error == null || error == 'network') &&
              dio != null &&
              dio != 'unknown'
        ? dio
        : error ?? (failure == 'none' ? null : failure);
    final type = attrs['error_type'];
    if (kind == null) return type == null ? null : '异常类型 $type';
    return '${_label(kind)}'
        '${type != null && const {'unexpected', 'flutter_framework', 'uncaught_async', 'unknown'}.contains(kind) ? '（$type）' : ''}';
  }

  static String _label(Object? value) =>
      _labels[value] ?? _formatConsoleValue(value);

  // 只翻译固定事件和安全枚举；原始事件、字段及标识仍保留在详情和 JSON 中。
  static const _labels = {
    'http': 'HTTP 请求',
    'service.login': '业务登录',
    'service.request': '业务请求',
    'refresh': '刷新数据',
    'query': '查询空教室',
    'buildings.refresh': '刷新教学楼列表',
    'category.load': '加载公告列表',
    'category.load_more': '加载更多公告',
    'feed.refresh': '刷新订阅公告',
    'sync': '同步课表',
    'sync.run': '同步课表',
    'room.bind': '绑定电费宿舍',
    'bind': '绑定门户',
    'unbind': '解绑门户',
    'open': '打开小程序网页',
    'export': '导出',
    'share': '分享',
    'edit.persist': '保存课表修改',
    'preview.read': '读取诊断日志',
    'preview.refresh': '刷新诊断日志',
    'read': '读取本地数据',
    'write': '保存本地数据',
    'delete': '删除本地数据',
    'json.read': '读取缓存文件',
    'json.write': '保存缓存文件',
    'start': 'VPN 建连',
    'start.cancel': '取消 VPN 建连',
    'start.native_ready': 'VPN 原生库就绪',
    'start.authenticated': 'VPN 认证通过',
    'start.native_completed': 'VPN 原生握手完成',
    'connection': '目标连接',
    'connection.retry': '目标连接失败，重建 VPN 后重试',
    'connection.status': '查询 VPN 隧道状态',
    'tcp': 'TCP 连接',
    'tls': 'TLS 握手',
    'tunnel.status': 'VPN 隧道状态',
    'tunnel.health': 'VPN 健康检查',
    'tunnel.stop': '停止 VPN 隧道',
    'tunnel.invalidated': 'VPN 隧道失效',
    'tunnel.network_changed': '网络变化，重建 VPN 隧道',
    'clients.reset': '重建 HTTP 连接池',
    'clients.session_changed': '隧道变化，更新 HTTP 连接池',
    'certificate.repaired_retry': '证书链已补全，重试 HTTP 请求',
    'session.started': '应用启动',
    'session.expired': '门户会话已过期',
    'session.login_timeout': '门户登录超时',
    'session.restored': '门户会话已恢复',
    'storage.unavailable': '本地存储不可用',
    'session.reset': '清理 VPN 会话',
    'session.cleared': 'VPN 会话已清理',
    'flutter.unhandled': 'Flutter 未捕获异常',
    'platform.unhandled': '平台未捕获异常',
    'first_grid_frame': '课表首帧绘制完成',
    'subscription.updated': '公告订阅已更新',
    'network.changed': '网络出口变化',
    'state.changed': '应用状态变化',
    'verbose.enabled': '详细日志已开启',
    'verbose.disabled': '详细日志已关闭',
    'export.created': '诊断日志已导出',
    'occupation_names.failed_using_builtin': '占用字典获取失败，使用内置配置',
    'exams.fetch_failed_using_existing': '考试获取失败，保留现有安排',
    'exams.save_failed_using_existing': '考试保存失败，保留现有安排',
    'academic': '学业进度',
    'student_info': '学生信息',
    'score': '成绩',
    'innovation_credit': '双创学分',
    'labor_score': '劳动积分',
    'electricity': '电费',
    'announcement': '应用公告',
    'contributors': '贡献者名单',
    'cas': '统一认证',
    'jwxt': '教务',
    'icard': '校园卡',
    'portal': '门户',
    'bulletin': '学校公告',
    'labor': '劳动教育',
    'innovation': '双创',
    'vpn': '校园 VPN',
    'shuttle': '小公交',
    'campus_map': '校园地图',
    'community': '社团服务',
    'external': '外部服务',
    'request.prepare': '请求准备',
    'vpn.authenticate': 'VPN 认证',
    'vpn.clear': '清理 VPN 凭据',
    'cas.preload': '统一认证证书准备',
    'cas.credential': '读取门户凭据',
    'cas.login': '统一认证登录',
    'vpn.credential': '读取 VPN 凭据',
    'service.preload': '业务证书准备',
    'map.prepare': '地图请求准备',
    'native.version': '检查 VPN 原生库',
    'native.prepareStart': '准备 VPN 原生建连',
    'native.start': 'VPN 原生握手',
    'native.startStatus': '查询 VPN 建连进度',
    'native.cancelStart': '取消 VPN 原生建连',
    'native.stop': '停止 VPN 原生隧道',
    'native.open': 'VPN 目标连接',
    'native.status': '查询 VPN 原生状态',
    'config': '读取配置',
    'dns': 'DNS 查询',
    'protocol_auth': '协议鉴权',
    'loopback_auth': '本地回环鉴权',
    'waiting': '等待调用',
    'done': '完成',
    'network': '网络错误',
    'timeout': '等待超时',
    'connection_error': '连接失败',
    'tls_handshake': 'TLS 握手失败',
    'portal_credential': '门户凭据不可用',
    'portal_network': '认证网络错误',
    'portal_login': '门户登录失败',
    'storage_io': '存储读写失败',
    'storage_write': '保存失败',
    'invalid_format': '数据格式异常',
    'platform_unavailable': '平台能力不可用',
    'platform_error': '平台调用失败',
    'unexpected': '未分类异常',
    'flutter_framework': '框架错误',
    'uncaught_async': '未捕获异步异常',
    'offline': '当前离线',
    'credential': '门户凭据不可用',
    'sessionExpired': '教务会话过期',
    'unbound': '门户尚未绑定',
    'storage': '存储失败',
    'format': '数据格式异常',
    'connectionTimeout': '连接超时',
    'sendTimeout': '发送超时',
    'receiveTimeout': '响应超时',
    'badCertificate': '证书校验失败',
    'badResponse': 'HTTP 响应异常',
    'connectionError': '连接失败',
    'cancel': '请求已取消',
    'flex_overflow': '布局溢出',
    'invalid_parent_data': '组件父级不匹配',
    'set_state_after_dispose': '组件销毁后仍更新状态',
    'build_during_build': '构建期间更新状态',
    'render_box_not_laid_out': '组件未完成布局',
    'unbounded_viewport': '滚动区域缺少边界',
    'infinite_constraints': '布局尺寸无限',
    'unbounded_flex': '弹性布局缺少边界',
    'duplicate_global_key': 'GlobalKey 重复',
    'hit': '缓存命中',
    'miss': '未命中缓存',
    'cache_fallback': '沿用缓存',
    'memory_fallback': '沿用内存数据',
    'cancelled': '已取消',
    'skipped': '已跳过',
    'updated': '有更新',
    'unchanged': '数据未变化',
    'upToDate': '已是最新',
    'worker_stopped': 'VPN 进程已停止',
    'receive_idle': '长时间未收到数据',
    'network_changed': '网络出口变化',
    'resumed': '前台',
    'inactive': '暂不活跃',
    'hidden': '已隐藏',
    'paused': '后台',
    'detached': '界面已分离',
    'wifi': 'Wi-Fi',
    'mobile': '移动网络',
    'ethernet': '有线网络',
    'none': '无网络',
    'unknown': '未知原因',
  };

  /// 应用内展开内容保留原始事件、全部安全字段及完整 Trace／Span。
  static String formatDetails(Map<String, Object?> record) {
    final attrs = (record['attrs'] as Map?)?.cast<String, Object?>() ?? {};
    final keys = attrs.keys.where((key) => key != 'stack_trace').toList()
      ..sort();
    return [
      for (final key in ['ts', 'level', 'scope', 'event'])
        if (record[key] case final value?) '$key: $value',
      for (final key in keys) '$key: ${_formatConsoleValue(attrs[key])}',
      for (final key in [
        'seq',
        'session_id',
        'trace_id',
        'span_id',
        'parent_span_id',
      ])
        if (record[key] case final value?) '$key: $value',
    ].join('\n');
  }

  static String _formatDuration(Object value) {
    if (value is! num) return '$value';
    if (value < 1000) return '${value.toInt()}ms';
    if (value < 60000) return '${(value / 1000).toStringAsFixed(2)}s';
    return '${value ~/ 60000}m${((value % 60000) / 1000).toStringAsFixed(1)}s';
  }

  static String _formatConsoleValue(Object? value) => switch (value) {
    String() when RegExp(r'\s').hasMatch(value) => jsonEncode(value),
    String() => value,
    Iterable() => jsonEncode(value.toList()),
    _ => '$value',
  };

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final values = List<int>.generate(bytes, (_) => random.nextInt(256));
    if (values.every((value) => value == 0)) values[0] = 1;
    return values
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _sanitizeName(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80);
  }

  static Map<String, Object?> _sanitizeFields(Map<String, Object?>? fields) {
    if (fields == null || fields.isEmpty) return <String, Object?>{};
    final result = <String, Object?>{};
    for (final entry in fields.entries.take(64)) {
      final key = _sanitizeName(entry.key);
      final value = _sanitizeField(key, entry.value);
      if (value != null) result[key] = value;
      if (result.length == 32) break;
    }
    for (final entry in const {
      'host': 'service',
      'redirect_host': 'redirect_service',
    }.entries) {
      final host = fields[entry.key];
      if (result[entry.key] != null &&
          !result.containsKey(entry.value) &&
          host is String &&
          !RegExp(r'^host_(?:\d{1,3}|other)$').hasMatch(host)) {
        result[entry.value] = serviceForHost(host);
      }
    }
    return result;
  }

  static Map<String, Object?>? _sanitizePersistedRecord(
    Map<String, Object?> record,
  ) {
    final at = record['ts'];
    final sequence = record['seq'];
    final scope = record['scope'];
    final event = record['event'];
    final level = record['level'];
    if (at is! String ||
        DateTime.tryParse(at) == null ||
        sequence is! int ||
        sequence < 0 ||
        sequence > 0x7fffffff ||
        scope is! String ||
        event is! String ||
        !const {'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'}.contains(level)) {
      return null;
    }
    final originalAttrs = record['attrs'];
    final attrs = _sanitizeFields(
      originalAttrs is Map<String, dynamic> ? originalAttrs : null,
    );
    if (originalAttrs is Map && originalAttrs['stack_trace'] is String) {
      attrs['stack_trace'] = _sanitizeStack(
        StackTrace.fromString(originalAttrs['stack_trace'] as String),
      );
    }
    bool validId(Object? id, int length) =>
        id is String && RegExp('^[a-f0-9]{$length}\$').hasMatch(id);
    return {
      'ts': DateTime.parse(at).toUtc().toIso8601String(),
      'seq': sequence,
      'level': level,
      'scope': _sanitizeName(scope).replaceAll(RegExp(r'\d{6,20}'), 'id'),
      'event': _sanitizeName(event).replaceAll(RegExp(r'\d{6,20}'), 'id'),
      if (validId(record['session_id'], 16)) 'session_id': record['session_id'],
      if (validId(record['trace_id'], 32)) 'trace_id': record['trace_id'],
      if (validId(record['span_id'], 16)) 'span_id': record['span_id'],
      if (validId(record['parent_span_id'], 16))
        'parent_span_id': record['parent_span_id'],
      if (attrs.isNotEmpty) 'attrs': attrs,
    };
  }

  // 白名单同时限定字段语义、类型和范围，未知业务字段不进入日志。
  static const _booleanFields = {
    'automatic',
    'force',
    'force_refresh',
    'enabled',
    'has_cache',
    'offline',
    'not_modified',
    'alive',
    'healthy',
    'recovering',
    'cancelled',
    'silent',
  };
  static const _countFields = {
    'count',
    'course_count',
    'exam_count',
    'other_count',
    'skipped_count',
    'topic_count',
    'vehicle_count',
    'field_count',
    'waiters',
    'heartbeats',
    'dns_timeouts',
    'tcp_timeouts',
    'log_format_version',
    'duration_minutes',
    'recovered_files',
    'unreadable_files',
  };
  static const _idFields = {
    'request_id',
    'connection_id',
    'stage_id',
    'attempt',
    'native_start_id',
    'vpn_session_id',
  };
  static const _durationFields = {
    'duration_ms',
    'preparation_ms',
    'timeout_ms',
    'stage_elapsed_ms',
    'loop_idle_ms',
    'rx_idle_ms',
    'config_ms',
    'dns_ms',
    'tcp_ms',
    'tls_ms',
    'protocol_auth_ms',
    'waiting_ms',
    'native_timeout_ms',
  };
  static const _connectionTypes = {
    'wifi',
    'mobile',
    'ethernet',
    'bluetooth',
    'vpn',
    'other',
    'none',
    'satellite',
  };
  static const _codeFields = {
    'service': {
      'cas',
      'jwxt',
      'icard',
      'portal',
      'bulletin',
      'labor',
      'innovation',
      'vpn',
      'shuttle',
      'campus_map',
      'community',
      'external',
    },
    'redirect_service': {
      'cas',
      'jwxt',
      'icard',
      'portal',
      'bulletin',
      'labor',
      'innovation',
      'vpn',
      'shuttle',
      'campus_map',
      'community',
      'external',
    },
    'route': {'VPN', '直连', '请求准备'},
    'state': {'resumed', 'inactive', 'hidden', 'paused', 'detached'},
    'method': {
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
      'CONNECT',
      'TRACE',
      'version',
      'prepareStart',
      'start',
      'startStatus',
      'cancelStart',
      'stop',
      'open',
      'status',
    },
    'dio_type': {
      'connectionTimeout',
      'sendTimeout',
      'receiveTimeout',
      'badCertificate',
      'badResponse',
      'cancel',
      'connectionError',
      'unknown',
    },
    'error_kind': {
      'network',
      'timeout',
      'tls_handshake',
      'connection_error',
      'storage_io',
      'invalid_format',
      'platform_unavailable',
      'platform_error',
      'portal_credential',
      'portal_network',
      'portal_login',
      'storage_write',
      'unexpected',
      'flutter_framework',
      'uncaught_async',
    },
    'framework_library': {
      'rendering',
      'widgets',
      'animation',
      'scheduler',
      'services',
      'gestures',
      'painting',
      'image',
      'other',
    },
    'framework_error': {
      'exception',
      'flex_overflow',
      'invalid_parent_data',
      'set_state_after_dispose',
      'build_during_build',
      'render_box_not_laid_out',
      'unbounded_viewport',
      'infinite_constraints',
      'unbounded_flex',
      'duplicate_global_key',
      'unclassified',
    },
    'cache': {'hit', 'miss'},
    'stage': {
      'request.prepare',
      'vpn.authenticate',
      'vpn.clear',
      'cas.preload',
      'cas.credential',
      'cas.login',
      'vpn.credential',
      'vpn.clear_controller',
      'vpn.read_controller',
      'service.preload',
      'map.prepare',
      'opening',
      'sso_reused',
      'asserting',
      'submitting',
      'done',
      'native.version',
      'native.prepareStart',
      'native.start',
      'native.startStatus',
      'native.cancelStart',
      'native.stop',
      'native.open',
      'native.status',
    },
    'native_stage': {
      'config',
      'dns',
      'tcp',
      'tls',
      'protocol_auth',
      'done',
      'waiting',
      'loopback_auth',
      'unknown',
    },
    'outcome': {
      'success',
      'failure',
      'cache_fallback',
      'memory_fallback',
      'cancelled',
      'skipped',
      'idle',
      'syncing',
      'synced',
      'failed',
      'error',
      'upToDate',
      'updated',
      'unchanged',
      'initial',
      'notBound',
      'bound',
      'never',
      'successWithChanges',
      'successNoChanges',
      'dismissed',
      'unavailable',
    },
    'failure_kind': {
      'none',
      'offline',
      'network',
      'credential',
      'login',
      'format',
      'storage',
      'unknown',
      'sessionExpired',
      'unbound',
      'other',
      'server',
    },
    'reason': {
      'unknown',
      'worker_stopped',
      'receive_idle',
      'network_changed',
      'cancelled',
      'NotFound',
      'PermissionDenied',
      'ConnectionRefused',
      'ConnectionReset',
      'HostUnreachable',
      'NetworkUnreachable',
      'ConnectionAborted',
      'NotConnected',
      'AddrInUse',
      'AddrNotAvailable',
      'NetworkDown',
      'BrokenPipe',
      'AlreadyExists',
      'WouldBlock',
      'InvalidInput',
      'InvalidData',
      'TimedOut',
      'WriteZero',
      'Interrupted',
      'UnexpectedEof',
      'Unsupported',
      'OutOfMemory',
      'Other',
    },
    'script_event': {
      'injected',
      'request',
      'response',
      'device_check',
      'registration_blocked',
      'authenticator_check',
      'credential_create',
      'credential_get',
      'iframe_ignored',
      'iframe_patched',
      'patch_failed',
      'navigation',
      'form_submit',
      'environment',
      'bind_modal',
      'bind_button',
      'biometrics_tab',
      'biometrics_switch',
      'recheck_skipped',
      'verify_started',
      'verified',
      'unknown',
    },
  };

  /// 脚本日志只保留白名单事件和短返回码，丢弃地址、参数与原始消息。
  static Map<String, Object?> scriptEventFields(String message) {
    final text = message.length > 512 ? message.substring(0, 512) : message;
    var event = 'unknown';
    for (final entry in const {
      'injected at ': 'injected',
      'intercepted isDeviceBinded': 'device_check',
      'blocked page register': 'registration_blocked',
      'page asked isUserVerifyingPlatformAuthenticatorAvailable':
          'authenticator_check',
      'page called credentials.create': 'credential_create',
      'page called credentials.get': 'credential_get',
      'cross-origin iframe ignored': 'iframe_ignored',
      'same-origin iframe patched': 'iframe_patched',
      'reinstall patches failed': 'patch_failed',
      'page hash ->': 'navigation',
      'page history.': 'navigation',
      'page form submit ->': 'form_submit',
      'env ': 'environment',
      'signal: isDeviceBinded': 'device_check',
      'signal: bind modal': 'bind_modal',
      'bind button found': 'bind_button',
      'click biometrics tab': 'biometrics_tab',
      'click biometrics switch': 'biometrics_switch',
      'recheck not necessary': 'recheck_skipped',
      'click bind button to trigger verification': 'verify_started',
      'verified': 'verified',
    }.entries) {
      if (text.startsWith(entry.key)) {
        event = entry.value;
        break;
      }
    }
    if (text.contains(' -> code ')) event = 'response';
    final code = RegExp(r'(?: -> code |recheck code )(-?\d{1,5})(?!\d)')
        .firstMatch(text)
        ?.group(1);
    return {
      'script_event': event,
      'response_code': ?(code == null ? null : int.tryParse(code)),
    };
  }

  static Object? _sanitizeField(String key, Object? value) {
    if (value == null) return null;
    if (_booleanFields.contains(key)) return value is bool ? value : null;
    if (key == 'connection_types' && value is Iterable) {
      return value
          .take(20)
          .map((item) => item is Enum ? item.name : item)
          .whereType<String>()
          .where(_connectionTypes.contains)
          .toList();
    }
    final limit = _countFields.contains(key)
        ? 999999
        : _idFields.contains(key)
        ? 0x7fffffff
        : _durationFields.contains(key)
        ? 7 * 24 * 60 * 60 * 1000
        : {'bytes', 'received_bytes'}.contains(key)
        ? 64 * 1024 * 1024 * 1024
        : key == 'output_chars'
        ? 10 * 1024 * 1024
        : {'port', 'redirect_port'}.contains(key)
        ? 65535
        : key == 'status_code'
        ? 599
        : {'response_code', 'os_code'}.contains(key)
        ? 99999
        : null;
    if (limit != null) {
      final number = key == 'response_code' && value is String
          ? int.tryParse(value)
          : value;
      if (number is! num ||
          !number.isFinite ||
          number != number.truncateToDouble()) {
        return null;
      }
      final minimum = key == 'os_code' || key == 'response_code' ? -99999 : 0;
      if (number < minimum || number > limit) {
        return null;
      }
      if (key == 'status_code' && number < 100) return null;
      return number.toInt();
    }
    final text = value is Enum
        ? value.name
        : value is String
        ? value
        : null;
    if (text == null) return null;
    if (key == 'host' || key == 'redirect_host') {
      if (text.isEmpty ||
          text.length > 253 ||
          RegExp(r'[\s/@?#]').hasMatch(text)) {
        return null;
      }
      if (RegExp(r'^host_(?:\d{1,3}|other)$').hasMatch(text)) return text;
      final normalized = text.toLowerCase();
      return _hostAliases[normalized] ??
          (_hostAliases.length >= 128
              ? 'host_other'
              : _hostAliases.putIfAbsent(
                  normalized,
                  () => 'host_${++_hostSequence}',
                ));
    }
    if (key == 'error_type' || key == 'response_type') {
      final type = text.split('<').first;
      return RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,79}$').hasMatch(type)
          ? type
          : null;
    }
    if (key == 'app_id') {
      return RegExp(r'^[a-z][a-z_-]{0,63}$').hasMatch(text) ? text : null;
    }
    if (key == 'file_kind') {
      return const {
            'summary.json',
            'profile.json',
            'report.json',
            'credit.json',
            'prefs.json',
            'buildings.json',
            'snapshot.json',
            'settings.json',
            'manual.json',
            'manual_courses.json',
            'schedule_events.json',
            'course_edits.json',
            'overrides.json',
            'course_colors.json',
            'exam_overrides.json',
            'sync_state.json',
            'day_swaps.json',
          }.contains(text)
          ? text
          : null;
    }
    return _codeFields[key]?.contains(text) == true ? text : null;
  }

  static String _sanitizeText(String input) {
    var value = input;
    value = value.replaceAll(
      RegExp(
        r'-----BEGIN [^-]+-----.*?-----END [^-]+-----',
        caseSensitive: false,
        dotAll: true,
      ),
      '[REDACTED_SECRET]',
    );
    value = value.replaceAll(
      RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      '[REDACTED_TOKEN]',
    );
    value = value.replaceAll(
      RegExp(
        r'\b(?:authorization|proxy-authorization|(?:set-)?cookie)\s*[:=][^\r\n]*',
        caseSensitive: false,
      ),
      '[REDACTED_SECRET]',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:bearer|basic)\s+[^\s,;]+', caseSensitive: false),
      '[REDACTED_SECRET]',
    );
    value = value.replaceAll(
      RegExp(
        r'\b(authorization|cookie|ticket|token|password|secret|signature|pin)\s*[:=]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      '[REDACTED_SECRET]',
    );
    value = value.replaceAll(RegExp(r'(?<!\d)\d{6,20}(?!\d)'), '[REDACTED_ID]');
    value = value.replaceAll(
      RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
      '[REDACTED_URL]',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b'),
      '[REDACTED_HOST]',
    );
    value = value.replaceAll(
      RegExp(r'(?<![a-zA-Z0-9_-])(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?::\d+)?'),
      '[REDACTED_HOST]',
    );
    value = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return value.length <= 256 ? value : '${value.substring(0, 253)}...';
  }

  static String _sanitizeStack(StackTrace stackTrace) {
    final lines = stackTrace.toString().split('\n').take(20);
    final value = lines
        .map((line) {
          if (line.trim() == '<asynchronous suspension>') {
            return '<asynchronous suspension>';
          }
          final frame = RegExp(r'^#(\d+)\s+(.+?)(?:\s+\((.+):(\d+):(\d+)\))?$')
              .firstMatch(line.trim());
          if (frame == null) return '[省略无法安全解析的堆栈帧]';
          final method = frame.group(2)!;
          if (!RegExp(r'^[A-Za-z0-9_$ .<>-]+$').hasMatch(method)) {
            return '#${frame.group(1)} [省略无法安全解析的方法]';
          }
          final location = frame.group(3);
          if (location == null) return '#${frame.group(1)} $method';
          String? safeLocation;
          if (RegExp(r'^(?:package:[a-z0-9_]+/|dart:)[A-Za-z0-9_./-]+\.dart$')
              .hasMatch(location)) {
            safeLocation = location;
          } else {
            final filename = location.replaceAll('\\', '/').split('/').last;
            if (RegExp(r'^[A-Za-z0-9_-]+\.dart$').hasMatch(filename)) {
              safeLocation = filename;
            }
          }
          return '#${frame.group(1)} $method '
              '(${safeLocation ?? '[外部代码]'}:${frame.group(4)}:${frame.group(5)})';
        })
        .join('\n');
    return value.length <= 2048 ? value : value.substring(0, 2048);
  }

  @visibleForTesting
  static String sanitizeTextForTesting(String value) => _sanitizeText(value);

  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _store?.flush();
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _verboseTimer?.cancel();
    _verboseTimer = null;
    _verboseUntil = null;
    verboseExpiresAt.value = null;
    storageAvailable.value = false;
    verboseEnabled.value = kDebugMode;
    _store = null;
    _sequence = 0;
    _hostSequence = 0;
    _hostAliases.clear();
    _initialized = false;
    _initialization = null;
    _nativeConsoleAvailable = true;
    recordListenerForTesting = null;
    consoleEnabledForTesting = false;
  }
}

/// 绑定业务作用域的日志器。
class AppLogger {
  const AppLogger._(this.scope);

  final String scope;

  /// 创建可跨异步回调绑定的本机 Span，不写入任何请求头。
  AppLogSpan startSpan() {
    final parent = Zone.current[AppLog._contextKey] as _LogContext?;
    return AppLogSpan._(
      _LogContext(
        traceId: parent?.traceId ?? AppLog._randomHex(16),
        spanId: AppLog._randomHex(8),
        parentSpanId: parent?.spanId,
      ),
    );
  }

  /// 为已有业务 Trace 的一次内部 I/O 建立子 Span，不额外输出事件。
  Future<T> inSpan<T>(Future<T> Function() body) {
    if (Zone.current[AppLog._contextKey] == null) return body();
    return startSpan().run(body);
  }

  void debug(String event, {Map<String, Object?>? fields}) =>
      AppLog._write(scope, AppLogLevel.debug, event, fields: fields);

  void info(String event, {Map<String, Object?>? fields}) =>
      AppLog._write(scope, AppLogLevel.info, event, fields: fields);

  void warning(
    String event, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
    String? errorKind,
  }) => AppLog._write(
    scope,
    AppLogLevel.warning,
    event,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
    errorKind: errorKind,
  );

  void error(
    String event, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
    String? errorKind,
  }) => AppLog._write(
    scope,
    AppLogLevel.error,
    event,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
    errorKind: errorKind,
  );

  void fatal(
    String event, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
    String? errorKind,
  }) => AppLog._write(
    scope,
    AppLogLevel.fatal,
    event,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
    errorKind: errorKind,
  );

  /// 在新的 Span 中执行异步业务操作；顶层操作同时创建 Trace。
  Future<T> operation<T>(
    String event,
    Future<T> Function() body, {
    Map<String, Object?>? fields,
    Map<String, Object?> Function(T result)? resultFields,
    Map<String, Object?> Function(Object error)? errorFields,
    String? failureEvent,
    AppLogLevel successLevel = AppLogLevel.info,
    AppLogLevel failureLevel = AppLogLevel.warning,
    AppLogLevel Function(Object error)? failureLevelForError,
  }) {
    return startSpan().run(() async {
      final watch = Stopwatch()..start();
      debug('$event.started', fields: fields);
      try {
        final result = await body();
        watch.stop();
        final completed = <String, Object?>{
          ...?fields,
          'duration_ms': watch.elapsedMilliseconds,
        };
        if (resultFields != null) {
          try {
            completed.addAll(resultFields(result));
          } catch (_) {
            // 结果字段只用于诊断，不能影响业务返回值。
          }
        }
        AppLog._write(
          scope,
          successLevel,
          '$event.completed',
          fields: completed,
        );
        return result;
      } catch (error, stackTrace) {
        watch.stop();
        final failed = <String, Object?>{
          ...?fields,
          'duration_ms': watch.elapsedMilliseconds,
        };
        var level = failureLevel;
        try {
          failed.addAll(errorFields?.call(error) ?? const {});
          level = failureLevelForError?.call(error) ?? failureLevel;
        } catch (_) {
          // 日志补充字段或级别选择不能改变原始业务异常。
        }
        AppLog._write(
          scope,
          level,
          failureEvent ?? '$event.failed',
          fields: failed,
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    });
  }
}

/// 保留本机追踪上下文的 Span，供网络回调、队列与重试复用。
class AppLogSpan {
  const AppLogSpan._(this._context);
  final _LogContext _context;

  /// 在该 Span 内执行同步或异步回调。
  T run<T>(T Function() body) =>
      runZoned(body, zoneValues: {AppLog._contextKey: _context});
}

class _LogContext {
  const _LogContext({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
  });

  final String traceId;
  final String spanId;
  final String? parentSpanId;
}
