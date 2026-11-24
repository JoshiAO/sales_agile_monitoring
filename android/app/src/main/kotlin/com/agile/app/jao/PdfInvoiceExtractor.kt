package com.agile.app.jao

import android.content.Context
import android.net.Uri
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import kotlin.math.abs

object PdfInvoiceExtractor {
    private const val MAX_PDF_BYTES = 20 * 1024 * 1024 // 20 MB safety cap

    @Volatile
    private var resourceLoaderInitialized = false

    private fun ensureInitialized(context: Context) {
        if (!resourceLoaderInitialized) {
            synchronized(this) {
                if (!resourceLoaderInitialized) {
                    PDFBoxResourceLoader.init(context.applicationContext)
                    resourceLoaderInitialized = true
                }
            }
        }
    }

    data class ExtractionResult(
        val text: String,
        val isSfaInvoice: Boolean,
    )

    fun extractFromUri(context: Context, uri: Uri): ExtractionResult {
        ensureInitialized(context)
        context.contentResolver.openInputStream(uri)?.use { stream ->
            return extractFromStream(stream)
        }
        return ExtractionResult(text = "", isSfaInvoice = false)
    }

    fun extractFromStream(inputStream: InputStream): ExtractionResult {
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = inputStream.read(chunk)
            if (read <= 0) break
            total += read
            if (total > MAX_PDF_BYTES) {
                throw IllegalArgumentException("PDF exceeds maximum allowed size of 20 MB.")
            }
            buffer.write(chunk, 0, read)
        }

