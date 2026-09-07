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

    func testFileServiceDirectoryListingIsShallowAndDoesNotAggregateChildDirectorySize() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        let deep = child.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 64 * 1024).write(to: deep.appendingPathComponent("payload.bin"))

        let entries = try FileService().list(directory: root, allowedRoot: root)
        let childEntry = try XCTUnwrap(entries.first(where: { $0.name == "child" }))
        XCTAssertTrue(childEntry.isDirectory)
        XCTAssertEqual(childEntry.size, 0, "shallow listing must not recursively aggregate a directory subtree")
    }

    func testFileSearchQueryAddsTraversalCircuitBreakerWithoutChangingExistingBudgets() {
        let defaults = FileSearchQuery()
        XCTAssertEqual(defaults.maxVisited, 20_000)
        XCTAssertEqual(defaults.maxDepth, 4)
        XCTAssertEqual(defaults.maxResults, 500)

        let boundedTraversal = FileSearchQuery(maxDepth: 99, maxResults: 99_999, maxVisited: 999_999)
        XCTAssertEqual(boundedTraversal.maxDepth, 99)
        XCTAssertEqual(boundedTraversal.maxResults, 99_999)
        XCTAssertEqual(boundedTraversal.maxVisited, 100_000)
    }

    func testFileSearchStopsAtVisitedBudgetEvenWhenMoreEntriesMatch() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<220 {
            try Data("x".utf8).write(to: root.appendingPathComponent(String(format: "match-%03d.txt", index)))
        }

        let results = try FileService().search(
            root: root,
            query: FileSearchQuery(maxDepth: 5, maxResults: 500, maxVisited: 128),
            allowedRoot: root
        )
        XCTAssertEqual(results.count, 128, "bounded scan must stop before processing entries beyond maxVisited")
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
        XCTAssertFalse(graph.nodes.contains(where: { $0.displayName == indexedURL.lastPathComponent }))
        XCTAssertTrue(graph.nodes.contains(where: { $0.displayName == fallbackURL.lastPathComponent }))
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

    func testProgressiveResourceIndexPersistsAcrossRestartAndKeepsGraphSnapshotBounded() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let graphURL = root.appendingPathComponent("index/resource-graph.json")
        let first = ProgressiveResourceIndex(fileURL: graphURL)
        let nodes = (0..<2_000).map { offset in
            let path = root.appendingPathComponent("persist-\(offset).txt").path
            return ResourceNode(
                id: ResourceID(URL(fileURLWithPath: path).absoluteString),
                kind: .file,
                displayName: "persist-\(offset).txt",
                logicalLocation: URL(fileURLWithPath: path).absoluteString,
                resolvedPath: path,
                byteSize: Int64(offset)
            )
        }
        try await first.add(nodes, source: "test_bulk")
        let firstStats = await first.statistics()
        let firstSnapshot = await first.snapshot()
        XCTAssertEqual(firstStats.resourceCount, 2_000)
        XCTAssertGreaterThan(firstStats.sidecarBytes, 0)
        XCTAssertLessThanOrEqual(firstSnapshot.nodes.count, 1_024)

        let restarted = ProgressiveResourceIndex(fileURL: graphURL)
        let matches = await restarted.search(nameContains: "persist-1999", pathPrefix: root.path, maxResults: 10)
        let restartedStats = await restarted.statistics()
        XCTAssertEqual(matches.first?.displayName, "persist-1999.txt")
        XCTAssertEqual(restartedStats.resourceCount, 2_000)
        XCTAssertLessThanOrEqual((try Data(contentsOf: graphURL)).count, 4 * 1024 * 1024)
    }

    func testProgressiveResourceIndexRebuildsCorruptSidecar() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexDirectory = root.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let sidecar = indexDirectory.appendingPathComponent("resource-index.sqlite")
        try Data("not-a-sqlite-database".utf8).write(to: sidecar)

        let index = ProgressiveResourceIndex(fileURL: indexDirectory.appendingPathComponent("resource-graph.json"))
        let stats = await index.statistics()
        XCTAssertTrue(stats.rebuiltCorruptSidecar)
        XCTAssertEqual(stats.resourceCount, 0)

        let path = root.appendingPathComponent("rebuilt.txt").path
        try await index.add(ResourceNode(
            id: ResourceID(URL(fileURLWithPath: path).absoluteString),
            kind: .file,
            displayName: "rebuilt.txt",
            logicalLocation: URL(fileURLWithPath: path).absoluteString,
            resolvedPath: path
        ))
        let rebuiltMatches = await index.search(nameContains: "rebuilt", pathPrefix: root.path)
        XCTAssertEqual(rebuiltMatches.count, 1)
    }

    func testProgressiveResourceIndexInvalidatesOldContainerUUIDPaths() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ProgressiveResourceIndex(fileURL: root.appendingPathComponent("index/resource-graph.json"))
        let bundleID = "com.example.relocated"
        let oldRoot = "/var/mobile/Containers/Data/Application/OLD-UUID"
        let newRoot = "/var/mobile/Containers/Data/Application/NEW-UUID"
        let rootID = ResourceID("container://\(bundleID)")
        try await index.add(ResourceNode(
            id: rootID,
            kind: .directory,
            displayName: "OLD-UUID",
            logicalLocation: rootID.rawValue,
            resolvedPath: oldRoot,
            ownerBundleID: bundleID
        ), source: "container_resolve")
        let stalePath = oldRoot + "/Documents/report.txt"
        try await index.add(ResourceNode(
            id: ResourceID(URL(fileURLWithPath: stalePath).absoluteString),
            kind: .file,
            displayName: "report.txt",
            logicalLocation: URL(fileURLWithPath: stalePath).absoluteString,
            resolvedPath: stalePath,
            ownerBundleID: bundleID
        ))
        let matchesBeforeRelocation = await index.search(nameContains: "report", ownerBundleID: bundleID)
        XCTAssertEqual(matchesBeforeRelocation.count, 1)

        try await index.add(ResourceNode(
            id: rootID,
            kind: .directory,
            displayName: "NEW-UUID",
            logicalLocation: rootID.rawValue,
            resolvedPath: newRoot,
            ownerBundleID: bundleID
        ), source: "container_resolve")
        let matchesAfterRelocation = await index.search(nameContains: "report", ownerBundleID: bundleID)
        XCTAssertTrue(matchesAfterRelocation.isEmpty)

        let currentPath = newRoot + "/Documents/current-report.txt"
        try await index.add(ResourceNode(
            id: ResourceID(URL(fileURLWithPath: currentPath).absoluteString),
            kind: .file,
            displayName: "current-report.txt",
            logicalLocation: URL(fileURLWithPath: currentPath).absoluteString,
            resolvedPath: currentPath,
            ownerBundleID: bundleID
        ))
        let currentMatches = await index.search(nameContains: "current-report", ownerBundleID: bundleID)
        XCTAssertEqual(currentMatches.count, 1)
        try await index.invalidate(ownerBundleID: bundleID)
        let matchesAfterUninstallInvalidation = await index.search(nameContains: "current-report", ownerBundleID: bundleID)
        XCTAssertTrue(matchesAfterUninstallInvalidation.isEmpty)
    }

    func testProgressiveResourceIndexFiftyThousandResourceLookupStaysBounded() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let graphURL = root.appendingPathComponent("index/resource-graph.json")
        let index = ProgressiveResourceIndex(fileURL: graphURL)
        let nodes = (0..<50_000).map { offset in
            let name = String(format: "resource-%05d.json", offset)
            let path = root.appendingPathComponent("bulk").appendingPathComponent(name).path
            return ResourceNode(
                id: ResourceID(URL(fileURLWithPath: path).absoluteString),
                kind: .file,
                displayName: name,
                logicalLocation: URL(fileURLWithPath: path).absoluteString,
                resolvedPath: path,
                ownerBundleID: "com.example.synthetic",
                byteSize: Int64(offset),
                metadata: ["contentType": "public.json"]
            )
        }
        try await index.add(Array(nodes.prefix(10_000)), source: "synthetic_10k")
        let tenThousandStats = await index.statistics()
        XCTAssertEqual(tenThousandStats.resourceCount, 10_000)
        let tenThousandStart = Date()
        let tenThousandExact = await index.search(nameContains: "resource-09999.json", ownerBundleID: "com.example.synthetic", pathPrefix: root.path, maxResults: 10)
        XCTAssertEqual(tenThousandExact.first?.displayName, "resource-09999.json")
        XCTAssertLessThan(Date().timeIntervalSince(tenThousandStart), 2.0)

        try await index.add(Array(nodes.dropFirst(10_000)), source: "synthetic_50k_increment")
        let bulkStats = await index.statistics()
        XCTAssertEqual(bulkStats.resourceCount, 50_000)

        let exactStart = Date()
        let exact = await index.search(nameContains: "resource-49999.json", ownerBundleID: "com.example.synthetic", pathPrefix: root.path, maxResults: 10)
        let exactElapsed = Date().timeIntervalSince(exactStart)
        XCTAssertEqual(exact.first?.displayName, "resource-49999.json")
        XCTAssertLessThan(exactElapsed, 2.0)

        let containsStart = Date()
        let contains = await index.search(nameContains: "999", ownerBundleID: "com.example.synthetic", pathPrefix: root.path, maxResults: 25)
        let containsElapsed = Date().timeIntervalSince(containsStart)
        let bulkSnapshot = await index.snapshot()
        XCTAssertFalse(contains.isEmpty)
        XCTAssertLessThan(containsElapsed, 2.0)
        XCTAssertLessThanOrEqual(bulkSnapshot.nodes.count, 1_024)
        XCTAssertLessThanOrEqual((try Data(contentsOf: graphURL)).count, 4 * 1024 * 1024)
    }

    func testFileServiceBoundedSearchRespondsToCancellation() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for offset in 0..<384 {
            try Data().write(to: root.appendingPathComponent("cancel-\(offset).txt"))
        }
        let task = Task.detached {
            try FileService().search(root: root, query: FileSearchQuery(maxDepth: 2, maxResults: 1_000), allowedRoot: root)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled bounded filesystem search must stop cooperatively")
        } catch is CancellationError {
            // expected
        }
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

    func testLocalDataSemanticAliasRevalidatesAgainstCurrentContainerInsteadOfStoredUUIDPath() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("CURRENT", isDirectory: true)
        let preferences = container.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let jsonURL = preferences.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["enabled": true]).write(to: jsonURL)

        let resolver = StaticAppResolver(containerPaths: ["com.example.app": container.path])
        let resourceIndex = ProgressiveResourceIndex(fileURL: root.appendingPathComponent("index/resource-graph.json"))
        let knowledge = AppKnowledgeRegistry(fileURL: root.appendingPathComponent("index/app-knowledge.json"))
        try await knowledge.upsert(AppKnowledge(
            appName: "Example",
            bundleID: "com.example.app",
            appVersion: "1.0",
            localDataMap: ["preferences": "/var/mobile/Containers/Data/Application/STALE/Library/Preferences"]
        ))
        let executor = try makeStructuredExecutor(root: root, resolver: resolver, resourceIndex: resourceIndex, appKnowledgeRegistry: knowledge)
        let descriptor = ToolDescriptor(name: "data.localQuery", summary: "", risk: .readOnly, requiredCapabilities: ["native.data_macro"])
        let call = ToolCall(name: "data.localQuery", arguments: [
            "bundleId": "com.example.app",
            "semanticAlias": "preferences",
            "format": "json",
            "query": "settings.json",
            "keyPath": "enabled"
        ], sessionID: UUID())
        let result = try await executor.execute(call, descriptor: descriptor, context: ToolExecutionContext(permissionMode: .safe, capabilityProfile: publicNativeProfile(), allowedRoot: root))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.summary.contains("lookup:semantic_alias"))
        XCTAssertTrue(result.summary.contains("resolve:container_revalidated_alias"))
        XCTAssertFalse(result.summary.contains("STALE"))
        let graph = await resourceIndex.snapshot()
        XCTAssertTrue(graph.nodes.contains(where: { $0.resolvedPath == jsonURL.path }))
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

    private func makeStructuredExecutor(root: URL, resolver: StaticAppResolver, resourceIndex: ProgressiveResourceIndex, appKnowledgeRegistry: AppKnowledgeRegistry? = nil) throws -> StructuredToolExecutor {
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
            resourceIndex: resourceIndex,
            appKnowledgeRegistry: appKnowledgeRegistry
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
