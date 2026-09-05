import Foundation

public enum GUIAutomationPayloadPolicy {
    /// The privileged helper encodes point-sized screenshots adaptively until they fit this bound.
    /// Keeping the same explicit limit in the app layer makes oversized/corrupt transport fail
    /// closed even when the helper process itself exits successfully.
    public static let maxScreenshotBytes = 700 * 1024

    public static func isValidScreenshotJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maxScreenshotBytes,
              data.count >= 3 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xFF
    }
}
