package dev.duohuo.nuist_sta_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import dev.duohuo.nuist_sta_app.widget.TimetableWeekWidgetRuntime
import dev.duohuo.nuist_sta_app.widget.TimetableWidgetUpdates

/** 4×6 当周课表；保留已固定组件的接收器名。 */
class TimetableWeekWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TimetableWidgetUpdates.ACTION_REFRESH) {
            super.onReceive(context, intent)
            return
        }
        val pending = goAsync()
        TimetableNativeWork.background(context, "widget.week.refresh", "widget_broadcast_failed", pending::finish) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, TimetableWeekWidgetProvider::class.java))
            TimetableWeekWidgetRuntime.render(context, manager, ids)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        val pending = goAsync()
        TimetableNativeWork.background(context, "widget.week.update", "widget_broadcast_failed", pending::finish) {
            TimetableWeekWidgetRuntime.render(context, manager, appWidgetIds, force = true)
            TimetableWidgetUpdates.schedule(context)
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        val pending = goAsync()
        TimetableNativeWork.background(context, "widget.week.resize", "widget_broadcast_failed", pending::finish) {
            TimetableWeekWidgetRuntime.render(context, manager, intArrayOf(id))
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val pending = goAsync()
        TimetableNativeWork.background(context, "widget.week.delete", "widget_broadcast_failed", pending::finish) {
            TimetableWeekWidgetRuntime.clear(context, appWidgetIds)
            TimetableWidgetUpdates.schedule(context)
        }
    }
}

/** 只有组件创建的不可变 PendingIntent 能触发此非导出接收器。 */
class TimetableWeekWidgetFlipReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TimetableWeekWidgetRuntime.ACTION_FLIP) return
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        // 无排课或重绘，不必等待与同步、闹钟和缩放共用的工作队列。
        try {
            TimetableWeekWidgetRuntime.flip(context, AppWidgetManager.getInstance(context), id)
        } catch (error: Exception) {
            val pending = goAsync()
            val stage = "widget.week.flip"
            val reason = "widget_broadcast_failed"
            TimetableNativeWork.background(context, stage, reason, pending::finish) {
                it.add(notifyFailureDetails(error, stage) + ("reason_code" to reason))
            }
        }
    }
}
