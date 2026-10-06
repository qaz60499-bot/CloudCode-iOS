import Foundation

/// Typed normalization over the existing AX / LocalVision OCR / screenshot / AppKnowledge evidence.
/// This is a facade only: it owns no second AX runtime, OCR runtime, screenshot backend, or authority.
public struct ObservationFrame: Codable, Equatable, Sendable {
    public enum ElementSource: String, Codable, Hashable, Sendable {
        case accessibility
        case localOCR
        case appKnowledge
    }

    public struct SemanticElement: Codable, Equatable, Sendable {
        public var text: String
        public var role: String?
        public var identifier: String?
        public var confidence: Double
        public var x: Double?
        public var y: Double?
        public var width: Double?
        public var height: Double?
        public var source: ElementSource

        public init(
            text: String,
            role: String? = nil,
            identifier: String? = nil,
            confidence: Double,
            x: Double? = nil,
            y: Double? = nil,
            width: Double? = nil,
            height: Double? = nil,
            source: ElementSource
        ) {
            self.text = text
            self.role = role
            self.identifier = identifier
            self.confidence = min(max(confidence, 0), 1)
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.source = source
        }
    }

    public enum AXFailureClass: String, Codable, Sendable {
        case none
        case unknownClient = "unknown_client"
        case transportTimeout = "transport_timeout"
        case semanticEmpty = "semantic_empty"
        case unsupported
        case temporaryFailure = "temporary_failure"
    }

    public struct AXEvidence: Codable, Equatable, Sendable {
        public var attempted: Bool
        public var succeeded: Bool
        public var failureClass: AXFailureClass
        public var backend: String?
        public var nodeCount: Int?
        public var semanticNodeCount: Int?
        public var latencyMS: Int?
        public var treeRevision: String?
    }

    public enum OCRStatus: String, Codable, Sendable {
        case notInvoked
        case recognized
        case availableEmpty
        case failed
    }

    public struct OCREvidence: Codable, Equatable, Sendable {
        public var invoked: Bool
        public var succeeded: Bool
        public var status: OCRStatus
        public var backend: String?
        public var region: String?
        public var recognitionLevel: String?
        public var elementCount: Int
        public var latencyMS: Int?
        public var cacheHit: Bool
        public var requestCoalesced: Bool
    }

    public struct ScreenshotEvidence: Codable, Equatable, Sendable {
        public var available: Bool
        public var sha256: String?
        public var byteCount: Int?
        public var latencyMS: Int?
    }

    public struct SourceLatency: Codable, Equatable, Sendable {
        public var screenshotMS: Int?
        public var axTotalMS: Int?
        public var ocrTotalMS: Int?
    }

    public struct DegradationState: Codable, Equatable, Sendable {
        public var axCircuitOpen: Bool
        public var ocrCircuitOpen: Bool
        public var fallbackReason: String?
    }

    public enum SemanticPresence: String, Codable, Sendable {
        case unknown
        case absent
        case present
    }

    public enum ComposerState: String, Codable, Sendable {
        case unknown
        case visible
        case focused
    }

    /// A light semantic projection over the same evidence already present in ObservationFrame.
    /// It is descriptive telemetry/state only and never grants permission to execute an action.
    public struct SemanticSurfaceSnapshot: Codable, Equatable, Sendable {
        public var identity: String?
        public var type: IOSInteractionSurface
        public var landmarks: [String]
        public var controls: [String]
        public var navigationState: String?
        public var composerState: ComposerState
        public var keyboardState: SemanticPresence
        public var modalState: SemanticPresence
        public var feedItemIdentity: String?
        public var confidence: Double
        public var evidenceSources: [ElementSource]
        public var ambiguous: Bool
    }

    public var foregroundBundleID: String?
    public var screenRevision: String?
    public var genericSurface: IOSInteractionSurface
    public var semanticSurface: String?
    public var semanticElements: [SemanticElement]
    public var ax: AXEvidence
    public var ocr: OCREvidence
    public var screenshot: ScreenshotEvidence
    public var sourceLatency: SourceLatency
    public var capturedAt: Date
    public var confidence: Double
    public var degradation: DegradationState
    /// Optional for backward-compatible decoding of earlier ObservationFrame payloads.
    public var surfaceSnapshot: SemanticSurfaceSnapshot?

    public var isFresh: Bool {
        Date().timeIntervalSince(capturedAt) <= 5
    }

    public func canReuseOCR(
        screenRevision requestedRevision: String?,
        region: String?,
        recognitionLevel: String?
    ) -> Bool {
        guard ocr.invoked,
              let screenRevision,
              let requestedRevision,
              screenRevision == requestedRevision else { return false }
        if let region, let existingRegion = ocr.region, region != existingRegion { return false }
        if let recognitionLevel, let existingLevel = ocr.recognitionLevel, recognitionLevel != existingLevel { return false }
        return true
    }
}

