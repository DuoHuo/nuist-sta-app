package dev.duohuo.nuist_sta_app

import android.util.Xml
import app.opendocument.core.Element as OfficeElement
import app.opendocument.core.FileType
import app.opendocument.core.Odr
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.URI
import java.util.zip.ZipFile

/** 从 Office Open XML 文件读取正文、单元格和幻灯片文字。 */
internal object BulletinOfficePreview {
    private const val MAX_FILE_BYTES = 64L * 1024 * 1024
    private const val MAX_XML_BYTES = 3 * 1024 * 1024
    private const val MAX_TOTAL_XML_BYTES = 8 * 1024 * 1024
    private const val MAX_TEXT = 80_000
    private const val REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private const val STRICT_REL_NS = "http://purl.oclc.org/ooxml/officeDocument/relationships"
    private const val MIME_PREFIX = "application/vnd.openxmlformats-officedocument."
    private const val XLSX_MIME = MIME_PREFIX + "spreadsheetml.sheet"
    private const val MAX_SHEETS = 8
    private const val MAX_ROWS = 160
    private const val MAX_COLUMNS = 24
    private const val XLSX_COLUMNS = 16_384
    private const val MAX_WORKBOOK_SEARCH_RESULT = 24L * 1024 * 1024
    private const val MAX_WORKBOOK_SHARED_TEXT = 32L * 1024 * 1024
    private const val MAX_SLIDES = 80
    private const val MAX_IMAGE_BYTES = 2 * 1024 * 1024
    private const val MAX_TOTAL_IMAGE_BYTES = 6 * 1024 * 1024

    fun read(file: File): Map<String, Any>? {
        require(file.length() in 1L..MAX_FILE_BYTES)
        val compound = file.inputStream().use { input ->
            input.read() == 0xd0 && input.read() == 0xcf &&
                input.read() == 0x11 && input.read() == 0xe0
        }
        if (compound) return legacyWorkbook(file)
        return ZipFile(file).use { zip ->
            val pkg = Package(zip)
            val (part, mime) = pkg.officePart() ?: return@use null
            val root = pkg.xml(part) ?: return@use null
            val sections = when {
                root.name == "document" && (mime.startsWith(MIME_PREFIX + "wordprocessingml.") ||
                    mime.startsWith("application/vnd.ms-word.")) -> pkg.word(root, part)
                root.name == "workbook" && (mime.startsWith(MIME_PREFIX + "spreadsheetml.") ||
                    mime.startsWith("application/vnd.ms-excel.")) -> pkg.workbook(root, part)
                root.name == "presentation" && (mime.startsWith(MIME_PREFIX + "presentationml.") ||
                    mime.startsWith("application/vnd.ms-powerpoint.")) -> pkg.slides(root, part)
                else -> return@use null
            }
            mapOf(
                "mimeType" to mime,
                "sections" to sections,
                "limited" to pkg.limited,
            )
        }
    }

    fun mimeType(file: File): String? {
        require(file.length() in 1L..MAX_FILE_BYTES)
        return ZipFile(file).use { Package(it).officePart()?.second }
    }

    fun searchWorkbook(file: File, pattern: Regex, cancelled: () -> Boolean): List<Map<String, Any>> {
        return ZipFile(file).use { zip ->
            val pkg = Package(zip)
            val (part, mime) = requireNotNull(pkg.officePart())
            require(mime == XLSX_MIME)
            val root = requireNotNull(pkg.xml(part))
            require(root.name == "workbook")
            pkg.searchWorkbook(root, part, pattern, cancelled)
        }
    }

