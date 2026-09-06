import Foundation
import SQLite3
import XCTest
@testable import CloudCodeCore

final class NativeDataServicesTests: XCTestCase {
    func testRegistryPublishesPublicNativeContracts() async throws {
        let registry = ToolRegistry()
        let names = Set(await registry.all().map(\.name))
        let expected: Set<String> = [
            "files.stat", "files.metadata", "files.hash", "files.diff", "files.copy", "files.move",
            "plist.read", "plist.query", "plist.metadata",
            "json.read", "json.query", "json.filter", "json.aggregate",
            "sqlite.discover", "sqlite.tables", "sqlite.schema", "sqlite.query", "sqlite.filter", "sqlite.aggregate", "sqlite.sample",
            "container.list", "container.search", "data.localQuery"
        ]
        XCTAssertTrue(expected.isSubset(of: names), "missing native contracts: \(expected.subtracting(names).sorted())")

        let copyDescriptor = await registry.descriptor(named: "files.copy")
        let sqliteDescriptor = await registry.descriptor(named: "sqlite.query")
        let macroDescriptor = await registry.descriptor(named: "data.localQuery")
        XCTAssertEqual(copyDescriptor?.preferredRoute, .structuredTool)
        XCTAssertEqual(sqliteDescriptor?.requiredCapabilities, ["native.sqlite"])
        XCTAssertEqual(macroDescriptor?.requiredCapabilities, ["native.data_macro"])
    }

