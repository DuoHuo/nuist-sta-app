import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'campus_map_page.dart';

/// 校园地图小程序的注册信息。
const campusMapManifest = AppManifest(
  id: 'campus-map',
  label: '校园地图',
  color: Color(0xFF00B578),
  icon: Icons.map,
  entry: _campusMapEntry,
);

Widget _campusMapEntry(BuildContext context) => const CampusMapPage();
