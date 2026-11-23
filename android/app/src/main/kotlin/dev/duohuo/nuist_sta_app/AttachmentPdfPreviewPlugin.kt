package dev.duohuo.nuist_sta_app

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Build
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
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min

/** 本机 PDF 预览桥接；文件读取和页面渲染都在串行后台线程执行。 */
class AttachmentPdfPreviewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var worker: ExecutorService
    private lateinit var searchWorker: ExecutorService
    private lateinit var search: BulletinAttachmentSearch
    private val searchGeneration = AtomicInteger()
    private lateinit var cacheRoot: String
    private lateinit var wordHtml: BulletinWordHtmlClient
    private val main = Handler(Looper.getMainLooper())
    private val documents = mutableMapOf<Int, PdfRenderer>()
    private var nextId = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cacheRoot = binding.applicationContext.cacheDir.canonicalPath + File.separator
        wordHtml = BulletinWordHtmlClient(binding.applicationContext)
        worker = Executors.newSingleThreadExecutor()
        searchWorker = Executors.newSingleThreadExecutor()
        search = BulletinAttachmentSearch(binding.applicationContext)
        val context = binding.applicationContext
        worker.execute {
            try {
                BulletinWordHtml.removeLegacyEngine(context)
            } catch (_: Exception) {
                // 清理失败只会留下旧文件，下次启动再试。
            }
        }
        channel = MethodChannel(binding.binaryMessenger, "dev.duohuo.nuist_sta_app/attachment_pdf")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "searchPdf" || call.method == "searchXls") {
            searchAttachment(call, result)
            return
        }
        if (call.method == "cancelSearch") {
            searchGeneration.incrementAndGet()
            if (call.argument<Boolean>("release") == true) searchWorker.execute { search.close() }
            result.success(null)
            return
        }
        if (call.method == "convertWord") {
            val file = try {
                cachedFile(call)
            } catch (_: Exception) {
                result.error("preview_failed", "无法预览此附件", null)
                return
            }
            wordHtml.convert(file, result)
            return
        }
        if (call.method !in setOf("open", "render", "close", "office", "officeMimeType")) {
            result.notImplemented()
            return
        }
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "open" -> open(call)
                    "render" -> render(call)
                    "office" -> BulletinOfficePreview.read(cachedFile(call))
                    "officeMimeType" -> BulletinOfficePreview.mimeType(cachedFile(call))
                    else -> {
                        val id = requireNotNull(call.argument<Number>("id")).toInt()
                        documents.remove(id)?.close()
                        null
                    }
                }
                main.post { result.success(value) }
            } catch (_: Exception) {
                // 不把本地路径或附件内容放进错误和日志。
                main.post { result.error("preview_failed", "无法预览此附件", null) }
            }
        }
    }

    private fun searchAttachment(call: MethodCall, result: MethodChannel.Result) {
        val generation = searchGeneration.incrementAndGet()
        val query = call.argument<String>("query").orEmpty()
        val matchCase = call.argument<Boolean>("matchCase") == true
        searchWorker.execute {
            try {
                val cancelled = { searchGeneration.get() != generation }
                val resultRows = when {
                    cancelled() || query.isBlank() -> emptyList()
                    call.method == "searchPdf" -> search.pdf(cachedFile(call), query, matchCase, cancelled)
                    else -> search.xls(cachedFile(call), query, matchCase, cancelled)
                }
                main.post { result.success(resultRows) }
            } catch (_: Exception) {
                main.post { result.error("search_failed", "无法查找附件中的文字", null) }
            } catch (_: LinkageError) {
                main.post { result.error("search_failed", "无法查找附件中的文字", null) }
            }
        }
    }

    private fun cachedFile(call: MethodCall): File {
        val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
        require(file.path.startsWith(cacheRoot) && file.isFile)
        return file
    }

    private fun open(call: MethodCall): Map<String, Any> {
        val file = cachedFile(call)
        val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = try {
            PdfRenderer(descriptor)
        } catch (error: Exception) {
            descriptor.close()
            throw error
        }
        val (probedCount, pageAspectRatios) = try {
            require(renderer.pageCount > 0)
            val probedCount = min(renderer.pageCount, INITIAL_PROBED_PAGES)
            val probed = List(probedCount) { index ->
                renderer.openPage(index).use { page ->
                    require(page.width > 0 && page.height > 0)
                    page.width.toDouble() / page.height
                }
            }
            val defaultRatio = probed.first()
            probedCount to List(renderer.pageCount) { index ->
                if (index < probed.size) probed[index] else defaultRatio
            }
        } catch (error: Exception) {
            renderer.close()
            throw error
        }
        val id = ++nextId
        documents[id] = renderer
        return mapOf(
            "id" to id,
            "pageAspectRatios" to pageAspectRatios,
            "probedPageCount" to probedCount,
        )
    }

    private fun render(call: MethodCall): ByteArray {
        val id = requireNotNull(call.argument<Number>("id")).toInt()
        val renderer = requireNotNull(documents[id])
        val pageIndex = requireNotNull(call.argument<Number>("page")).toInt()
        val maxWidth = call.argument<Number>("width")?.toInt()?.coerceIn(320, 1600) ?: 1600
        renderer.openPage(pageIndex).use { page ->
            // 限制单页位图大小，避免滚动经过大尺寸页面时占用过多内存。
            val scale = min(maxWidth.toDouble() / page.width, 2400.0 / page.height)
            val width = (page.width * scale).toInt().coerceAtLeast(1)
            val height = (page.height * scale).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Bitmap.CompressFormat.WEBP_LOSSY
                } else {
                    @Suppress("DEPRECATION")
                    Bitmap.CompressFormat.WEBP
                }
                return ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(format, 90, output))
                    output.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }
    }

    companion object {
        private const val INITIAL_PROBED_PAGES = 8
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        wordHtml.close()
        searchGeneration.incrementAndGet()
        searchWorker.execute { search.close() }
        searchWorker.shutdown()
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
