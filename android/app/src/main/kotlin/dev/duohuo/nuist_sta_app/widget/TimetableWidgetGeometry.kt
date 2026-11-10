package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.ui.unit.DpSize

/** 课表内容的布局尺寸，与桌面占格和外层背景边界分开处理。 */
internal object TimetableWidgetGeometry {
    /** 默认桌面不可识别时保留通用策略，不按手机品牌扩大兼容分支。 */
    fun homePackage(context: Context): String? = try {
        context.packageManager.resolveActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
            PackageManager.MATCH_DEFAULT_ONLY,
        )?.activityInfo?.packageName
    } catch (_: Exception) {
        null
    }

    /** 仅识别 vivo 系统桌面，第三方桌面不套用 OriginOS 铺满策略。 */
    fun isOriginOsHome(context: Context): Boolean {
        val home = homePackage(context)
        return home == "com.bbk.launcher2" || home?.startsWith("com.vivo.launcher") == true
    }

    /** 其他桌面沿用原有尺寸预算；OriginOS 不通过此函数获取布局宽高。 */
    fun contentSize(square: Boolean, hostSize: DpSize): DpSize {
        val side = minOf(hostSize.width, hostSize.height)
        return if (square) DpSize(side, side) else hostSize
    }
}
