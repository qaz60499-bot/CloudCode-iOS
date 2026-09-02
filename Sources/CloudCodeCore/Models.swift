import Foundation
import CryptoKit

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case safe
    case balanced
    case full
}

public enum CapabilityStatus: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
    case deviceValidationRequired = "device_validation_required"
}

public enum CapabilityDomain: String, Codable, CaseIterable, Sendable {
    case filesystem
    case execution
    case apps
    case data
    case automation
    case ipa
}

public struct CapabilityRecord: Codable, Hashable, Sendable {
    public var id: String
    public var domain: CapabilityDomain
    public var status: CapabilityStatus
    public var detail: String

    public init(id: String, domain: CapabilityDomain, status: CapabilityStatus, detail: String) {
        self.id = id
        self.domain = domain
        self.status = status
        self.detail = detail
    }
}

public struct CapabilityProfile: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var records: [CapabilityRecord]

    public init(generatedAt: Date = Date(), records: [CapabilityRecord]) {
        self.generatedAt = generatedAt
        self.records = records
    }

    public func status(_ id: String) -> CapabilityStatus {
        records.first(where: { $0.id == id })?.status ?? .unknown
    }

    public func isAvailable(_ id: String) -> Bool {
        status(id) == .available
    }
}

public enum ResourceKind: String, Codable, Sendable {
    case app
    case container
    case file
    case directory
    case photo
    case ipa
    case archive
    case project
    case storageCategory
}

public struct ResourceID: Codable, Hashable, CustomStringConvertible, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct ResourceNode: Codable, Hashable, Identifiable, Sendable {
    public var id: ResourceID
    public var kind: ResourceKind
    public var displayName: String
    public var logicalLocation: String
    public var resolvedPath: String?
    public var ownerBundleID: String?
    public var byteSize: Int64?
    public var metadata: [String: String]

    public init(
        id: ResourceID,
        kind: ResourceKind,
        displayName: String,
        logicalLocation: String,
        resolvedPath: String? = nil,
        ownerBundleID: String? = nil,
        byteSize: Int64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.logicalLocation = logicalLocation
        self.resolvedPath = resolvedPath
        self.ownerBundleID = ownerBundleID
        self.byteSize = byteSize
        self.metadata = metadata
    }
}

public struct ResourceGraph: Codable, Equatable, Sendable {
    public var nodes: [ResourceNode]
    public var indexedAt: Date
    public var deepIndexedResourceIDs: Set<ResourceID>

    public init(nodes: [ResourceNode] = [], indexedAt: Date = Date(), deepIndexedResourceIDs: Set<ResourceID> = []) {
        self.nodes = nodes
        self.indexedAt = indexedAt
        self.deepIndexedResourceIDs = deepIndexedResourceIDs
    }

    public mutating func upsert(_ node: ResourceNode) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
    }
}

public enum AppExecutionRoute: String, Codable, Sendable {
    case structuredTool
    case cli
    case privateFramework
    case urlScheme
    case guiFallback
}

public struct AppKnowledge: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var appName: String
    public var bundleID: String
    public var supportedUTTypes: [String]
    public var urlSchemes: [String]
    public var preferredRoutes: [AppExecutionRoute]
    public var successRate: Double
    public var estimatedCost: Double
    public var knownPages: [String]
    public var failureNotes: [String]
    public var appVersion: String?

    public init(
        appName: String,
        bundleID: String,
        supportedUTTypes: [String] = [],
        urlSchemes: [String] = [],
        preferredRoutes: [AppExecutionRoute] = [],
        successRate: Double = 0,
        estimatedCost: Double = 1,
        knownPages: [String] = [],
        failureNotes: [String] = [],
        appVersion: String? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.supportedUTTypes = supportedUTTypes
        self.urlSchemes = urlSchemes
        self.preferredRoutes = preferredRoutes
        self.successRate = successRate
        self.estimatedCost = estimatedCost
        self.knownPages = knownPages
        self.failureNotes = failureNotes
        self.appVersion = appVersion
    }
}

public enum ToolRisk: String, Codable, Comparable, Sendable {
    case readOnly
    case safeWrite
    case sensitiveWrite
    case destructive
    case systemChange
    case externalSideEffect
    case permanentDestructive

    private var rank: Int {
        switch self {
        case .readOnly: return 0
        case .safeWrite: return 1
        case .sensitiveWrite: return 2
        case .destructive: return 3
        case .systemChange: return 4
        case .externalSideEffect: return 5
        case .permanentDestructive: return 6
        }
    }

    public static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool { lhs.rank < rhs.rank }
}

