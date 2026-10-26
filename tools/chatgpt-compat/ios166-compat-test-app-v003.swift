import UIKit
import Foundation
import Darwin
import Observation
import Synchronization

// Research-only iOS 16.6 application. Does not contain or launch ChatGPT.
// Never touches other application containers, credentials, network or entitlements.
final class ObservableCounter: Observable, @unchecked Sendable {
    let registrar = ObservationRegistrar()
    private var numberStorage = 0
    private var otherStorage = 0

    var number: Int {
        get {
            registrar.access(self, keyPath: \.number)
            return numberStorage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.number) {
                numberStorage = newValue
            }
        }
    }
    var other: Int {
        get {
            registrar.access(self, keyPath: \.other)
            return otherStorage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.other) {
                otherStorage = newValue
            }
        }
    }
}

private enum ProbeError: Error { case expected }

private struct ProbeResult {
    let name: String
    let status: String
    let detail: String
}

@main
final class CompatProbeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var root: UIViewController?
    private var phaseLabel: UILabel?
    private var statusLabels: [String: UILabel] = [:]
    private var detailsView: UITextView?
    private var detailsButton: UIButton?
    private var reportURL: URL?
    private var detailsVisible = false
    private var latestReport = ""
    private let fields = [
        "Launch", "Mutex 256", "Mutex contention", "Mutex throw/unlock",
        "Observation one-shot", "Observation rearm", "Swift metadata",
        "PAC dylib", "PAC exports 5/5", "PAC ABI calls", "Official ChatGPT"
    ]
    private let symbols = [
        "swift_conformsToProtocol2",
        "swift_getOpaqueTypeConformance2",
        "swift_getOpaqueTypeMetadata2",
        "swift_getTypeByMangledNameInContext2",
        "swift_getTypeByMangledNameInContextInMetadataState2"
    ]

    private func label(_ text: String, size: CGFloat = 15, bold: Bool = false) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.text = text
        return l
    }

    private func configureUI() {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        stack.addArrangedSubview(label("IPA Total | Compatibility Probe", size: 22, bold: true))
        let warning = label("INDEPENDENT TEST APP • NOT OFFICIAL CHATGPT", size: 12, bold: true)
        warning.textColor = .systemOrange
        stack.addArrangedSubview(warning)
        let info = label("v0.0.3  •  iOS " + ProcessInfo.processInfo.operatingSystemVersionString, size: 12)
        info.textColor = .secondaryLabel
        stack.addArrangedSubview(info)
        let phase = label("Starting isolated runtime checks…", size: 16, bold: true)
        phaseLabel = phase
        stack.addArrangedSubview(phase)
        for name in fields {
            let value = label(name + ": PENDING", size: 14)
            value.accessibilityIdentifier = "probe.status." + name.replacingOccurrences(of: " ", with: "-")
            value.textColor = .secondaryLabel
            statusLabels[name] = value
            stack.addArrangedSubview(value)
        }
        let button = UIButton(type: .system)
        button.setTitle("Show diagnostic log", for: .normal)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(toggleDetails), for: .touchUpInside)
        detailsButton = button
        stack.addArrangedSubview(button)
        let details = UITextView()
        details.isEditable = false
        details.isScrollEnabled = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.backgroundColor = .secondarySystemGroupedBackground
        details.layer.cornerRadius = 8
        details.isHidden = true
        details.text = "Diagnostics pending."
        detailsView = details
        stack.addArrangedSubview(details)
        let export = UIButton(type: .system)
        export.setTitle("Export own diagnostic report", for: .normal)
        export.contentHorizontalAlignment = .leading
        export.addTarget(self, action: #selector(exportReport), for: .touchUpInside)
        stack.addArrangedSubview(export)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        self.root = vc
    }

    @objc private func toggleDetails() {
        detailsVisible.toggle()
        detailsView?.isHidden = !detailsVisible
        detailsButton?.setTitle(detailsVisible ? "Hide diagnostic log" : "Show diagnostic log", for: .normal)
    }

    @objc private func exportReport() {
        guard let reportURL, FileManager.default.fileExists(atPath: reportURL.path),
              let root else { return }
        let sheet = UIActivityViewController(activityItems: [reportURL], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = root.view
        root.present(sheet, animated: true)
    }

    private func publish(stage: String, results: [ProbeResult], lines: [String]) {
        let report = (["IPA Total isolated probe 0.0.3",
                       "bundle=" + (Bundle.main.bundleIdentifier ?? "UNKNOWN"),
                       "OS=" + ProcessInfo.processInfo.operatingSystemVersionString,
                       "stage=" + stage] + lines + results.map {
                           $0.name + ": " + $0.status + " | " + $0.detail
                       }).joined(separator: "\n") + "\n"
        NSLog("IPACompatProbe: %@", report)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ios166-probe-result.txt")
        if let url {
            do { try report.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSLog("IPACompatProbe report write error: %@", String(describing: error)) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportURL = url
            self.latestReport = report
            self.phaseLabel?.text = "Stage: " + stage
            self.detailsView?.text = report
            for item in results {
                let value = self.statusLabels[item.name]
                value?.text = item.name + ": " + item.status
                    + (item.detail.isEmpty ? "" : " — " + item.detail)
                value?.textColor = item.status == "PASS" ? .systemGreen
                    : item.status == "FAIL" ? .systemRed : .secondaryLabel
            }
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                         [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureUI()
        var initial = [
            ProbeResult(name: "Launch", status: "PASS", detail: "UIKit is visible"),
            ProbeResult(name: "PAC ABI calls", status: "NOT TESTED", detail: "private ABI safety gate"),
            ProbeResult(name: "Official ChatGPT", status: "BLOCKED", detail: "never loaded")
        ]
        publish(stage: "LAUNCHED", results: initial, lines: ["scope=INDEPENDENT"])
        let model = Mutex<ObservableCounter>(ObservableCounter())
        let notifications = Mutex<Int>(0)
        let observed = model.withLock { object in
            withObservationTracking({ object.number }, onChange: {
                notifications.withLock { $0 += 1 }
            })
        }
        // CI and USB evidence marker: established before first mutation.
        publish(stage: "OBSERVATION_TRACKING_ESTABLISHED", results: initial,
                lines: ["initial=\(observed)"])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.concurrentPerform(iterations: 256) { _ in
                model.withLock { $0.number += 1 }
            }
            let final = model.withLock { $0.number }
            let callbacks = notifications.withLock { $0 }
            let countPass = observed == 0 && final == 256 && callbacks == 1
            initial.append(ProbeResult(name: "Mutex 256", status: countPass ? "PASS" : "FAIL",
                                       detail: "initial=\(observed) final=\(final)"))
            initial.append(ProbeResult(name: "Observation one-shot",
                                       status: countPass ? "PASS" : "FAIL",
                                       detail: "onChange=\(callbacks)"))
            let contended = model.withLock { _ in
                model.withLockIfAvailable { $0.number } == nil
            }
            initial.append(ProbeResult(name: "Mutex contention",
                                       status: contended ? "PASS" : "FAIL",
                                       detail: "non-blocking acquisition while locked"))
            let throwable = Mutex<Int>(0)
            var caught = false
            do {
                try throwable.withLock { (value: inout Int) -> Void in
                    value = 7
                    throw ProbeError.expected
                }
            } catch ProbeError.expected { caught = true }
            catch { caught = false }
            let unlocked = throwable.withLockIfAvailable { $0 } == 7
            initial.append(ProbeResult(name: "Mutex throw/unlock",
                                       status: (caught && unlocked) ? "PASS" : "FAIL",
                                       detail: "expected throw; reacquire=\(unlocked)"))

            // Re-arm tracking after the first notification. Mutation to an
            // unrelated property must NOT trigger the number observer.
            let separate = ObservableCounter()
            let updates = Mutex<Int>(0)
            let first = withObservationTracking({ separate.number }, onChange: {
                updates.withLock { $0 += 1 }
            })
            separate.other = 3
            let unrelated = updates.withLock { $0 }
            separate.number = 1
            let firstCount = updates.withLock { $0 }
            let second = withObservationTracking({ separate.number }, onChange: {
                updates.withLock { $0 += 1 }
            })
            separate.number = 2
            let secondCount = updates.withLock { $0 }
            let rearmPass = first == 0 && unrelated == 0 && firstCount == 1
                && second == 1 && secondCount == 2
            initial.append(ProbeResult(name: "Observation rearm",
                                       status: rearmPass ? "PASS" : "FAIL",
                                       detail: "unrelated=\(unrelated) callbacks=\(secondCount)"))
            let typeName = String(reflecting: type(of: model))
            let metadataPass = typeName.contains("Mutex<") && typeName.contains("ObservableCounter")
            initial.append(ProbeResult(name: "Swift metadata",
                                       status: metadataPass ? "PASS" : "FAIL",
                                       detail: typeName))
            self.publish(stage: "CONCURRENCY_FINISHED", results: initial,
                         lines: ["initial=\(observed) final=\(final) onChange=\(callbacks)"])
            guard let frameworks = Bundle.main.privateFrameworksURL else {
                initial.append(ProbeResult(name: "PAC dylib", status: "FAIL", detail: "no Frameworks URL"))
                self.publish(stage: "FINISHED_WITH_ERRORS", results: initial, lines: [])
                return
            }
            let path = frameworks.appendingPathComponent("ChatGPTCompatibility.dylib").path
            _ = dlerror()
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown dyld error"
                initial.append(ProbeResult(name: "PAC dylib", status: "FAIL", detail: reason))
                self.publish(stage: "FINISHED_WITH_ERRORS", results: initial, lines: [])
                return
            }
            initial.append(ProbeResult(name: "PAC dylib", status: "PASS", detail: "dlopen succeeded"))
            var found = 0
            var symbolsLog: [String] = []
            for name in self.symbols {
                _ = dlerror()
                let ok = name.withCString { dlsym(handle, $0) != nil }
                if ok { found += 1 }
                symbolsLog.append("dlsym " + name + ": " + (ok ? "PASS" : "FAIL"))
            }
            initial.append(ProbeResult(name: "PAC exports 5/5",
                                       status: found == 5 ? "PASS" : "FAIL",
                                       detail: "\(found)/5 dlsym only"))
            symbolsLog.append("PAC shim actual function calls: NOT TESTED")
            symbolsLog.append("Official ChatGPT 1.2026.286: NOT LOADED")
            dlclose(handle)
            self.publish(stage: "FINISHED", results: initial, lines: symbolsLog)
        }
        return true
    }
}
