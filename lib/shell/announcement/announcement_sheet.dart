import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'announcement_models.dart';
import 'announcement_web_page.dart';

/// 按 [AnnouncementTone] 给出卡片配色，只用 [AppColors]。
abstract final class AnnouncementToneColors {
  /// 卡片背景色。
  static Color background(AnnouncementTone tone) => switch (tone) {
    AnnouncementTone.normal => Colors.white,
    AnnouncementTone.notice => AppColors.accent.withValues(alpha: 0.08),
    AnnouncementTone.alert => AppColors.warning.withValues(alpha: 0.10),
  };

  /// 卡片描边色。
  static Color border(AnnouncementTone tone) => switch (tone) {
    AnnouncementTone.normal => AppColors.divider,
    AnnouncementTone.notice => AppColors.accent.withValues(alpha: 0.35),
    AnnouncementTone.alert => AppColors.warning.withValues(alpha: 0.45),
  };
}

/// 弹出居中的公告对话框（铃铛与自动弹出共用），纵向卡片列表，最高约屏幕 70%。
Future<void> showAnnouncementDialog(
  BuildContext context,
  List<Announcement> items,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.pageBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: AnnouncementListPanel(items: items),
    ),
  );
}

/// 对话框内容：标题栏 + 可滚动卡片列表。
class AnnouncementListPanel extends StatelessWidget {
  const AnnouncementListPanel({
    super.key,
    required this.items,
    this.dismissible = true,
  });

  /// 要展示的公告。
  final List<Announcement> items;

  /// 是否可关闭：为 false 时不显示关闭按钮，打开链接时也不关闭对话框。
  final bool dismissible;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 4, dismissible ? 0 : 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '公告',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleText,
                    ),
                  ),
                ),
                if (dismissible)
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, color: AppColors.hint),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('暂无公告', style: TextStyle(color: AppColors.hint)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => AnnouncementCard(
                  item: items[i],
                  closeDialogOnOpenLink: dismissible,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 公告卡片：直接显示标题、摘要、正文；有链接时显示「查看详情」按钮。
class AnnouncementCard extends StatelessWidget {
  const AnnouncementCard({
    super.key,
    required this.item,
    this.closeDialogOnOpenLink = true,
  });

  /// 要展示的公告。
  final Announcement item;

  /// 打开链接前是否先关闭所在对话框。
  final bool closeDialogOnOpenLink;

  void _openLink(BuildContext context, AnnouncementLink link) {
    final navigator = Navigator.of(context);
    if (closeDialogOnOpenLink) navigator.pop();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => announcementWebPageBuilder(link)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = item;
    final link = a.link;
    return Material(
      color: AnnouncementToneColors.background(a.tone),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AnnouncementToneColors.border(a.tone)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              a.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.titleText,
              ),
            ),
            if (a.summary != null) ...[
              const SizedBox(height: 4),
              Text(
                a.summary!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.labelText,
                ),
              ),
            ],
            if (a.content.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                a.content,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.titleText,
                ),
              ),
            ],
            if (link != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(link.label),
                onPressed: () => _openLink(context, link),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