public struct ToolDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var summary: String
    public var risk: ToolRisk
    public var requiredCapabilities: [String]
    public var preferredRoute: AppExecutionRoute

    public init(name: String, summary: String, risk: ToolRisk, requiredCapabilities: [String] = [], preferredRoute: AppExecutionRoute = .structuredTool) {
        self.name = name
        self.summary = summary
        self.risk = risk
        self.requiredCapabilities = requiredCapabilities
        self.preferredRoute = preferredRoute
    }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var arguments: [String: String]
    public var sessionID: UUID

    public init(id: UUID = UUID(), name: String, arguments: [String: String], sessionID: UUID) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.sessionID = sessionID
    }

    public static func stableID(sessionID: UUID, providerCallID: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(sessionID.uuidString)|\(providerCallID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var toolCallID: UUID
    public var success: Bool
    public var summary: String
    public var payload: [String: String]
    public var verification: VerificationResult?

    public init(toolCallID: UUID, success: Bool, summary: String, payload: [String: String] = [:], verification: VerificationResult? = nil) {
        self.toolCallID = toolCallID
        self.success = success
        self.summary = summary
        self.payload = payload
        self.verification = verification
    }
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public var passed: Bool
    public var checks: [String]
    public var failures: [String]

    public init(passed: Bool, checks: [String] = [], failures: [String] = []) {
        self.passed = passed
        self.checks = checks
        self.failures = failures
    }
}

public enum PolicyDecision: String, Codable, Sendable {
    case allow
    case requireConfirmation
    case deny
}

public struct ApprovalPreview: Codable, Equatable, Sendable {
    public var title: String
    public var target: String
    public var originalSummary: String?
    public var diff: String?
    public var reason: String
    public var plan: [String]
    public var risk: ToolRisk

    public init(title: String, target: String, originalSummary: String? = nil, diff: String? = nil, reason: String, plan: [String], risk: ToolRisk) {
        self.title = title
        self.target = target
        self.originalSummary = originalSummary
        self.diff = diff
        self.reason = reason
        self.plan = plan
        self.risk = risk
    }
}

public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: UUID
    public var toolCallID: UUID?
    public var action: String
    public var target: String?
    public var risk: ToolRisk?
    public var result: String
    public var detail: [String: String]

    public init(id: UUID = UUID(), timestamp: Date = Date(), sessionID: UUID, toolCallID: UUID? = nil, action: String, target: String? = nil, risk: ToolRisk? = nil, result: String, detail: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.action = action
        self.target = target
        self.risk = risk
        self.result = result
        self.detail = detail
    }
}

public struct TrashRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var originalPath: String
    public var logicalResourceID: String
    public var trashPath: String
    public var filename: String
    public var size: Int64
    public var hash: String
    public var timestamp: Date
    public var sessionID: UUID
    public var toolCallID: UUID
    public var reason: String
    public var sourceApp: String?

    public init(id: UUID = UUID(), originalPath: String, logicalResourceID: String, trashPath: String, filename: String, size: Int64, hash: String, timestamp: Date = Date(), sessionID: UUID, toolCallID: UUID, reason: String, sourceApp: String?) {
        self.id = id
        self.originalPath = originalPath
        self.logicalResourceID = logicalResourceID
        self.trashPath = trashPath
        self.filename = filename
        self.size = size
        self.hash = hash
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.reason = reason
        self.sourceApp = sourceApp
    }
}

public enum TransactionState: String, Codable, Sendable {
    case planned
    case awaitingConfirmation
    case backedUp
    case applying
    case verifying
    case committed
    case rolledBack
    case failed
}

public struct TransactionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var toolCallID: UUID
    public var targetPath: String
    public var backupPath: String?
    public var diff: String?
    public var state: TransactionState
    public var startedAt: Date
    public var finishedAt: Date?
    public var failure: String?

    public init(id: UUID = UUID(), sessionID: UUID, toolCallID: UUID, targetPath: String, backupPath: String? = nil, diff: String? = nil, state: TransactionState = .planned, startedAt: Date = Date(), finishedAt: Date? = nil, failure: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.diff = diff
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failure = failure
    }
}

public struct TaskCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var taskName: String
    public var stepIndex: Int
    public var stepName: String
    public var totalSteps: Int
    public var state: String
    public var updatedAt: Date
    public var payload: [String: String]

    public init(id: UUID = UUID(), sessionID: UUID, taskName: String, stepIndex: Int, stepName: String, totalSteps: Int, state: String, updatedAt: Date = Date(), payload: [String: String] = [:]) {
        self.id = id
        self.sessionID = sessionID
        self.taskName = taskName
        self.stepIndex = stepIndex
        self.stepName = stepName
        self.totalSteps = totalSteps
        self.state = state
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    public var model: String
    public var apiKeyReference: String

    public init(id: UUID = UUID(), name: String, baseURL: URL, model: String, apiKeyReference: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKeyReference = apiKeyReference
    }
}

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date
    public var providerMetadata: [String: String]

    public init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(), providerMetadata: [String: String] = [:]) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.providerMetadata = providerMetadata
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var permissionMode: PermissionMode
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "New Session", messages: [ChatMessage] = [], permissionMode: PermissionMode = .safe, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.permissionMode = permissionMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RunGenerationGuard: Sendable, Equatable {
    public private(set) var current: UUID?

    public init(current: UUID? = nil) {
        self.current = current
    }

    @discardableResult
    public mutating func start() -> UUID {
        let id = UUID()
        current = id
        return id
    }

    public func isCurrent(_ id: UUID) -> Bool { current == id }

    @discardableResult
    public mutating func finish(_ id: UUID) -> Bool {
        guard current == id else { return false }
        current = nil
        return true
    }

    public mutating func cancel() {
        current = nil
    }
}

public enum InputSource: String, Codable, Sendable {
    case text
    case voice
    case shortcut
    case siri
    case external
}
