import Foundation

public enum HomeOSCapabilityID: String, Codable, CaseIterable, Sendable {
    case file = "homeos.file"
    case app = "homeos.app"
    case process = "homeos.process"
    case shell = "homeos.shell"
    case git = "homeos.git"
    case archive = "homeos.archive"
    case network = "homeos.network"
    case script = "homeos.script"
    case device = "homeos.device"
    case workspace = "homeos.workspace"
    case rootHelper = "homeos.root_helper"
}

public struct HomeOSCapabilitySnapshot: Codable, Equatable, Sendable {
    public var id: HomeOSCapabilityID
    public var status: CapabilityStatus
    public var detail: String
    public var backingCapabilities: [String]

    public init(id: HomeOSCapabilityID, status: CapabilityStatus, detail: String, backingCapabilities: [String]) {
        self.id = id
        self.status = status
        self.detail = detail
        self.backingCapabilities = backingCapabilities
    }
}

/// HomeOS is a facade over already verified Cloud Code capabilities. It never
/// elevates privilege and never bypasses CapabilityProbe, ToolRouter, PolicyEngine,
/// transaction/audit handling, confirmation, or final-state verification.
public enum HomeOSCapabilityLayer {
    public static func snapshots(from records: [CapabilityRecord]) -> [HomeOSCapabilitySnapshot] {
        var map: [String: CapabilityStatus] = [:]
        for record in records {
            if let existing = map[record.id], existing != record.status {
                map[record.id] = .unknown
            } else if map[record.id] == nil {
                map[record.id] = record.status
            }
        }
        func status(_ id: String) -> CapabilityStatus { map[id] ?? .unknown }
        func strongest(_ candidates: [CapabilityStatus]) -> CapabilityStatus {
            if candidates.contains(.available) { return .available }
            if candidates.contains(.deviceValidationRequired) { return .deviceValidationRequired }
            if candidates.contains(.unknown) { return .unknown }
            return .unavailable
        }
        return [
            .init(id: .file, status: strongest([status("filesystem.unrestricted"), status("filesystem.own_container")]), detail: "FileService/TransactionEngine backing; allowedRoot remains authoritative.", backingCapabilities: ["filesystem.unrestricted", "filesystem.own_container"]),
            .init(id: .app, status: strongest([status("apps.enumerate"), status("apps.launch"), status("apps.uninstall")]), detail: "Existing app resolver/private adapters with policy and postcondition checks.", backingCapabilities: ["apps.enumerate", "apps.launch", "apps.terminate", "apps.uninstall"]),
            .init(id: .process, status: strongest([status("apps.terminate"), status("execution.root_helper")]), detail: "Process operations require a verified lifecycle/root-helper backend.", backingCapabilities: ["apps.terminate", "execution.root_helper"]),
            .init(id: .shell, status: status("execution.ios_system"), detail: "Existing semantic ios_system route; not a privileged escape hatch.", backingCapabilities: ["execution.ios_system"]),
            .init(id: .git, status: .unavailable, detail: "No libgit2/MiniGit backend is linked yet; do not expose a fake Git capability.", backingCapabilities: []),
            .init(id: .archive, status: status("ipa.inspect"), detail: "ZIPFoundation/IPAService-backed archive inspection; mutations remain transactional.", backingCapabilities: ["ipa.inspect"]),
            .init(id: .network, status: status("network.urlsession"), detail: "Foundation URLSession availability is exposed through the primitive network.urlsession probe; endpoint policy and live reachability checks still apply.", backingCapabilities: ["network.urlsession"]),
            .init(id: .script, status: status("execution.ios_system"), detail: "Script execution is available only through verified shell/runtime adapters.", backingCapabilities: ["execution.ios_system"]),
            .init(id: .device, status: strongest([status("apps.enumerate"), status("data.keychain_scope")]), detail: "Device facts aggregate existing probes and never imply root by themselves.", backingCapabilities: ["apps.enumerate", "data.keychain_scope"]),
            .init(id: .workspace, status: status("filesystem.own_container"), detail: "Workspace root is app-controlled unless unrestricted filesystem access is actually verified.", backingCapabilities: ["filesystem.own_container", "filesystem.unrestricted"]),
            .init(id: .rootHelper, status: status("execution.root_helper"), detail: "Embedded root helper is exposed only after runtime UID 0/persona validation.", backingCapabilities: ["execution.root_helper"])
        ]
    }

    public static func records(from records: [CapabilityRecord]) -> [CapabilityRecord] {
        snapshots(from: records).map { snapshot in
            CapabilityRecord(id: snapshot.id.rawValue, domain: .execution, status: snapshot.status, detail: snapshot.detail)
        }
    }
}
