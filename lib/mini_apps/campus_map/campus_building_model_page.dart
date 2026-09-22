import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'campus_building_model.dart';
import 'campus_map_api.dart';
import 'campus_map_widgets.dart';

/// Kept in both building details and indoor mode, independent of navigation.
class CampusBuildingModelEntry extends StatefulWidget {
  const CampusBuildingModelEntry({
    super.key,
    required this.source,
    required this.buildingId,
    required this.buildingName,
    this.levelIndex,
  });

  final CampusBuildingModelSource? source;
  final String buildingId, buildingName;
  final int? levelIndex;

  @override
  State<CampusBuildingModelEntry> createState() =>
      _CampusBuildingModelEntryState();
}

class _CampusBuildingModelEntryState extends State<CampusBuildingModelEntry> {
  CampusBuildingModel? _model;
  String? _error;
  bool _loading = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CampusBuildingModelEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.buildingId != widget.buildingId) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final revision = ++_revision;
    final source = widget.source;
    setState(() {
      _loading = source != null;
      _model = null;
      _error = null;
    });
    if (source == null) return;
    try {
      final model = await source.loadBuildingModel(widget.buildingId);
      if (!mounted || revision != _revision) return;
      setState(() {
        _model = model;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _error = error is CampusMapApiException
            ? error.message
            : '模型状态检测失败，请重试';
      });
    }
  }

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusBuildingModelPage(
          source: widget.source!,
          buildingId: widget.buildingId,
          buildingName: widget.buildingName,
          model: _model!,
          initialLevelIndex: widget.levelIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MapSurface(
    radius: 18,
    child: ListTile(
      minVerticalPadding: 12,
      leading: const Icon(Icons.view_in_ar_outlined, color: MapPalette.blue),
      title: const Text('三维模型', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Semantics(
        liveRegion: true,
        child: Text(
          _loading
              ? '正在检测模型…'
              : _error ??
                    (_model != null
                        ? '查看完整模型 · ${_model!.floors.length} 个楼层'
                        : widget.source == null
                        ? '当前地图服务未提供三维模型'
                        : '该建筑尚未上传 GLB 模型'),
        ),
      ),
      trailing: _loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _model != null
          ? const Icon(Icons.chevron_right_rounded)
          : IconButton(
              tooltip: '重新检测三维模型',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: widget.source == null ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
      onTap: _model == null ? null : _open,
    ),
  );
}

class CampusBuildingModelPage extends StatefulWidget {
  const CampusBuildingModelPage({
    super.key,
    required this.source,
    required this.buildingId,
    required this.buildingName,
    required this.model,
    this.initialLevelIndex,
  });

  final CampusBuildingModelSource source;
  final String buildingId, buildingName;
  final CampusBuildingModel model;
  final int? initialLevelIndex;

  @override
  State<CampusBuildingModelPage> createState() =>
      _CampusBuildingModelPageState();
}

class _CampusBuildingModelPageState extends State<CampusBuildingModelPage> {
  int? _levelIndex;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    if (widget.model.floors.any(
      (f) => f.levelIndex == widget.initialLevelIndex,
    )) {
      _levelIndex = widget.initialLevelIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = widget.source.buildingModelViewerUri(
      widget.buildingId,
      levelIndex: _levelIndex,
    );
    final supported =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final theme = ThemeData.light(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: MapPalette.blue),
      scaffoldBackgroundColor: MapPalette.surface,
    );
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.buildingName} · 三维模型'),
          actions: [
            IconButton(
              tooltip: '重新加载模型',
              onPressed: () => setState(() => _attempt++),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: DropdownButtonFormField<int>(
                  key: ValueKey(_levelIndex),
                  initialValue: _levelIndex ?? _wholeBuilding,
                  isExpanded: true,
                  itemHeight: null,
                  decoration: const InputDecoration(
                    labelText: '查看范围',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: _wholeBuilding,
                      child: SizedBox(
                        height: 48,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('完整模型'),
                        ),
                      ),
                    ),
                    for (final floor in widget.model.floors)
                      DropdownMenuItem(
                        value: floor.levelIndex,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(floor.displayName),
                          ),
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _levelIndex = value == _wholeBuilding ? null : value;
                  }),
                ),
              ),
              Expanded(
                child: supported
                    ? _ModelWebView(
                        key: ValueKey('$uri#$_attempt'),
                        uri: uri,
                        onRetry: () => setState(() => _attempt++),
                      )
                    : _ViewerMessage(
                        title: '当前平台暂不支持内嵌三维查看',
                        message: '可在 Android 或 iOS 应用中查看，也可复制下方链接到浏览器打开。',
                        uri: uri,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _wholeBuilding = -2147483648;
}

class _ModelWebView extends StatefulWidget {
  const _ModelWebView({super.key, required this.uri, required this.onRetry});
  final Uri uri;
  final VoidCallback onRetry;

  @override
  State<_ModelWebView> createState() => _ModelWebViewState();
}

class _ModelWebViewState extends State<_ModelWebView> {
  WebViewController? _controller;
  Timer? _timeout;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(
      const Duration(seconds: 90),
      () => _fail('模型加载超时，请检查网络后重试'),
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'CampusModelViewer',
        onMessageReceived: (message) {
          if (!mounted || _error != null) return;
          try {
            final data = jsonDecode(message.message);
            if (data is! Map) return;
            if (data['type'] == 'ready') {
              _timeout?.cancel();
              setState(() => _ready = true);
            } else if (data['type'] == 'error') {
              _fail(
                data['message'] is String
                    ? data['message'] as String
                    : 'GLB 模型加载失败',
              );
            }
          } on FormatException {
            // Ignore unrelated or malformed messages from the document.
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            return target != null &&
                    target.hasAuthority &&
                    (target.scheme == 'http' || target.scheme == 'https') &&
                    target.origin == widget.uri.origin &&
                    target.path == widget.uri.path
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _fail('三维查看页面加载失败，请检查网络后重试');
          },
          onHttpError: (error) {
            if (error.request?.uri.toString() == widget.uri.toString()) {
              _fail('三维查看页面请求失败（HTTP ${error.response?.statusCode ?? '未知'}）');
            }
          },
        ),
      );
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.loadRequest(widget.uri);
    } catch (_) {
      _fail('无法启动三维查看页面，请重试或复制链接到浏览器打开');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    _timeout?.cancel();
    setState(() => _error = message);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ViewerMessage(
        title: '模型加载失败',
        message: _error!,
        uri: widget.uri,
        onRetry: widget.onRetry,
      );
    }
    return Stack(
      children: [
        if (_controller != null)
          Positioned.fill(child: WebViewWidget(controller: _controller!)),
        if (!_ready)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Semantics(
              liveRegion: true,
              child: const Material(
                child: Column(
                  children: [
                    LinearProgressIndicator(),
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('正在加载三维模型…'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ViewerMessage extends StatelessWidget {
  const _ViewerMessage({
    required this.title,
    required this.message,
    required this.uri,
    this.onRetry,
  });
  final String title, message;
  final Uri uri;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.view_in_ar_outlined,
              size: 40,
              color: MapPalette.blue,
            ),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            SelectableText(uri.toString()),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onRetry != null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () async {
                    try {
                      await Clipboard.setData(
                        ClipboardData(text: uri.toString()),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('查看链接已复制')));
                    } catch (_) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('复制失败，请长按上方链接手动复制')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制查看链接'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
