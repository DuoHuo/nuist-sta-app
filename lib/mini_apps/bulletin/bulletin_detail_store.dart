import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../../core/app_directories.dart';
import '../../core/logging/app_log.dart';
import 'bulletin_models.dart';

/// 本地正文快照及其缓存时间。
typedef CachedBulletinDetail = ({
  BulletinDetailDocument document,
  DateTime savedAt,
});

/// 缓存解析后的正文与附件链接，独立于列表及订阅数据。
class BulletinDetailStore {
  /// 可注入目录与时间，便于验证缓存淘汰及过期行为。
  BulletinDetailStore({
    Future<Directory?> Function()? resolveDirectory,
    DateTime Function()? now,
  }) : _resolveDirectory = resolveDirectory ?? AppDirectories.temporary,
       _now = now ?? DateTime.now;

  static final _log = AppLog.logger('bulletin.detail_store');

  /// 本地快照的最长保留时间。
  static const retention = Duration(days: 7);
  static const _maxEntries = 24;
  static const _maxEntryBytes = 512 * 1024;
  static final _entryName = RegExp(r'^[a-f0-9]{64}\.json$');
  final Future<Directory?> Function() _resolveDirectory;
  final DateTime Function() _now;
  Future<void> _pendingWrite = Future.value();

  Future<Directory?> _directory() async {
    final root = await _resolveDirectory();
    if (root == null) return null;
    return Directory(
      '${root.path}${Platform.pathSeparator}bulletin_details_v1',
    );
  }

  File _file(Directory directory, Uri uri) {
    final bytes = SHA256Digest().process(utf8.encode(uri.toString()));
    final key = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return File('${directory.path}${Platform.pathSeparator}$key.json');
  }

  /// 读取仍在保留期内的正文；缓存丢失或损坏时当作未命中。
  Future<CachedBulletinDetail?> read(Uri uri) => _log.inSpan(() async {
    try {
      final directory = await _directory();
      if (directory == null) return null;
      final file = _file(directory, uri);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > _maxEntryBytes ||
          _now().difference(stat.modified) >= retention) {
        return null;
      }
      final document = await compute(
        _decodeDetail,
        await file.readAsBytes(),
        debugLabel: 'bulletin.decode_detail_cache',
      );
      return (document: document, savedAt: stat.modified);
    } catch (error) {
      _log.debug(
        'cache.read_failed',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  });

  /// 保存有效正文；限制单篇大小，保留最近写入的有限篇数。
  Future<void> save(Uri uri, BulletinDetailDocument document) {
    if (document.isEmpty) return Future.value();
    return _pendingWrite = _pendingWrite.then(
      (_) => _log.inSpan(() async {
        File? temp;
        try {
          final directory = await _directory();
          if (directory == null) return;
          final data = await compute(
            _encodeDetail,
            document,
            debugLabel: 'bulletin.encode_detail_cache',
          );
          if (data.length > _maxEntryBytes) return;
          await directory.create(recursive: true);
          final file = _file(directory, uri);
          temp = File('${file.path}.tmp');
          await temp.writeAsBytes(data, flush: true);
          await temp.setLastModified(_now());
          await temp.rename(file.path);
          temp = null;
          await _prune(directory);
        } catch (error) {
          _log.warning(
            'cache.write_failed',
            fields: {'error_type': error.runtimeType.toString()},
          );
          try {
            await temp?.delete();
          } on FileSystemException {
            // 临时文件不参与读取，下次写入同一地址会覆盖它。
          }
        }
      }),
    );
  }

  Future<void> _prune(Directory directory) async {
    final entries = <(File, DateTime)>[];
    final now = _now();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.tmp') &&
          _entryName.hasMatch(name.substring(0, name.length - 4))) {
        // 写入串行，剩下的临时文件均来自中断的旧写入。
        await entity.delete();
        continue;
      }
      if (!_entryName.hasMatch(name)) continue;
      final stat = await entity.stat();
      if (stat.size > _maxEntryBytes ||
          now.difference(stat.modified) >= retention) {
        await entity.delete();
      } else {
        entries.add((entity, stat.modified));
      }
    }
    entries.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (file, _) in entries.skip(_maxEntries)) {
      await file.delete();
    }
  }
}

List<int> _encodeDetail(BulletinDetailDocument document) => utf8.encode(
  jsonEncode({
    'blocks': [
      for (final block in document.blocks)
        {
          'kind': block.kind.name,
          if (block.text.isNotEmpty) 'text': block.text,
          if (block.items.isNotEmpty) 'items': block.items,
          if (block.url != null) 'url': block.url,
          if (block.altText.isNotEmpty) 'altText': block.altText,
          if (block.level != 0) 'level': block.level,
          if (block.centered) 'centered': true,
        },
    ],
    'attachments': [
      for (final item in document.attachments)
        {'name': item.name, 'url': item.url},
    ],
  }),
);

BulletinDetailDocument _decodeDetail(List<int> bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final document = BulletinDetailDocument(
    blocks: List.unmodifiable([
      for (final raw in json['blocks'] as List<dynamic>)
        _decodeBlock(raw as Map<String, dynamic>),
    ]),
    attachments: List.unmodifiable([
      for (final raw in json['attachments'] as List<dynamic>)
        BulletinAttachment(
          name: raw['name'] as String,
          url: raw['url'] as String,
        ),
    ]),
  );
  if (document.isEmpty) throw const FormatException('缓存正文为空');
  return document;
}

BulletinDetailBlock _decodeBlock(Map<String, dynamic> json) {
  final kind = BulletinDetailBlockKind.values.byName(json['kind'] as String);
  final url = json['url'] as String?;
  if (kind == BulletinDetailBlockKind.image && url == null) {
    throw const FormatException('缓存图片缺少地址');
  }
  return BulletinDetailBlock(
    kind: kind,
    text: json['text'] as String? ?? '',
    items: List.unmodifiable(
      (json['items'] as List<dynamic>? ?? const []).cast<String>(),
    ),
    url: url,
    altText: json['altText'] as String? ?? '',
    level: json['level'] as int? ?? 0,
    centered: json['centered'] as bool? ?? false,
  );
}
