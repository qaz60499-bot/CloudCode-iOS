import UIKit
import Foundation
import Darwin
import Observation
import Synchronization

// Independent test app. No network, accounts, Apple ID, keychain, production
// application data, process injection, global OS spoofing, or private entitlements.
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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        let view = UITextView(frame: root.view.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.text = "IPA Total — iOS 16.6 independent ABI probe\nStarting isolated checks…"
        root.view.addSubview(view)
        output = view

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        let protected = Mutex<ObservableCounter>(ObservableCounter())
        let notifications = Mutex<Int>(0)
        let before = protected.withLock { model in
            withObservationTracking({ model.number }, onChange: {
                notifications.withLock { $0 += 1 }
            })
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: 256) { _ in
                protected.withLock { $0.number += 1 }
            }
            let after = protected.withLock { $0.number }
            let hits = notifications.withLock { $0 }
            let runtime = String(reflecting: type(of: protected))
            let semanticallyCorrect = before == 0 && after == 256 && hits == 1
            var lines = [
                "OS: " + ProcessInfo.processInfo.operatingSystemVersionString,
                "Observable + Mutex test: " + (semanticallyCorrect ? "PASS" : "FAIL"),
                "initial=\(before) final=\(after) onChange=\(hits)",
                "Swift metadata: " + runtime,
            ]
            if let frameworkDir = Bundle.main.privateFrameworksURL {
                let lib = frameworkDir.appendingPathComponent("ChatGPTCompatibility.dylib").path
                if let handle = dlopen(lib, RTLD_NOW | RTLD_LOCAL) {
                    let names = [
                        "swift_conformsToProtocol2",
                        "swift_getOpaqueTypeConformance2",
                        "swift_getOpaqueTypeMetadata2",
                        "swift_getTypeByMangledNameInContext2",
                        "swift_getTypeByMangledNameInContextInMetadataState2",
                    ]
                    let present = names.filter { name in
                        name.withCString { dlsym(handle, $0) != nil }
                    }
                    lines.append("PAC shim dlopen: PASS")
                    lines.append("PAC shim exports: \(present.count)/\(names.count)")
                    dlclose(handle)
                } else {
                    lines.append("PAC shim dlopen: FAIL")
                    if let error = dlerror() { lines.append(String(cString: error)) }
                }
            } else {
                lines.append("Frameworks directory: NOT AVAILABLE")
            }
            lines.append("Independent tester only — official ChatGPT not loaded.")
            let report = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                self?.output?.text = report
            }
        }
        return true
    }
}
