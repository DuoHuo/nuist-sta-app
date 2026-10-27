package dev.duohuo.nuist_sta_app

/**
 * 桌面小组件 2×2「当前/下一节」。
 *
 * 与 4×2 共用 Flutter payload、`prefs`、颜色 token 和刷新闹钟，渲染入口在
 * [TimetableWidgetProvider.render]（按 AppWidget provider 组件分发）。这里保留独立类，
 * 是因为 Android 清单里的同一个 receiver 组件不能注册两次；不要改成复用
 * [TimetableWidgetProvider] 的 ComponentName，否则两个尺寸会共用同一份 layout。
 */
class TimetableWidget2x2Provider : TimetableWidgetProvider()
