import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'library_page.dart';

/// 图书馆小程序的首页入口。
const libraryManifest = AppManifest(
  id: 'library',
  label: '图书馆',
  color: Color(0xFF26776D),
  icon: Icons.local_library_outlined,
  entry: _entry,
);

Widget _entry(BuildContext context) => const LibraryPage();
