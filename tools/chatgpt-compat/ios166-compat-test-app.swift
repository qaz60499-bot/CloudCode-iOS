import UIKit
import Foundation
import Darwin
import Observation
import Synchronization

// Self-owned, independent local ABI probe. No network, accounts, keychain,
// third-party app data, extensions, system injection or privileged entitlements.
final class ObservableCounter: Observable, @unchecked Sendable {
    let registrar = ObservationRegistrar()
    private var storage = 0
    var number: Int {
        get {
            registrar.access(self, keyPath: \.number)
            return storage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.number) {
                storage = newValue
            }
        }
    }
}

@main
final class CompatProbeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var output: UITextView?

    private let title = "IPA Total isolated iOS16.6 probe v0.0.2"
    private let symbols = [
        "swift_conformsToProtocol2",
        "swift_getOpaqueTypeConformance2",
        "swift_getOpaqueTypeMetadata2",
        "swift_getTypeByMangledNameInContext2",
        "swift_getTypeByMangledNameInContextInMetadataState2"
    ]

    // Only this bundle's Documents directory is written, permitting USB readback
    // even if the process crashes after a later check. Never stores credentials.
    private func publish(_ lines: [String]) {
        let report = lines.joined(separator: "\n") + "\n"
        NSLog("IPACompatProbe: %@", report)
        if let documents = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: documents,
                                                      withIntermediateDirectories: true)
            do {
                try report.write(to: documents.appendingPathComponent("ios166-probe-result.txt"),
                                 atomically: true, encoding: .utf8)
            } catch {
                NSLog("IPACompatProbe: report persistence error: %@", String(describing: error))
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.output?.text = report
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        let view = UITextView(frame: root.view.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.text = title + "\nChecking self-contained Swift ABI…"
        root.view.addSubview(view)
        output = view

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        let head = [
            title,
            "bundle: " + (Bundle.main.bundleIdentifier ?? "UNKNOWN"),
            "OS: " + ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        publish(head + ["stage=LAUNCHED", "on-device semantics=IN PROGRESS"])

        // This closure is intentionally created before the first write: the
        // Observation registrar must fire exactly once for one-shot tracking.
        let model = Mutex<ObservableCounter>(ObservableCounter())
        let notifications = Mutex<Int>(0)
        let initial = model.withLock { object in
            withObservationTracking({ object.number }, onChange: {
                notifications.withLock { $0 += 1 }
            })
        }
        publish(head + ["stage=OBSERVATION_TRACKING_ESTABLISHED",
                        "initial=\(initial)"])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: 256) { _ in
                model.withLock { $0.number += 1 }
            }
            let final = model.withLock { $0.number }
            let callbacks = notifications.withLock { $0 }
            let countPass = initial == 0 && final == 256 && callbacks == 1
            let typeName = String(reflecting: type(of: model))
            let metadataPass = typeName.contains("Mutex<") && typeName.contains("ObservableCounter")

            var lines = head + [
                "stage=CONCURRENCY_FINISHED",
                "Mutex 256 and one-shot Observation: " + (countPass ? "PASS" : "FAIL"),
                "initial=\(initial) final=\(final) onChange=\(callbacks)",
                "Swift generic metadata: " + (metadataPass ? "PASS" : "FAIL"),
                "metadata=" + typeName
            ]
            self?.publish(lines)

            guard let frameworks = Bundle.main.privateFrameworksURL else {
                lines.append("PAC shim dlopen: FAIL (Frameworks URL unavailable)")
                lines.append("PAC shim actual function calls: NOT TESTED")
                self?.publish(lines + ["stage=FINISHED_WITH_ERRORS"])
                return
            }

            let path = frameworks.appendingPathComponent("ChatGPTCompatibility.dylib").path
            // dlopen is a real dyld / dependency / code-signature check, but
            // dlsym does not establish correctness of PAC or Swift ABI calls.
            _ = dlerror()
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                let message = dlerror().map { String(cString: $0) } ?? "dyld returned no reason"
                lines.append("PAC shim dlopen: FAIL")
                lines.append("dyld: " + message)
                lines.append("PAC shim actual function calls: NOT TESTED")
                self?.publish(lines + ["stage=FINISHED_WITH_ERRORS"])
                return
            }
            lines.append("PAC shim dlopen: PASS")
            var found = 0
            for name in self?.symbols ?? [] {
                _ = dlerror()
                let resolved = name.withCString { dlsym(handle, $0) != nil }
                if resolved { found += 1 }
                lines.append("dlsym " + name + ": " + (resolved ? "PASS" : "FAIL"))
            }
            lines.append("PAC shim dlsym: \(found)/5 " + (found == 5 ? "PASS" : "FAIL"))
            lines.append("PAC shim actual function calls: NOT TESTED")
            lines.append("Official ChatGPT 1.2026.286: NOT LOADED")
            dlclose(handle)
            self?.publish(lines + ["stage=FINISHED"])
        }
        return true
    }
}