        PDDocument.load(
            ByteArrayInputStream(buffer.toByteArray()),
            MemoryUsageSetting.setupTempFileOnly(),
        ).use { document ->
            if (document.isEncrypted) {
                return ExtractionResult(text = "", isSfaInvoice = false)
            }

            val stripper = CoordinateTableStripper()
            stripper.sortByPosition = true
            // Trigger writeText across all pages to populate captured glyphs
            val plainText = stripper.getText(document)

            val upper = plainText.uppercase()
            val isSfa = upper.contains("PROFORMA INVOICE") &&
                (upper.contains("INVOICE CODE") || upper.contains("SALESREP CODE"))

            if (!isSfa) {
                return ExtractionResult(text = plainText, isSfaInvoice = false)
            }

            val structured = stripper.buildStructuredPayload(plainText)
            return ExtractionResult(text = structured, isSfaInvoice = true)
        }
    }

    private data class Glyph(
        val text: String,
        val x: Float,
        val endX: Float,
        val y: Float,
    )

    private data class WordToken(
        val text: String,
        val startX: Float,
        val endX: Float,
        val glyphs: List<Glyph>,
    )

    private data class VisualLine(
        val y: Float,
        val glyphs: MutableList<Glyph>,
    ) {
        fun joinedText(): String = joinGlyphs(glyphs)
    }

    private data class TableColumnBounds(
        val codeHeaderEndX: Float?,
        val descHeaderStartX: Float,
        val qtyHeaderStartX: Float,
        val qtyEndX: Float,
        val uomEndX: Float,
        val priceEndX: Float,
    )

    private data class RawAnchorLine(
        val lineIndex: Int,
        val y: Float,
        val leftGlyphs: List<Glyph>,
        val qtyMinX: Float,
        val qty: String,
        val uom: String,
        val price: String,
        val total: String,
    )

    private data class RawNonAnchorLine(
        val lineIndex: Int,
        val y: Float,
        val leftGlyphs: List<Glyph>,
    )

    private class CoordinateTableStripper : PDFTextStripper() {
        private val glyphsByPage = mutableMapOf<Int, MutableList<Glyph>>()
        private var currentPage = 0

        override fun startPage(page: com.tom_roush.pdfbox.pdmodel.PDPage?) {
            super.startPage(page)
            currentPage = currentPageNo
            glyphsByPage.putIfAbsent(currentPage, mutableListOf())
        }

        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
            if (textPositions != null) {
                val pageList = glyphsByPage.getOrPut(currentPage) { mutableListOf() }
                for (tp in textPositions) {
                    val ch = tp.unicode ?: continue
                    if (ch.isEmpty()) continue
                    pageList.add(
                        Glyph(
                            text = ch,
                            x = tp.xDirAdj,
                            endX = tp.xDirAdj + tp.widthDirAdj,
                            y = tp.yDirAdj,
                        ),
                    )
                }
            }
            super.writeString(text, textPositions)
        }

        fun buildStructuredPayload(fallbackPlainText: String): String {
            val headerLines = mutableListOf<String>()
            val footerLines = mutableListOf<String>()
            val structuredRows = mutableListOf<String>()
            var lastKnownBounds: TableColumnBounds? = null

            val sortedPages = glyphsByPage.keys.sorted()
            for (pageIndex in sortedPages) {
                val glyphs = glyphsByPage[pageIndex] ?: continue
                if (glyphs.isEmpty()) continue

                val lines = groupIntoLines(glyphs)
                val headerDetect = detectTableHeader(lines)
                val bounds = headerDetect?.bounds ?: lastKnownBounds
                if (headerDetect != null) {
                    lastKnownBounds = headerDetect.bounds
                }

                // Collect header lines (from page 1 before table header)
                val tableStartLineIdx = headerDetect?.lastHeaderLineIdx?.plus(1) ?: 0
                if (pageIndex == sortedPages.first()) {
                    val endPreTable = headerDetect?.firstHeaderLineIdx ?: lines.size
                    for (i in 0 until endPreTable) {
                        val lineText = lines[i].joinedText().trim()
                        if (lineText.isNotEmpty()) {
                            headerLines.add(lineText)
                        }
                    }
                }

                // Determine where footer starts on this page
                var footerStartIdx = lines.size
                for (i in tableStartLineIdx until lines.size) {
                    val lt = lines[i].joinedText()
                    if (lt.contains("Vatable Sales", ignoreCase = true) ||
                        lt.contains("12% VAT", ignoreCase = true) ||
                        lt.contains("Grand total", ignoreCase = true)
                    ) {
                        footerStartIdx = i
                        break
                    }
                }

                for (i in footerStartIdx until lines.size) {
                    val lt = lines[i].joinedText().trim()
                    if (lt.isNotEmpty()) {
                        footerLines.add(lt)
                    }
                }

                if (bounds == null) continue

                val bodyLines = lines.subList(
                    tableStartLineIdx.coerceAtMost(footerStartIdx),
                    footerStartIdx,
                )
                val rows = parseBodyRows(bodyLines, bounds)
                structuredRows.addAll(rows)
            }

            if (structuredRows.isEmpty()) {
                return fallbackPlainText
            }

            return buildString {
                for (h in headerLines) {
                    appendLine(h)
                }
                for (r in structuredRows) {
                    appendLine(r)
                }
                for (f in footerLines) {
                    appendLine(f)
                }
            }
        }

        private data class HeaderDetection(
            val firstHeaderLineIdx: Int,
            val lastHeaderLineIdx: Int,
            val bounds: TableColumnBounds,
        )

        private fun detectTableHeader(lines: List<VisualLine>): HeaderDetection? {
            var anchorIdx = -1
            for (i in lines.indices) {
                val u = lines[i].joinedText().uppercase()
                if (u.contains("DESCRIPTION") && u.contains("QTY") && u.contains("UOM")) {
                    anchorIdx = i
                    break
                }
            }
            if (anchorIdx == -1) return null

            // Only include anchorIdx - 1 / anchorIdx + 1 in the header band if they are
            // genuine header lines (contain header tokens and do not contain line-item money).
            val moneyPattern = Regex("""\d+\.\d{2}""")
            fun looksLikeHeaderBandLine(line: VisualLine): Boolean {
                val u = line.joinedText().uppercase()
                if (moneyPattern.containsMatchIn(u)) return false
                return u.contains("PRODUCT") ||
                    u.contains("CODE") ||
                    u.contains("UNIT") ||
                    u.contains("PRICE") ||
                    u.contains("TAX") ||
                    u.contains("LINE") ||
                    u.contains("TOTAL")
            }

            val firstIdx = if (anchorIdx > 0 && looksLikeHeaderBandLine(lines[anchorIdx - 1])) {
                anchorIdx - 1
            } else {
                anchorIdx
            }
            val lastIdx = if (anchorIdx + 1 < lines.size && looksLikeHeaderBandLine(lines[anchorIdx + 1])) {
                anchorIdx + 1
            } else {
                anchorIdx
            }
            val anchorGlyphs = lines[anchorIdx].glyphs

            val descBounds = findPhraseX(anchorGlyphs, "DESCRIPTION")
            val qtyBounds = findPhraseX(anchorGlyphs, "QTY")
            val uomBounds = findPhraseX(anchorGlyphs, "UOM")

            // Look in anchorIdx +/- 1 for PRODUCT/CODE, UNIT/PRICE and LINE/TOTAL
            val bandGlyphs = mutableListOf<Glyph>()
            for (idx in firstIdx..lastIdx) {
                bandGlyphs.addAll(lines[idx].glyphs)
            }
            val codeHeaderEndX = listOfNotNull(
                findPhraseX(bandGlyphs, "PRODUCT")?.second,
                findPhraseX(bandGlyphs, "CODE")?.second,
            ).maxOrNull()
            val priceStart = findPhraseX(bandGlyphs, "PRICE")?.first
                ?: findPhraseX(bandGlyphs, "UNIT")?.first
            val totalStart = findPhraseX(bandGlyphs, "TOTAL")?.first
                ?: findPhraseX(bandGlyphs, "LINE")?.first

            if (descBounds == null || qtyBounds == null || uomBounds == null ||
                priceStart == null || totalStart == null
            ) {
                return null
            }

            val qtyEndX = uomBounds.first - 6f
            val uomEndX = priceStart - 12f
            val priceEndX = totalStart - 12f

            return HeaderDetection(
                firstHeaderLineIdx = firstIdx,
                lastHeaderLineIdx = lastIdx,
                bounds = TableColumnBounds(
                    codeHeaderEndX = codeHeaderEndX,
                    descHeaderStartX = descBounds.first,
                    qtyHeaderStartX = qtyBounds.first,
                    qtyEndX = qtyEndX,
                    uomEndX = uomEndX,
                    priceEndX = priceEndX,
                ),
            )
        }

        private fun parseBodyRows(
            bodyLines: List<VisualLine>,
            bounds: TableColumnBounds,
        ): List<String> {
            val moneyRegex = Regex("""[\d,]+\.\d{2}""")
            val qtyRegex = Regex("""\d+(?:\.\d+)?""")

            // Pass 1: Detect anchor lines from right-hand metrics (TOTAL, PRICE, UOM, QTY).
            // Pulling QTY as the single rightmost numeric token before qtyEndX prevents trailing
            // description numbers (e.g. "30g x 10 x 20") from leaking into QTY.
            val rawAnchors = mutableListOf<RawAnchorLine>()
            val rawNonAnchors = mutableListOf<RawNonAnchorLine>()

            for ((lineIdx, line) in bodyLines.withIndex()) {
                val cUom = mutableListOf<Glyph>()
                val cPrice = mutableListOf<Glyph>()
                val cTotal = mutableListOf<Glyph>()
                val preUom = mutableListOf<Glyph>()

                for (g in line.glyphs) {
                    val cx = (g.x + g.endX) / 2f
                    when {
                        cx < bounds.qtyEndX -> preUom.add(g)
                        cx < bounds.uomEndX -> cUom.add(g)
                        cx < bounds.priceEndX -> cPrice.add(g)
                        else -> cTotal.add(g)
                    }
                }

                val uomStr = joinGlyphs(cUom).trim()
                val priceStr = joinGlyphs(cPrice).trim()
                val totalStr = joinGlyphs(cTotal).trim()

                var matchedAnchor: RawAnchorLine? = null
                if (totalStr.matches(moneyRegex) && priceStr.matches(moneyRegex)) {
                    val tokens = groupIntoTokens(preUom)
                    val lastToken = tokens.lastOrNull()
                    if (lastToken != null &&
                        lastToken.text.matches(qtyRegex) &&
                        lastToken.endX >= bounds.qtyHeaderStartX - 18f
                    ) {
                        val qtyGlyphSet = lastToken.glyphs.toSet()
                        val leftGlyphs = preUom.filter { it !in qtyGlyphSet }
                        matchedAnchor = RawAnchorLine(
                            lineIndex = lineIdx,
                            y = line.y,
                            leftGlyphs = leftGlyphs,
                            qtyMinX = lastToken.startX,
                            qty = lastToken.text,
                            uom = uomStr,
                            price = priceStr,
                            total = totalStr,
                        )
                    }
                }

                if (matchedAnchor != null) {
                    rawAnchors.add(matchedAnchor)
                } else {
                    rawNonAnchors.add(
                        RawNonAnchorLine(
                            lineIndex = lineIdx,
                            y = line.y,
                            leftGlyphs = preUom,
                        ),
                    )
                }
            }

            if (rawAnchors.isEmpty()) return emptyList()

            // Pass 2: Compute data-driven Code/Description boundary (codeEndX) from actual body glyphs
            // instead of trusting centered "DESCRIPTION" header coordinates.
            val allLeftGlyphLists = buildList {
                rawAnchors.forEach { if (it.leftGlyphs.isNotEmpty()) add(it.leftGlyphs) }
                rawNonAnchors.forEach { if (it.leftGlyphs.isNotEmpty()) add(it.leftGlyphs) }
            }
            val codeEndX = detectCodeEndX(allLeftGlyphLists, bounds)

            // Split each line's leftGlyphs into Code vs Description using the data-driven codeEndX.
            val descPartsByAnchor = Array(rawAnchors.size) { mutableListOf<Pair<Float, String>>() }
            val codeByAnchor = Array(rawAnchors.size) { "" }

            for (idx in rawAnchors.indices) {
                val anchor = rawAnchors[idx]
                val (codeStr, descStr) = splitCodeAndDescription(anchor.leftGlyphs, codeEndX)
                if (codeStr.isNotEmpty()) {
                    codeByAnchor[idx] = codeStr
                }
                if (descStr.isNotEmpty()) {
                    descPartsByAnchor[idx].add(anchor.y to descStr)
                }
            }

            val descFragments = mutableListOf<Pair<Float, String>>()
            val codeFragments = mutableListOf<Pair<Float, String>>()

            for (nonAnchor in rawNonAnchors) {
                val (codeStr, descStr) = splitCodeAndDescription(nonAnchor.leftGlyphs, codeEndX)
                if (descStr.isNotEmpty()) {
                    descFragments.add(nonAnchor.y to descStr)
                }
                if (codeStr.isNotEmpty()) {
                    codeFragments.add(nonAnchor.y to codeStr)
                }
            }

            // Detect whether item rows are top-aligned (no fragments above first anchor)
            // or vertically centered (fragments exist above first anchor).
            val firstAnchorY = rawAnchors.first().y
            val hasFragmentAboveFirst = descFragments.any { it.first < firstAnchorY - 3.5f } ||
                codeFragments.any { it.first < firstAnchorY - 3.5f }

            fun resolveAnchorIndex(fragY: Float): Int {
                return if (hasFragmentAboveFirst) {
                    rawAnchors.indices.minByOrNull { abs(rawAnchors[it].y - fragY) } ?: 0
                } else {
                    val preceding = rawAnchors.indexOfLast { it.y <= fragY + 3.5f }
                    if (preceding >= 0) preceding else 0
                }
            }

            for ((fragY, fragText) in descFragments) {
                val targetIdx = resolveAnchorIndex(fragY)
                descPartsByAnchor[targetIdx].add(fragY to fragText)
            }

            for ((fragY, fragCode) in codeFragments) {
                val targetIdx = resolveAnchorIndex(fragY)
                if (codeByAnchor[targetIdx].isEmpty()) {
                    codeByAnchor[targetIdx] = fragCode
                }
            }

            val result = mutableListOf<String>()
            for (idx in rawAnchors.indices) {
                val anchor = rawAnchors[idx]
                val fullDesc = descPartsByAnchor[idx]
                    .sortedBy { it.first }
                    .joinToString(" ") { it.second }
                    .replace(Regex("""\s+"""), " ")
                    .trim()
                val code = codeByAnchor[idx].trim()
                result.add(
                    "[PDF_TABLE_ROW]\t$code\t$fullDesc\t${anchor.qty}\t${anchor.uom}\t${anchor.price}\t${anchor.total}",
                )
            }
            return result
        }

        private fun detectCodeEndX(
            leftGlyphLists: List<List<Glyph>>,
            bounds: TableColumnBounds,
        ): Float {
            if (leftGlyphLists.isEmpty()) {
                return (bounds.codeHeaderEndX ?: (bounds.descHeaderStartX - 6f))
            }

            val tokenLines = leftGlyphLists
                .map { groupIntoTokens(it) }
                .filter { it.isNotEmpty() }

            if (tokenLines.isEmpty()) {
                return (bounds.codeHeaderEndX ?: (bounds.descHeaderStartX - 6f))
            }

            val minLineStartX = tokenLines.minOf { it.first().startX }
            val codePattern = Regex("""^[A-Za-z0-9\-]{2,14}$""")

            val candidateCodeEnds = mutableListOf<Float>()
            val candidateDescStarts = mutableListOf<Float>()

            for (tokens in tokenLines) {
                val first = tokens.first()
                val startsNearLeftMargin = first.startX <= minLineStartX + 20f
                val looksLikeProductCode = first.text.matches(codePattern) &&
                    first.text.any { it.isDigit() }

                if (startsNearLeftMargin && looksLikeProductCode) {
                    if (tokens.size == 1) {
                        candidateCodeEnds.add(first.endX)
                    } else {
                        val second = tokens[1]
                        val gap = second.startX - first.endX
                        if (gap >= 5.5f) {
                            candidateCodeEnds.add(first.endX)
                            candidateDescStarts.add(second.startX)
                        }
                    }
                }
            }

            // Also include continuation lines that start significantly to the right of the code margin
            val maxCodeEnd = candidateCodeEnds.maxOrNull()
            if (maxCodeEnd != null) {
                for (tokens in tokenLines) {
                    val firstStart = tokens.first().startX
                    if (firstStart > maxCodeEnd + 3f) {
                        candidateDescStarts.add(firstStart)
                    }
                }
            }

            val minDescStart = candidateDescStarts.minOrNull()
            if (maxCodeEnd != null && minDescStart != null && minDescStart > maxCodeEnd) {
                return (maxCodeEnd + minDescStart) / 2f
            }

            if (maxCodeEnd != null) {
                return maxCodeEnd + 4f
            }

            // Fallback: find the widest empty vertical X-gutter in the left portion of the table
            val allNonSpace = leftGlyphLists.flatten().filter { it.text.isNotBlank() }
            val searchUpperX = (bounds.descHeaderStartX + 16f).coerceAtMost(bounds.qtyHeaderStartX - 10f)
            val gutterMid = findWidestVerticalGutter(allNonSpace, minLineStartX + 8f, searchUpperX)
            if (gutterMid != null) {
                return gutterMid
            }

            return bounds.codeHeaderEndX?.plus(4f) ?: (bounds.descHeaderStartX - 6f)
        }

        private fun findWidestVerticalGutter(
            glyphs: List<Glyph>,
            minSearchX: Float,
            maxSearchX: Float,
        ): Float? {
            if (glyphs.isEmpty() || maxSearchX <= minSearchX) return null
            val intervals = glyphs
                .map { it.x to it.endX }
                .sortedBy { it.first }

            // Merge overlapping glyph X-intervals
            val merged = mutableListOf<Pair<Float, Float>>()
            for ((start, end) in intervals) {
                val last = merged.lastOrNull()
                if (last == null || start > last.second) {
                    merged.add(start to end)
                } else {
                    merged[merged.lastIndex] = last.first to maxOf(last.second, end)
                }
            }

            var bestGap = 0f
            var bestMid: Float? = null
            for (i in 0 until merged.size - 1) {
                val gapStart = merged[i].second
                val gapEnd = merged[i + 1].first
                val gap = gapEnd - gapStart
                val mid = (gapStart + gapEnd) / 2f
                if (mid in minSearchX..maxSearchX && gap > bestGap && gap >= 4f) {
                    bestGap = gap
                    bestMid = mid
                }
            }
            return bestMid
        }

        private fun splitCodeAndDescription(
            glyphs: List<Glyph>,
            codeEndX: Float,
        ): Pair<String, String> {
            val cCode = mutableListOf<Glyph>()
            val cDesc = mutableListOf<Glyph>()
            for (g in glyphs) {
                val cx = (g.x + g.endX) / 2f
                if (cx < codeEndX) {
                    cCode.add(g)
                } else {
                    cDesc.add(g)
                }
            }
            return joinGlyphs(cCode).trim() to joinGlyphs(cDesc).trim()
        }

        private fun groupIntoTokens(glyphs: List<Glyph>): List<WordToken> {
            val nonSpace = glyphs
                .filter { it.text.isNotBlank() }
                .sortedBy { it.x }
            if (nonSpace.isEmpty()) return emptyList()

            val tokens = mutableListOf<WordToken>()
            var current = mutableListOf(nonSpace.first())

            for (i in 1 until nonSpace.size) {
                val g = nonSpace[i]
                val prev = current.last()
                val gap = g.x - prev.endX
                if (gap > 2.2f) {
                    tokens.add(buildToken(current))
                    current = mutableListOf(g)
                } else {
                    current.add(g)
                }
            }
            tokens.add(buildToken(current))
            return tokens
        }

        private fun buildToken(glyphs: List<Glyph>): WordToken {
            val text = glyphs.joinToString("") { it.text }.trim()
            return WordToken(
                text = text,
                startX = glyphs.minOf { it.x },
                endX = glyphs.maxOf { it.endX },
                glyphs = glyphs,
            )
        }

        private fun groupIntoLines(glyphs: List<Glyph>): List<VisualLine> {
            val sorted = glyphs.sortedWith(compareBy<Glyph> { it.y }.thenBy { it.x })
            val lines = mutableListOf<VisualLine>()
            for (g in sorted) {
                val last = lines.lastOrNull()
                if (last != null && abs(last.y - g.y) <= 3.5f) {
                    last.glyphs.add(g)
                } else {
                    lines.add(VisualLine(y = g.y, glyphs = mutableListOf(g)))
                }
            }
            for (line in lines) {
                line.glyphs.sortBy { it.x }
            }
            return lines
        }

        private fun findPhraseX(glyphs: List<Glyph>, phrase: String): Pair<Float, Float>? {
            val lineGroups = groupIntoLines(glyphs)
            for (line in lineGroups) {
                val nonSpace = line.glyphs.filter { it.text.isNotBlank() }
                val joined = nonSpace.joinToString("") { it.text }.uppercase()
                val idx = joined.indexOf(phrase.uppercase())
                if (idx >= 0) {
                    // Map character index back to glyph range
                    var charCount = 0
                    var startX: Float? = null
                    var endX = 0f
                    val targetEnd = idx + phrase.length
                    for (g in nonSpace) {
                        val len = g.text.length
                        if (charCount + len > idx && charCount < targetEnd) {
                            if (startX == null) startX = g.x
                            endX = g.endX
                        }
                        charCount += len
                    }
                    if (startX != null) {
                        return startX to endX
                    }
                }
            }
            return null
        }
    }

    private fun joinGlyphs(glyphs: List<Glyph>): String {
        if (glyphs.isEmpty()) return ""
        val sorted = glyphs.sortedBy { it.x }
        val sb = StringBuilder()
        var prevEnd: Float? = null
        for (g in sorted) {
            if (prevEnd != null) {
                val gap = g.x - prevEnd
                if (gap > 2.2f && sb.isNotEmpty() && sb.last() != ' ' && !g.text.startsWith(" ")) {
                    sb.append(' ')
                }
            }
            sb.append(g.text)
            prevEnd = g.endX
        }
        return sb.toString().replace(Regex("""\s+"""), " ").trim()
    }
}