    private fun legacyWorkbook(file: File): Map<String, Any>? {
        val decoded = try {
            Odr.open(file.absolutePath)
        } catch (_: LinkageError) {
            return null
        }
        return decoded.use {
            if (decoded.fileType() != FileType.LEGACY_EXCEL_WORKSHEETS ||
                decoded.passwordEncrypted()) return null
            val sections = mutableListOf<Map<String, Any>>()
            var limited = false
            var remainingText = MAX_TEXT
            decoded.asDocumentFile().use { workbook ->
                workbook.document().use { document ->
                    document.rootElement().use { root ->
                        var child = root.firstChild()
                        while (child != null) {
                            child.use { sheetElement ->
                                sheetElement.asSheet()?.use { sheet ->
                                    val dimensions = sheet.content(null)
                                    if (dimensions.rows > MAX_ROWS || dimensions.columns > MAX_COLUMNS) {
                                        limited = true
                                    }
                                    val rows = mutableListOf<Map<String, Any>>()
                                    val columns = dimensions.columns.coerceIn(0, MAX_COLUMNS)
                                    for (row in 0 until dimensions.rows.coerceIn(0, MAX_ROWS)) {
                                        if (remainingText == 0) {
                                            limited = true
                                            break
                                        }
                                        val cells = List(columns) { column ->
                                            val value = sheet.cell(column, row)?.use { cell ->
                                                buildString { appendCellText(cell) }
                                            }.orEmpty().trim()
                                            value.take(minOf(320, remainingText)).also {
                                                remainingText -= it.length
                                                if (it.length < value.length) limited = true
                                            }
                                        }
                                        val last = cells.indexOfLast { it.isNotEmpty() }
                                        if (last >= 0) rows.add(mapOf("number" to row + 1, "cells" to cells.take(last + 1)))
                                    }
                                    if (rows.isNotEmpty()) {
                                        sections.add(mapOf("title" to sheet.name(), "rows" to rows, "columns" to columns))
                                    }
                                }
                                child = sheetElement.nextSibling()
                            }
                            if (sections.size == MAX_SHEETS || remainingText == 0) {
                                if (child != null) limited = true
                                child?.close()
                                break
                            }
                        }
                    }
                }
            }
            mapOf("mimeType" to "application/vnd.ms-excel", "sections" to sections, "limited" to limited)
        }
    }

    private fun StringBuilder.appendCellText(element: OfficeElement, depth: Int = 0) {
        if (depth == 12 || length >= 321) return
        element.asText()?.use { text ->
            append(text.content().take(321 - length))
            return
        }
        var child = element.firstChild()
        while (child != null) {
            child.use {
                appendCellText(it, depth + 1)
                child = if (length < 321) it.nextSibling() else null
            }
        }
    }

    private class Element(
        val name: String,
        val attrs: Map<String, String>,
    ) {
        private var textBuffer: StringBuilder? = null
        val text: String get() = textBuffer?.toString().orEmpty()
        val children = mutableListOf<Element>()

        fun append(value: String) {
            val buffer = textBuffer ?: StringBuilder().also { textBuffer = it }
            buffer.append(value)
        }

        fun child(name: String): Element? = children.firstOrNull { it.name == name }
        fun children(name: String): Sequence<Element> =
            children.asSequence().filter { it.name == name }

        fun descendants(name: String, stopAtMatch: Boolean = false): Sequence<Element> = sequence {
            for (child in children) {
                // 兼容内容包含多个版本时，只读取第一个分支。
                if (child.name == "AlternateContent") {
                    val branch = child.children.firstOrNull()
                    if (branch != null) yieldAll(branch.descendants(name, stopAtMatch))
                } else {
                    if (child.name == name) yield(child)
                    if (child.name != name || !stopAtMatch) {
                        yieldAll(child.descendants(name, stopAtMatch))
                    }
                }
            }
        }
    }

    private data class Relationship(val type: String, val path: String)

    private class WorkbookXmlBudget {
        private var remaining = 256L * 1024 * 1024

        fun consume(size: Long) {
            require(size in 1L..remaining)
            remaining -= size
        }
    }

    /** 按压缩包声明的长度读取，避免损坏的成员在解析时突破解压上限。 */
    private class WorkbookXmlInput(input: InputStream, private var remaining: Long) : FilterInputStream(input) {
        override fun read(): Int = super.read().also { value ->
            if (value >= 0) require(remaining-- > 0)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            super.read(buffer, offset, minOf(length.toLong(), remaining + 1).toInt()).also { count ->
                if (count > 0) {
                    remaining -= count
                    require(remaining >= 0)
                }
            }
    }

