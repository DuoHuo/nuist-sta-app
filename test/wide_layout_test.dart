import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/layout/app_pane_layout.dart';

void main() {
  test('阈值扣除安全区，竖向铰链填满两侧，横向铰链使用最大安全区域', () {
    AppPaneLayout layout(
      double width, {
      EdgeInsets padding = EdgeInsets.zero,
      List<DisplayFeature> features = const [],
    }) => AppPaneLayout.resolve(
      MediaQueryData(
        size: Size(width, 900),
        padding: padding,
        displayFeatures: features,
      ),
    );
    expect(layout(655).wide, isFalse);
    expect(layout(656).home!.width, 320);
    expect(
      layout(
        696,
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ).home!.width,
      320,
    );
    expect(
      layout(695, padding: const EdgeInsets.symmetric(horizontal: 20)).wide,
      isFalse,
    );
    final hinge = layout(
      740,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(320, 0, 40, 900),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(hinge.home!.width, 320);
    expect(hinge.study!.width, 380);
    expect(hinge.study!.left, 360);
    final small = layout(
      650,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(290, 0, 40, 900),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(small.wide, isFalse);
    expect(small.region, const Rect.fromLTWH(330, 0, 320, 900));
    final horizontal = layout(
      700,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 350, 700, 30),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.unknown,
        ),
      ],
    );
    expect(horizontal.region, const Rect.fromLTWH(0, 380, 700, 520));
  });

  test('折叠屏展开或状态未知的折痕不裁剪连续屏幕', () {
    for (final state in [
      DisplayFeatureState.postureFlat,
      DisplayFeatureState.unknown,
    ]) {
      for (final bounds in [
        const Rect.fromLTWH(400, 0, 0, 900),
        const Rect.fromLTWH(0, 450, 800, 0),
      ]) {
        final layout = AppPaneLayout.resolve(
          MediaQueryData(
            size: const Size(800, 900),
            padding: const EdgeInsets.only(top: 24, bottom: 20),
            displayFeatures: [
              DisplayFeature(
                bounds: bounds,
                type: DisplayFeatureType.fold,
                state: state,
              ),
            ],
          ),
        );
        expect(layout.region, const Rect.fromLTWH(0, 24, 800, 856));
        expect(layout.home, const Rect.fromLTWH(0, 24, 392, 856));
        expect(layout.study, const Rect.fromLTWH(408, 24, 392, 856));
        expect(layout.separatedByHinge, isFalse);
      }
    }
  });

  test('半开折叠屏仍避开分隔折痕，展平后恢复完整高度', () {
    MediaQueryData media(DisplayFeatureState state) => MediaQueryData(
      size: const Size(800, 900),
      displayFeatures: [
        DisplayFeature(
          bounds: const Rect.fromLTWH(0, 450, 800, 0),
          type: DisplayFeatureType.fold,
          state: state,
        ),
      ],
    );
    expect(
      AppPaneLayout.resolve(media(DisplayFeatureState.postureHalfOpened))
          .region,
      const Rect.fromLTWH(0, 0, 800, 450),
    );
    expect(
      AppPaneLayout.resolve(media(DisplayFeatureState.postureFlat)).region,
      const Rect.fromLTWH(0, 0, 800, 900),
    );
  });

  test('mediaForRect 仅在贴合完整窗口时保留物理屏幕圆角，其余设为 zero', () {
    for (final cornerRadii in [BorderRadius.circular(42), null]) {
      final media = const MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.only(top: 43, bottom: 20),
        viewPadding: EdgeInsets.only(top: 43, bottom: 20),
      ).applyDisplayCornerRadii(cornerRadii);
      expect(
        AppPaneLayout.mediaForRect(
          media,
          const Rect.fromLTRB(0, 43, 390, 824),
        ).displayCornerRadii,
        BorderRadius.zero,
      );
      expect(
        AppPaneLayout.mediaForRect(
          media,
          const Rect.fromLTWH(0, 0, 190, 844),
        ).displayCornerRadii,
        BorderRadius.zero,
      );
      expect(
        AppPaneLayout.mediaForRect(
          media,
          const Rect.fromLTWH(0, 0, 390, 844),
        ).displayCornerRadii,
        cornerRadii,
      );
    }
  });
}
