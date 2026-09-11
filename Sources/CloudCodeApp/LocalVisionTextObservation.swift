import Foundation
import Vision
import ImageIO
import UIKit
import CryptoKit
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

    private actor Coordinator {
        private struct CacheEntry: Sendable {
            var observation: Observation
            var createdAt: Date
        }

        private var cache: [String: CacheEntry] = [:]
        private var inFlight: [String: Task<Observation, Never>] = [:]
        private var activeKey: String?
        private var coreVideoCircuitOpenUntil: Date?
        private let retention: TimeInterval = 3
        // Once the App-process Vision stack reports kCVReturnAllocationFailed, repeated retries on
        // every fresh screenshot only reproduce the same entitlement/resource failure. The
        // independent helper is still allowed on every request; this circuit suppresses only the
        // in-process fallback long enough for the GUI task to continue through screenshot/remote
        // vision instead of spending two recovery rounds on the same hard failure.
        private let coreVideoCircuitDuration: TimeInterval = 15

        func coreVideoCircuitRemainingMS() -> Int? {
            let now = Date()
            guard let until = coreVideoCircuitOpenUntil else { return nil }
            if until <= now {
                coreVideoCircuitOpenUntil = nil
                return nil
            }
            return max(1, Int(until.timeIntervalSince(now) * 1_000))
        }

        func resolve(
            key: String,
            bypassCoreVideoCircuit: Bool = false,
            operation: @escaping @Sendable () async -> Observation
        ) async -> Observation {
            let now = Date()
            cache = cache.filter { now.timeIntervalSince($0.value.createdAt) <= retention }
            if let until = coreVideoCircuitOpenUntil, until > now, !bypassCoreVideoCircuit {
                return Observation(payload: [
                    "localVisionOCR": "unavailable_corevideo_circuit_open",
                    "localVisionBackend": "vision_circuit_breaker",
                    "localVisionErrorDomain": NSOSStatusErrorDomain,
                    "localVisionErrorCode": "-6662",
                    "localVisionCircuitRemainingMS": String(max(0, Int(until.timeIntervalSince(now) * 1_000))),
                    "localVisionElementCount": "0"
                ], elements: [])
            }
            if let until = coreVideoCircuitOpenUntil, until <= now {
                coreVideoCircuitOpenUntil = nil
            }
            if var cached = cache[key]?.observation {
                cached.payload["localVisionCacheHit"] = "true"
                cached.payload["localVisionRequestCoalesced"] = "false"
                return cached
            }
            if let task = inFlight[key] {
                var shared = await task.value
                shared.payload["localVisionCacheHit"] = "false"
                shared.payload["localVisionRequestCoalesced"] = "true"
                return shared
            }
            if let activeKey, let activeTask = inFlight[activeKey] {
                _ = await activeTask.value
                return await resolve(key: key, bypassCoreVideoCircuit: bypassCoreVideoCircuit, operation: operation)
            }
            let task = Task { await operation() }
            activeKey = key
            inFlight[key] = task
            var value = await task.value
            inFlight[key] = nil
            if activeKey == key { activeKey = nil }
            if Self.hasCoreVideoAllocationFailure(value) {
                coreVideoCircuitOpenUntil = Date().addingTimeInterval(coreVideoCircuitDuration)
                value.payload["localVisionCircuitOpened"] = "true"
                value.payload["localVisionCircuitDurationMS"] = String(Int(coreVideoCircuitDuration * 1_000))
            }
            cache[key] = CacheEntry(observation: value, createdAt: Date())
            value.payload["localVisionCacheHit"] = "false"
            value.payload["localVisionRequestCoalesced"] = "false"
            return value
        }

        private static func hasCoreVideoAllocationFailure(_ observation: Observation) -> Bool {
            let finalDomain = observation.payload["localVisionErrorDomain"] ?? ""
            let finalCode = observation.payload["localVisionErrorCode"] ?? ""
            let primaryDomain = observation.payload["localVisionPrimaryErrorDomain"] ?? ""
            let primaryCode = observation.payload["localVisionPrimaryErrorCode"] ?? ""
            return (finalDomain == NSOSStatusErrorDomain && finalCode == "-6662")
                || (primaryDomain == NSOSStatusErrorDomain && primaryCode == "-6662")
        }
    }

    private static let coordinator = Coordinator()

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
    private static let recognitionConfigurations: (primary: RecognitionConfiguration, accurate: RecognitionConfiguration) = {
        let preferred = ["zh-Hans", "en-US"]
        func supportedLanguages(_ level: VNRequestTextRecognitionLevel) -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            return (try? request.supportedRecognitionLanguages()) ?? []
        }
        let fast = supportedLanguages(.fast)
        let accurateLanguages = supportedLanguages(.accurate)
        let accurate = RecognitionConfiguration(
            level: .accurate,
            languages: preferred.filter { accurateLanguages.contains($0) }
        )
        let primary: RecognitionConfiguration
        if fast.contains("zh-Hans") {
            primary = RecognitionConfiguration(level: .fast, languages: preferred.filter { fast.contains($0) })
        } else {
            primary = accurate
        }
        return (primary, accurate)
    }()

    private static var primaryRecognitionConfiguration: RecognitionConfiguration {
        recognitionConfigurations.primary
    }

    private static var accurateRecognitionConfiguration: RecognitionConfiguration {
        recognitionConfigurations.accurate
    }

    /// Initializes the process-local OCR capability state without capturing a screen, allocating an
    /// image tensor, or performing recognition. Cloud Code calls this once during normal bootstrap so
    /// the supported-language/recognizer policy follows the App lifecycle while all real OCR remains
    /// silent and on-demand. This function never creates an overlay or touches another App.
    static func prepare() {
        _ = primaryRecognitionConfiguration
    }

    static func payload(for jpegData: Data, maximumElements: Int = 28, regionInScreenPoints: CGRect? = nil) async -> [String: String] {
        await observe(for: jpegData, maximumElements: maximumElements, regionInScreenPoints: regionInScreenPoints).payload
    }

    static func observe(
        for jpegData: Data,
        maximumElements: Int = 28,
        regionInScreenPoints: CGRect? = nil,
        requiresText: Bool = false,
        forcePrecise: Bool = false
    ) async -> Observation {
        let boundedMaximum = min(max(maximumElements, 1), 48)
        let digest = SHA256.hash(data: jpegData).map { String(format: "%02x", $0) }.joined()
        let regionKey = regionInScreenPoints.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "full"
        let key = "\(digest)|\(regionKey)|\(boundedMaximum)|\(requiresText ? 1 : 0)|\(forcePrecise ? 1 : 0)"
        let hostActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        // The circuit guards failed App-process allocations; it must not suppress the independent
        // mobile helper. Same-image requests coalesce and the bridge bounds outstanding children.
        return await coordinator.resolve(key: key, bypassCoreVideoCircuit: true) {
            await Task.detached(priority: .utility) {
            let started = Date()
            let helper = recognizeWithHelper(jpegData, maximumElements: boundedMaximum,
                                             regionInScreenPoints: regionInScreenPoints,
                                             forcePrecise: forcePrecise)
            if var value = helper, Self.isUsable(value, requiresText: requiresText) {
                value.payload["localVisionHostState"] = hostActive ? "active" : "inactive_or_background"
                value.payload["localVisionInvoked"] = "true"
                return value
            }
            if let circuitRemainingMS = await coordinator.coreVideoCircuitRemainingMS() {
                var value = helper ?? Observation(payload: [
                    "localVisionOCR": "unavailable_corevideo_circuit_open",
                    "localVisionBackend": "vision_circuit_breaker",
                    "localVisionElementCount": "0"
                ], elements: [])
                value.payload["localVisionHostState"] = hostActive ? "active" : "inactive_or_background"
                value.payload["localVisionInvoked"] = "true"
                value.payload["localVisionInProcessSuppressed"] = "corevideo_circuit_open"
                value.payload["localVisionCircuitRemainingMS"] = String(circuitRemainingMS)
                value.payload["localVisionTotalLatencyMS"] = String(Int(Date().timeIntervalSince(started) * 1_000))
                return value
            }
#if targetEnvironment(simulator)
            var inProcess = recognizeInProcess(
                jpegData,
                maximumElements: boundedMaximum,
                regionInScreenPoints: regionInScreenPoints,
                forcePrecise: forcePrecise,
                lowMemoryMode: !hostActive
            )
            inProcess.payload["localVisionHostState"] = hostActive ? "active" : "inactive_or_background"
            inProcess.payload["localVisionInvoked"] = "true"
            inProcess.payload["localVisionFallbackUsed"] = "true"
            inProcess.payload["localVisionTotalLatencyMS"] = String(Int(Date().timeIntervalSince(started) * 1_000))
            inProcess.payload["localVisionSecondaryBackend"] = helper?.payload["localVisionBackend"] ?? "vision_helper_public_api"
            inProcess.payload["localVisionSecondaryStatus"] = helper?.payload["localVisionOCR"] ?? "unavailable"
            inProcess.payload["localVisionSecondaryErrorDomain"] = helper?.payload["localVisionErrorDomain"] ?? ""
            inProcess.payload["localVisionSecondaryErrorCode"] = helper?.payload["localVisionErrorCode"] ?? ""
            inProcess.payload["localVisionSecondaryDiagnostic"] = helper?.payload["localVisionHelperDiagnostic"] ?? ""
            return inProcess
#else
            // Build 119 produced a device crash in this fallback on iOS 16.6 while Vision/ANE was
            // tearing down: libdispatch trapped because an internal Vision semaphore was deallocated
            // while still in use. The isolated CloudCodeVisionHelper is the only supported device OCR
            // process boundary. If it fails, preserve its exact evidence and fall back to screenshot /
            // remote vision instead of running the same Vision stack inside the long-lived host App.
            var value = helper ?? Observation(payload: [
                "localVisionOCR": "unavailable_helper_failed",
                "localVisionBackend": "vision_helper_public_api",
                "localVisionElementCount": "0"
            ], elements: [])
            value.payload["localVisionHostState"] = hostActive ? "active" : "inactive_or_background"
            value.payload["localVisionInvoked"] = "true"
            value.payload["localVisionInProcessSuppressed"] = "device_vision_teardown_crash_guard"
            value.payload["localVisionFallbackUsed"] = "false"
            value.payload["localVisionTotalLatencyMS"] = String(Int(Date().timeIntervalSince(started) * 1_000))
            return value
#endif
            }.value
        }
    }

    private static func isUsable(_ observation: Observation, requiresText: Bool) -> Bool {
        let status = observation.payload["localVisionOCR"] ?? ""
        if status == "recognized" { return true }
        return status == "available_empty" && !requiresText
    }

    private static func recognizeWithHelper(
        _ jpegData: Data,
        maximumElements: Int,
        regionInScreenPoints: CGRect?,
        forcePrecise: Bool
    ) -> Observation? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Observation(payload: [
                "localVisionOCR": "unavailable_invalid_image",
                "localVisionBackend": "vision_helper_public_api"
            ], elements: [])
        }
        let fullWidth = CGFloat(max(1, sourceImage.width))
        let fullHeight = CGFloat(max(1, sourceImage.height))
        let fullBounds = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        let boundedRegion: CGRect? = regionInScreenPoints.flatMap { requested in
            let intersection = requested.standardized.intersection(fullBounds)
            return (!intersection.isNull && intersection.width >= 1 && intersection.height >= 1) ? intersection.integral : nil
        }

        var helperInput = jpegData
        var helperOrigin = CGPoint.zero
        var regionExecution = "full_frame"
        if let boundedRegion {
            if let cropped = croppedJPEG(sourceImage, region: boundedRegion) {
                helperInput = cropped
                helperOrigin = boundedRegion.origin
                regionExecution = "helper_input_crop"
            } else {
                // Preserve correctness if crop encoding fails: full-frame helper output is still filtered
                // below, but diagnostics make the more expensive fallback explicit.
                regionExecution = "post_filter_fallback"
            }
        }

        let helper = EmbeddedVisionHelper.guiOCR(
            jpegData: helperInput,
            maximumElements: maximumElements,
            forcePrecise: forcePrecise
        )
        guard let json = helper.json,
              let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(HelperResponse.self, from: data) else {
            return Observation(payload: [
                "localVisionOCR": "unavailable_helper_failed",
                "localVisionBackend": "vision_helper_public_api",
                "localVisionRegionExecution": regionExecution,
                "localVisionHelperDiagnostic": String(helper.detail.prefix(512))
            ], elements: [])
        }

        let mappedElements = response.elements.prefix(maximumElements).map { element in
            LocalPerceptionTextElement(
                text: element.text,
                confidence: element.confidence,
                x: element.x + Double(helperOrigin.x),
                y: element.y + Double(helperOrigin.y),
                width: element.width,
                height: element.height
            )
        }.filter { element in
            guard let boundedRegion else { return true }
            return CGRect(x: element.x, y: element.y, width: element.width, height: element.height).intersects(boundedRegion)
        }
        let boundedElements = Array(mappedElements)
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
            "screenPointWidth": String(Int(fullWidth)),
            "screenPointHeight": String(Int(fullHeight)),
            "localVisionCoordinateSpace": "screen_points_top_left",
            "localVisionLatencyMS": String(max(0, response.latencyMS)),
            "localVisionRecognitionLevel": response.recognitionLevel ?? "accurate",
            "localVisionFallbackUsed": response.cpuFallbackUsed == true ? "true" : "false",
            "localVisionBackend": response.backend ?? "vision_helper_public_api",
            "localVisionHelperDiagnostic": String(helper.detail.suffix(4096)),
            "localVisionRegion": boundedRegion.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "full_screen",
            "localVisionRegionExecution": regionExecution
        ]
        if regionExecution == "helper_input_crop", let boundedRegion {
            payload["localVisionHelperInputWidth"] = String(Int(boundedRegion.width))
            payload["localVisionHelperInputHeight"] = String(Int(boundedRegion.height))
        }
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

    private static func croppedJPEG(_ image: CGImage, region: CGRect) -> Data? {
        guard let cropped = image.cropping(to: region),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        return GUIAutomationPayloadPolicy.isValidScreenshotJPEG(data) ? data : nil
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

    private static func recognizeInProcess(_ jpegData: Data, maximumElements: Int, regionInScreenPoints: CGRect?, forcePrecise: Bool, lowMemoryMode: Bool) -> Observation {
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
        // Do not hand a 3MP full-screen capture to Vision just to learn normalized text boxes.
        // Build 98 repeatedly hit kCVReturnAllocationFailed (-6662) before its fallback could help.
        // ImageIO downsamples before Vision allocates its working buffers; normalized boxes are then
        // mapped back through the original screen dimensions below, so GUI coordinates stay exact.
        // Cross-app OCR normally runs while Cloud Code itself is backgrounded. Build 113 showed
        // repeated kCVReturnAllocationFailed(-6662) in that state, made worse by leaked root helpers.
        // Keep the foreground quality path unchanged, but bound the background working image much
        // more aggressively so Vision/CoreVideo does not need a full-screen intermediate surface.
        let primaryMaxDimension = lowMemoryMode ? (forcePrecise ? 960 : 640) : (forcePrecise ? 1_600 : 1_280)
        let primaryImage: CGImage
        let primaryDownsampled = max(pixelWidth, pixelHeight) > primaryMaxDimension
        if primaryDownsampled {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: primaryMaxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            primaryImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
        } else {
            primaryImage = image
        }
        var boundedRegion: CGRect?
        if let requestedRegion = regionInScreenPoints {
            let screenBounds = CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
            let region = requestedRegion.standardized.intersection(screenBounds)
            if !region.isNull, region.width >= 1, region.height >= 1 {
                boundedRegion = region
            }
        }

        func makeRequest(level: VNRequestTextRecognitionLevel, languages: [String]?, precise: Bool) -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            request.minimumTextHeight = precise ? 0.011 : (level == .fast ? 0.020 : 0.018)
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
        let precise = Self.accurateRecognitionConfiguration
        let requestedLevel: VNRequestTextRecognitionLevel = forcePrecise ? precise.level : primary.level
        let requestedLanguages: [String] = forcePrecise ? precise.languages : primary.languages
        var request = makeRequest(level: requestedLevel, languages: requestedLanguages, precise: forcePrecise)
        let handler = VNImageRequestHandler(cgImage: primaryImage, orientation: .up, options: [:])
        var fallbackUsed = false
        var firstFailure: NSError?
        var backend = primaryDownsampled ? "app_process_vision_cpu_only_thumbnail" : "app_process_vision_cpu_only"
        do {
            try handler.perform([request])
        } catch {
            let primaryFailure = error as NSError
            firstFailure = primaryFailure
            fallbackUsed = true
            request = makeRequest(level: .fast, languages: nil, precise: false)

            let fallbackImage: CGImage
            if Self.coreVideoAllocationFailure(in: primaryFailure) != nil {
                // -6662 is kCVReturnAllocationFailed. Retrying the same accurate pipeline is not
                // useful, but Apple's Vision fast path uses a smaller recognition model. Combine
                // that with an ImageIO thumbnail so the fallback materially reduces memory rather
                // than merely changing language settings. Bounding boxes remain normalized, so the
                // original screen-point dimensions still produce correct GUI coordinates.
                let maxFallbackDimension = lowMemoryMode ? 384 : 640
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
            "localVisionMinimumTextHeight": String(request.minimumTextHeight),
            "localVisionPass": forcePrecise ? "precise" : "fast_or_supported_primary",
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
