import Foundation

public enum CompactVisibleCountParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?i)(?<![0-9.])([0-9]+(?:\.[0-9]+)?)\s*([kmbw万亿]?)(?![A-Za-z0-9.])"#,
        options: []
    )

    /// Parses one compact visible count from an OCR text fragment.
    ///
    /// This is intentionally conservative: ambiguous fragments containing more than one numeric
    /// token are rejected instead of guessing. The result is observation data only and never grants
    /// authority for a state-changing action.
    public static func parse(_ raw: String) -> Double? {
        let normalized = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains(":"),
              !normalized.contains("："),
              !normalized.contains("%") else { return nil }

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = expression.matches(in: normalized, options: [], range: range)
        guard matches.count == 1,
              let match = matches.first,
              let numberRange = Range(match.range(at: 1), in: normalized),
              let value = Double(normalized[numberRange]),
              value.isFinite,
              value >= 0 else { return nil }

        let suffix: String
        if let suffixRange = Range(match.range(at: 2), in: normalized) {
            suffix = String(normalized[suffixRange]).lowercased()
        } else {
            suffix = ""
        }
        let multiplier: Double
        switch suffix {
        case "k": multiplier = 1_000
        case "w", "万": multiplier = 10_000
        case "m": multiplier = 1_000_000
        case "亿": multiplier = 100_000_000
        case "b": multiplier = 1_000_000_000
        default: multiplier = 1
        }
        let result = value * multiplier
        return result.isFinite ? result : nil
    }
}

public struct LocalPerceptionTextElement: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

public enum LocalPerceptionTextMatchResult: Equatable, Sendable {
    case unique(LocalPerceptionTextElement)
    case notFound
    case ambiguous(Int)
}

