package dev.duohuo.nuist_sta_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/** 只为公告附件缓存内的文件生成可临时授权的 URI。 */
class BulletinAttachmentFileProvider : FileProvider()

/** 将下载好的附件交给系统应用选择器。 */
internal object BulletinAttachmentActions {
    private const val CHANNEL = "dev.duohuo.nuist_sta_app/attachment_actions"
    private const val ATTACHMENT_DIRECTORY = "bulletin_attachments"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            try {
                val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                val root = File(activity.cacheDir, ATTACHMENT_DIRECTORY).canonicalPath
                require(file.path.startsWith(root + File.separator) && file.isFile)

                val uri = FileProvider.getUriForFile(
                    activity,
                    "${activity.packageName}.$ATTACHMENT_DIRECTORY",
                    file,
                )
                val extension = file.extension.lowercase(Locale.ROOT)
                val mimeType = call.argument<String>("mimeType")
                    ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                    ?: "application/octet-stream"
                val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType)
                intent.clipData = ClipData.newRawUri(null, uri)
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (intent.resolveActivity(activity.packageManager) == null) {
                    result.error("no_app", "本机没有可打开此附件的应用", null)
                    return@setMethodCallHandler
                }
                activity.startActivity(Intent.createChooser(intent, "用其他应用打开"))
                result.success(null)
            } catch (_: ActivityNotFoundException) {
                result.error("no_app", "本机没有可打开此附件的应用", null)
            } catch (_: Exception) {
                result.error("action_failed", "无法处理此附件", null)
            }
        }
    }
}
