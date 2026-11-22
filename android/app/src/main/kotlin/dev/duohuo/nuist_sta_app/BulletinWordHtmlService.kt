package dev.duohuo.nuist_sta_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import android.util.Base64
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.converter.WordToHtmlConverter
import org.apache.poi.hwpf.usermodel.PictureType
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.File
import java.io.Writer
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.xml.parsers.DocumentBuilderFactory

/** 在独立进程中串行把旧版 Word 转成静态 HTML，解析异常不影响应用阅读界面。 */
class BulletinWordHtmlService : Service() {
    override fun onBind(intent: Intent?): IBinder {
        val engine = messenger ?: createMessenger(applicationContext).also { messenger = it }
        return engine.binder
    }

    companion object {
        private var messenger: Messenger? = null

        private fun createMessenger(context: Context): Messenger {
            val converter = BulletinWordHtmlConverter(context)
            val worker = HandlerThread("公告 Word 转换").also { it.start() }
            return Messenger(Handler(worker.looper) { request ->
                val path = try {
                    request.data.getString("path")?.let(converter::convert)?.path
                } catch (_: Exception) {
                    null
                } catch (_: LinkageError) {
                    // Android 缺少部分 java.awt 类，遇到依赖它们的内容时放弃预览。
                    null
                } catch (_: OutOfMemoryError) {
                    null
                }
                val response = Message.obtain().apply {
                    arg1 = request.arg1
                    data = Bundle().apply { putString("path", path) }
                }
                try {
                    request.replyTo?.send(response)
                } catch (_: RemoteException) {
                    // 阅读界面已关闭时，生成的 HTML 仍可供下次读取。
                }
                true
            })
        }
    }
}

/** 旧版 Word 转换结果的缓存位置，阅读窗口只接受这里的 HTML。 */
internal object BulletinWordHtml {
    const val DIRECTORY = "bulletin_word_html"
    const val MIME_TYPE = "application/msword"
    const val MAX_HTML_BYTES = 16L * 1024 * 1024

    /** 清理旧版本 LibreOffice 引擎解包到数据目录的文件和 PDF 缓存。 */
    fun removeLegacyEngine(context: Context) {
        val marker = File(context.filesDir, "bulletin_word_engine_26.2.7.3-1")
        if (!marker.exists()) return
        val data = File(context.applicationInfo.dataDir)
        for (name in listOf("etc", "program", "user")) File(data, name).deleteRecursively()
        for (name in listOf("bulletin_word_pdf", "bulletin_word_fonts")) {
            File(context.cacheDir, name).deleteRecursively()
        }
        marker.delete()
    }
}

private class BulletinWordHtmlConverter(private val context: Context) {
    fun convert(path: String): File {
        val source = File(path).canonicalFile
        val attachments = File(context.cacheDir, "bulletin_attachments").canonicalPath + File.separator
        require(source.path.startsWith(attachments) && source.isFile)
        require(source.length() in 1L..BulletinOfficeRenderer.MAX_FILE_BYTES)
        val outputDir = File(context.cacheDir, "${BulletinWordHtml.DIRECTORY}/$CACHE_VERSION")
        outputDir.mkdirs()
        val output = File(outputDir, "${digest(source)}.html")
        if (output.isFile) {
            output.setLastModified(System.currentTimeMillis())
            return output
        }
        val partial = File.createTempFile("word-", ".part", outputDir)
        try {
            val dom = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument()
            val converter = WordToHtmlConverter(dom)
            // 图片内联为 data URI，阅读窗口禁止加载其他资源；WebView 无法显示的格式直接省略。
            converter.setPicturesManager { content, type, _, _, _ ->
                if (type in webImageTypes && content.size <= MAX_IMAGE_BYTES) {
                    "data:${type.mime};base64,${Base64.encodeToString(content, Base64.NO_WRAP)}"
                } else {
                    null
                }
            }
            source.inputStream().buffered().use { input ->
                HWPFDocument(input).use(converter::processDocument)
            }
            partial.bufferedWriter().use { writer ->
                writer.write("<!doctype html>")
                writeHtml(converter.document.documentElement, writer)
            }
            check(partial.length() in 1L..BulletinWordHtml.MAX_HTML_BYTES)
            check(partial.renameTo(output))
            trimCache(outputDir, output)
            return output
        } finally {
            partial.delete()
        }
    }

    /** Android 的 XML Transformer 不支持 HTML 输出方式，这里按 HTML 规则序列化。 */
    private fun writeHtml(node: Node, writer: Writer) {
        when (node.nodeType) {
            Node.TEXT_NODE -> writer.write(escape(node.nodeValue.orEmpty(), attribute = false))
            Node.ELEMENT_NODE -> {
                val element = node as Element
                val tag = element.tagName.lowercase()
                writer.write("<$tag")
                val attributes = element.attributes
                for (index in 0 until attributes.length) {
                    val attribute = attributes.item(index)
                    writer.write(" ${attribute.nodeName}=\"${escape(attribute.nodeValue.orEmpty(), attribute = true)}\"")
                }
                writer.write(">")
                if (tag in voidElements) return
                val children = element.childNodes
                for (index in 0 until children.length) {
                    val child = children.item(index)
                    // 样式表内容不能转义，否则 CSS 选择器会失效。
                    if (tag == "style" && child.nodeType == Node.TEXT_NODE) {
                        writer.write(child.nodeValue.orEmpty().replace("</", "<\\/"))
                    } else {
                        writeHtml(child, writer)
                    }
                }
                writer.write("</$tag>")
            }
        }
    }

    private fun escape(value: String, attribute: Boolean): String = buildString(value.length) {
        for (char in value) {
            when (char) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> if (attribute) append("&quot;") else append(char)
                else -> append(char)
            }
        }
    }

    private fun digest(source: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        source.inputStream().buffered().use { input ->
            val bytes = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(bytes)
                if (count == -1) break
                digest.update(bytes, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun trimCache(directory: File, current: File) {
        val files = directory.listFiles().orEmpty()
            .filter { it.isFile && it != current }
            .sortedByDescending(File::lastModified)
        var bytes = current.length()
        val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(7)
        for (file in files) {
            val size = file.length()
            if (file.lastModified() < cutoff || bytes + size > MAX_CACHE_BYTES) {
                file.delete()
            } else {
                bytes += size
            }
        }
    }

    companion object {
        private const val CACHE_VERSION = "poi-5.5.1-1"
        private const val MAX_CACHE_BYTES = 128L * 1024 * 1024
        private const val MAX_IMAGE_BYTES = 8 * 1024 * 1024
        private val webImageTypes = setOf(PictureType.PNG, PictureType.JPEG, PictureType.GIF, PictureType.BMP)
        private val voidElements = setOf("br", "hr", "img", "meta", "link", "col", "input", "wbr")
    }
}
