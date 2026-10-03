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
            // TrollStore/System-app installs can report the embedded helper as non-executable to
            // Foundation even though the privileged spawn bridge can execute that exact bundle
            // binary. Treat existence as the cheap preflight and let the bounded spawn result be
            // authoritative for executability/privilege failures.
            guard FileManager.default.fileExists(atPath: helperURL.path) else {
                NSLog("[PCControl] embedded root helper missing")
                return
            }

            var standardOutput: NSString?
            var standardError: NSString?
            let code = CloudCodeSpawnHelperWithSeparatedOutput(
                helperURL.path,
                ["pc-control-server-start"],
                true,
                7.0,
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
