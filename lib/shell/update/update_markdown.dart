import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import '../announcement/announcement_models.dart';
import '../announcement/announcement_web_page.dart';

/// 更新日志的 Markdown 正文；独立于下载进度，只在正文或主题变化时重建。
class UpdateChangelog extends StatelessWidget {
  const UpdateChangelog({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final body = TextStyle(color: palette.titleText, fontSize: 15, height: 1.5);
    TextStyle heading(double size) => body.copyWith(
      fontSize: size,
      height: 1.35,
      fontWeight: FontWeight.w600,
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      fitContent: false,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: body,
        a: body.copyWith(
          color: appSnackBarActionColor(palette),
          decoration: TextDecoration.underline,
        ),
        h1: heading(22),
        h2: heading(20),
        h3: heading(18),
        h4: heading(16),
        h5: heading(15),
        h6: heading(15),
        em: const TextStyle(fontStyle: FontStyle.italic),
        strong: const TextStyle(fontWeight: FontWeight.w700),
        listBullet: body,
        listIndent: 20,
        blockSpacing: 12,
        blockquote: body.copyWith(color: palette.labelText),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        blockquoteDecoration: BoxDecoration(
          color: palette.pageBg,
          border: Border(left: BorderSide(color: palette.divider, width: 3)),
        ),
        code: body.copyWith(fontFamily: 'monospace', fontSize: 13),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: palette.pageBg,
          borderRadius: BorderRadius.circular(8),
        ),
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        tableBorder: TableBorder.all(color: palette.divider),
        tableHeadCellsDecoration: BoxDecoration(color: palette.pageBg),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.divider)),
        ),
        textScaler: MediaQuery.textScalerOf(context),
      ),
      // 日志图片只展示替代文本，不因阅读更新日志请求新的网络出口。
      imageBuilder: (_, _, alt) => Text(alt ?? '', style: body),
      onTapLink: (text, href, title) {
        final link = AnnouncementLink.tryParse({
          'label': title.isNotEmpty ? title : text,
          'url': href,
        });
        if (link == null) return;
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => announcementWebPageBuilder(link),
          ),
        );
      },
    );
  }
}
