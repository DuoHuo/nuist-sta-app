import 'package:flutter/material.dart';

import 'campus_map_data.dart';
import 'campus_map_widgets.dart';

class StreetViewRequest {
  const StreetViewRequest({required this.buildingId, this.sceneId, this.entry});
  final String buildingId;
  final String? sceneId;
  final GeoPoint? entry;
}

class CampusStreetViewPage extends StatelessWidget {
  const CampusStreetViewPage({
    super.key,
    required this.request,
    required this.placeName,
  });
  final StreetViewRequest request;
  final String placeName;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF1F3F5),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                MapSurface(
                  radius: 16,
                  child: MapIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: '返回地图',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    placeName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: MapPalette.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: const Icon(
                        Icons.streetview_rounded,
                        size: 42,
                        color: MapPalette.blue,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '街景暂未开放',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: MapPalette.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      request.sceneId == null
                          ? '这里还没有可浏览的街景。\n采集开放后，就能从地图走进实景。'
                          : '已保留此处的街景入口。\n实景浏览功能将在后续开放。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: MapPalette.secondary,
                        fontSize: 15,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 28),
                    MapAction(
                      icon: Icons.map_outlined,
                      label: '返回地图',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '实景浏览',
              style: TextStyle(color: MapPalette.secondary, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