    private class Package(private val zip: ZipFile) {
        private var remainingBytes = MAX_TOTAL_XML_BYTES
        private var remainingText = MAX_TEXT
        private var remainingImages = MAX_TOTAL_IMAGE_BYTES
        var limited = false
            private set

        fun xml(path: String): Element? {
            val entry = zip.getEntry(path) ?: return null
            val limit = minOf(remainingBytes, MAX_XML_BYTES)
            require(entry.size in 1L..limit.toLong())
            val bytes = ByteArray(entry.size.toInt())
            zip.getInputStream(entry).use { stream ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = stream.read(bytes, offset, bytes.size - offset)
                    require(count > 0)
                    offset += count
                }
                require(stream.read() == -1)
            }
            remainingBytes -= bytes.size
            val parser = xmlParser(ByteArrayInputStream(bytes))
            var root: Element? = null
            while (true) {
                when (parser.nextToken()) {
                    XmlPullParser.START_TAG -> {
                        require(root == null)
                        root = readElement(parser, 50_000)
                    }
                    XmlPullParser.DOCDECL -> error("Unsupported document declaration")
                    XmlPullParser.END_DOCUMENT -> return root
                }
            }
        }

        private fun xmlParser(input: InputStream) = Xml.newPullParser().apply {
            if (getFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL)) {
                setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
            }
            setInput(input, null)
        }

        private fun readElement(
            parser: XmlPullParser,
            maxElements: Int,
            cancelled: () -> Boolean = { false },
        ): Element {
            val stack = mutableListOf<Element>()
            var elements = 0
            var token = parser.eventType
            while (token != XmlPullParser.END_DOCUMENT) {
                when (token) {
                    XmlPullParser.START_TAG -> {
                        require(++elements <= maxElements && parser.depth <= 64)
                        if (elements % 128 == 0 && cancelled()) throw InterruptedIOException()
                        val attrs = buildMap {
                            for (index in 0 until parser.attributeCount) {
                                val key = parser.getAttributeName(index)
                                val namespace = parser.getAttributeNamespace(index)
                                when (namespace) {
                                    "" -> put(key, parser.getAttributeValue(index))
                                    REL_NS, STRICT_REL_NS -> put("r:$key", parser.getAttributeValue(index))
                                    "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
                                    "http://purl.oclc.org/ooxml/wordprocessingml/main" ->
                                        put(key, parser.getAttributeValue(index))
                                }
                            }
                        }
                        val node = Element(parser.name, attrs)
                        stack.lastOrNull()?.children?.add(node)
                        stack.add(node)
                    }
                    XmlPullParser.TEXT, XmlPullParser.CDSECT, XmlPullParser.ENTITY_REF -> {
                        val node = stack.lastOrNull()
                        if (node != null && (node.name == "t" || node.name == "v" || node.name == "f")) {
                            val value = parser.text
                            require(value != null)
                            node.append(value)
                        }
                    }
                    XmlPullParser.DOCDECL -> error("Unsupported document declaration")
                    XmlPullParser.END_TAG -> {
                        val node = stack.removeAt(stack.lastIndex)
                        if (stack.isEmpty()) return node
                    }
                }
                token = parser.nextToken()
            }
            error("Incomplete XML element")
        }

        fun officePart(): Pair<String, String>? {
            val part = relationships("").values.firstOrNull { it.type == "officeDocument" }?.path
                ?: return null
            val type = xml("[Content_Types].xml")?.children("Override")
                ?.firstOrNull { it.attrs["PartName"]?.removePrefix("/") == part }
                ?.attrs?.get("ContentType") ?: return null
            val mime = type.removeSuffix(".main+xml").removeSuffix(".main")
            return part to if (mime.endsWith(".macroEnabled", ignoreCase = true)) {
                mime.substringBeforeLast('.') + ".macroEnabled.12"
            } else {
                mime
            }
        }

        private fun optionalXml(path: String): Element? = try {
            xml(path)
        } catch (_: Exception) {
            limited = true
            null
        }

