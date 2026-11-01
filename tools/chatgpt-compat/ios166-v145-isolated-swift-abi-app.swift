/* V145 isolated iOS16.6 runtime ABI test host; NOT the official ChatGPT App.
 * Imports only self-written research FinanceKit/MarketplaceKit modules.
 * Both use fail-closed semantics. Never reads wallet, user account or system data.
 */
import UIKit
import Darwin
import Foundation
import FinanceKit
import MarketplaceKit

@main
@MainActor
final class V145SwiftABIApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var output: UITextView?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor(red:0.035, green:0.071, blue:0.13, alpha:1)
        let label = UITextView(frame:vc.view.bounds.insetBy(dx:18, dy:62))
        label.isEditable = false
        label.backgroundColor = .clear
        label.textColor = .white
        label.font = UIFont.monospacedSystemFont(ofSize:15, weight:.semibold)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = "IPA TOTAL V145\nRESEARCH HOST ONLY\niOS16.6\n\nSTARTING..."
        vc.view.addSubview(label)
        self.output = label
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        Task { await self.runResearchOnly() }
        return true
    }

    private func runResearchOnly() async {
        var lines = ["IPA TOTAL V145", "RESEARCH HOST ONLY", "NOT OFFICIAL CHATGPT", ""]
        let av = dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", RTLD_NOW | RTLD_LOCAL)
        let systemAVAudioPresent = NSClassFromString("AVAudioApplication") != nil
        lines.append(av != nil ? "Apple AVFAudio: LOAD PASS" : "Apple AVFAudio: NOT LOADABLE")
        lines.append("Apple audio class: " + (systemAVAudioPresent ? "PRESENT" : "ABSENT"))
        lines.append("No duplicate AVAudio class loaded")
        if av != nil { dlclose(av) }

        let dataAvailable = FinanceStore.isDataAvailable(.financialData)
        lines.append("Finance data availability: " + (dataAvailable ? "FAIL" : "DENIED PASS"))
        do {
            let state = try await FinanceStore.shared.authorizationStatus()
            lines.append("Finance status: " + (state == .denied ? "DENIED PASS" : "FAIL"))
        } catch {
            lines.append("Finance status throws: FAIL")
        }
        do {
            let state = try await FinanceStore.shared.requestAuthorization()
            lines.append("Finance authorization: " + (state == .denied ? "DENIED PASS" : "FAIL"))
        } catch {
            lines.append("Finance authorization throws: FAIL")
        }
        do {
            _ = try await AppDistributor.current
            lines.append("Marketplace current: FAIL (unexpected success)")
        } catch {
            lines.append("Marketplace current: UNSUPPORTED PASS")
        }
        lines.append("")
        lines.append("No wallet read, no login, no audio permission.")
        lines.append("This does not prove official app compatibility.")
        self.output?.text = lines.joined(separator:"\n")
    }
}
