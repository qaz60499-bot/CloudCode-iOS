import UIKit
import Foundation
import Darwin
import Observation
import Synchronization

// Self-authored, isolated compatibility container for iOS 16.6.
// No official ChatGPT executable, credentials, network calls or shared containers.
@main
final class ChatGPTIOS16LabDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let bundleID = "cc.guess.ipatotal.chatgpt166.lab"
    private let libraryNames = [
        "libswiftObservation.dylib",
        "libswiftSynchronization.dylib",
        "ChatGPTCompatibility.dylib"
    ]
    private let pacSymbols = [
        "swift_conformsToProtocol2",
        "swift_getOpaqueTypeConformance2",
        "swift_getOpaqueTypeMetadata2",
        "swift_getTypeByMangledNameInContext2",
        "swift_getTypeByMangledNameInContextInMetadataState2"
    ]
    private var loadedHandles: [UnsafeMutableRawPointer] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemGroupedBackground

        let header = UILabel()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = .boldSystemFont(ofSize: 23)
        header.numberOfLines = 0
        header.text = "ChatGPT iOS16 Lab\nIndependent research app"

        let reportView = UITextView()
        reportView.translatesAutoresizingMaskIntoConstraints = false
        reportView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        reportView.backgroundColor = .secondarySystemGroupedBackground
        reportView.isEditable = false
        reportView.text = "Running self-authored compatibility checks..."

        controller.view.addSubview(header)
        controller.view.addSubview(reportView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
            reportView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            reportView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            reportView.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            reportView.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        let report = verifyOwnRuntime()
        reportView.text = report
        NSLog("IPA_TOTAL_IOS166_LAB: %@", report)
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let output = directory.appendingPathComponent("ios166-lab-v001-result.txt")
            do { try report.write(to: output, atomically: true, encoding: .utf8) }
            catch { NSLog("IPA_TOTAL_IOS166_LAB_WRITE_FAIL: %@", String(describing: error)) }
        }
        return true
    }

    private func verifyOwnRuntime() -> String {
        var lines = [
            "IPA Total / ChatGPT iOS16 Lab 0.0.1",
            "bundle=\(Bundle.main.bundleIdentifier ?? "UNKNOWN")",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "official_chatgpt_binary=NOT_INCLUDED",
            "official_chatgpt_functionality=NOT_TESTED",
            "data_container=THIS_APP_ONLY",
            "arm64e_data_pac_hardware=NOT_TESTED",
            "swift_pac_descriptor_calls=NOT_TESTED"
        ]
        lines.append("bundle_identity=" + (Bundle.main.bundleIdentifier == bundleID ? "PASS" : "FAIL"))

        let counter = Mutex<Int>(0)
        counter.withLock { $0 += 1 }
        let value = counter.withLock { $0 }
        lines.append("synchronization_mutex=" + (value == 1 ? "PASS" : "FAIL"))

        _ = ObservationRegistrar()
        lines.append("observation_registrar_constructed=PASS")

        guard let frameworks = Bundle.main.privateFrameworksPath else {
            lines.append("frameworks_location=FAIL")
            return lines.joined(separator: "\n") + "\n"
        }
        for name in libraryNames {
            let path = (frameworks as NSString).appendingPathComponent(name)
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                lines.append("dlopen_\(name)=FAIL")
                continue
            }
            loadedHandles.append(handle)
            lines.append("dlopen_\(name)=PASS")
            if name == "ChatGPTCompatibility.dylib" {
                let count = pacSymbols.filter { dlsym(handle, $0) != nil }.count
                lines.append("pac_export_address_lookup=\(count == pacSymbols.count ? "PASS" : "FAIL") (\(count)/5)")
            }
        }
        lines.append("dyld_three_libraries_loaded=" +
                     (loadedHandles.count == libraryNames.count ? "PASS" : "FAIL"))
        lines.append("compatibility_level=SELF_AUTHORED_CONTAINER_ONLY")
        return lines.joined(separator: "\n") + "\n"
    }
}
