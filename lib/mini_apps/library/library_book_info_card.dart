import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/colors.dart';
import 'library_book_cover.dart';
import 'library_models.dart';

/// 书目卡依次展示封面与责任者、常用编目信息以及摘要。
class LibraryBookInfoCard extends StatelessWidget {
  const LibraryBookInfoCard({
    super.key,
    required this.book,
    this.cover,
    required this.onCopyIsbn,
  });

  final LibraryBookInfo book;
  final Uint8List? cover;
  final ValueChanged<String> onCopyIsbn;

  static const _featuredFields = {
    '题名/责任者',
    '个人责任者',
    '出版发行项',
    '学科主题',
    '中图法分类号',
    '图书定价',
    '定价',
    'ISBN及定价',
    '载体形态项',
    '载体形态',
    '页数',
    '并列正题名',
    '其他题名',
    '其它题名',
    '提要文摘附注',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final fields = book.fields;
    final classification = fields['中图法分类号'];
    final pageCount = book.pageCount;
    final isbnText = book.isbns.isEmpty
        ? fields['ISBN']
        : book.isbns.join('\n');
    final parallelTitle = fields['并列正题名'];
    final abstract = fields['提要文摘附注'];
    final metaValue = theme.titleMedium?.copyWith(height: 1.2);
    final cells = [
      if (classification != null)
        _MetadataCell(
          label: '中图法分类号',
          value: classification,
          valueStyle: metaValue?.copyWith(color: palette.accent),
        ),
      if (book.price.isNotEmpty)
        _MetadataCell(label: '图书定价', value: book.price, valueStyle: metaValue),
      if (isbnText != null)
        _MetadataCell(
          label: 'ISBN',
          value: isbnText,
          valueStyle: theme.bodyMedium?.copyWith(fontSize: 13.5, height: 1.2),
          action: book.isbns.isEmpty
              ? null
              : IconButton(
                  tooltip: '复制 ISBN',
                  iconSize: 14,
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  color: palette.accent,
                  onPressed: () => onCopyIsbn(isbnText),
                  icon: const Icon(Icons.content_copy_outlined),
                ),
        ),
      if (pageCount != null)
        _MetadataCell(label: '页数', value: pageCount, valueStyle: metaValue),
    ];
    final sections = [
      if (book.title.isNotEmpty ||
          book.author.isNotEmpty ||
          fields['学科主题'] != null ||
          fields['出版发行项'] != null ||
          cover != null)
        _BookHeader(book: book, cover: cover),
      if (cells.isNotEmpty)
        Table(
          defaultColumnWidth: const FlexColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: palette.rowDivider),
            verticalInside: BorderSide(color: palette.rowDivider),
          ),
          children: [
            for (var index = 0; index < cells.length; index += 2)
              TableRow(
                children: [
                  cells[index],
                  index + 1 < cells.length
                      ? cells[index + 1]
                      : const SizedBox.shrink(),
                ],
              ),
          ],
        ),
      if (parallelTitle != null)
        _BookNote(label: '并列正题名', value: parallelTitle),
      if (abstract != null) _BookNote(label: '内容提要', value: abstract),
      if (book.isbnNotes.isNotEmpty)
        _BookNote(label: 'ISBN 附注', value: book.isbnNotes),
      for (final entry in fields.entries)
        if (entry.key != 'ISBN' && !_featuredFields.contains(entry.key))
          _BookNote(label: entry.key, value: entry.value),
    ];
    return Card(
      margin: EdgeInsets.zero,
      color: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, section) in sections.indexed) ...[
            if (index > 0) Divider(height: 1, color: palette.rowDivider),
            section,
          ],
        ],
      ),
    );
  }
}

class _BookHeader extends StatelessWidget {
  const _BookHeader({required this.book, required this.cover});

  final LibraryBookInfo book;
  final Uint8List? cover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final subject = book.fields['学科主题'];
    final publication = book.fields['出版发行项'];
    final size = MediaQuery.sizeOf(context).width < 360 ? 76.0 : 94.0;
    final secondary = theme.bodySmall?.copyWith(
      color: palette.labelText,
      height: 1.35,
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cover case final image?) ...[
            LibraryBookCover(bytes: image, width: size),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subject != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      subject,
                      style: secondary?.copyWith(color: palette.accent),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (book.title.isNotEmpty)
                  Text(
                    book.title,
                    style: theme.titleLarge?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                if (book.author.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    book.author,
                    style: theme.bodyMedium?.copyWith(
                      color: palette.titleText,
                      height: 1.4,
                    ),
                  ),
                ],
                if (publication != null) ...[
                  const SizedBox(height: 8),
                  Text(publication, style: secondary),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataCell extends StatelessWidget {
  const _MetadataCell({
    required this.label,
    required this.value,
    this.valueStyle,
    this.action,
  });

  final String label;
  final String value;
  final TextStyle? valueStyle;
  final Widget? action;

  static const _actionWidth = 36.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsetsDirectional.only(
                  end: action == null ? 0 : _actionWidth,
                ),
                child: _FieldLabel(label),
              ),
              const SizedBox(height: 2),
              Text(value, style: valueStyle),
            ],
          ),
        ),
        // 图标与按压反馈共用中心，按钮不参与表格行高计算。
        if (action case final control?)
          PositionedDirectional(
            top: 0,
            end: 8,
            width: _actionWidth,
            height: 14 + MediaQuery.textScalerOf(context).scale(11) * 1.2,
            child: control,
          ),
      ],
    );
  }
}

class _BookNote extends StatelessWidget {
  const _BookNote({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldLabel(label),
          const SizedBox(height: 3),
          Text(value, style: theme.bodyMedium?.copyWith(height: 1.36)),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: Color.lerp(palette.labelText, palette.hint, .4),
      ),
    );
  }
}
