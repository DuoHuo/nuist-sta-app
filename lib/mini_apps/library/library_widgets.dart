import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 适用于详情区块和列表页脚的圆形加载提示。
class LibraryLoading extends StatelessWidget {
  const LibraryLoading({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// 图书馆内的加载失败、空列表和绑定提示。
class LibraryMessage extends StatelessWidget {
  const LibraryMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
    this.onPressed,
  });

  final IconData icon;
  final String message;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: palette.hint),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.labelText),
            ),
            if (action case final label?) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onPressed, child: Text(label)),
            ],
          ],
        ),
      ),
    );
  }
}
