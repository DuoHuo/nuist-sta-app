package dev.duohuo.nuist_sta_app

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import jxl.Workbook
import jxl.WorkbookSettings
import java.io.File

/** 在搜索线程上读取 PDF 字符位置或遍历 Excel 的实际单元格。 */
internal class BulletinAttachmentSearch(private val context: Context) {
    private var pdfFile: File? = null
    private var pdfIndex: BulletinPdfTextIndex? = null
    private var workbook: Workbook? = null
    private var workbookFile: File? = null

    fun pdf(
        file: File,
        query: String,
        matchCase: Boolean,
        cancelled: () -> Boolean,
    ): List<Map<String, Any>> {
        var index = pdfIndex?.takeIf { pdfFile == file }
        if (index == null) {
            PDFBoxResourceLoader.init(context)
            index = BulletinPdfTextIndex.read(file, cancelled) ?: return emptyList()
            pdfFile = file
            pdfIndex = index
        }
        return index.find(literalPattern(query, matchCase), cancelled)
    }

    fun xls(
        file: File,
        query: String,
        matchCase: Boolean,
        cancelled: () -> Boolean,
    ): List<Map<String, Any>> {
        require(file.length() in 1L..BulletinOfficeRenderer.MAX_FILE_BYTES)
        val pattern = literalPattern(query, matchCase)
        val zipped = file.inputStream().use { it.read() == 'P'.code && it.read() == 'K'.code }
        if (zipped) return BulletinOfficePreview.searchWorkbook(file, pattern, cancelled)
        val book = workbook?.takeIf { file == workbookFile } ?: openWorkbook(file)
        val sheets = mutableListOf<Map<String, Any>>()
        for (sheet in book.sheets) {
            val matches = BulletinWorkbookMatches(pattern)
            for (row in 0 until sheet.rows) {
                if (cancelled()) return emptyList()
                val cells = linkedMapOf<Int, String>()
                for (cell in sheet.getRow(row)) {
                    val text = cell.contents
                    if (text.isNotEmpty()) cells[cell.column] = text
                }
                matches.addRow(row + 1, cells)
            }
            matches.sheet(sheet.name)?.let(sheets::add)
        }
        return sheets
    }

    private fun openWorkbook(file: File): Workbook {
        workbook?.close()
        workbook = null
        workbookFile = null
        val settings = WorkbookSettings().apply {
            setSuppressWarnings(true)
            setDrawingsDisabled(true)
            setNamesDisabled(true)
            setPropertySets(false)
        }
        val book = Workbook.getWorkbook(file, settings)
        workbook = book
        workbookFile = file
        return book
    }

    fun close() {
        workbook?.close()
        workbook = null
        workbookFile = null
        pdfFile = null
        pdfIndex = null
    }

    private fun literalPattern(query: String, matchCase: Boolean) =
        Regex(Regex.escape(query), if (matchCase) emptySet() else setOf(RegexOption.IGNORE_CASE))
}

/** 汇集工作表实际坐标和同一单元格内的全部命中范围。 */
internal class BulletinWorkbookMatches(private val pattern: Regex) {
    private val rows = mutableListOf<Map<String, Any>>()
    private var columns = 0
    private var count = 0
    private var retainedUnits = 0L

    fun addRow(number: Int, cells: Map<Int, String>) {
        val highlights = linkedMapOf<Int, IntArray>()
        for ((column, text) in cells) {
            val ranges = pattern.findAll(text).flatMap { match ->
                sequenceOf(match.range.first, match.range.last + 1)
            }.toList().toIntArray()
            if (ranges.isEmpty()) continue
            highlights[column] = ranges
            count += ranges.size / 2
        }
        if (highlights.isEmpty()) return
        columns = maxOf(columns, cells.keys.max() + 1)
        retainedUnits += cells.values.sumOf { it.length.toLong() + 16 } +
            highlights.values.sumOf { it.size.toLong() * 4 } + 32
        rows.add(mapOf("number" to number, "cells" to cells, "highlights" to highlights))
    }

    fun sheet(name: String): Map<String, Any>? = rows.takeIf { it.isNotEmpty() }?.let {
        mapOf("title" to name, "columns" to columns, "rows" to it, "count" to count)
    }

    fun resultSize(): Long = retainedUnits
}
