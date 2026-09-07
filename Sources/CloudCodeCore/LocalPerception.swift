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
    public static func extract(metric: LocalFeedMetric, elements: [LocalPerceptionTextElement]) -> LocalFeedMetricExtraction? {
        let usable = elements.filter { $0.confidence >= 0.35 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return nil }

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
        guard let best = sorted.first else { return nil }
        if sorted.count > 1 {
            let second = sorted[1]
            // Fail closed when two different visible values are similarly plausible for the same metric.
            if best.extraction.value != second.extraction.value && abs(best.score - second.score) < 0.2 {
                return nil
            }
        }
        return best.extraction
    }

    public static func select(
        metric: LocalFeedMetric,
        selection: LocalFeedMetricSelection,
        samples: [[LocalPerceptionTextElement]]
    ) -> LocalFeedMetricSelectionResult? {
        guard samples.count >= 2, samples.count <= 8 else { return nil }
        var extractions: [LocalFeedMetricExtraction] = []
        for sample in samples {
            guard let extraction = extract(metric: metric, elements: sample) else { return nil }
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

    private static func containsAnchor(_ text: String, metric: LocalFeedMetric) -> Bool {
        let normalized = text.lowercased()
        return metric.anchors.contains { normalized.contains($0) }
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
