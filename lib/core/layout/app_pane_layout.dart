import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';

/// 根据窗口安全区域和铰链计算面板矩形，不依赖设备型号或横竖屏。
class AppPaneLayout {
  const AppPaneLayout({
    required this.region,
    required this.windowRegion,
    this.home,
    this.study,
    this.separatedByHinge = false,
  });

  /// 每栏最小宽度与普通屏幕栏间距，单位为逻辑像素。
  static const minPaneWidth = 320.0;
  static const gutter = 16.0;
  static const wideMinWidth = minPaneWidth * 2 + gutter;

  final Rect region;

  /// 完整窗口扣除系统安全区后的范围，全屏分支不按折痕分割。
  final Rect windowRegion;
  final Rect? home;
  final Rect? study;
  final bool separatedByHinge;

  bool get wide => home != null && study != null;

  /// 单页在有铰链时使用最大的一侧，避免内容跨过不可用区域。
  Rect get singleRegion => separatedByHinge
      ? (home!.width >= study!.width ? home! : study!)
      : region;

  /// 先避开安全区；无法在铰链两侧展示时，选择最大连续安全区域。
  static AppPaneLayout resolve(MediaQueryData media) {
    final padding = EdgeInsets.fromLTRB(
      math.max(media.padding.left, media.viewPadding.left),
      math.max(media.padding.top, media.viewPadding.top),
      math.max(media.padding.right, media.viewPadding.right),
      math.max(media.padding.bottom, media.viewPadding.bottom),
    );
    final windowRegion = Rect.fromLTRB(
      padding.left,
      padding.top,
      math.max(padding.left, media.size.width - padding.right),
      math.max(padding.top, media.size.height - padding.bottom),
    );
    var region = windowRegion;
    Rect? verticalHinge;
    for (final feature in media.displayFeatures) {
      // 展平的柔性屏折痕不阻挡绘制；旋转为横向后也不能截掉半屏。
      // 只有物理铰链或半开状态的折痕需要划分连续可用区域。
      if (feature.type != DisplayFeatureType.hinge &&
          (feature.type != DisplayFeatureType.fold ||
              feature.state != DisplayFeatureState.postureHalfOpened)) {
        continue;
      }
      final bounds = feature.bounds;
      if (bounds.top <= region.top &&
          bounds.bottom >= region.bottom &&
          bounds.left > region.left &&
          bounds.right < region.right) {
        final left = Rect.fromLTRB(
          region.left,
          region.top,
          bounds.left,
          region.bottom,
        );
        final right = Rect.fromLTRB(
          bounds.right,
          region.top,
          region.right,
          region.bottom,
        );
        if (left.width >= minPaneWidth && right.width >= minPaneWidth) {
          verticalHinge = bounds;
        } else {
          region = left.width >= right.width ? left : right;
        }
      } else if (bounds.left <= region.left &&
          bounds.right >= region.right &&
          bounds.top > region.top &&
          bounds.bottom < region.bottom) {
        final top = Rect.fromLTRB(
          region.left,
          region.top,
          region.right,
          bounds.top,
        );
        final bottom = Rect.fromLTRB(
          region.left,
          bounds.bottom,
          region.right,
          region.bottom,
        );
        region = top.height >= bottom.height ? top : bottom;
        verticalHinge = null;
      }
    }
    if (verticalHinge != null) {
      return AppPaneLayout(
        region: region,
        windowRegion: windowRegion,
        separatedByHinge: true,
        home: Rect.fromLTRB(
          region.left,
          region.top,
          verticalHinge.left,
          region.bottom,
        ),
        study: Rect.fromLTRB(
          verticalHinge.right,
          region.top,
          region.right,
          region.bottom,
        ),
      );
    }
    if (region.width < wideMinWidth) {
      return AppPaneLayout(region: region, windowRegion: windowRegion);
    }
    final width = (region.width - gutter) / 2;
    return AppPaneLayout(
      region: region,
      windowRegion: windowRegion,
      home: Rect.fromLTWH(region.left, region.top, width, region.height),
      study: Rect.fromLTWH(
        region.left + width + gutter,
        region.top,
        width,
        region.height,
      ),
    );
  }

  /// 将窗口级安全区、键盘、显示特征与屏幕圆角换算成面板局部坐标。
  static MediaQueryData mediaForRect(MediaQueryData media, Rect rect) {
    EdgeInsets crop(EdgeInsets insets) => EdgeInsets.fromLTRB(
      (insets.left - rect.left).clamp(0.0, rect.width),
      (insets.top - rect.top).clamp(0.0, rect.height),
      (rect.right - (media.size.width - insets.right)).clamp(0.0, rect.width),
      (rect.bottom - (media.size.height - insets.bottom)).clamp(
        0.0,
        rect.height,
      ),
    );
    final coversWindow =
        rect.left <= 0 &&
        rect.top <= 0 &&
        rect.right >= media.size.width &&
        rect.bottom >= media.size.height;
    final cropped = media.copyWith(
      size: rect.size,
      padding: crop(media.padding),
      viewPadding: crop(media.viewPadding),
      viewInsets: crop(media.viewInsets),
      displayFeatures: [
        for (final feature in media.displayFeatures)
          if (feature.bounds.overlaps(rect))
            DisplayFeature(
              bounds: feature.bounds.intersect(rect).shift(-rect.topLeft),
              type: feature.type,
              state: feature.state,
            ),
      ],
    );
    // 面板未贴合窗口四边时，其顶/底角不在物理屏幕圆角处；显式设为 BorderRadius.zero
    // 可同时避免 Android API 31+ 透传物理圆角，以及设为 null 后回退到 0→32dp 圆角插值
    // 导致窄屏或宽屏分栏在手势完成前顶栏两角出现突兀圆角缺口。
    return coversWindow
        ? cropped
        : cropped.applyDisplayCornerRadii(BorderRadius.zero);
  }
}