    func testCapabilityProbePublishesPublicNativeRecordsAtStartup() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = CapabilityProbe(appResolver: StaticAppResolver(), homeDirectory: root)
        let profile = await probe.probeStartupSafe()
        for id in ["native.files", "native.plist", "native.json", "native.sqlite", "native.container", "native.data_macro"] {
            XCTAssertEqual(profile.status(id), .available, id)
        }
    }

    func testFileServiceStatHashDiffAndSecureCopyMove() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let changed = root.appendingPathComponent("changed.txt")
        try Data("hello\nworld\n".utf8).write(to: source)
        try Data("hello\nswift\n".utf8).write(to: changed)

        let service = FileService()
        let metadata = try service.stat(source, allowedRoot: root)
        XCTAssertTrue(metadata.isRegularFile)
        XCTAssertFalse(metadata.isDirectory)
        XCTAssertEqual(metadata.name, "source.txt")
        XCTAssertGreaterThan(metadata.size, 0)
        XCTAssertEqual(try service.sha256(source, allowedRoot: root), "4a1e67f2fe1d1cc7b31d0ca2ec441da4778203a036a77da10344c85e24ff0f92")

        let diff = try service.diffText(source, changed, allowedRoot: root)
        XCTAssertFalse(diff.identical)
        XCTAssertEqual(diff.addedLineCount, 1)
        XCTAssertEqual(diff.removedLineCount, 1)
        XCTAssertFalse(diff.firstDifferences.isEmpty)

        let mutation = SecureFileMutation()
        let copy = root.appendingPathComponent("copy.txt")
        let sourceIdentity = try mutation.identity(of: source, allowedRoot: root)
        try mutation.copyFile(from: source, sourceAllowedRoot: root, to: copy, destinationAllowedRoot: root, expectedSourceIdentity: sourceIdentity)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))

        let moved = root.appendingPathComponent("moved.txt")
        let copyIdentity = try mutation.identity(of: copy, allowedRoot: root)
        try mutation.moveItem(from: copy, sourceAllowedRoot: root, to: moved, destinationAllowedRoot: root, expectedSourceIdentity: copyIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: moved), try Data(contentsOf: source))
    }

    func testNativePlistJSONAndSQLiteServicesStayBoundedAndReadOnly() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let plistURL = root.appendingPathComponent("config.plist")
        let plistObject: [String: Any] = ["app": ["name": "CloudCode", "build": 66], "enabled": true]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistObject, format: .binary, options: 0)
        try plistData.write(to: plistURL)
        let plist = NativePropertyListService()
        XCTAssertEqual(try plist.query(path: plistURL, keyPath: "app.name", allowedRoot: root) as? String, "CloudCode")
        XCTAssertEqual(try plist.metadata(path: plistURL, allowedRoot: root)["format"], "binary")

        let jsonURL = root.appendingPathComponent("records.json")
        let jsonObject: [String: Any] = [
            "items": [
                ["kind": "a", "value": 2],
                ["kind": "b", "value": 3],
                ["kind": "a", "value": 5]
            ]
        ]
        try JSONSerialization.data(withJSONObject: jsonObject).write(to: jsonURL)
        let json = NativeJSONService()
        let filtered = try json.filter(path: jsonURL, keyPath: "items", field: "kind", equals: "a", limit: 10, allowedRoot: root)
        XCTAssertEqual(filtered.count, 2)
        let aggregate = try json.aggregate(path: jsonURL, keyPath: "items", field: "value", operation: "sum", allowedRoot: root)
        XCTAssertEqual(Double(aggregate["value"] ?? ""), 10)

        let databaseURL = root.appendingPathComponent("records.sqlite")
        try createSQLiteDatabase(databaseURL)
        let sqlite = NativeSQLiteService()
        let tables = try sqlite.tables(path: databaseURL, allowedRoot: root)
        XCTAssertEqual(tables.rows.first?["name"], "items")
        let sqliteFiltered = try sqlite.filter(path: databaseURL, table: "items", field: "kind", equals: "a", limit: 10, allowedRoot: root)
        XCTAssertEqual(sqliteFiltered.rows.count, 2)
        let sqliteAggregate = try sqlite.aggregate(path: databaseURL, table: "items", field: "value", operation: "sum", allowedRoot: root)
        XCTAssertEqual(sqliteAggregate.rows.first?["value"], "10")
        XCTAssertThrowsError(try sqlite.query(path: databaseURL, sql: "DELETE FROM items", parametersJSON: nil, allowedRoot: root))
    }

    func testPersistentResourceIndexServesSearchBeforeFilesystemScanAndRevalidatesStalePaths() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexedURL = root.appendingPathComponent("indexed-target.txt")
        let fallbackURL = root.appendingPathComponent("fallback-target.txt")
        try Data("indexed".utf8).write(to: indexedURL)
        try Data("fallback".utf8).write(to: fallbackURL)

        let resourceIndex = ProgressiveResourceIndex(fileURL: root.appendingPathComponent("index/resource-graph.json"))
        let indexedNode = ResourceNode(
            id: ResourceID(indexedURL.absoluteString),
            kind: .file,
            displayName: indexedURL.lastPathComponent,
            logicalLocation: indexedURL.absoluteString,
            resolvedPath: indexedURL.path,
            byteSize: 7
        )
        try await resourceIndex.add(indexedNode)

        let resolver = StaticAppResolver(containerPaths: [:])
        let executor = try makeStructuredExecutor(root: root, resolver: resolver, resourceIndex: resourceIndex)
        let descriptor = ToolDescriptor(name: "files.search", summary: "", risk: .readOnly)
        let context = ToolExecutionContext(permissionMode: .safe, capabilityProfile: publicNativeProfile(), allowedRoot: root)
        let call = ToolCall(name: "files.search", arguments: ["path": root.path, "query": "target"], sessionID: UUID())

        let indexedResult = try await executor.execute(call, descriptor: descriptor, context: context)
        XCTAssertEqual(indexedResult.payload["searchPath"], "persistent_index_revalidated")
        XCTAssertTrue(indexedResult.summary.contains("持久资源索引"))

        try FileManager.default.removeItem(at: indexedURL)
        let fallbackResult = try await executor.execute(call, descriptor: descriptor, context: context)
        XCTAssertEqual(fallbackResult.payload["searchPath"], "bounded_scan_then_index")
        XCTAssertTrue(fallbackResult.summary.contains("有界目录扫描"))
        let graph = await resourceIndex.snapshot()
        XCTAssertFalse(graph.nodes.contains(where: { $0.resolvedPath == indexedURL.path }))
        XCTAssertTrue(graph.nodes.contains(where: { $0.resolvedPath == fallbackURL.path }))
    }

    func testProgressiveResourceIndexRanksExactAndPrefixNamesBeforePathOnlyMatches() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ProgressiveResourceIndex(fileURL: root.appendingPathComponent("index/resource-graph.json"))
        let nodes = [
            ResourceNode(id: ResourceID("file:///tmp/target-folder/notes"), kind: .file, displayName: "notes", logicalLocation: "file:///tmp/target-folder/notes", resolvedPath: "/tmp/target-folder/notes"),
            ResourceNode(id: ResourceID("file:///tmp/target"), kind: .file, displayName: "target", logicalLocation: "file:///tmp/target", resolvedPath: "/tmp/target"),
            ResourceNode(id: ResourceID("file:///tmp/target-backup"), kind: .file, displayName: "target-backup", logicalLocation: "file:///tmp/target-backup", resolvedPath: "/tmp/target-backup")
        ]
        try await index.add(nodes)
        let matches = await index.search(nameContains: "target", pathPrefix: "/tmp", maxResults: 10)
        XCTAssertEqual(matches.map(\.displayName), ["target", "target-backup", "notes"])
    }

    func testStructuredDataMacroResolvesSearchesIndexesAndQueriesLocally() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let jsonURL = container.appendingPathComponent("state.json")
        let object: [String: Any] = ["items": [["value": 1], ["value": 2], ["value": 3]]]
        try JSONSerialization.data(withJSONObject: object).write(to: jsonURL)

        let resolver = StaticAppResolver(containerPaths: ["com.example.app": container.path])
        let resourceIndex = ProgressiveResourceIndex(fileURL: root.appendingPathComponent("index/resource-graph.json"))
        let executor = try makeStructuredExecutor(root: root, resolver: resolver, resourceIndex: resourceIndex)
        let descriptor = ToolDescriptor(name: "data.localQuery", summary: "", risk: .readOnly, requiredCapabilities: ["native.data_macro"])
        let call = ToolCall(name: "data.localQuery", arguments: [
            "bundleId": "com.example.app",
            "format": "json",
            "query": "state.json",
            "keyPath": "items",
            "operation": "count"
        ], sessionID: UUID())
        let context = ToolExecutionContext(permissionMode: .safe, capabilityProfile: publicNativeProfile(), allowedRoot: root)
        let result = try await executor.execute(call, descriptor: descriptor, context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.summary.contains("resolve:container"))
        XCTAssertTrue(result.summary.contains("search:unique"))
        XCTAssertTrue(result.summary.contains("aggregate:json"))

        let graph = await resourceIndex.snapshot()
        XCTAssertTrue(graph.nodes.contains(where: { $0.resolvedPath == jsonURL.path }))
        XCTAssertTrue(graph.nodes.contains(where: { $0.ownerBundleID == "com.example.app" }))
    }

    func testToolRouterProviderSchemaEligibilityOmitsUnavailableCapabilities() async throws {
        let registry = ToolRegistry(descriptors: [
            ToolDescriptor(name: "test.routable", summary: "", risk: .readOnly),
            ToolDescriptor(name: "test.blocked", summary: "", risk: .readOnly, requiredCapabilities: ["missing.capability"])
        ])
        let router = ToolRouter(registry: registry, executors: [RouteStubExecutor(route: .structuredTool, supported: true)])
        let names = await router.providerRoutableToolNames(capabilities: CapabilityProfile(records: []))
        XCTAssertTrue(names.contains("test.routable"))
        XCTAssertFalse(names.contains("test.blocked"))
    }

    func testToolRouterRecordsFallbackCandidatesReasonsAndExecutionLatency() async throws {
        let registry = ToolRegistry(descriptors: [ToolDescriptor(name: "test.route", summary: "", risk: .readOnly)])
        let structured = RouteStubExecutor(route: .structuredTool, supported: false)
        let cli = RouteStubExecutor(route: .cli, supported: true)
        let metrics = ExecutionPathMetrics(maximumCount: 64)
        let router = ToolRouter(registry: registry, executors: [structured, cli], executionPathMetrics: metrics)
        let call = ToolCall(name: "test.route", arguments: [:], sessionID: UUID())
        let result = try await router.execute(call, context: ToolExecutionContext(permissionMode: .safe, capabilityProfile: CapabilityProfile(records: [])))
        XCTAssertTrue(result.success)

        let recent = await metrics.recent(limit: 10)
        let metric = try XCTUnwrap(recent.last)
        XCTAssertEqual(metric.selectedRoute, .cli)
        XCTAssertEqual(metric.routeCandidates.first, .structuredTool)
        XCTAssertEqual(metric.fallbackDepth, 1)
        XCTAssertTrue(metric.fallbackReason.contains("structuredTool"))
        XCTAssertGreaterThanOrEqual(metric.routeSelectionLatencyMS, 0)
        XCTAssertGreaterThanOrEqual(metric.executionLatencyMS, 0)
        XCTAssertGreaterThanOrEqual(metric.totalLatencyMS, metric.executionLatencyMS)
        XCTAssertEqual(metric.outcome, "completed")
    }

    private func makeStructuredExecutor(root: URL, resolver: StaticAppResolver, resourceIndex: ProgressiveResourceIndex) throws -> StructuredToolExecutor {
        let policy = PolicyEngine()
        let audit = AuditLogStore(fileURL: root.appendingPathComponent("audit/audit.jsonl"))
        let journal = TransactionJournal(fileURL: root.appendingPathComponent("transactions/transactions.json"))
        return StructuredToolExecutor(
            capabilityProbe: TestCapabilityProbe(profile: publicNativeProfile()),
            appResolver: resolver,
            resourceResolver: ResourceResolver(appResolver: resolver),
            fileService: FileService(),
            ipaService: IPAService(),
            trashService: TrashService(root: root.appendingPathComponent("trash", isDirectory: true)),
            transactionEngine: TransactionEngine(backupRoot: root.appendingPathComponent("backups", isDirectory: true), policy: policy, journal: journal, audit: audit),
            policy: policy,
            audit: audit,
            approval: FixedApprovalRequester(approved: true),
            resourceIndex: resourceIndex
        )
    }

    private func publicNativeProfile() -> CapabilityProfile {
        CapabilityProfile(records: [
            CapabilityRecord(id: "native.files", domain: .filesystem, status: .available, detail: "test"),
            CapabilityRecord(id: "native.plist", domain: .data, status: .available, detail: "test"),
            CapabilityRecord(id: "native.json", domain: .data, status: .available, detail: "test"),
            CapabilityRecord(id: "native.sqlite", domain: .data, status: .available, detail: "test"),
            CapabilityRecord(id: "native.container", domain: .filesystem, status: .available, detail: "test"),
            CapabilityRecord(id: "native.data_macro", domain: .data, status: .available, detail: "test")
        ])
    }

    private func createSQLiteDatabase(_ url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw NSError(domain: "NativeDataServicesTests", code: 1) }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE items (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, value INTEGER NOT NULL);
        INSERT INTO items(kind, value) VALUES ('a', 2), ('b', 3), ('a', 5);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodeNativeDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct TestCapabilityProbe: CapabilityProbing, Sendable {
    let profile: CapabilityProfile
    func probe() async -> CapabilityProfile { profile }
}

private struct RouteStubExecutor: ToolExecuting, Sendable {
    let route: AppExecutionRoute
    let supported: Bool

    func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool { supported }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(toolCallID: call.id, success: true, summary: "ok")
    }
}
