import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/network/owned_api_client.dart';

/// 同域头像通过受控客户端加载，避免图片诊断对象持有设备请求头。
class ContributorAvatarLoader {
  ContributorAvatarLoader({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? createOwnedApiDio(),
      _ownsDio = dio == null,
      _now = now ?? DateTime.now;

  /// 应用内复用连接和有限内存缓存。
  static final instance = ContributorAvatarLoader();

  static const _maxImageBytes = 2 * 1024 * 1024;
  static const _maxCacheBytes = 8 * 1024 * 1024;
  static const _maxEntries = 64;
  static const _ttl = Duration(hours: 1);
  final Dio _dio;
  final bool _ownsDio;
  final DateTime Function() _now;
  final _cache = <String, ({Uint8List bytes, DateTime at})>{};
  final _pending = <String, Future<Uint8List?>>{};
  final _cancellations = <CancelToken>{};
  int _cacheBytes = 0;
  bool _closed = false;

  /// 合并同一头像的并发请求；失败显示占位，且不缓存失败结果。
  Future<Uint8List?> load(String url) {
    if (_closed) return Future.value();
    final uri = Uri.tryParse(url);
    if (uri == null || !isOwnedApiUri(uri)) return Future.value();
    final cached = _cache.remove(url);
    if (cached != null) {
      final age = _now().difference(cached.at);
      if (!age.isNegative && age < _ttl) {
        _cache[url] = cached;
        return Future.value(cached.bytes);
      }
      _cacheBytes -= cached.bytes.length;
    }
    return _pending.putIfAbsent(
      url,
      () => _fetch(url).whenComplete(() {
        _pending.remove(url);
      }),
    );
  }

  Future<Uint8List?> _fetch(String url) async {
    final cancel = CancelToken();
    _cancellations.add(cancel);
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancel,
        onReceiveProgress: (received, total) {
          if (received > _maxImageBytes || total > _maxImageBytes) {
            cancel.cancel('头像大小超过限制');
          }
        },
      );
      final raw = response.data;
      if (_closed ||
          cancel.isCancelled ||
          raw == null ||
          raw.isEmpty ||
          raw.length > _maxImageBytes) {
        return null;
      }
      final bytes = Uint8List.fromList(raw);
      while (_cache.isNotEmpty &&
          (_cache.length >= _maxEntries ||
              _cacheBytes + bytes.length > _maxCacheBytes)) {
        _cacheBytes -= _cache.remove(_cache.keys.first)!.bytes.length;
      }
      _cache[url] = (bytes: bytes, at: _now());
      _cacheBytes += bytes.length;
      return bytes;
    } catch (_) {
      // 图片失败只显示首字占位，不让含请求元数据的异常进入图片诊断对象。
      return null;
    } finally {
      _cancellations.remove(cancel);
    }
  }

  /// 图片解码失败时移除对应缓存，使下次加载可以重新请求。
  void evict(String url) {
    final cached = _cache.remove(url);
    if (cached != null) _cacheBytes -= cached.bytes.length;
  }

  /// 释放自建客户端和内存缓存；注入客户端由调用者管理。
  void close() {
    _closed = true;
    for (final cancel in _cancellations.toList()) {
      cancel.cancel('头像加载已结束');
    }
    if (_ownsDio) _dio.close(force: true);
    _cache.clear();
    _cacheBytes = 0;
  }
}

/// 贡献者头像；历史缓存中的外部 HTTPS 图片不携带设备元数据。
class ContributorAvatar extends StatefulWidget {
  const ContributorAvatar({
    super.key,
    required this.url,
    required this.fallback,
    this.loader,
  });

  final String url;
  final Widget fallback;
  final ContributorAvatarLoader? loader;

  @override
  State<ContributorAvatar> createState() => _ContributorAvatarState();
}

class _ContributorAvatarState extends State<ContributorAvatar> {
  Future<Uint8List?>? _bytes;
  Uri? _uri;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ContributorAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.loader != widget.loader) {
      _load();
    }
  }

  void _load() {
    _uri = Uri.tryParse(widget.url);
    _bytes = _uri != null && isOwnedApiUri(_uri!)
        ? (widget.loader ?? ContributorAvatarLoader.instance).load(widget.url)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return widget.fallback;
    }
    if (_bytes == null) {
      return Image.network(
        widget.url,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        // 切换请求时 FutureBuilder 会保留旧数据，等待期间只显示当前占位。
        if (snapshot.connectionState != ConnectionState.done || data == null) {
          return widget.fallback;
        }
        return Image.memory(
          data,
          width: 44,
          height: 44,
          cacheWidth: 176,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
            (widget.loader ?? ContributorAvatarLoader.instance).evict(
              widget.url,
            );
            return widget.fallback;
          },
        );
      },
    );
  }
}
