import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_snack_bar.dart';
import '../../core/colors.dart';
import 'library_api.dart';
import 'library_book_info_card.dart';
import 'library_models.dart';
import 'library_widgets.dart';

/// 书目和馆藏分别加载，封面可用时补入书目信息。
class LibraryDetailPage extends StatefulWidget {
  const LibraryDetailPage({super.key, required this.api, required this.bookId});

  final LibraryApi api;
  final String bookId;

  @override
  State<LibraryDetailPage> createState() => _LibraryDetailPageState();
}

class _LibraryDetailPageState extends State<LibraryDetailPage> {
  final _cancelToken = CancelToken();
  late Future<LibraryBookInfo> _info;
  late Future<Uint8List?> _cover;
  late Future<List<LibraryHolding>> _holdings;
  Timer? _copyFeedbackTimer;
  bool? _isbnCopied;
  int _copyAttempt = 0;

  @override
  void initState() {
    super.initState();
    _loadInfo();
    _loadHoldings();
  }

  void _loadInfo() {
    _info = widget.api.fetchBookInfo(widget.bookId, _cancelToken);
    _cover = _info.then((book) async {
      if (_cancelToken.isCancelled) return null;
      try {
        return await widget.api.fetchCover(
          widget.bookId,
          book.isbns,
          _cancelToken,
        );
      } on DioException {
        return null;
      } on FormatException {
        return null;
      }
    }, onError: (Object _) => null);
  }

  void _loadHoldings() {
    _holdings = widget.api.fetchHoldings(widget.bookId, _cancelToken);
  }

  Future<void> _copyIsbn(String isbn) async {
    final attempt = ++_copyAttempt;
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: isbn));
    } on PlatformException {
      copied = false;
    }
    if (!mounted ||
        attempt != _copyAttempt ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    // 本页只显示一条复制提示，连点时刷新消失时间，不在路由之间排队。
    _copyFeedbackTimer?.cancel();
    setState(() => _isbnCopied = copied);
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      setState(() => _isbnCopied = null);
    });
  }

  @override
  void dispose() {
    _copyFeedbackTimer?.cancel();
    _cancelToken.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final heading = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('馆藏详情')),
      backgroundColor: palette.pageBg,
      body: SafeArea(
        top: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildDetails(heading, palette),
            if (_isbnCopied case final copied?)
              Positioned(
                top: 8,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Semantics(
                    liveRegion: true,
                    child: Material(
                      color: palette.surface,
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: palette.divider),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: AppSnackBarContent(
                          tone: copied
                              ? AppSnackBarTone.success
                              : AppSnackBarTone.error,
                          child: Text(copied ? 'ISBN 已复制' : '无法复制 ISBN'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(TextStyle? heading, AppPalette palette) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    children: [
      FutureBuilder(
        future: _info,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LibraryLoading();
          }
          if (snapshot.hasError) {
            return LibraryMessage(
              icon: Icons.cloud_off_outlined,
              message: '暂时无法读取书目信息',
              action: '重试',
              onPressed: () => setState(_loadInfo),
            );
          }
          final book = snapshot.requireData;
          return FutureBuilder(
            future: _cover,
            builder: (context, snapshot) {
              final cover = snapshot.data;
              if (!book.hasDetails && cover == null) {
                return const LibraryMessage(
                  icon: Icons.info_outline,
                  message: '暂无书目详情',
                );
              }
              return LibraryBookInfoCard(
                book: book,
                cover: cover,
                onCopyIsbn: _copyIsbn,
              );
            },
          );
        },
      ),
      const SizedBox(height: 18),
      Text('馆藏位置', style: heading),
      const SizedBox(height: 8),
      FutureBuilder(
        future: _holdings,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LibraryLoading();
          }
          if (snapshot.hasError) {
            return LibraryMessage(
              icon: Icons.cloud_off_outlined,
              message: '暂时无法读取馆藏位置',
              action: '重试',
              onPressed: () => setState(_loadHoldings),
            );
          }
          final holdings = snapshot.requireData;
          if (holdings.isEmpty) {
            return const LibraryMessage(
              icon: Icons.shelves,
              message: '暂无馆藏副本信息',
            );
          }
          return Card(
            margin: EdgeInsets.zero,
            color: palette.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, item) in holdings.indexed) ...[
                  if (index > 0) Divider(height: 1, color: palette.rowDivider),
                  _HoldingTile(item: item),
                ],
              ],
            ),
          );
        },
      ),
    ],
  );
}

class _HoldingTile extends StatelessWidget {
  const _HoldingTile({required this.item});

  final LibraryHolding item;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context).textTheme;
    final place = [
      item.library,
      item.location,
    ].where((value) => value.isNotEmpty).toSet().join(' · ');
    final secondary = theme.bodySmall?.copyWith(
      color: palette.labelText,
      height: 1.3,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            place.isEmpty ? '馆藏地点未标注' : place,
            style: theme.titleSmall?.copyWith(height: 1.3),
          ),
          const SizedBox(height: 3),
          DefaultTextStyle.merge(
            style: secondary,
            child: Wrap(
              spacing: 12,
              runSpacing: 3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  item.status.isEmpty ? '状态未标注' : item.status,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: item.status == '可借' ? palette.success : null,
                  ),
                ),
                if (item.callNumber.isNotEmpty) Text('索书号 ${item.callNumber}'),
                if (item.shelfMark.isNotEmpty) Text('书架 ${item.shelfMark}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
