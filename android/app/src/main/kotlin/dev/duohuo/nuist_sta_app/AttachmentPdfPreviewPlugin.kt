package dev.duohuo.nuist_sta_app

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import kotlin.math.min

/** 本机 PDF 预览桥接；文件读取和页面渲染都在串行后台线程执行。 */
class AttachmentPdfPreviewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var worker: ExecutorService
    private lateinit var cacheRoot: String
    private val main = Handler(Looper.getMainLooper())
    private val documents = mutableMapOf<Int, PdfRenderer>()
    private var nextId = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cacheRoot = binding.applicationContext.cacheDir.canonicalPath + File.separator
        worker = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, "dev.duohuo.nuist_sta_app/attachment_pdf")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("open", "render", "close")) {
            result.notImplemented()
            return
        }
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "open" -> open(call)
                    "render" -> render(call)
                    else -> {
                        val id = requireNotNull(call.argument<Number>("id")).toInt()
                        documents.remove(id)?.close()
                        null
                    }
                }
                main.post { result.success(value) }
            } catch (_: Exception) {
                // 不把本地路径或附件内容放进错误和日志。
                main.post { result.error("preview_failed", "无法预览此 PDF", null) }
            }
        }
    }

    private fun open(call: MethodCall): Map<String, Int> {
        val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
        require(file.path.startsWith(cacheRoot) && file.isFile)
        val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = try {
            PdfRenderer(descriptor)
        } catch (error: Exception) {
            descriptor.close()
            throw error
        }
        if (renderer.pageCount < 1) {
            renderer.close()
            throw IllegalArgumentException("PDF 没有页面")
        }
        val id = ++nextId
        documents[id] = renderer
        return mapOf("id" to id, "pageCount" to renderer.pageCount)
    }

    private fun render(call: MethodCall): ByteArray {
        val id = requireNotNull(call.argument<Number>("id")).toInt()
        val renderer = requireNotNull(documents[id])
        val pageIndex = requireNotNull(call.argument<Number>("page")).toInt()
        renderer.openPage(pageIndex).use { page ->
            // 限制单页位图大小；长文档翻页时不一次性展开全部页面。
            val scale = min(1600.0 / page.width, 2400.0 / page.height)
            val width = (page.width * scale).toInt().coerceAtLeast(1)
            val height = (page.height * scale).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                    output.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.execute {
            documents.values.forEach { renderer ->
                try {
                    renderer.close()
                } catch (_: Exception) {
                    // 关闭一个失败不妨碍释放其他文档。
                }
            }
            documents.clear()
        }
        worker.shutdown()
    }
}
