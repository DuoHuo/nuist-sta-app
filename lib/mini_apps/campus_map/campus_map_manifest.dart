import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'campus_map_api.dart';
import 'campus_map_page.dart';

const campusMapManifest = AppManifest(
  id: 'campus-map',
  label: '校园地图',
  color: Color(0xFF00B578),
  icon: Icons.map,
  entry: _campusMapEntry,
);

Widget _campusMapEntry(BuildContext context) => const _ConnectedCampusMap();

class _ConnectedCampusMap extends StatefulWidget {
  const _ConnectedCampusMap();
  @override
  State<_ConnectedCampusMap> createState() => _ConnectedCampusMapState();
}

class _ConnectedCampusMapState extends State<_ConnectedCampusMap> {
  late final CampusMapApi _api = CampusMapApi();
  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CampusMapPage(source: _api);
}
