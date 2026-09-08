import Foundation
import Vision
import ImageIO
import CloudCodeCore

/// Bounded, on-device text observation for GUI screenshots.
///
/// The privileged screenshot helper already normalizes captures to point-sized JPEGs. Vision's
/// normalized bounding boxes can therefore be converted directly into the same screen-point
/// coordinate space consumed by gui.tap/gui.swipe without sending the image to a remote model.
/// This is observation data only: it never grants authority, never clicks by itself, and must not
/// be used to automate protected confirmation surfaces.
enum LocalVisionTextObservation {
    struct Observation: Sendable {
        var payload: [String: String]
        var elements: [LocalPerceptionTextElement]
    }

    private struct RecognitionConfiguration {
        var level: VNRequestTextRecognitionLevel
        var languages: [String]
    }

    private struct HelperResponse: Decodable {
        var status: String
        var screenPointWidth: Int
        var screenPointHeight: Int
        var latencyMS: Int
        var recognitionLevel: String?
        var backend: String?
        var cpuFallbackUsed: Bool?
        var errorDomain: String?
        var errorCode: Int?
        var primaryErrorDomain: String?
        var primaryErrorCode: Int?
        var elements: [LocalPerceptionTextElement]
    }

    // Vision language support is fixed for the running OS/Vision revision. Probe it once per
    // process instead of paying the supported-language lookup on every screenshot.
    private static let primaryRecognitionConfiguration: RecognitionConfiguration = {
        let preferred = ["zh-Hans", "en-US"]
        func supportedLanguages(_ level: VNRequestTextRecognitionLevel) -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            return (try? request.supportedRecognitionLanguages()) ?? []
        }
        let fast = supportedLanguages(.fast)
        if fast.contains("zh-Hans") {
            return RecognitionConfiguration(level: .fast, languages: preferred.filter { fast.contains($0) })
        }
        let accurate = supportedLanguages(.accurate)
        return RecognitionConfiguration(level: .accurate, languages: preferred.filter { accurate.contains($0) })
    }()

    static func payload(for jpegData: Data, maximumElements: Int = 28, regionInScreenPoints: CGRect? = nil) async -> [String: String] {
        await observe(for: jpegData, maximumElements: maximumElements, regionInScreenPoints: regionInScreenPoints).payload
    }

    static func observe(
        for jpegData: Data,
        maximumElements: Int = 28,
        regionInScreenPoints: CGRect? = nil,
        requiresText: Bool = false
    ) async -> Observation {
        let boundedMaximum = min(max(maximumElements, 1), 48)
        return await Task.detached(priority: .utility) {
            // Vision/Core ML is an App compute workload, not a privilege workload. Running OCR as
            // persona-99/root caused real-device failures in CoreVideo/CoreML even though capture
            // itself succeeded. Prefer the host App process with a CPU-only/background-friendly
            // request, then use the embedded helper only as an isolated secondary execution context.
            let inProcess = recognizeInProcess(
                jpegData,
                maximumElements: boundedMaximum,
                regionInScreenPoints: regionInScreenPoints
            )
            if Self.isUsable(inProcess, requiresText: requiresText) { return inProcess }
            if let helperObservation = recognizeWithHelper(
                jpegData,
                maximumElements: boundedMaximum,
                regionInScreenPoints: regionInScreenPoints
            ) {
                if Self.isUsable(helperObservation, requiresText: requiresText) { return helperObservation }
                var combined = inProcess
                combined.payload["localVisionSecondaryBackend"] = helperObservation.payload["localVisionBackend"] ?? "vision_helper_public_api"
                combined.payload["localVisionSecondaryStatus"] = helperObservation.payload["localVisionOCR"] ?? "unavailable"
                combined.payload["localVisionSecondaryErrorDomain"] = helperObservation.payload["localVisionErrorDomain"] ?? ""
                combined.payload["localVisionSecondaryErrorCode"] = helperObservation.payload["localVisionErrorCode"] ?? ""
                combined.payload["localVisionSecondaryDiagnostic"] = helperObservation.payload["localVisionHelperDiagnostic"] ?? ""
                return combined
            }
            return inProcess
        }.value
    }

    private static func isUsable(_ observation: Observation, requiresText: Bool) -> Bool {
        let status = observation.payload["localVisionOCR"] ?? ""
        if status == "recognized" { return true }
        return status == "available_empty" && !requiresText
    }

    private static func recognizeWithHelper(
        _ jpegData: Data,
        maximumElements: Int,
        regionInScreenPoints: CGRect?
    ) -> Observation? {
        let helper = EmbeddedVisionHelper.guiOCR(jpegData: jpegData, maximumElements: maximumElements)
        guard let json = helper.json,
              let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(HelperResponse.self, from: data) else {
            return Observation(payload: [
                "localVisionOCR": "unavailable_helper_failed",
                "localVisionBackend": "vision_helper_public_api",
                "localVisionHelperDiagnostic": String(helper.detail.prefix(512))
            ], elements: [])
        }

        let screenWidth = CGFloat(max(1, response.screenPointWidth))
        let screenHeight = CGFloat(max(1, response.screenPointHeight))
        let boundedRegion: CGRect? = regionInScreenPoints.flatMap { requested in
            let intersection = requested.standardized.intersection(CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
            return (!intersection.isNull && intersection.width >= 1 && intersection.height >= 1) ? intersection : nil
        }
        let elements = response.elements.prefix(maximumElements).filter { element in
            guard let boundedRegion else { return true }
            return CGRect(x: element.x, y: element.y, width: element.width, height: element.height).intersects(boundedRegion)
        }
        let boundedElements = Array(elements)
        let encodedElements: String
        if let encoded = try? JSONEncoder().encode(boundedElements), encoded.count <= 16 * 1024 {
            encodedElements = String(data: encoded, encoding: .utf8) ?? "[]"
        } else {
            encodedElements = "[]"
        }
        let visibleText = boundedElements.map(\.text).joined(separator: " | ")
        var payload: [String: String] = [
            "localVisionOCR": response.status == "recognized" && boundedElements.isEmpty ? "available_empty" : response.status,
            "localVisionElementCount": String(boundedElements.count),
            "localVisionText": String(visibleText.prefix(4_096)),
            "localVisionElements": encodedElements,
            "screenPointWidth": String(response.screenPointWidth),
            "screenPointHeight": String(response.screenPointHeight),
            "localVisionCoordinateSpace": "screen_points_top_left",
            "localVisionLatencyMS": String(max(0, response.latencyMS)),
            "localVisionRecognitionLevel": response.recognitionLevel ?? "accurate",
            "localVisionFallbackUsed": response.cpuFallbackUsed == true ? "true" : "false",
            "localVisionBackend": response.backend ?? "vision_helper_public_api",
            "localVisionRegion": boundedRegion.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "full_screen"
        ]
        if let errorDomain = response.errorDomain, !errorDomain.isEmpty {
            payload["localVisionErrorDomain"] = errorDomain
        }
        if let errorCode = response.errorCode {
            payload["localVisionErrorCode"] = String(errorCode)
        }
        if let primaryErrorDomain = response.primaryErrorDomain, !primaryErrorDomain.isEmpty {
            payload["localVisionPrimaryErrorDomain"] = primaryErrorDomain
        }
        if let primaryErrorCode = response.primaryErrorCode {
            payload["localVisionPrimaryErrorCode"] = String(primaryErrorCode)
        }
        return Observation(payload: payload, elements: boundedElements)
    }

    private static func coreVideoAllocationFailure(in error: NSError) -> NSError? {
        var current: NSError? = error
        for _ in 0..<4 {
            guard let candidate = current else { return nil }
            if candidate.domain == NSOSStatusErrorDomain, candidate.code == -6662 {
                return candidate
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private static func recognizeInProcess(_ jpegData: Data, maximumElements: Int, regionInScreenPoints: CGRect?) -> Observation {
        let startedAt = Date()
        guard !jpegData.isEmpty,
              let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Observation(payload: ["localVisionOCR": "unavailable_invalid_image"], elements: [])
        }

        let pixelWidth = max(1, image.width)
        let pixelHeight = max(1, image.height)
        let screenWidth = CGFloat(pixelWidth)
        let screenHeight = CGFloat(pixelHeight)
        var boundedRegion: CGRect?
        if let requestedRegion = regionInScreenPoints {
            let screenBounds = CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
            let region = requestedRegion.standardized.intersection(screenBounds)
            if !region.isNull, region.width >= 1, region.height >= 1 {
                boundedRegion = region
            }
        }

        func makeRequest(level: VNRequestTextRecognitionLevel, languages: [String]?) -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.009
            // Cross-app automation backgrounds this host on iOS 16. Keep Vision away from
            // GPU/ANE-backed paths that can fail in background with CoreVideo/CoreML errors.
            request.usesCPUOnly = true
            request.preferBackgroundProcessing = true
            if let languages, !languages.isEmpty {
                request.recognitionLanguages = languages
            } else {
                request.automaticallyDetectsLanguage = true
            }
            if let region = boundedRegion {
                request.regionOfInterest = CGRect(
                    x: region.minX / screenWidth,
                    y: 1.0 - (region.maxY / screenHeight),
                    width: region.width / screenWidth,
                    height: region.height / screenHeight
                )
            }
            return request
        }

        // `zh-Hans` is not guaranteed to be supported by Vision's `.fast` recognizer on every
        // iOS/Vision revision. Asking a fast request to use an unsupported language can make the
        // entire OCR request fail, which previously collapsed GUI planning into remote/text-only
        // coordinate guesses. Prefer fast only when it can actually recognize Simplified Chinese;
        // otherwise use accurate locally. Even the accurate local pass is far cheaper than a
        // provider round-trip or a multi-second AX timeout.
        let primary = Self.primaryRecognitionConfiguration
        var request = makeRequest(level: primary.level, languages: primary.languages)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        var fallbackUsed = false
        var firstFailure: NSError?
        var backend = "app_process_vision_cpu_only"
        do {
            try handler.perform([request])
        } catch {
            let primaryFailure = error as NSError
            firstFailure = primaryFailure
            fallbackUsed = true
            request = makeRequest(level: .fast, languages: nil)

            let fallbackImage: CGImage
            if Self.coreVideoAllocationFailure(in: primaryFailure) != nil {
                // -6662 is kCVReturnAllocationFailed. Retrying the same accurate pipeline is not
                // useful, but Apple's Vision fast path uses a smaller recognition model. Combine
                // that with an ImageIO thumbnail so the fallback materially reduces memory rather
                // than merely changing language settings. Bounding boxes remain normalized, so the
                // original screen-point dimensions still produce correct GUI coordinates.
                let maxFallbackDimension = 640
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxFallbackDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                fallbackImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
                backend = "app_process_vision_fast_thumbnail_fallback"
            } else {
                fallbackImage = image
                backend = "app_process_vision_fast_fallback"
            }

            do {
                // Use a fresh handler after a failed Vision request so fallback state is isolated.
                let fallbackHandler = VNImageRequestHandler(cgImage: fallbackImage, orientation: .up, options: [:])
                try fallbackHandler.perform([request])
            } catch {
                let finalFailure = error as NSError
                return Observation(payload: [
                    "localVisionOCR": "unavailable_request_failed",
                    "screenPointWidth": String(pixelWidth),
                    "screenPointHeight": String(pixelHeight),
                    "localVisionLatencyMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))),
                    "localVisionErrorDomain": finalFailure.domain,
                    "localVisionErrorCode": String(finalFailure.code),
                    "localVisionPrimaryErrorDomain": firstFailure?.domain ?? "",
                    "localVisionPrimaryErrorCode": firstFailure.map { String($0.code) } ?? "",
                    "localVisionBackend": backend
                ], elements: [])
            }
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            let lhsTop = 1.0 - lhs.boundingBox.maxY
            let rhsTop = 1.0 - rhs.boundingBox.maxY
            if abs(lhsTop - rhsTop) > 0.015 { return lhsTop < rhsTop }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var elements: [LocalPerceptionTextElement] = []
        var visibleTextParts: [String] = []
        var visibleTextCharacters = 0
        for observation in observations {
            guard elements.count < maximumElements,
                  let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.12 else { continue }
            let cleaned = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let text = String(cleaned.prefix(120))
            let box = observation.boundingBox
            // Vision uses normalized lower-left coordinates; GUI automation uses upper-left points.
            guard let screenRect = LocalPerceptionGeometry.topLeftScreenRect(
                normalizedLowerLeftX: Double(box.minX),
                y: Double(box.minY),
                width: Double(box.width),
                height: Double(box.height),
                screenWidth: Double(screenWidth),
                screenHeight: Double(screenHeight)
            ) else { continue }
            elements.append(LocalPerceptionTextElement(
                text: text,
                confidence: (Double(candidate.confidence) * 1_000).rounded() / 1_000,
                x: (screenRect.x * 10).rounded() / 10,
                y: (screenRect.y * 10).rounded() / 10,
                width: (screenRect.width * 10).rounded() / 10,
                height: (screenRect.height * 10).rounded() / 10
            ))
            if visibleTextCharacters < 4_096 {
                let remaining = max(0, 4_096 - visibleTextCharacters)
                let part = String(text.prefix(remaining))
                visibleTextParts.append(part)
                visibleTextCharacters += part.count + 3
            }
        }

        let encodedElements: String
        if let encoded = try? JSONEncoder().encode(elements), encoded.count <= 16 * 1024 {
            encodedElements = String(data: encoded, encoding: .utf8) ?? "[]"
        } else {
            encodedElements = "[]"
        }
        var payload: [String: String] = [
            "localVisionOCR": elements.isEmpty ? "available_empty" : "recognized",
            "localVisionElementCount": String(elements.count),
            "localVisionText": visibleTextParts.joined(separator: " | "),
            "localVisionElements": encodedElements,
            "screenPointWidth": String(pixelWidth),
            "screenPointHeight": String(pixelHeight),
            "localVisionCoordinateSpace": "screen_points_top_left",
            "localVisionLatencyMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))),
            "localVisionRecognitionLevel": request.recognitionLevel == .fast ? "fast" : "accurate",
            "localVisionFallbackUsed": fallbackUsed ? "true" : "false",
            "localVisionBackend": backend
        ]
        if let boundedRegion {
            payload["localVisionRegion"] = "\(boundedRegion.minX),\(boundedRegion.minY),\(boundedRegion.width),\(boundedRegion.height)"
        } else {
            payload["localVisionRegion"] = "full_screen"
        }
        return Observation(payload: payload, elements: elements)
    }
}
