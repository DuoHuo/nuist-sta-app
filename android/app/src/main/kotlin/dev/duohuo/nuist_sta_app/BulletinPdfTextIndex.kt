package dev.duohuo.nuist_sta_app

import android.graphics.RectF
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import java.io.File
import java.io.IOException
import java.io.Writer
import kotlin.math.abs

/** 保存文字与页面坐标，连续输入时复用已经提取的位置。 */
internal class BulletinPdfTextIndex private constructor(private val pages: List<Page>) {
    fun find(pattern: Regex, cancelled: () -> Boolean): List<Map<String, Any>> {
        val matches = mutableListOf<Map<String, Any>>()
        for ((number, page) in pages.withIndex()) {
            if (cancelled()) return emptyList()
            for (match in pattern.findAll(page.text)) {
                if (cancelled()) return emptyList()
                val boxes = mutableListOf<RectF>()
                for (index in match.range) {
                    val box = page.boxes[index] ?: continue
                    val last = boxes.lastOrNull()
                    if (last != null && last.top < box.bottom && last.bottom > box.top &&
                        abs(box.left - last.right) <= maxOf(box.width(), last.height())
                    ) {
                        last.union(box)
                    } else {
                        boxes.add(RectF(box))
                    }
                }
                if (boxes.isNotEmpty()) {
                    val rects = FloatArray(boxes.size * 4)
                    for ((index, box) in boxes.withIndex()) {
                        rects[index * 4] = box.left
                        rects[index * 4 + 1] = box.top
                        rects[index * 4 + 2] = box.right
                        rects[index * 4 + 3] = box.bottom
                    }
                    matches.add(mapOf("page" to number, "rects" to rects))
                }
            }
        }
        return matches
    }

    private data class Page(val text: String, val boxes: List<RectF?>)

    private class TextPositionReader(private val cancelled: () -> Boolean) : PDFTextStripper() {
        val pages = mutableListOf<Page>()
        private var words = StringBuilder()
        private var boxes = mutableListOf<RectF?>()
        private var width = 0f
        private var height = 0f
        private var rotation = 0

        init {
            sortByPosition = true
        }

        override fun startPage(page: PDPage) {
            if (cancelled()) throw SearchCancelled()
            // PDFTextStripper 可能略过空页，索引仍需与预览的页码一致。
            while (pages.size < currentPageNo - 1) pages.add(Page("", emptyList()))
            words = StringBuilder()
            boxes = mutableListOf()
            rotation = page.rotation
            val crop = page.cropBox
            width = if (rotation % 180 == 0) crop.width else crop.height
            height = if (rotation % 180 == 0) crop.height else crop.width
        }

        override fun writeString(text: String, positions: MutableList<TextPosition>) {
            if (cancelled()) throw SearchCancelled()
            for (position in positions) {
                val characters = position.unicode
                val box = bounds(position)
                words.append(characters)
                repeat(characters.length) { boxes.add(box) }
            }
        }

        override fun writeWordSeparator() = separator()
        override fun writeLineSeparator() = separator()

        private fun separator() {
            if (words.isEmpty() || words.last().isWhitespace()) return
            words.append(' ')
            boxes.add(null)
        }

        override fun endPage(page: PDPage) {
            pages.add(Page(words.toString(), boxes))
        }

        private fun bounds(position: TextPosition): RectF? {
            val x = position.x
            val y = position.y
            val advance = position.widthDirAdj
            val ascent = position.heightDir
            if (width <= 0 || height <= 0 || advance <= 0 || ascent <= 0) return null
            val box = when ((position.dir.toInt() + 360 - rotation) % 360) {
                90 -> RectF(x - ascent, y - advance, x, y)
                180 -> RectF(x - advance, y, x, y + ascent)
                270 -> RectF(x, y, x + ascent, y + advance)
                else -> RectF(x, y - ascent, x + advance, y)
            }
            box.set(box.left / width, box.top / height, box.right / width, box.bottom / height)
            return box
        }
    }

    private class SearchCancelled : IOException()

    companion object {
        fun read(file: File, cancelled: () -> Boolean): BulletinPdfTextIndex? {
            return try {
                PDDocument.load(file, MemoryUsageSetting.setupMixed(16 * 1024 * 1024L)).use { document ->
                    val reader = TextPositionReader(cancelled)
                    reader.writeText(document, object : Writer() {
                        override fun write(chars: CharArray, offset: Int, length: Int) = Unit
                        override fun flush() = Unit
                        override fun close() = Unit
                    })
                    BulletinPdfTextIndex(reader.pages)
                }
            } catch (_: SearchCancelled) {
                null
            }
        }
    }
}