public enum LocalPerceptionTextMatcher {
    public static func resolve(
        query rawQuery: String,
        mode: GUIElementMatchMode = .exact,
        elements: [LocalPerceptionTextElement]
    ) -> LocalPerceptionTextMatchResult {
        let query = normalized(rawQuery)
        guard !query.isEmpty else { return .notFound }
        let usable = elements.compactMap { element -> (element: LocalPerceptionTextElement, normalized: String)? in
            guard element.confidence >= 0.12, element.width > 0, element.height > 0 else { return nil }
            let candidate = normalized(element.text)
            guard !candidate.isEmpty else { return nil }
            return (element, candidate)
        }
        let primary = usable.filter { candidate in
            switch mode {
            case .exact: return candidate.normalized == query
            case .contains: return candidate.normalized.contains(query)
            }
        }.map(\.element)
        if primary.count == 1 { return .unique(primary[0]) }
        if primary.count > 1 { return .ambiguous(primary.count) }

        // Accurate Vision OCR can return a complete UI row as one box. Preserve exact matching
        // first, then accept a non-trivial requested label inside exactly one current-frame row.
        if mode == .exact, query.count >= 2 {
            let containment = usable.filter { $0.normalized.contains(query) }.map(\.element)
            if containment.count == 1 { return .unique(containment[0]) }
            if containment.count > 1 { return .ambiguous(containment.count) }
        }

        // Chinese UI labels may arrive with OCR-inserted whitespace/punctuation or as adjacent
        // observations on one visual row. Only after normal matching fails, compact those benign
        // separators and try a tightly bounded same-line merge. Multiple candidates still fail
        // closed instead of guessing between rows.
        let compactQuery = compactNormalized(rawQuery)
        if compactQuery.count >= 2 {
            let compactMatches = usable.filter { candidate in
                let compactCandidate = compactNormalized(candidate.element.text)
                switch mode {
                case .exact: return compactCandidate == compactQuery
                case .contains: return compactCandidate.contains(compactQuery)
                }
            }.map(\.element)
            if compactMatches.count == 1 { return .unique(compactMatches[0]) }
            if compactMatches.count > 1 { return .ambiguous(compactMatches.count) }

            let mergedMatches = mergedSameLineCandidates(elements: usable.map(\.element)).filter { candidate in
                let compactCandidate = compactNormalized(candidate.text)
                switch mode {
                case .exact: return compactCandidate == compactQuery
                case .contains: return compactCandidate.contains(compactQuery)
                }
            }
            if mergedMatches.count == 1 { return .unique(mergedMatches[0]) }
            if mergedMatches.count > 1 { return .ambiguous(mergedMatches.count) }
        }
        return .notFound
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func compactNormalized(_ value: String) -> String {
        normalized(value).unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                return
            }
            result.append(contentsOf: String(scalar))
        }
    }

    private static func mergedSameLineCandidates(elements: [LocalPerceptionTextElement]) -> [LocalPerceptionTextElement] {
        let sorted = elements.sorted { lhs, rhs in
            if lhs.centerY == rhs.centerY { return lhs.x < rhs.x }
            return lhs.centerY < rhs.centerY
        }
        var lines: [[LocalPerceptionTextElement]] = []
        for element in sorted {
            if let index = lines.firstIndex(where: { line in
                guard let first = line.first else { return false }
                let tolerance = max(8, min(first.height, element.height) * 0.65)
                return abs(first.centerY - element.centerY) <= tolerance
            }) {
                lines[index].append(element)
            } else {
                lines.append([element])
            }
        }

        var merged: [LocalPerceptionTextElement] = []
        for rawLine in lines {
            let line = rawLine.sorted { $0.x < $1.x }
            guard line.count >= 2 else { continue }
            for start in line.indices {
                var minX = line[start].x
                var minY = line[start].y
                var maxX = line[start].x + line[start].width
                var maxY = line[start].y + line[start].height
                var text = line[start].text
                var confidenceTotal = line[start].confidence
                var count = 1
                var previous = line[start]
                let upperBound = min(line.count, start + 4)
                guard start + 1 < upperBound else { continue }
                for index in (start + 1)..<upperBound {
                    let next = line[index]
                    let gap = next.x - (previous.x + previous.width)
                    let maxGap = max(28, max(previous.height, next.height) * 1.8)
                    if gap > maxGap { break }
                    if gap < -max(previous.width, next.width) * 0.35 { break }

                    text += next.text
                    confidenceTotal += next.confidence
                    count += 1
                    minX = min(minX, next.x)
                    minY = min(minY, next.y)
                    maxX = max(maxX, next.x + next.width)
                    maxY = max(maxY, next.y + next.height)
                    merged.append(LocalPerceptionTextElement(
                        text: text,
                        confidence: confidenceTotal / Double(count),
                        x: minX,
                        y: minY,
                        width: maxX - minX,
                        height: maxY - minY
                    ))
                    previous = next
                }
            }
        }
        return merged
    }
}

public enum LocalFeedMetric: String, Codable, Sendable {
    case likeCount
    case commentCount
    case shareCount

    fileprivate var anchors: [String] {
        switch self {
        case .likeCount: return ["点赞", "获赞", "喜欢", "likes", "like"]
        case .commentCount: return ["评论", "comments", "comment"]
        case .shareCount: return ["分享", "转发", "shares", "share"]
        }
    }
}

public enum LocalFeedMetricSelection: String, Codable, Sendable {
    case max
    case min
}

public struct LocalPerceptionScreenSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct LocalPerceptionScreenRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum LocalPerceptionGeometry {
    /// Converts a normalized Vision-style lower-left rectangle into the top-left screen-point
    /// coordinate space used by GUI automation. The input is intersected with the normalized unit
    /// image bounds so tiny detector overshoots cannot produce off-screen coordinates.
    public static func topLeftScreenRect(
        normalizedLowerLeftX x: Double,
        y: Double,
        width: Double,
        height: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> LocalPerceptionScreenRect? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              screenWidth.isFinite, screenHeight.isFinite,
              width > 0, height > 0, screenWidth > 0, screenHeight > 0 else { return nil }

        let minX = max(0, min(1, x))
        let minY = max(0, min(1, y))
        let maxX = max(0, min(1, x + width))
        let maxY = max(0, min(1, y + height))
        guard maxX > minX, maxY > minY else { return nil }

        return LocalPerceptionScreenRect(
            x: minX * screenWidth,
            y: (1 - maxY) * screenHeight,
            width: (maxX - minX) * screenWidth,
            height: (maxY - minY) * screenHeight
        )
    }
}