        fun relationships(part: String): Map<String, Relationship> {
            val parent = part.substringBeforeLast('/', "")
            val base = if (parent.isEmpty()) "" else "$parent/"
            val path = "${base}_rels/${part.substringAfterLast('/')}.rels"
            val root = xml(path) ?: return emptyMap()
            return buildMap {
                for (node in root.children("Relationship")) {
                    if (node.attrs["TargetMode"] == "External") continue
                    val id = node.attrs["Id"] ?: continue
                    val type = node.attrs["Type"]?.substringAfterLast('/') ?: continue
                    val target = node.attrs["Target"] ?: continue
                    val uri = try {
                        URI(null, null, "/$part", null).resolve(target).normalize()
                    } catch (_: IllegalArgumentException) {
                        continue
                    }
                    val resolved = uri.path?.removePrefix("/") ?: continue
                    if (uri.isAbsolute || uri.authority != null || uri.query != null ||
                        uri.fragment != null || resolved.contains('\\') || resolved.split('/').any { it == ".." }) {
                        continue
                    }
                    put(id, Relationship(type, resolved))
                }
            }
        }

        private fun previewText(value: String, max: Int = 4_000): String {
            val length = minOf(value.length, max, remainingText)
            if (length < value.length) limited = true
            remainingText -= length
            if (length == value.length || length == 0) return value.take(length)
            val end = if (Character.isHighSurrogate(value[length - 1])) length - 1 else length
            return value.substring(0, end) + "…"
        }

        fun word(root: Element, part: String): List<Map<String, Any>> {
            val body = root.child("body") ?: return emptyList()
            val links = relationships(part)
            val styles = links.values.firstOrNull { it.type == "styles" }
                ?.let { optionalXml(it.path) }
                ?.children("style")
                ?.mapNotNull { style -> style.attrs["styleId"]?.let { it to style } }
                ?.toMap().orEmpty()
            val blocks = mutableListOf<Map<String, Any>>()
            wordBlocks(body, links, styles, blocks)
            val stories = links.values.filter { it.type == "header" || it.type == "footer" }
                .distinctBy { it.path }
            for (story in stories) {
                val element = optionalXml(story.path) ?: continue
                val contents = mutableListOf<Map<String, Any>>()
                wordBlocks(element, optionalRelationships(story.path), styles, contents)
                if (contents.isNotEmpty()) {
                    blocks.add(mapOf("text" to if (story.type == "header") "页眉" else "页脚", "heading" to 2))
                    blocks.addAll(contents)
                }
            }
            return if (blocks.isEmpty()) emptyList() else listOf(mapOf("blocks" to blocks))
        }

        private fun wordBlocks(
            container: Element,
            links: Map<String, Relationship>,
            styles: Map<String, Element>,
            out: MutableList<Map<String, Any>>,
        ) {
            for (node in container.children) {
                if (remainingText == 0 || out.size >= 2_000) {
                    limited = true
                    return
                }
                when (node.name) {
                    "p" -> {
                        val props = node.child("pPr")
                        val style = styles[props?.child("pStyle")?.attrs?.get("val")]
                        val styleProps = style?.child("pPr")
                        val align = props?.child("jc")?.attrs?.get("val")
                            ?: styleProps?.child("jc")?.attrs?.get("val")
                        val outline = props?.child("outlineLvl")?.attrs?.get("val")?.toIntOrNull()
                            ?: styleProps?.child("outlineLvl")?.attrs?.get("val")?.toIntOrNull()
                        val title = style?.child("name")?.attrs?.get("val").equals("title", ignoreCase = true)
                        var text = buildString { appendWord(node) }.trimEnd()
                        if (text.isNotBlank()) {
                            if (props?.child("numPr")?.child("numId")?.attrs?.get("val")?.let { it != "0" } == true) {
                                text = "•  $text"
                            }
                            out.add(buildMap {
                                put("text", previewText(text))
                                if (align != null) put("align", align)
                                if (title || (outline != null && outline in 0..8)) {
                                    put("heading", if (title || outline == 0) 1 else 2)
                                }
                            })
                        }
                        addImages(node, links, out)
                        for (box in node.descendants("txbxContent", stopAtMatch = true)) {
                            wordBlocks(box, links, styles, out)
                        }
                    }
                    "tbl" -> {
                        val rows = node.children("tr").take(MAX_ROWS + 1).toList()
                        if (rows.size > MAX_ROWS) limited = true
                        val table = rows.take(MAX_ROWS).map { row ->
                            val cells = row.children("tc").take(MAX_COLUMNS + 1).toList()
                            if (cells.size > MAX_COLUMNS) limited = true
                            cells.take(MAX_COLUMNS).map { cell ->
                                previewText(
                                    cell.descendants("p").joinToString("\n") {
                                        buildString { appendWord(it) }
                                    }.trimEnd(),
                                )
                            }
                        }.filter { it.isNotEmpty() }
                        if (table.isNotEmpty()) out.add(mapOf("table" to table))
                        addImages(node, links, out)
                    }
                    "sdt" -> node.child("sdtContent")?.let { wordBlocks(it, links, styles, out) }
                    "customXml", "ins" -> wordBlocks(node, links, styles, out)
                    "AlternateContent" -> node.children.firstOrNull()?.let { wordBlocks(it, links, styles, out) }
                }
            }
        }

