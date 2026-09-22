import 'dart:async';

import 'package:flutter/material.dart';

import 'campus_map_photos.dart';
import 'campus_map_widgets.dart';

/// 实拍图片浏览页：先看缩略图网格，点开进入大图左右翻页（百度地图式）。
class CampusPhotoGalleryPage extends StatefulWidget {
  const CampusPhotoGalleryPage({
    super.key,
    required this.source,
    required this.buildingId,
    required this.buildingName,
    this.initialPhotos = const [],
  });

  final CampusBuildingPhotosSource? source;
  final String buildingId;
  final String buildingName;
  final List<CampusPhoto> initialPhotos;

  @override
  State<CampusPhotoGalleryPage> createState() => _CampusPhotoGalleryPageState();
}

class _CampusPhotoGalleryPageState extends State<CampusPhotoGalleryPage> {
  late List<CampusPhoto> _photos = widget.initialPhotos;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_photos.isEmpty) _load();
  }

  Future<void> _load() async {
    final source = widget.source;
    if (source == null) {
      setState(() => _error = '当前地图服务未提供实拍图片');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final photos = await source.loadBuildingPhotos(widget.buildingId);
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is CampusPhotoException ? error.message : '实拍图片加载失败';
      });
    }
  }

  void _openViewer(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusPhotoViewerPage(
          photos: _photos,
          initialIndex: index,
          buildingName: widget.buildingName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MapPalette.surface,
    appBar: AppBar(
      title: Text('${widget.buildingName} · 实拍图片'),
      backgroundColor: MapPalette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      actions: [
        MapIconButton(
          icon: Icons.refresh_rounded,
          label: '刷新实拍图片',
          onPressed: _loading ? null : _load,
        ),
      ],
    ),
    body: _body(),
  );

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.image_not_supported_outlined,
                size: 34,
                color: MapPalette.secondary,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: MapPalette.ink),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('重新加载')),
            ],
          ),
        ),
      );
    }
    if (_photos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 34,
                color: MapPalette.secondary,
              ),
              SizedBox(height: 12),
              Text(
                '暂无实拍图片',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 6),
              Text(
                '采集并上传后，这里会显示建筑实景。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: MapPalette.secondary),
              ),
            ],
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _photos.length,
      itemBuilder: (context, index) {
        final photo = _photos[index];
        return Semantics(
          button: true,
          label: photo.label.isEmpty ? '第 ${index + 1} 张实拍图片' : photo.label,
          child: InkWell(
            onTap: () => _openViewer(index),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _PhotoImage(photo: photo),
            ),
          ),
        );
      },
    );
  }
}

/// 大图浏览：左右翻页 + 双指缩放 + 页码/说明。
class CampusPhotoViewerPage extends StatefulWidget {
  const CampusPhotoViewerPage({
    super.key,
    required this.photos,
    required this.buildingName,
    this.initialIndex = 0,
  });

  final List<CampusPhoto> photos;
  final String buildingName;
  final int initialIndex;

  @override
  State<CampusPhotoViewerPage> createState() => _CampusPhotoViewerPageState();
}

class _CampusPhotoViewerPageState extends State<CampusPhotoViewerPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.buildingName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_index + 1}/${widget.photos.length}',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.photos.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, index) => InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: _PhotoImage(
                    photo: widget.photos[index],
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
          if (current.label.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                MediaQuery.paddingOf(context).bottom + 16,
              ),
              child: Text(
                current.label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhotoImage extends StatelessWidget {
  const _PhotoImage({required this.photo, this.fit = BoxFit.cover});
  final CampusPhoto photo;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Image.network(
    photo.url,
    fit: fit,
    width: double.infinity,
    height: double.infinity,
    loadingBuilder: (context, child, progress) => progress == null
        ? child
        : const ColoredBox(
            color: Color(0xFFE9EDF1),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
    errorBuilder: (context, error, stack) => const ColoredBox(
      color: Color(0xFFE9EDF1),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: MapPalette.secondary,
          size: 26,
        ),
      ),
    ),
  );
}

/// 详情卡片里的实拍图片入口：有图时显示缩略图条与张数，点击进入浏览页。
class CampusBuildingPhotosEntry extends StatefulWidget {
  const CampusBuildingPhotosEntry({
    super.key,
    required this.source,
    required this.buildingId,
    required this.buildingName,
  });

  final CampusBuildingPhotosSource? source;
  final String buildingId;
  final String buildingName;

  @override
  State<CampusBuildingPhotosEntry> createState() =>
      _CampusBuildingPhotosEntryState();
}

class _CampusBuildingPhotosEntryState extends State<CampusBuildingPhotosEntry> {
  List<CampusPhoto> _photos = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CampusBuildingPhotosEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.buildingId != widget.buildingId ||
        oldWidget.source != widget.source) {
      _photos = const [];
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final source = widget.source;
    if (source == null) {
      setState(() => _error = '当前地图服务未提供实拍图片');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final photos = await source.loadBuildingPhotos(widget.buildingId);
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is CampusPhotoException ? error.message : '实拍图片加载失败';
      });
    }
  }

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusPhotoGalleryPage(
          source: widget.source,
          buildingId: widget.buildingId,
          buildingName: widget.buildingName,
          initialPhotos: _photos,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MapSurface(
    radius: 18,
    child: InkWell(
      onTap: _photos.isEmpty ? null : _open,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.photo_library_outlined,
                  color: MapPalette.blue,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '实拍图片',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _loading
                              ? '正在加载…'
                              : _error ??
                                    (_photos.isEmpty
                                        ? '暂无实拍图片'
                                        : '${_photos.length} 张实景照片'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: MapPalette.secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (_photos.isEmpty)
                  IconButton(
                    tooltip: '重新加载实拍图片',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: widget.source == null ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                  )
                else
                  const Icon(Icons.chevron_right_rounded),
              ],
            ),
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 96,
                      child: _PhotoImage(photo: _photos[index]),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
