package dev.duohuo.nuist_sta_app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.ComponentName
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import dev.duohuo.nuist_sta_app.widget.TimetableGlanceWidget
import dev.duohuo.nuist_sta_app.widget.TimetableWidgetData
import dev.duohuo.nuist_sta_app.widget.TimetableWidgetUpdates

/** 4×2 今日课表。保留组件名，使已固定的小组件在应用升级后继续有效。 */
open class TimetableWidgetProvider : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = TimetableGlanceWidget(square = false)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_SCHEDULE) {
            val pending = goAsync()
            val app = context.applicationContext
            TimetableNativeWork.background(app, "widget.schedule", "widget_broadcast_failed", pending::finish) {
                TimetableWidgetData.invalidate(app)
                TimetableWidgetUpdates.schedule(app)
            }
            return
        }
        if (intent.action == TimetableWidgetUpdates.ACTION_TICK) {
            val pending = goAsync()
            val app = context.applicationContext
            TimetableNativeWork.background(app, "widget.tick", "widget_broadcast_failed", pending::finish) {
                TimetableWidgetUpdates.refresh(app)
            }
            return
        }
        try {
            super.onReceive(context, intent)
            if (intent.action == TimetableWidgetUpdates.ACTION_REFRESH) {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(ComponentName(context, javaClass))
                if (ids.isNotEmpty()) onUpdate(context, manager, ids)
            }
        } catch (error: Exception) {
            recordBackgroundFailure(context, "widget.receive", error)
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try {
            super.onUpdate(context, appWidgetManager, appWidgetIds)
            requestSchedule(context)
        } catch (error: Exception) {
            recordBackgroundFailure(context, "widget.update", error)
        }
    }

    override fun onDisabled(context: Context) {
        try {
            super.onDisabled(context)
            requestSchedule(context)
        } catch (error: Exception) {
            recordBackgroundFailure(context, "widget.disabled", error)
        }
    }

    private fun recordBackgroundFailure(context: Context, stage: String, error: Exception) {
        TimetableNativeWork.background(context, stage, "widget_broadcast_failed") {
            it.add(notifyFailureDetails(error, stage) + ("reason_code" to "widget_broadcast_failed"))
        }
    }

    private fun requestSchedule(context: Context) {
        // Glance 自己持有当前广播的 goAsync/Worker；排程使用独立广播持有生命周期，
        // 不能在同一接收回调第二次 goAsync，也不能依赖 daemon 线程保活。
        context.sendBroadcast(Intent(ACTION_SCHEDULE).setComponent(ComponentName(context, javaClass)))
    }

    companion object {
        private const val ACTION_SCHEDULE = "dev.duohuo.nuist_sta_app.WIDGET_SCHEDULE"
        /** 接收 Flutter 现有 payload，并通知两种尺寸重新组合。 */
        fun savePayload(context: Context, json: String) = TimetableWidgetUpdates.save(context, json)

        /** 开机、时间变化和手动同步共用入口。 */
        fun refreshAll(context: Context) = TimetableWidgetUpdates.refresh(context)

        /** 保留桥接入口；配置变化也影响密度、语言和字号，统一重新组合。 */
        fun refreshIfNightChanged(context: Context) = TimetableWidgetUpdates.refresh(context)
    }
}
