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
    private struct Element: Codable, Sendable {
        var text: String
        var confidence: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    static func payload(for jpegData: Data, maximumElements: Int = 28) async -> [String: String] {
        let boundedMaximum = min(max(maximumElements, 1), 48)
        return await Task.detached(priority: .utility) {
            recognize(jpegData, maximumElements: boundedMaximum)
        }.value
    }

    private static func recognize(_ jpegData: Data, maximumElements: Int) -> [String: String] {
        let startedAt = Date()
        guard !jpegData.isEmpty,
              let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ["localVisionOCR": "unavailable_invalid_image"]
        }

        let pixelWidth = max(1, image.width)
        let pixelHeight = max(1, image.height)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.009
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
        } catch {
            return [
                "localVisionOCR": "unavailable_request_failed",
                "screenPointWidth": String(pixelWidth),
                "screenPointHeight": String(pixelHeight),
                "localVisionLatencyMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
            ]
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            let lhsTop = 1.0 - lhs.boundingBox.maxY
            let rhsTop = 1.0 - rhs.boundingBox.maxY
            if abs(lhsTop - rhsTop) > 0.015 { return lhsTop < rhsTop }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var elements: [Element] = []
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
            let x = box.minX * Double(pixelWidth)
            let y = (1.0 - box.maxY) * Double(pixelHeight)
            let width = box.width * Double(pixelWidth)
            let height = box.height * Double(pixelHeight)
            elements.append(Element(
                text: text,
                confidence: (Double(candidate.confidence) * 1_000).rounded() / 1_000,
                x: (x * 10).rounded() / 10,
                y: (y * 10).rounded() / 10,
                width: (width * 10).rounded() / 10,
                height: (height * 10).rounded() / 10
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
        return [
            "localVisionOCR": elements.isEmpty ? "available_empty" : "recognized",
            "localVisionElementCount": String(elements.count),
            "localVisionText": visibleTextParts.joined(separator: " | "),
            "localVisionElements": encodedElements,
            "screenPointWidth": String(pixelWidth),
            "screenPointHeight": String(pixelHeight),
            "localVisionCoordinateSpace": "screen_points_top_left",
            "localVisionLatencyMS": String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
        ]
    }
}
