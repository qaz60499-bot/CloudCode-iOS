import Foundation

public enum MockCapabilityProfiles {
    private static let granularGUI = GUIAutomationFeature.allCases.map(\.capabilityID)

    public static let sandbox = profile(
        available: ["filesystem.own_container", "data.keychain_scope", "automation.url_scheme", "ipa.inspect"],
        unavailable: ["filesystem.unrestricted", "apps.enumerate", "apps.resolve_data_container", "execution.ios_system", "execution.root_helper", "automation.gui"] + granularGUI
    )

    public static let trollStoreNoSandbox = profile(
        available: ["filesystem.own_container", "filesystem.shared_user_files", "filesystem.unrestricted", "apps.enumerate", "apps.resolve_bundle_path", "apps.resolve_data_container", "execution.spawn_helper", "ipa.inspect"],
        deviceValidation: ["execution.root_helper", "ipa.install", "automation.gui"] + granularGUI
    )

    public static let rootHelperAvailable = profile(
        available: ["filesystem.own_container", "filesystem.unrestricted", "apps.enumerate", "apps.resolve_bundle_path", "apps.resolve_data_container", "execution.spawn_helper", "execution.root_helper", "ipa.inspect", "ipa.install"],
        deviceValidation: ["automation.gui"] + granularGUI
    )

    public static let rootHelperUnavailable = profile(
        available: ["filesystem.own_container", "filesystem.unrestricted", "apps.enumerate", "apps.resolve_bundle_path", "apps.resolve_data_container", "ipa.inspect"],
        unavailable: ["execution.root_helper", "ipa.install"]
    )

    public static let guiAvailable = profile(
        available: ["filesystem.own_container", "automation.gui", "automation.xctest_wda", "ipa.inspect"] + granularGUI
    )

    public static let guiUnavailable = profile(
        available: ["filesystem.own_container", "ipa.inspect"],
        unavailable: ["automation.gui", "automation.xctest_wda"] + granularGUI
    )

    private static func profile(available: [String] = [], unavailable: [String] = [], deviceValidation: [String] = []) -> CapabilityProfile {
        var records: [CapabilityRecord] = []
        records += available.map { CapabilityRecord(id: $0, domain: domain(for: $0), status: .available, detail: "mock") }
        records += unavailable.map { CapabilityRecord(id: $0, domain: domain(for: $0), status: .unavailable, detail: "mock") }
        records += deviceValidation.map { CapabilityRecord(id: $0, domain: domain(for: $0), status: .deviceValidationRequired, detail: "mock") }
        return CapabilityProfile(records: records)
    }

    private static func domain(for id: String) -> CapabilityDomain {
        if id.hasPrefix("filesystem.") { return .filesystem }
        if id.hasPrefix("execution.") { return .execution }
        if id.hasPrefix("apps.") { return .apps }
        if id.hasPrefix("data.") { return .data }
        if id.hasPrefix("automation.") { return .automation }
        return .ipa
    }
}
