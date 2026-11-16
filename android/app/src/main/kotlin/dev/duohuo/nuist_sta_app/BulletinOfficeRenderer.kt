package dev.duohuo.nuist_sta_app

import app.opendocument.core.DecodedFile
import app.opendocument.core.FileType
import app.opendocument.core.Html
import app.opendocument.core.HtmlColorScheme
import app.opendocument.core.HtmlConfig
import app.opendocument.core.HtmlService
import app.opendocument.core.Odr
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.zip.ZipFile

/** 通过原生引擎生成静态 HTML，WebView 只负责显示。 */
internal class BulletinOfficeRenderer(
    private val file: File,
    private val dark: Boolean,
) {
    private val lock = Any()
    private var session: Session? = null
    @Volatile private var closed = false

    fun metadata(width: Int): String? = synchronized(lock) {
        if (closed) return null
        val active = session ?: open(width)?.also { session = it } ?: return null
        val views = JSONArray()
        for (view in active.views) views.put(view.name)
        JSONObject()
            .put("mime", Odr.mimetypeByFileType(active.type))
            .put("sheets", active.views.first().path.startsWith("sheet"))
            .put("views", views)
            .toString()
    }

    fun render(index: Int): ByteArray? = synchronized(lock) {
        if (closed) return null
        val active = session ?: return null
        val view = active.views.getOrNull(index) ?: return null
        active.service.write(view.path).takeIf { it.size <= MAX_HTML_BYTES }
    }

    fun close() {
        closed = true
        cleanup.execute {
            synchronized(lock) {
                session?.let {
                    try {
                        it.service.close()
                    } finally {
                        it.document.close()
                    }
                }
                session = null
            }
        }
    }

    private fun open(width: Int): Session? {
        if (!withinArchiveBudget()) return null
        val document = Odr.open(file.absolutePath)
        var service: HtmlService? = null
        var transferred = false
        try {
            val type = document.fileType()
            if (type !in officeTypes || document.passwordEncrypted()) return null
            val config = HtmlConfig().apply {
                viewportWidth = width
                colorScheme = if (dark) HtmlColorScheme.DARK else HtmlColorScheme.LIGHT
                textDocumentMargin = true
                lazyLayout = false
            }
            val html = Html.translate(document, config)
            service = html
            val allViews = html.listViews().map { view ->
                view.use { View(it.name(), it.path()) }
            }
            val parts = allViews.filter { partPath.matches(it.path) }
            val views = parts.ifEmpty { allViews }
            if (views.isEmpty()) return null
            return Session(document, html, type, views).also { transferred = true }
        } finally {
            if (!transferred) {
                try {
                    service?.close()
                } finally {
                    document.close()
                }
            }
        }
    }

    private fun withinArchiveBudget(): Boolean {
        val zip = file.inputStream().buffered().use { input ->
            input.read() == 0x50 && input.read() == 0x4b
        }
        if (!zip) return true
        return ZipFile(file).use { archive ->
            if (archive.size() > 12_000) return@use false
            var remaining = 192L * 1024 * 1024
            val entries = archive.entries()
            while (entries.hasMoreElements()) {
                val size = entries.nextElement().size
                if (size !in 0L..MAX_FILE_BYTES || size > remaining) return@use false
                remaining -= size
            }
            true
        }
    }

    private data class View(val name: String, val path: String)

    private data class Session(
        val document: DecodedFile,
        val service: HtmlService,
        val type: FileType,
        val views: List<View>,
    )

    companion object {
        const val MAX_FILE_BYTES = 64L * 1024 * 1024
        private const val MAX_HTML_BYTES = 16 * 1024 * 1024
        private val cleanup = Executors.newSingleThreadExecutor()
        private val partPath = Regex("(sheet|slide)\\d+\\.html")
        private val officeTypes = setOf(
            FileType.OPENDOCUMENT_TEXT,
            FileType.OPENDOCUMENT_SPREADSHEET,
            FileType.OPENDOCUMENT_PRESENTATION,
            FileType.OFFICE_OPEN_XML_DOCUMENT,
            FileType.OFFICE_OPEN_XML_WORKBOOK,
            FileType.OFFICE_OPEN_XML_PRESENTATION,
            FileType.EXCEL_BINARY_WORKBOOK,
            FileType.LEGACY_WORD_DOCUMENT,
            FileType.LEGACY_EXCEL_WORKSHEETS,
            FileType.LEGACY_POWERPOINT_PRESENTATION,
            FileType.RICH_TEXT_FORMAT,
        )
    }
}