public enum PerceptionBrokerFacade {
    /// Normalize one existing tool result into an ObservationFrame. No new perception work is
    /// performed here; callers may use this frame to decide whether current evidence is reusable.
    public static func frame(
        from result: ToolResult,
        foregroundBundleID: String?,
        genericSurface: IOSInteractionSurface = .unknown,
        semanticSurface: String? = nil,
        axCircuitOpen: Bool = false,
        ocrCircuitOpen: Bool = false,
        capturedAt: Date = Date()
    ) -> ObservationFrame {
        let payload = result.payload
        let screenshotHash = nonEmpty(payload["sha256"])
            ?? nonEmpty(payload["frameSHA256"])
            ?? nonEmpty(payload["baselineSHA256"])
        let treeRevision = nonEmpty(payload["treeSHA256"])
            ?? nonEmpty(payload["treeHash"])
        let screenRevision = screenshotHash ?? treeRevision

        let axAttempted = bool(payload["perceptionAXAttempted"])
        let axSucceeded = bool(payload["perceptionAXSucceeded"])
        let ocrInvoked = bool(payload["perceptionOCRInvoked"])
        let ocrSucceeded = bool(payload["perceptionOCRSucceeded"])
        let ocrStatus = normalizedOCRStatus(payload["localVisionOCR"], invoked: ocrInvoked, succeeded: ocrSucceeded)
        let elements = decodeLocalOCRElements(payload["localVisionElements"])

        let combinedAXText = [
            result.summary,
            payload["error"],
            payload["diagnostic"],
            payload["perceptionFallbackReason"],
            payload["axFailureClass"]
        ].compactMap { $0 }.joined(separator: " ")

        let axEvidence = ObservationFrame.AXEvidence(
            attempted: axAttempted,
            succeeded: axSucceeded,
            failureClass: classifyAXFailure(
                attempted: axAttempted,
                succeeded: axSucceeded,
                text: combinedAXText,
                semanticNodeCount: payload["axSemanticNodeCount"].flatMap(Int.init),
                fallbackReason: payload["perceptionFallbackReason"]
            ),
            backend: nonEmpty(payload["axBackend"]),
            nodeCount: payload["axNodeCount"].flatMap(Int.init),
            semanticNodeCount: payload["axSemanticNodeCount"].flatMap(Int.init),
            latencyMS: payload["axLatencyMS"].flatMap(Int.init),
            treeRevision: treeRevision
        )

        let ocrEvidence = ObservationFrame.OCREvidence(
            invoked: ocrInvoked,
            succeeded: ocrSucceeded,
            status: ocrStatus,
            backend: nonEmpty(payload["localVisionBackend"]),
            region: nonEmpty(payload["localVisionRegion"]),
            recognitionLevel: nonEmpty(payload["localVisionRecognitionLevel"]),
            elementCount: max(0, payload["localVisionElementCount"].flatMap(Int.init) ?? elements.count),
            latencyMS: payload["perceptionOCRLatencyMS"].flatMap(Int.init)
                ?? payload["localVisionLatencyMS"].flatMap(Int.init),
            cacheHit: bool(payload["localVisionCacheHit"]),
            requestCoalesced: bool(payload["localVisionRequestCoalesced"])
        )

        let screenshotEvidence = ObservationFrame.ScreenshotEvidence(
            available: screenshotHash != nil || result.attachments?.contains(where: { $0.mimeType.lowercased().hasPrefix("image/") }) == true,
            sha256: screenshotHash,
            byteCount: payload["byteCount"].flatMap(Int.init),
            latencyMS: payload["screenshotMS"].flatMap(Int.init)
        )

        let localSufficient = bool(payload["perceptionLocalSufficient"])
        let confidence: Double
        if localSufficient && (axSucceeded || ocrSucceeded) {
            confidence = 0.9
        } else if axSucceeded || ocrSucceeded || screenshotEvidence.available {
            confidence = 0.6
        } else {
            confidence = 0.2
        }

        let snapshot = semanticSnapshot(
            payload: payload,
            genericSurface: genericSurface,
            semanticSurface: semanticSurface,
            elements: elements,
            axSucceeded: axSucceeded,
            confidence: confidence
        )

        return ObservationFrame(
            foregroundBundleID: foregroundBundleID ?? nonEmpty(payload["axForegroundBundleID"]),
            screenRevision: screenRevision,
            genericSurface: genericSurface,
            semanticSurface: semanticSurface,
            semanticElements: elements,
            ax: axEvidence,
            ocr: ocrEvidence,
            screenshot: screenshotEvidence,
            sourceLatency: .init(
                screenshotMS: screenshotEvidence.latencyMS,
                axTotalMS: axEvidence.latencyMS,
                ocrTotalMS: ocrEvidence.latencyMS
            ),
            capturedAt: capturedAt,
            confidence: confidence,
            degradation: .init(
                axCircuitOpen: axCircuitOpen,
                ocrCircuitOpen: ocrCircuitOpen,
                fallbackReason: nonEmpty(payload["perceptionFallbackReason"])
            ),
            surfaceSnapshot: snapshot
        )
    }

