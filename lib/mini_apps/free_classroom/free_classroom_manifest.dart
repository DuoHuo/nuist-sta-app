import 'package:flutter/material.dart';

import '../../core/app_manifest.dart';
import 'free_classroom_page.dart';
import 'free_classroom_widgets.dart';

/// 空教室小程序：按教学楼 / 日期查教务的教室占用，本地按时段、楼层、类型筛选。
const freeClassroomManifest = AppManifest(
  id: 'free-classroom',
  label: '空教室',
  color: kClassroomColor,
  icon: Icons.meeting_room_outlined,
  entry: _entry,
);

Widget _entry(BuildContext context) => const FreeClassroomPage();
