import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'announcement_models.dart';
import 'announcement_web_page.dart';

/// 弹出居中的公告对话框，铃铛与自动弹出共用。
Future<void> showAnnouncementDialog(
  BuildContext context,
  List<Announcement> items, {
  Map<String, AnnouncementLocalAction> localActions = const {},
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        AnnouncementDialog(items: items, localActions: localActions),
  );
}

/// 仅由本地代码附加的公告操作，服务端文本不能构造站内跳转。
class AnnouncementLocalAction {
  const AnnouncementLocalAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

/// 公告统一外框；不可关闭公告由调用方保留返回拦截与过期释放。
class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({
    super.key,
    required this.items,
    this.dismissible = true,
    this.localActions = const {},
  });

  /// 要展示的公告。
  final List<Announcement> items;

  /// 是否显示关闭操作，并在打开详情时关闭公告。
  final bool dismissible;
  final Map<String, AnnouncementLocalAction> localActions;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 480),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: palette.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnnouncementListPanel(
        items: items,
        dismissible: dismissible,
        localActions: localActions,
      ),
    );
  }
}

/// 公告阅读面板：标题与关闭操作固定，正文按可用空间滚动。
class AnnouncementListPanel extends StatelessWidget {
  const AnnouncementListPanel({
    super.key,
    required this.items,
    this.dismissible = true,
    this.localActions = const {},
  });

  /// 要展示的公告。
  final List<Announcement> items;

  /// 为 false 时不显示关闭操作，打开链接时也不关闭对话框。
  final bool dismissible;
  final Map<String, AnnouncementLocalAction> localActions;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(20, 12, dismissible ? 8 : 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  namesRoute: true,
                  header: true,
                  child: Text(
                    '公告',
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: palette.titleText,
                    ),
                  ),
                ),
                if (items.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${items.length} 条公告',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: palette.labelText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (dismissible)
            IconButton(
              tooltip: '关闭',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(
                Icons.close_rounded,
                size: 22,
                color: palette.labelText,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  Icon(
                    Icons.notifications_none_rounded,
                    size: 32,
                    color: palette.labelText,
                  ),
                  const SizedBox(height: 8),
                  Text('暂无公告', style: TextStyle(color: palette.labelText)),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Divider(height: 1, color: palette.divider),
                    ),
                  AnnouncementCard(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    closeDialogOnOpenLink: dismissible,
                    localAction: localActions[items[i].id],
                  ),
                ],
              ],
            ),
    );
    final footer = dismissible
        ? DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.rowDivider)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent.withValues(alpha: 0.10),
                    foregroundColor: _actionColor(palette),
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('我知道了'),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = math.min(
          constraints.maxHeight,
          MediaQuery.sizeOf(context).height * 0.8,
        );
        // 横屏、键盘或大字体压缩高度时整体滚动，避免固定头尾挤掉正文。
        final compactHeight =
            maxHeight < 320 * MediaQuery.textScalerOf(context).scale(1);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SizedBox(
            width: double.infinity,
            child: compactHeight
                ? SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [header, content, footer],
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      Flexible(child: SingleChildScrollView(child: content)),
                      footer,
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// 单条公告的阅读内容，以分隔线区分多条公告，不嵌套卡片。
class AnnouncementCard extends StatelessWidget {
  const AnnouncementCard({
    super.key,
    required this.item,
    this.closeDialogOnOpenLink = true,
    this.localAction,
  });

  /// 要展示的公告。
  final Announcement item;

  /// 打开链接前是否先关闭所在对话框。
  final bool closeDialogOnOpenLink;
  final AnnouncementLocalAction? localAction;

  void _openLink(BuildContext context, AnnouncementLink link) {
    final navigator = Navigator.of(context);
    if (closeDialogOnOpenLink) navigator.pop();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => announcementWebPageBuilder(link)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final link = item.link;
    final toneColor = switch (item.tone) {
      AnnouncementTone.normal => palette.labelText,
      AnnouncementTone.notice => palette.accent,
      AnnouncementTone.alert => palette.warning,
    };
    // 空行仍表示分段，但用紧凑段距代替整行留白；段内换行保持原样。
    final paragraphs = item.content.trim().isEmpty
        ? const <String>[]
        : item.content.trim().split(
            RegExp(r'\r?\n[ \t]*\r?\n(?:[ \t]*\r?\n)*'),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 8),
              child: Icon(Icons.campaign_outlined, size: 20, color: toneColor),
            ),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: palette.titleText,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (item.summary?.trim().isNotEmpty ?? false) ...[
          const SizedBox(height: 6),
          Text(
            item.summary!,
            style: TextStyle(
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w500,
              color: palette.titleText,
            ),
          ),
        ],
        for (final paragraph in paragraphs) ...[
          const SizedBox(height: 6),
          Text(
            paragraph,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: palette.labelText,
            ),
          ),
        ],
        if (localAction case final action?) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () {
              if (closeDialogOnOpenLink) Navigator.of(context).pop();
              action.onPressed();
            },
            icon: const Icon(Icons.system_update_rounded, size: 20),
            label: Text(action.label),
          ),
        ] else if (link != null) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: _actionColor(palette),
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              alignment: Alignment.centerLeft,
              textStyle: const TextStyle(
                fontSize: 14,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.arrow_outward_rounded, size: 18),
            label: Text(link.label),
            onPressed: () => _openLink(context, link),
          ),
        ],
      ],
    );
  }
}

// 浅色下加深品牌蓝以保证小字号操作文字的对比度，深色沿用色板。
Color _actionColor(AppPalette palette) => palette.isDark
    ? palette.accent
    : Color.lerp(palette.accent, palette.titleText, 0.24)!;