    public static func classifyAXFailure(
        attempted: Bool,
        succeeded: Bool,
        text: String,
        semanticNodeCount: Int? = nil,
        fallbackReason: String? = nil
    ) -> ObservationFrame.AXFailureClass {
        if succeeded { return .none }
        guard attempted else { return .none }
        let normalized = (text + " " + (fallbackReason ?? "")).lowercased()
        if normalized.contains("unknown client") || normalized.contains("unknown_client") {
            return .unknownClient
        }
        // A helper diagnostic may include configuration fields such as `timeoutSeconds` even when
        // waitpid observed a prompt exit. Semantic-empty AX is therefore stronger evidence than the
        // mere presence of the word "timeout" in structured transport diagnostics.
        if semanticNodeCount == 0
            || normalized.contains("semantic empty")
            || normalized.contains("semantically empty")
            || normalized.contains("empty-semantic-tree")
            || normalized.contains("no semantic/actionable")
            || normalized.contains("semantic/actionable tree insufficient")
            || normalized.contains("ax_transport_returned_semantically_empty_tree") {
            return .semanticEmpty
        }
        if normalized.contains("timed out")
            || normalized.contains("parenttimeout\":true")
            || normalized.contains("parenttimeout=true")
            || normalized.contains("helper timeout")
            || normalized.contains("transport timeout")
            || normalized.contains("transport_timeout") {
            return .transportTimeout
        }
        if normalized.contains("unsupported")
            || normalized.contains("required axruntime")
            || normalized.contains("symbols are unavailable")
            || normalized.contains("noexecutionroute") {
            return .unsupported
        }
        return .temporaryFailure
    }

    private static func semanticSnapshot(
        payload: [String: String],
        genericSurface: IOSInteractionSurface,
        semanticSurface: String?,
        elements: [ObservationFrame.SemanticElement],
        axSucceeded: Bool,
        confidence: Double
    ) -> ObservationFrame.SemanticSurfaceSnapshot {
        let keyboardState: ObservationFrame.SemanticPresence
        if let keyboard = payload["keyboardLikely"] {
            keyboardState = bool(keyboard) ? .present : .absent
        } else {
            keyboardState = .unknown
        }
        let composerState: ObservationFrame.ComposerState
        if bool(payload["composerFocusVerified"]) {
            composerState = .focused
        } else if genericSurface == .composer {
            composerState = .visible
        } else {
            composerState = .unknown
        }
        let modalState: ObservationFrame.SemanticPresence = (genericSurface == .sheet || genericSurface == .alert)
            ? .present
            : .unknown
        var sources = Set(elements.map(\.source))
        if axSucceeded { sources.insert(.accessibility) }
        let landmarks = Array(Set(elements
            .filter { $0.confidence >= 0.35 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted().prefix(16)
        let controls = Array(Set(elements.compactMap { element -> String? in
            guard let role = element.role?.lowercased(),
                  role.contains("button") || role.contains("field") || role.contains("control") else { return nil }
            let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? element.identifier : text
        })).sorted().prefix(12)
        let ambiguityText = [payload["perceptionFallbackReason"], payload["localVisionFailureClass"]]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let ambiguous = ambiguityText.contains("ambiguous") || ambiguityText.contains("multiple_match")
        let identity = nonEmpty(semanticSurface)
            ?? nonEmpty(payload["semanticSurface"])
            ?? (genericSurface == .unknown ? nil : genericSurface.rawValue)
        let feedIdentity = nonEmpty(payload["semanticIdentity"])
            ?? nonEmpty(payload["localMetricSelectedSample"]).map { "sample:\($0)" }

        return ObservationFrame.SemanticSurfaceSnapshot(
            identity: identity,
            type: genericSurface,
            landmarks: Array(landmarks),
            controls: Array(controls),
            navigationState: nonEmpty(payload["navigationState"]),
            composerState: composerState,
            keyboardState: keyboardState,
            modalState: modalState,
            feedItemIdentity: feedIdentity,
            confidence: ambiguous ? min(confidence, 0.45) : confidence,
            evidenceSources: sources.sorted { $0.rawValue < $1.rawValue },
            ambiguous: ambiguous
        )
    }

    private static func decodeLocalOCRElements(_ raw: String?) -> [ObservationFrame.SemanticElement] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let elements = try? JSONDecoder().decode([LocalPerceptionTextElement].self, from: data) else {
            return []
        }
        return elements.map {
            ObservationFrame.SemanticElement(
                text: $0.text,
                confidence: $0.confidence,
                x: $0.x,
                y: $0.y,
                width: $0.width,
                height: $0.height,
                source: .localOCR
            )
        }
    }

    private static func normalizedOCRStatus(_ raw: String?, invoked: Bool, succeeded: Bool) -> ObservationFrame.OCRStatus {
        guard invoked else { return .notInvoked }
        switch raw?.lowercased() {
        case "recognized": return .recognized
        case "available_empty": return .availableEmpty
        default: return succeeded ? .recognized : .failed
        }
    }

    private static func bool(_ raw: String?) -> Bool { raw == "true" || raw == "1" }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
}
