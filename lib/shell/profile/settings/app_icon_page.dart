import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/navigation/app_page.dart';
import '../../../core/app_snack_bar.dart';
import '../../../core/colors.dart';
import 'app_icon_controller.dart';
import 'app_icon_crop_page.dart';
import 'app_icon_models.dart';

/// 应用图标设置页：内置图标，以及相册图片生成的自定义桌面快捷方式。
class AppIconPage extends StatefulWidget {
  const AppIconPage({super.key, this.controller});

  /// 可注入的控制器；为空时由页面自建并在退出时释放。
  final AppIconController? controller;

  @override
  State<AppIconPage> createState() => _AppIconPageState();
}

class _AppIconPageState extends State<AppIconPage> with WidgetsBindingObserver {
  late final AppIconController _controller =
      widget.controller ?? AppIconController();
  late final bool _ownsController = widget.controller == null;
  // 提示和重试随图标页一起退出，避免在设置页继续触发旧页面的写入。
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.ensureStarted());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _selectBuiltin(String id) async {
    final ok = await _controller.setBuiltin(id);
    if (!mounted) return;
    if (!ok) {
      _showErrorWithRetry(_controller.errorMessage, () => _selectBuiltin(id));
      return;
    }
    final label = appIconChoices.firstWhere((item) => item.id == id).label;
    _showMessage('已切换为「$label」图标', tone: AppSnackBarTone.success);
  }

  Future<void> _chooseImage() async {
    final picked = await _controller.pickImage();
    if (!mounted) return;
    if (picked == null) {
      if (_controller.error) {
        _showErrorWithRetry(_controller.errorMessage, _chooseImage);
      }
      return;
    }
    final cropped = await Navigator.of(context).push<Uint8List>(
      AppPageRoute(builder: (_) => AppIconCropPage(imageBytes: picked)),
    );
    if (!mounted || cropped == null) {
      _controller.clearPickedImage();
      return;
    }
    await _commitCustom(cropped);
  }

  Future<void> _commitCustom(Uint8List bytes) async {
    final ok = await _controller.setCustomIcon(bytes);
    if (!mounted) return;
    if (!ok) {
      _showErrorWithRetry(_controller.errorMessage, () => _commitCustom(bytes));
      return;
    }
    final state = _controller.state;
    if (state.pending) {
      _showMessage('请在系统提示中确认添加快捷方式');
    } else if (state.customPinned) {
      _showMessage('自定义图标已添加到桌面', tone: AppSnackBarTone.success);
    } else {
      _showMessage('已请求添加桌面快捷方式');
    }
  }

  Future<void> _pinCustom() async {
    final ok = await _controller.pinCustomIcon();
    if (!mounted) return;
    if (!ok) {
      _showErrorWithRetry(_controller.errorMessage, _pinCustom);
      return;
    }
    _showMessage('请在系统提示中确认添加到桌面');
  }

  void _showErrorWithRetry(String? message, Future<void> Function() retry) {
    final text = message ?? '操作失败，请稍后重试';
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(
          tone: AppSnackBarTone.error,
          content: Text(text),
          action: SnackBarAction(
            label: '重试',
            onPressed: () {
              if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
              unawaited(retry());
            },
          ),
        ),
      );
  }

  void _showMessage(
    String message, {
    AppSnackBarTone tone = AppSnackBarTone.info,
  }) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(
          tone: tone,
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final palette = AppPalette.of(context);
          final state = _controller.state;
          return PopScope<Object?>(
            canPop: !_controller.busy,
            child: Scaffold(
              appBar: AppBar(title: const Text('应用图标')),
              body: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  if (_controller.busy || _controller.picking)
                    LinearProgressIndicator(
                      key: const Key('app_icon_busy'),
                      minHeight: 2,
                      color: palette.accent,
                      backgroundColor: palette.rowDivider,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                    child: Semantics(
                      header: true,
                      child: Text(
                        '内置图标',
                        style: TextStyle(
                          color: palette.labelText,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    _controller.unsupported
                        ? '当前系统暂不支持切换应用图标。'
                        : '选择后会立即更新桌面入口；桌面布局可能随之调整。',
                    style: TextStyle(
                      color: palette.labelText,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _BuiltinGrid(
                    state: state,
                    busy: _controller.busy || _controller.picking,
                    onSelected: _selectBuiltin,
                  ),
                  if (_controller.error && _controller.errorMessage != null)
                    _InlineError(
                      message: _controller.errorMessage!,
                      onRetry: () => unawaited(_controller.refresh()),
                    ),
                  const SizedBox(height: 26),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: Semantics(
                      header: true,
                      child: Text(
                        '自定义桌面图标',
                        style: TextStyle(
                          color: palette.labelText,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  _CustomSection(
                    state: state,
                    busy: _controller.busy || _controller.picking,
                    unsupported: _controller.unsupported,
                    onChoose: _chooseImage,
                    onPin: _pinCustom,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BuiltinGrid extends StatelessWidget {
  const _BuiltinGrid({
    required this.state,
    required this.busy,
    required this.onSelected,
  });

  final AppIconState state;
  final bool busy;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    const gap = 8.0;
    const maxCardWidth = 116.0;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxCardWidth * 4 + gap * 3),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, choice) in appIconChoices.indexed) ...[
                if (index > 0) const SizedBox(width: gap),
                Expanded(
                  child: _BuiltinCard(
                    key: Key('app_icon_choice_${choice.id}'),
                    choice: choice,
                    selected: state.builtinId == choice.id,
                    enabled: state.supported && !busy,
                    onTap: () => onSelected(choice.id),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BuiltinCard extends StatelessWidget {
  const _BuiltinCard({
    super.key,
    required this.choice,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final AppIconChoice choice;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final border = selected ? palette.accent : palette.divider;
    const iconSize = 56.0;
    const cardRadius = BorderRadius.all(Radius.circular(8));
    final iconCacheSize = math.max(
      1,
      (iconSize * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    return Semantics(
      selected: selected,
      button: true,
      enabled: enabled,
      label: '${choice.label}图标',
      child: Material(
        color: palette.surface,
        borderRadius: cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.all(8),
            foregroundDecoration: BoxDecoration(
              border: Border.all(color: border, width: selected ? 2 : 1),
              borderRadius: cardRadius,
            ),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: iconSize),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            choice.assetPath,
                            cacheWidth: iconCacheSize,
                            cacheHeight: iconCacheSize,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, _, _) => ColoredBox(
                              color: palette.pageBg,
                              child: Icon(
                                Icons.apps_rounded,
                                color: palette.hint,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: palette.accent,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: palette.surface,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.check,
                            size: 14,
                            color: palette.surface,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  choice.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: enabled ? palette.titleText : palette.hint,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomSection extends StatelessWidget {
  const _CustomSection({
    required this.state,
    required this.busy,
    required this.unsupported,
    required this.onChoose,
    required this.onPin,
  });

  final AppIconState state;
  final bool busy;
  final bool unsupported;
  final VoidCallback onChoose;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final available = state.supported && state.canPin;
    final status = switch (true) {
      _ when state.pending => '等待系统确认。如果系统提示已关闭，可再次点击“添加到桌面”。',
      _ when state.customPinned => '已添加到桌面；仍可继续添加新的快捷方式。',
      _ when state.customIcon != null => '已保存上次图片，可直接添加到桌面。',
      _ when !state.supported => '当前系统暂不支持自定义桌面图标。',
      _ when !state.canPin => '当前桌面不支持添加快捷方式，内置图标仍可切换。',
      _ => '会创建额外的桌面快捷方式，原应用入口仍然保留，并可能带有系统角标。',
    };
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CustomPreview(bytes: state.customIcon, enabled: available),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '自定义桌面图标',
                        style: TextStyle(
                          color: palette.titleText,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        status,
                        style: TextStyle(
                          color: palette.labelText,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('app_icon_choose_image'),
              onPressed: available && !busy ? onChoose : null,
              icon: const Icon(Icons.photo_library_outlined, size: 19),
              label: Text(
                state.customPinned || state.customIcon != null
                    ? '从相册更换'
                    : '从相册选择',
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('app_icon_pin_custom'),
              onPressed: available && !busy && state.customIcon != null
                  ? onPin
                  : null,
              icon: const Icon(Icons.add_to_home_screen_outlined, size: 19),
              label: const Text('添加到桌面'),
            ),
            if (state.customIcon == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '请先保存一张图片，再添加到桌面。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.hint, fontSize: 11),
                ),
              ),
            if (unsupported || !state.canPin)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  unsupported ? '该功能需要 Android 8.0 及以上版本。' : '内置图标不受影响。',
                  style: TextStyle(color: palette.hint, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomPreview extends StatelessWidget {
  const _CustomPreview({required this.bytes, required this.enabled});

  final Uint8List? bytes;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return SizedBox.square(
      dimension: 58,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: palette.pageBg,
          child: bytes == null
              ? Icon(
                  Icons.add_photo_alternate_outlined,
                  color: enabled ? palette.accent : palette.hint,
                )
              : Image.memory(
                  bytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      Icon(Icons.broken_image_outlined, color: palette.hint),
                ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: palette.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: palette.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: palette.titleText,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('刷新状态')),
          ],
        ),
      ),
    );
  }
}
