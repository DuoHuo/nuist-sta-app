package dev.duohuo.nuist_sta_app

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** 明日课表专用本地调度，不涉及课前提醒，也不在后台访问网络或凭据。 */
object NextDayReminder {
    private const val CHANNEL_ID = "timetable_next_day"
    private const val NOTIFICATION_ID = 2200
    private const val ALARM_REQUEST = 2201
    private const val PREFS = "timetable_next_day"
    const val OPEN_URI = "nuist://timetable/today?focus=tomorrow"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun alarmIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, ALARM_REQUEST,
        Intent(context, NextDayReminderReceiver::class.java).setAction("nuist.TIMETABLE_EVE"),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** 原子替换所有日期文案，关闭/解绑时立即删除文案并取消闹钟。 */
    fun update(context: Context, args: Map<*, *>): Boolean {
        val minute = (args["minuteOfDay"] as? Number)?.toInt() ?: 1320
        val enabled = args["enabled"] == true
        val payloads = if (enabled) args["payloads"] as? Map<*, *> ?: emptyMap<Any, Any>()
            else emptyMap<Any, Any>()
        val saved = prefs(context).edit()
            .putBoolean("enabled", enabled)
            .putInt("minuteOfDay", if (minute in 1260..1410 && minute % 30 == 0) minute else 1320)
            .putString("payloads", JSONObject(payloads).toString())
            // lastEveNotifyDate 独立保留，开关反复切换/改时间不会在当天重复推送。
            .commit()
        if (saved) reschedule(context)
        return saved
    }

    /** 只排下一次本机时间闹钟；系统广播、App 更新和每次闹钟后都会重排。 */
    fun reschedule(context: Context) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = alarmIntent(context)
        alarms.cancel(pending)
        if (!prefs(context).getBoolean("enabled", false)) {
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
            return
        }
        createChannel(context)
        val now = Calendar.getInstance()
        val minute = prefs(context).getInt("minuteOfDay", 1320)
        val target = (now.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, minute / 60)
            set(Calendar.MINUTE, minute % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (now.timeInMillis >= target.timeInMillis) {
            // 最晚当日 23:59:59；跨午夜只取新一天的文案，绝不补昨天。
            notifyToday(context, now)
            target.add(Calendar.DAY_OF_MONTH, 1)
        }
        try {
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, target.timeInMillis, pending)
                return
            }
        } catch (_: RuntimeException) {
            // 权限被撤销等情况退回非精确闹钟，不要求用户跳系统设置。
        }
        try {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, target.timeInMillis, pending)
        } catch (_: RuntimeException) {
            // 系统调度服务暂不可用时等待下次启动/系统广播重试。
        }
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "明日课表", NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "按本机已保存课表推送明日安排" })
        }
    }

    private fun notifyToday(context: Context, now: Calendar) {
        val stored = prefs(context)
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(now.time)
        if (stored.getString("lastEveNotifyDate", null) == day) return
        val payload = try {
            JSONObject(stored.getString("payloads", "{}") ?: "{}").optJSONObject(day)
        } catch (_: Exception) { null } ?: return
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        if (Build.VERSION.SDK_INT >= 26) {
            val system = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (system.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) return
        }
        val open = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(OPEN_URI)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context, NOTIFICATION_ID, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = payload.optString("title")
        val body = payload.optString("body")
        val warm = payload.optString("warmLine", "").takeUnless { it == "null" }.orEmpty()
        val footer = "按本机已保存课表"
        val expanded = SpannableString(listOf(body, warm, footer).filter { it.isNotEmpty() }.joinToString("\n"))
        if (warm.isNotEmpty()) {
            val start = body.length + 1
            expanded.setSpan(ForegroundColorSpan(0xFFB7791F.toInt()), start, start + warm.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_timetable_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setSubText(footer)
            .setStyle(NotificationCompat.BigTextStyle().setBigContentTitle(title).bigText(expanded))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        // 先持久化去重标记；进程在 notify 后被杀也不会再弹一次。
        if (!stored.edit().putString("lastEveNotifyDate", day).commit()) return
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // 恰在发送时撤销权限：恢复标记，重新授权后当晚仍可补推。
            stored.edit().remove("lastEveNotifyDate").commit()
        }
    }
}

/** 闹钟、开机、校时、时区变化和升级后恢复下一次本地调度。 */
class NextDayReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        NextDayReminder.reschedule(context)
    }
}
