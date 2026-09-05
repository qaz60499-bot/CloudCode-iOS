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
        func allRequired(_ candidates: [CapabilityStatus]) -> CapabilityStatus {
            guard !candidates.isEmpty else { return .unavailable }
            if candidates.allSatisfy({ $0 == .available }) { return .available }
            if candidates.contains(.deviceValidationRequired) { return .deviceValidationRequired }
            if candidates.contains(.unknown) { return .unknown }
            return .unavailable
        }
        func anyUsable(_ candidates: [CapabilityStatus]) -> CapabilityStatus {
            guard !candidates.isEmpty else { return .unavailable }
            if candidates.contains(.available) { return .available }
            if candidates.contains(.deviceValidationRequired) { return .deviceValidationRequired }
            if candidates.contains(.unknown) { return .unknown }
            return .unavailable
        }
        return [
            .init(id: .file, status: status("filesystem.own_container"), detail: "File facade is proven only for Cloud Code's own container here. Unrestricted access remains a separate primitive and is never inferred from this aggregate.", backingCapabilities: ["filesystem.own_container"]),
            .init(id: .app, status: anyUsable([status("apps.enumerate"), status("apps.launch"), status("apps.terminate"), status("apps.uninstall")]), detail: "App facade reflects whether at least one app operation is currently usable. Each concrete operation remains gated by its exact primitive, so an unavailable uninstall backend does not hide a verified launch or enumeration path.", backingCapabilities: ["apps.enumerate", "apps.launch", "apps.terminate", "apps.uninstall"]),
            .init(id: .process, status: allRequired([status("apps.terminate"), status("execution.root_helper")]), detail: "Broad process control is available only when both lifecycle and root-helper primitives are verified; exact operations remain separately gated.", backingCapabilities: ["apps.terminate", "execution.root_helper"]),
            .init(id: .shell, status: status("execution.ios_system"), detail: "Existing semantic ios_system route; not a privileged escape hatch.", backingCapabilities: ["execution.ios_system"]),
            .init(id: .git, status: .unavailable, detail: "No libgit2/MiniGit backend is linked yet; do not expose a fake Git capability.", backingCapabilities: []),
            .init(id: .archive, status: status("ipa.inspect"), detail: "ZIPFoundation/IPAService-backed archive inspection; mutations remain transactional.", backingCapabilities: ["ipa.inspect"]),
            .init(id: .network, status: status("network.urlsession"), detail: "Foundation URLSession availability is exposed through the primitive network.urlsession probe; endpoint policy and live reachability checks still apply.", backingCapabilities: ["network.urlsession"]),
            .init(id: .script, status: status("execution.ios_system"), detail: "Script execution is available only through verified shell/runtime adapters.", backingCapabilities: ["execution.ios_system"]),
            .init(id: .device, status: allRequired([status("apps.enumerate"), status("data.keychain_scope")]), detail: "Device aggregate is available only when all listed read primitives are verified and never implies root by itself.", backingCapabilities: ["apps.enumerate", "data.keychain_scope"]),
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
