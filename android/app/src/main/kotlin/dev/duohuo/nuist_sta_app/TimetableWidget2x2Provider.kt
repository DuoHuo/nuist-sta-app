package dev.duohuo.nuist_sta_app

import androidx.glance.appwidget.GlanceAppWidget
import dev.duohuo.nuist_sta_app.widget.TimetableGlanceWidget

/** 2×2 当前／下一节课，使用独立组件标识和同一套 Glance 数据链路。 */
class TimetableWidget2x2Provider : TimetableWidgetProvider() {
    override val glanceAppWidget: GlanceAppWidget = TimetableGlanceWidget(square = true)
}