        private fun optionalRelationships(part: String): Map<String, Relationship> = try {
            relationships(part)
        } catch (_: Exception) {
            limited = true
            emptyMap()
        }

        private fun addImages(
            node: Element,
            links: Map<String, Relationship>,
            out: MutableList<Map<String, Any>>,
        ) {
            for (drawing in node.descendants("blip") + node.descendants("imagedata")) {
                val id = drawing.attrs["r:embed"] ?: drawing.attrs["r:id"] ?: continue
                val path = links[id]?.takeIf { it.type == "image" }?.path ?: continue
                val bytes = try {
                    image(path)
                } catch (_: Exception) {
                    limited = true
                    null
                }
                if (bytes != null) out.add(mapOf("image" to bytes))
            }
        }

        private fun image(path: String): ByteArray? {
            if (path.substringAfterLast('.').lowercase() !in setOf("png", "jpg", "jpeg", "gif", "webp", "bmp")) {
                limited = true
                return null
            }
            val entry = zip.getEntry(path) ?: return null
            val limit = minOf(MAX_IMAGE_BYTES, remainingImages)
            if (entry.size !in 1L..limit.toLong()) {
                limited = true
                return null
            }
            val bytes = ByteArray(entry.size.toInt())
            zip.getInputStream(entry).use { stream ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = stream.read(bytes, offset, bytes.size - offset)
                    if (count <= 0) return null
                    offset += count
                }
                if (stream.read() != -1) return null
            }
            remainingImages -= bytes.size
            return bytes
        }

        private fun StringBuilder.appendWord(node: Element) {
            when (node.name) {
                "t" -> append(node.text)
                "tab" -> append('\t')
                "br", "cr" -> append('\n')
                "drawing", "pict", "object", "del" -> return
                "AlternateContent" -> node.children.firstOrNull()?.let { appendWord(it) }
                else -> node.children.forEach { appendWord(it) }
            }
        }

        fun searchWorkbook(
            root: Element,
            part: String,
            pattern: Regex,
            cancelled: () -> Boolean,
        ): List<Map<String, Any>> {
            val budget = WorkbookXmlBudget()
            val relations = relationships(part)
            val strings = workbookSharedStrings(relations, budget, cancelled)
            val result = mutableListOf<Map<String, Any>>()
            var retainedSize = 0L
            for (sheet in root.child("sheets")?.children("sheet").orEmpty()) {
                if (cancelled()) return emptyList()
                val relation = relations[sheet.attrs["r:id"]]?.takeIf { it.type == "worksheet" } ?: continue
                val matches = BulletinWorkbookMatches(pattern)
                var number = 0
                workbookItems(relation.path, "worksheet", "sheetData", "row", budget, cancelled) { row ->
                    number = row.attrs["r"]?.toIntOrNull() ?: number + 1
                    require(number in 1..1_048_576)
                    var nextColumn = 0
                    val cells = linkedMapOf<Int, String>()
                    for (cell in row.children("c")) {
                        val column = cell.attrs["r"]?.let { columnIndex(it, XLSX_COLUMNS) } ?: nextColumn
                        require(column in 0 until XLSX_COLUMNS)
                        nextColumn = column + 1
                        val value = cellValue(cell, strings)
                        if (value.isNotEmpty()) cells[column] = value
                    }
                    matches.addRow(number, cells)
                    require(retainedSize + matches.resultSize() <= MAX_WORKBOOK_SEARCH_RESULT)
                    true
                }
                retainedSize += matches.resultSize()
                matches.sheet(sheet.attrs["name"].orEmpty())?.let(result::add)
            }
            return result
        }

        private fun workbookSharedStrings(
            relations: Map<String, Relationship>,
            budget: WorkbookXmlBudget,
            cancelled: () -> Boolean,
        ): List<String> {
            val path = relations.values.firstOrNull { it.type == "sharedStrings" }?.path
                ?: return emptyList()
            var retainedSize = 0L
            val strings = mutableListOf<String>()
            workbookItems(path, "sst", "sst", "si", budget, cancelled) { item ->
                val text = stringRuns(item)
                retainedSize += text.length.toLong() * 2 + 32
                require(retainedSize <= MAX_WORKBOOK_SHARED_TEXT)
                strings.add(text)
                true
            }
            return strings
        }

        private fun workbookItems(
            path: String,
            rootName: String,
            parentName: String,
            itemName: String,
            budget: WorkbookXmlBudget,
            cancelled: () -> Boolean,
            onStartTag: ((XmlPullParser) -> Unit)? = null,
            readItem: (Element) -> Boolean,
        ) {
            val entry = requireNotNull(zip.getEntry(path))
            budget.consume(entry.size)
            WorkbookXmlInput(zip.getInputStream(entry), entry.size).use { input ->
                val parser = xmlParser(input)
                val parentDepth = if (parentName == rootName) 1 else 2
                var inItems = false
                var tokens = 0
                while (true) {
                    if (++tokens % 128 == 0 && cancelled()) throw InterruptedIOException()
                    when (parser.nextToken()) {
                        XmlPullParser.START_TAG -> {
                            require(parser.depth <= 64)
                            if (parser.depth == 1) require(parser.name == rootName)
                            onStartTag?.invoke(parser)
                            if (parser.depth == parentDepth) inItems = parser.name == parentName
                            if (inItems && parser.depth == parentDepth + 1 && parser.name == itemName) {
                                if (cancelled()) throw InterruptedIOException()
                                if (!readItem(readElement(parser, 250_000, cancelled))) return
                            }
                        }
                        XmlPullParser.END_TAG -> if (parser.depth == parentDepth) inItems = false
                        XmlPullParser.DOCDECL -> error("Unsupported document declaration")
                        XmlPullParser.END_DOCUMENT -> return
                    }
                }
            }
        }

        fun workbook(root: Element, part: String): List<Map<String, Any>> {
            val relations = relationships(part)
            val budget = WorkbookXmlBudget()
            val strings = workbookSharedStrings(relations, budget) { false }
            val sheets = root.child("sheets")?.children("sheet").orEmpty().filter {
                it.attrs["state"] !in setOf("hidden", "veryHidden") &&
                    relations[it.attrs["r:id"]]?.type == "worksheet"
            }.toList()
            if (sheets.size > MAX_SHEETS) limited = true
            return sheets.take(MAX_SHEETS).mapNotNull { sheet ->
                val path = relations.getValue(sheet.attrs.getValue("r:id")).path
                try {
                    previewWorksheet(path, sheet.attrs["name"].orEmpty(), strings, budget)
                } catch (_: Exception) {
                    limited = true
                    null
                }
            }
        }

        private fun previewWorksheet(
            path: String,
            name: String,
            strings: List<String>,
            budget: WorkbookXmlBudget,
        ): Map<String, Any>? {
            val hiddenColumns = BooleanArray(MAX_COLUMNS)
            var inColumns = false
            fun readColumn(parser: XmlPullParser) {
                if (parser.depth == 2) inColumns = parser.name == "cols"
                if (inColumns && parser.depth == 3 && parser.name == "col") {
                    val hidden = parser.getAttributeValue(null, "hidden")
                    if (hidden != "1" && hidden != "true") return
                    val from = parser.getAttributeValue(null, "min")?.toIntOrNull() ?: return
                    val to = parser.getAttributeValue(null, "max")?.toIntOrNull() ?: return
                    for (column in maxOf(1, from)..minOf(to, MAX_COLUMNS)) {
                        hiddenColumns[column - 1] = true
                    }
                }
            }
            var number = 0
            var columns = 0
            val rows = mutableListOf<Map<String, Any>>()
            workbookItems(path, "worksheet", "sheetData", "row", budget, { false }, ::readColumn) { row ->
                number = row.attrs["r"]?.toIntOrNull() ?: number + 1
                if (isHidden(row)) return@workbookItems true
                if (rows.size == MAX_ROWS || remainingText == 0) {
                    limited = true
                    return@workbookItems false
                }
                var nextColumn = 0
                val cells = MutableList(MAX_COLUMNS) { "" }
                for (cell in row.children("c")) {
                    val index = cell.attrs["r"]?.let { columnIndex(it, MAX_COLUMNS) } ?: nextColumn
                    nextColumn = index + 1
                    val value = cellValue(cell, strings)
                    if (value.isEmpty()) continue
                    if (index >= MAX_COLUMNS) {
                        limited = true
                        continue
                    }
                    if (hiddenColumns[index]) continue
                    cells[index] = previewText(value, max = 320)
                    columns = maxOf(columns, index + 1)
                }
                val last = cells.indexOfLast { it.isNotEmpty() }
                if (last >= 0) {
                    rows.add(mapOf(
                        "number" to number,
                        "cells" to cells.take(last + 1),
                    ))
                }
                true
            }
            if (rows.isEmpty()) return null
            return mapOf("title" to name, "rows" to rows, "columns" to columns)
        }

        private fun columnIndex(reference: String, limit: Int): Int {
            var number = 0
            for (character in reference) {
                if (character !in 'A'..'Z') break
                number = number * 26 + (character - 'A' + 1)
                if (number > limit) return limit
            }
            require(number > 0)
            return number - 1
        }

        private fun cellValue(cell: Element, strings: List<String>): String {
            val value = cell.child("v")?.text
            return when (cell.attrs["t"]) {
                "inlineStr" -> cell.child("is")?.let(::stringRuns)
                "s" -> value?.toIntOrNull()?.let(strings::getOrNull)
                "b" -> value?.let { if (it == "1") "TRUE" else "FALSE" }
                else -> value?.takeIf { it.isNotEmpty() } ?: cell.child("f")?.text?.let { "=$it" }
            }.orEmpty()
        }

        private fun stringRuns(node: Element): String = buildString {
            node.child("t")?.let { append(it.text) }
            for (run in node.children("r")) run.child("t")?.let { append(it.text) }
        }

        private fun isHidden(node: Element): Boolean =
            node.attrs["hidden"] == "1" || node.attrs["hidden"] == "true"

        fun slides(root: Element, part: String): List<Map<String, Any>> {
            val relations = relationships(part)
            val ids = root.child("sldIdLst")?.children("sldId")?.toList().orEmpty()
            if (ids.size > MAX_SLIDES) limited = true
            val sections = ids.take(MAX_SLIDES).mapIndexedNotNull { index, id ->
                val path = relations[id.attrs["r:id"]]?.takeIf { it.type == "slide" }?.path
                    ?: return@mapIndexedNotNull null
                val slide = optionalXml(path) ?: return@mapIndexedNotNull null
                val lines = slide.descendants("p").map { paragraph ->
                    previewText(paragraph.descendants("t").joinToString("") { it.text }.trimEnd())
                }.filter { it.isNotBlank() }.toList()
                val blocks = mutableListOf<Map<String, Any>>()
                addImages(slide, optionalRelationships(path), blocks)
                mapOf("slide" to index + 1, "lines" to lines, "blocks" to blocks)
            }
            return sections.takeIf { items ->
                items.any { (it["lines"] as List<*>).isNotEmpty() || (it["blocks"] as List<*>).isNotEmpty() }
            }.orEmpty()
        }
    }
}