public struct LocalFeedMetricExtraction: Codable, Equatable, Sendable {
    public var value: Double
    public var sourceText: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var anchorText: String

    public init(value: Double, sourceText: String, confidence: Double, x: Double, y: Double, anchorText: String) {
        self.value = value
        self.sourceText = sourceText
        self.confidence = min(max(confidence, 0), 1)
        self.x = x
        self.y = y
        self.anchorText = anchorText
    }
}

public struct LocalFeedMetricSelectionResult: Codable, Equatable, Sendable {
    public var metric: LocalFeedMetric
    public var selection: LocalFeedMetricSelection
    public var values: [Double]
    /// One-based sample index matching gui.feedSample payloads.
    public var selectedSample: Int
    public var selectedValue: Double
    public var extractions: [LocalFeedMetricExtraction]

    public init(metric: LocalFeedMetric, selection: LocalFeedMetricSelection, values: [Double], selectedSample: Int, selectedValue: Double, extractions: [LocalFeedMetricExtraction]) {
        self.metric = metric
        self.selection = selection
        self.values = values
        self.selectedSample = selectedSample
        self.selectedValue = selectedValue
        self.extractions = extractions
    }
}

public enum LocalFeedMetricExtractor {
    /// Extracts a metric only when OCR supplies semantic anchor evidence in the same current frame.
    /// A naked number with no current-frame like/comment/share anchor is not classified.
    public static func extract(
        metric: LocalFeedMetric,
        elements: [LocalPerceptionTextElement],
        screenSize: LocalPerceptionScreenSize? = nil
    ) -> LocalFeedMetricExtraction? {
        let usable = elements.filter { $0.confidence >= 0.35 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rightRailUsable = elements.filter { $0.confidence >= 0.18 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !rightRailUsable.isEmpty else { return nil }

        var candidates: [(score: Double, extraction: LocalFeedMetricExtraction)] = []
        for anchor in usable where containsAnchor(anchor.text, metric: metric) {
            if let directValue = CompactVisibleCountParser.parse(anchor.text) {
                candidates.append((
                    score: 10 + anchor.confidence,
                    extraction: LocalFeedMetricExtraction(
                        value: directValue,
                        sourceText: anchor.text,
                        confidence: anchor.confidence,
                        x: anchor.centerX,
                        y: anchor.centerY,
                        anchorText: anchor.text
                    )
                ))
            }

            let verticalLimit = max(72, anchor.height * 6)
            let horizontalLimit = max(120, anchor.width * 4)
            for numeric in usable where numeric != anchor {
                guard let value = CompactVisibleCountParser.parse(numeric.text) else { continue }
                let dx = abs(numeric.centerX - anchor.centerX)
                let dy = abs(numeric.centerY - anchor.centerY)
                guard (dx <= horizontalLimit && dy <= verticalLimit) else { continue }
                let distance = hypot(dx, dy)
                let score = 5 + min(anchor.confidence, numeric.confidence) - min(distance / 1_000, 0.9)
                candidates.append((
                    score: score,
                    extraction: LocalFeedMetricExtraction(
                        value: value,
                        sourceText: numeric.text,
                        confidence: min(anchor.confidence, numeric.confidence),
                        x: numeric.centerX,
                        y: numeric.centerY,
                        anchorText: anchor.text
                    )
                ))
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.extraction.confidence > rhs.extraction.confidence }
            return lhs.score > rhs.score
        }
        guard let best = sorted.first else {
            return extractFromRightRail(metric: metric, usable: rightRailUsable, screenSize: screenSize)
        }
        if sorted.count > 1 {
            let second = sorted[1]
            // Fail closed when two different visible values are similarly plausible for the same metric.
            if best.extraction.value != second.extraction.value && abs(best.score - second.score) < 0.2 {
                return nil
            }
        }
        return best.extraction
    }

    public static func failureReason(
        metric: LocalFeedMetric,
        elements: [LocalPerceptionTextElement],
        screenSize: LocalPerceptionScreenSize?
    ) -> String? {
        if extract(metric: metric, elements: elements, screenSize: screenSize) != nil { return nil }
        let recognized = elements.filter {
            $0.confidence >= 0.18 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recognized.isEmpty else { return "ocr_completed_no_text" }

        if let screenSize,
           screenSize.width.isFinite, screenSize.height.isFinite,
           screenSize.width >= 200, screenSize.height >= 400 {
            let geometricRail = recognized.filter { element in
                element.centerX >= screenSize.width * 0.72
                    && element.centerX <= screenSize.width * 0.99
                    && element.centerY >= screenSize.height * 0.24
                    && element.centerY <= screenSize.height * 0.90
                    && element.width <= screenSize.width * 0.24
            }
            let countLike = geometricRail.filter { looksLikeCompactCountFragment($0.text) }
            let parsedCount = countLike.filter { CompactVisibleCountParser.parse($0.text) != nil }.count
            if countLike.count >= 3 && parsedCount < 3 {
                return "compact_count_normalization_failed"
            }
            if !geometricRail.isEmpty {
                return "right_rail_anchor_classification_failed"
            }
        }

        let semanticAnchors = recognized.filter { containsAnchor($0.text, metric: metric) }
        if !semanticAnchors.isEmpty {
            let nearbyCountLike = recognized.filter { element in
                guard looksLikeCompactCountFragment(element.text) else { return false }
                return semanticAnchors.contains { anchor in
                    abs(element.centerX - anchor.centerX) <= max(120, anchor.width * 4)
                        && abs(element.centerY - anchor.centerY) <= max(72, anchor.height * 6)
                }
            }
            if !nearbyCountLike.isEmpty,
               nearbyCountLike.allSatisfy({ CompactVisibleCountParser.parse($0.text) == nil }) {
                return "compact_count_normalization_failed"
            }
            return "metric_anchor_classification_failed"
        }
        return "right_rail_anchor_classification_failed"
    }

    public static func select(
        metric: LocalFeedMetric,
        selection: LocalFeedMetricSelection,
        samples: [[LocalPerceptionTextElement]],
        screenSizes: [LocalPerceptionScreenSize]? = nil
    ) -> LocalFeedMetricSelectionResult? {
        guard samples.count >= 2, samples.count <= 8 else { return nil }
        if let screenSizes, screenSizes.count != samples.count { return nil }
        var extractions: [LocalFeedMetricExtraction] = []
        for index in samples.indices {
            let screenSize = screenSizes?[index]
            guard let extraction = extract(metric: metric, elements: samples[index], screenSize: screenSize) else { return nil }
            extractions.append(extraction)
        }
        let values = extractions.map(\.value)
        let selectedOffset: Int
        switch selection {
        case .max:
            guard let offset = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
            selectedOffset = offset
        case .min:
            guard let offset = values.indices.min(by: { values[$0] < values[$1] }) else { return nil }
            selectedOffset = offset
        }
        return LocalFeedMetricSelectionResult(
            metric: metric,
            selection: selection,
            values: values,
            selectedSample: selectedOffset + 1,
            selectedValue: values[selectedOffset],
            extractions: extractions
        )
    }

    private static func extractFromRightRail(
        metric: LocalFeedMetric,
        usable: [LocalPerceptionTextElement],
        screenSize: LocalPerceptionScreenSize?
    ) -> LocalFeedMetricExtraction? {
        guard let screenSize,
              screenSize.width.isFinite, screenSize.height.isFinite,
              screenSize.width >= 200, screenSize.height >= 400 else { return nil }

        let rightRail = usable.compactMap { element -> (element: LocalPerceptionTextElement, value: Double)? in
            guard element.centerX >= screenSize.width * 0.72,
                  element.centerX <= screenSize.width * 0.99,
                  element.centerY >= screenSize.height * 0.24,
                  element.centerY <= screenSize.height * 0.90,
                  element.width <= screenSize.width * 0.24,
                  let value = CompactVisibleCountParser.parse(element.text) else { return nil }
            return (element, value)
        }.sorted { $0.element.centerY < $1.element.centerY }

        // Common short-video feeds expose like/comment/(favorite)/share as a right-edge vertical
        // numeric rail. We only infer semantics when the whole rail is structurally coherent;
        // arbitrary naked numbers remain unclassified. This is normalized geometry, never a
        // permanent screen coordinate or an authority to tap the icon itself.
        guard rightRail.count == 3 || rightRail.count == 4 else { return nil }
        let xValues = rightRail.map(\.element.centerX)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              maxX - minX <= screenSize.width * 0.14 else { return nil }
        for pair in zip(rightRail, rightRail.dropFirst()) {
            let gap = pair.1.element.centerY - pair.0.element.centerY
            guard gap >= screenSize.height * 0.035,
                  gap <= screenSize.height * 0.18 else { return nil }
        }
        guard let first = rightRail.first, let last = rightRail.last,
              last.element.centerY - first.element.centerY >= screenSize.height * 0.12 else { return nil }

        let slot: Int
        switch (metric, rightRail.count) {
        case (.likeCount, _): slot = 0
        case (.commentCount, _): slot = 1
        // With only three numeric slots, the final item can be favorite or share depending on
        // the current feed layout. Geometry alone cannot disambiguate that semantic role.
        case (.shareCount, 4): slot = 3
        default: return nil
        }
        let selected = rightRail[slot]
        let slotName: String
        switch metric {
        case .likeCount: slotName = "like"
        case .commentCount: slotName = "comment"
        case .shareCount: slotName = "share"
        }
        return LocalFeedMetricExtraction(
            value: selected.value,
            sourceText: selected.element.text,
            confidence: selected.element.confidence * 0.72,
            x: selected.element.centerX,
            y: selected.element.centerY,
            anchorText: "right_rail_\(rightRail.count)_slot_\(slotName)"
        )
    }

    private static func containsAnchor(_ text: String, metric: LocalFeedMetric) -> Bool {
        let normalized = text.lowercased()
        return metric.anchors.contains { normalized.contains($0) }
    }

    private static func looksLikeCompactCountFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,， kKmMbBwW万亿")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum LocalKeyboardHeuristic {
    /// Conservative OCR-only keyboard detector used after a bounded semantic composer-focus tap.
    /// It looks for many key-like labels distributed across multiple rows in the lower screen.
    /// A mere screenshot hash change is intentionally insufficient evidence of text-input focus.
    public static func isLikelyVisible(elements: [LocalPerceptionTextElement], screenHeight: Double) -> Bool {
        guard screenHeight.isFinite, screenHeight >= 200 else { return false }
        let lower = elements.filter {
            $0.confidence >= 0.12
                && $0.centerY >= screenHeight * 0.55
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lower.isEmpty else { return false }

        var keyEvidence = 0
        var rowBuckets = Set<Int>()
        for element in lower {
            let normalized = element.text
                .replacingOccurrences(of: "，", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "。", with: " ")
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "·", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var elementEvidence = 0
            for token in tokens {
                if isKeyLike(token) { elementEvidence += 1 }
            }
            if elementEvidence == 0,
               normalized.count >= 5,
               normalized.count <= 14,
               normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                // Vision can merge an entire QWERTY row into one OCR fragment.
                elementEvidence = min(normalized.count, 10)
            }
            if elementEvidence > 0 {
                keyEvidence += elementEvidence
                rowBuckets.insert(Int((element.centerY / max(24, screenHeight * 0.055)).rounded(.down)))
            }
        }
        return keyEvidence >= 8 && rowBuckets.count >= 2
    }

    private static func isKeyLike(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 8 else { return false }
        let lowered = token.lowercased()
        let namedKeys: Set<String> = [
            "space", "return", "enter", "delete", "shift", "abc", "123", "#+=", "空格", "换行", "发送", "删除", "中", "英"
        ]
        if namedKeys.contains(lowered) { return true }
        if token.count <= 2,
           token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            return true
        }
        return false
    }
}

public enum LocalPerceptionRoutingPolicy {
    /// AX is a structural source. When it has already answered the current observation question,
    /// running OCR is redundant work.
    public static func shouldInvokeOCR(axObservationSufficient: Bool) -> Bool {
        !axObservationSufficient
    }

    /// Remote visual reasoning is a fallback, not an automatic sequel to successful local parsing.
    public static func shouldAttachRemoteVision(localObservationSufficient: Bool, remoteVisionRequired: Bool) -> Bool {
        !(localObservationSufficient && !remoteVisionRequired)
    }
}
