import CryptoKit
import Foundation

public enum GUIAutomationPayloadPolicy {
    /// The privileged helper encodes point-sized screenshots adaptively until they fit this bound.
    /// Keeping the same explicit limit in the app layer makes oversized/corrupt transport fail
    /// closed even when the helper process itself exits successfully.
    public static let maxScreenshotBytes = 700 * 1024

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidScreenshotJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maxScreenshotBytes,
              data.count >= 5 else { return false }
        let end = data.endIndex
        return data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xFF
            && data[data.index(end, offsetBy: -2)] == 0xFF
            && data[data.index(before: end)] == 0xD9
    }
}
