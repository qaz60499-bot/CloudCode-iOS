import Foundation

/// Starts the detached authenticated PC-control root-helper bridge without blocking first-frame UI.
/// The worker itself owns the long-lived USB/loopback socket, so moving Cloud Code to the background
/// does not make the controller dependent on the SwiftUI app process remaining schedulable.
enum PCControlBootstrap {
    private static let lock = NSLock()
    private static var didSchedule = false

    static func startIfNeeded() {
        // Ordinary launches must never expose the PC-control socket. The Windows controller
        // opts in explicitly through DVT when it needs a temporary USB control session.
        guard ProcessInfo.processInfo.arguments.contains("--pc-control-bridge") else { return }

        lock.lock()
        guard !didSchedule else {
            lock.unlock()
            return
        }
        didSchedule = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("CloudCodeRootHelper", isDirectory: false)
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                NSLog("[PCControl] embedded root helper missing or not executable")
                return
            }

            var standardOutput: NSString?
            var standardError: NSString?
            let code = CloudCodeSpawnHelperWithSeparatedOutput(
                helperURL.path as NSString,
                ["pc-control-server-start"] as NSArray,
                true,
                4.0,
                &standardOutput,
                &standardError
            )
            let output = (standardOutput as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error = (standardError as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if code == 0 {
                NSLog("[PCControl] bridge ready %@", output)
            } else {
                NSLog("[PCControl] bridge start failed code=%ld detail=%@", code, error.isEmpty ? output : error)
            }
        }
    }
}
