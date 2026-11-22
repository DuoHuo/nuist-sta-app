import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bulletin_attachment_search.dart';

/// 在独立的 Android 阅读视图中显示离线引擎生成的内容。
class BulletinOfficeEngineView extends StatefulWidget {
  /// 打开已下载的附件，文件直接由原生视图读取。
  const BulletinOfficeEngineView({
    super.key,
    required this.file,
    required this.onReady,
    required this.onFailure,
    this.searchExpanded = false,
  });

  final File file;
  final ValueChanged<String?> onReady;
  final VoidCallback onFailure;

  /// 是否在阅读视图上方显示页内查找框。
  final bool searchExpanded;

  @override
  State<BulletinOfficeEngineView> createState() =>
      _BulletinOfficeEngineViewState();
}

class _BulletinOfficeEngineViewState extends State<BulletinOfficeEngineView> {
  static const _viewType = 'nuist/bulletin_office_view';

  MethodChannel? _channel;
  Timer? _timeout;
  bool _failed = false;
  late final BulletinLiveSearch<int> _search;
  Completer<int>? _finding;

  /// WebView 当前高亮的命中序号，用于把跳转换算成逐项移动。
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 15), _fail);
    _search = BulletinLiveSearch<int>(_find, (count) => count)
      ..addListener(_updateSearch);
  }

  @override
  void didUpdateWidget(covariant BulletinOfficeEngineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchExpanded && !widget.searchExpanded) {
      _search.updateText('');
    }
  }

  Future<int> _find(String query, bool _) async {
    final channel = _channel;
    if (channel == null) throw StateError('阅读视图尚未就绪');
    _finding?.completeError(StateError('查找已被新的关键词替代'));
    final finding = Completer<int>();
    _finding = finding;
    _active = 0;
    await channel.invokeMethod<void>('find', {'query': query});
    return finding.future.timeout(const Duration(seconds: 10));
  }

  void _updateSearch() {
    if (!mounted) return;
    setState(() {});
    final channel = _channel;
    if (channel == null) return;
    if (!_search.active) {
      unawaited(_invoke(channel, 'clearFind'));
      return;
    }
    final count = _search.count;
    final target = _search.selectedIndex;
    if (count == 0 || target == _active) return;
    final forward = (target - _active) % count;
    final backward = count - forward;
    final steps = forward <= backward ? forward : backward;
    for (var step = 0; step < steps; step++) {
      unawaited(_invoke(channel, 'findNext', {'forward': forward <= backward}));
    }
    _active = target;
  }

  Future<void> _invoke(
    MethodChannel channel,
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // 阅读视图已释放时忽略查找操作。
    } on MissingPluginException {
      // 同上。
    }
  }

  Future<void> _start(int id) async {
    if (!mounted || _failed) return;
    final channel = MethodChannel('$_viewType/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || _failed) return;
      switch (call.method) {
        case 'ready':
          _timeout?.cancel();
          final mime = call.arguments as String?;
          widget.onReady(mime?.isNotEmpty == true ? mime : null);
        case 'failed':
          _fail();
        case 'found':
          final data = call.arguments as Map;
          _active = data['active'] as int;
          final finding = _finding;
          if (finding != null && !finding.isCompleted) {
            _finding = null;
            finding.complete(data['count'] as int);
          }
      }
    });
    try {
      await channel.invokeMethod<void>('load', {
        'path': widget.file.path,
        'dark': Theme.of(context).brightness == Brightness.dark,
      });
    } on PlatformException {
      _fail();
    } on MissingPluginException {
      _fail();
    }
  }

  void _fail() {
    if (!mounted || _failed) return;
    _failed = true;
    _timeout?.cancel();
    widget.onFailure();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _channel?.setMethodCallHandler(null);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.searchExpanded)
        BulletinSearchField(search: _search, showMatchCase: false),
      Expanded(
        child: AndroidView(viewType: _viewType, onPlatformViewCreated: _start),
      ),
    ],
  );
}
