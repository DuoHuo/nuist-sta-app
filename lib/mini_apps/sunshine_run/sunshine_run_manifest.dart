import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'sunshine_run_controller.dart';
import 'sunshine_run_page.dart';

/// 阳光跑原生计算器：首页宫格入口与门户年级识别联动。
const sunshineRunManifest = AppManifest(
  id: 'sunshine-run',
  label: '阳光跑',
  color: Color(0xFFFF7D00),
  icon: Icons.directions_run_rounded,
  entry: _entry,
  onPortalBindingChanged: _bindingChanged,
);

Widget _entry(BuildContext context) => const SunshineRunPage();

Future<void> _bindingChanged(bool bound) =>
    SunshineRunController.instance.onPortalBindingChanged(bound);
