import Foundation

public struct CapabilityGraphNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var domain: CapabilityDomain
    public var status: CapabilityStatus
    public var detail: String
    public var toolNames: [String]
    public var preferredRoutes: [AppExecutionRoute]

    public init(
        id: String,
        domain: CapabilityDomain,
        status: CapabilityStatus,
        detail: String,
        toolNames: [String] = [],
        preferredRoutes: [AppExecutionRoute] = []
    ) {
        self.id = id
        self.domain = domain
        self.status = status
        self.detail = detail
        self.toolNames = toolNames
        self.preferredRoutes = preferredRoutes
    }
}

public struct CapabilityGraphEdge: Codable, Equatable, Hashable, Sendable {
    public enum Relation: String, Codable, Sendable {
        case requires
        case routesThrough
    }

    public var from: String
    public var to: String
    public var relation: Relation

    public init(from: String, to: String, relation: Relation) {
        self.from = from
        self.to = to
        self.relation = relation
    }
}

public struct CapabilityGraph: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var nodes: [CapabilityGraphNode]
    public var edges: [CapabilityGraphEdge]

    public init(generatedAt: Date = Date(), nodes: [CapabilityGraphNode] = [], edges: [CapabilityGraphEdge] = []) {
        self.generatedAt = generatedAt
        self.nodes = nodes
        self.edges = edges
    }

    public func node(_ id: String) -> CapabilityGraphNode? {
        nodes.first(where: { $0.id == id })
    }

    public func toolsEnabled(by capabilityID: String) -> [String] {
        node(capabilityID)?.toolNames ?? []
    }
}

public struct CapabilityGraphBuilder: Sendable {
    public init() {}

    public func build(profile: CapabilityProfile, tools: [ToolDescriptor]) -> CapabilityGraph {
        var toolsByCapability: [String: [ToolDescriptor]] = [:]
        for tool in tools {
            for capability in tool.requiredCapabilities {
                toolsByCapability[capability, default: []].append(tool)
            }
        }

        let nodes = profile.records.map { record -> CapabilityGraphNode in
            let dependentTools = toolsByCapability[record.id, default: []]
            return CapabilityGraphNode(
                id: "capability://\(record.id)",
                domain: record.domain,
                status: record.status,
                detail: record.detail,
                toolNames: dependentTools.map(\.name).sorted(),
                preferredRoutes: Array(Set(dependentTools.map(\.preferredRoute))).sorted { $0.rawValue < $1.rawValue }
            )
        }.sorted { $0.id < $1.id }

        var edges: [CapabilityGraphEdge] = []
        for tool in tools {
            for capability in tool.requiredCapabilities {
                edges.append(CapabilityGraphEdge(from: "tool://\(tool.name)", to: "capability://\(capability)", relation: .requires))
            }
            edges.append(CapabilityGraphEdge(from: "tool://\(tool.name)", to: "route://\(tool.preferredRoute.rawValue)", relation: .routesThrough))
        }

        return CapabilityGraph(nodes: nodes, edges: edges.sorted {
            if $0.from == $1.from { return $0.to < $1.to }
            return $0.from < $1.from
        })
    }
}
