import XCTest
@testable import CloudCodeCore

final class AppProviderPackageStoreTests: XCTestCase {
    func testFirstPartyPackagesSeedIntoIndependentProviderStore() async throws {
        let root = temporaryDirectory("seed")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppProviderPackageStore(rootURL: root)
        try await store.seedFirstPartyIfMissing()
        let packages = try await store.all()

        XCTAssertEqual(Set(packages.map(\.id)), Set(["ai.gemini.app", "ai.deepseek.app", "ai.chatgpt.app"]))
        XCTAssertEqual(packages.first(where: { $0.id == "ai.gemini.app" })?.manifest.bundleID, "com.google.gemini")
        XCTAssertEqual(packages.first(where: { $0.id == "ai.deepseek.app" })?.manifest.compatibility.testedAppVersion, "2.5.1")
        XCTAssertEqual(packages.first(where: { $0.id == "ai.chatgpt.app" })?.manifest.compatibility.testedAppVersion, "1.2024.348")
        XCTAssertTrue(packages.allSatisfy { $0.manifest.supportsBackgroundGeneration == false })
    }

    func testCustomTemplateCanBeCreatedBeforeGuidedSelectorLearning() async throws {
        let root = temporaryDirectory("template")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppProviderPackageStore(rootURL: root)
        let summary = try await store.createTemplate(
            id: "ai.custom.demo.app",
            displayName: "Demo AI",
            bundleID: "com.example.demoai",
            launchSchemes: ["demoai"],
            testedAppVersion: "4.2.1"
        )
        let package = try await store.package(id: summary.id)

        XCTAssertFalse(package.summary.manifest.requiresLogin)
        XCTAssertTrue(package.selectors.composer.isEmpty)
        XCTAssertEqual(package.summary.manifest.compatibility.testedAppVersion, "4.2.1")
        XCTAssertEqual(package.summary.manifest.launchSchemes, ["demoai"])
    }

    func testGuidedSetupAtomicallyUpdatesSelectorsAndRevision() async throws {
        let root = temporaryDirectory("setup")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppProviderPackageStore(rootURL: root)
        _ = try await store.createTemplate(
            id: "ai.custom.setup.app",
            displayName: "Setup AI",
            bundleID: "com.example.setup"
        )
        let before = try await store.package(id: "ai.custom.setup.app")
        let selectors = AppProviderSelectorSet(
            composer: [.init(strategy: .visibleText, value: "Ask Setup", minimumConfidence: 0.8)],
            send: [.init(strategy: .visibleText, value: "Send", minimumConfidence: 0.8)],
            readyIndicators: [.init(strategy: .visibleText, value: "Ask Setup", minimumConfidence: 0.8)]
        )

        _ = try await store.updateSetup(
            id: "ai.custom.setup.app",
            selectors: selectors,
            requiresLogin: false,
            testedAppVersion: "7.0",
            launchSchemes: ["setupai"]
        )
        let after = try await store.package(id: "ai.custom.setup.app")

        XCTAssertEqual(after.selectors, selectors)
        XCTAssertNotEqual(after.summary.manifest.revision, before.summary.manifest.revision)
        XCTAssertEqual(after.summary.manifest.compatibility.testedAppVersion, "7.0")
        XCTAssertEqual(after.summary.manifest.compatibility.selectorRevision, "2")
    }

    func testUnexpectedExecutableResourceFailsClosed() async throws {
        let root = temporaryDirectory("unexpected-resource")
        let source = temporaryDirectory("unexpected-resource-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let manifest = AppProviderPackageManifest(
            revision: "r1",
            id: "ai.custom.extra.app",
            displayName: "Extra",
            bundleID: "com.example.extra",
            requiresLogin: false,
            declaredCapabilities: ["app.launch", "gui.touch", "gui.textInput", "screenshot"],
            responseExtractors: [.init(kind: .axText)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: source.appendingPathComponent("provider.json"), options: .atomic)
        try encoder.encode(AppProviderSelectorSet()).write(to: source.appendingPathComponent("selectors.json"), options: .atomic)
        try encoder.encode(AppProviderWorkflow()).write(to: source.appendingPathComponent("workflow.json"), options: .atomic)
        try encoder.encode(AppProviderRecoveryDocument()).write(to: source.appendingPathComponent("recovery.json"), options: .atomic)
        try "# prompts".write(to: source.appendingPathComponent("prompts.md"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho never-run\n".write(to: source.appendingPathComponent("payload.sh"), atomically: true, encoding: .utf8)

        let store = AppProviderPackageStore(rootURL: root)
        do {
            _ = try await store.install(from: source)
            XCTFail("declarative provider packages must reject extra executable resources")
        } catch let error as AppProviderPackageError {
            XCTAssertEqual(error, .unexpectedResource("payload.sh"))
        }
    }

    func testMalformedOCRRegionFailsClosed() async throws {
        let root = temporaryDirectory("invalid-region")
        let source = temporaryDirectory("invalid-region-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let manifest = AppProviderPackageManifest(
            revision: "r1",
            id: "ai.custom.invalid.app",
            displayName: "Invalid",
            bundleID: "com.example.invalid",
            requiresLogin: false,
            declaredCapabilities: ["app.launch", "gui.touch", "gui.textInput", "screenshot"],
            responseExtractors: [
                .init(kind: .ocrRegion, region: .init(x: 0.9, y: 0.1, width: 0.3, height: 0.2))
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: source.appendingPathComponent("provider.json"), options: .atomic)
        try encoder.encode(AppProviderSelectorSet()).write(to: source.appendingPathComponent("selectors.json"), options: .atomic)
        try encoder.encode(AppProviderWorkflow()).write(to: source.appendingPathComponent("workflow.json"), options: .atomic)
        try encoder.encode(AppProviderRecoveryDocument()).write(to: source.appendingPathComponent("recovery.json"), options: .atomic)
        try "# prompts".write(to: source.appendingPathComponent("prompts.md"), atomically: true, encoding: .utf8)

        let store = AppProviderPackageStore(rootURL: root)
        do {
            _ = try await store.install(from: source)
            XCTFail("out-of-bounds normalized OCR region must be rejected")
        } catch let error as AppProviderPackageError {
            XCTAssertEqual(error, .manifestInvalid)
        }
    }

    func testAppBackedExecutionDoesNotReadNetworkKeyVault() async throws {
        let vault = CountingKeyVault()
        let app = EchoAppBackedProvider()
        let router = ProviderExecutionRouter(
            networkProvider: NeverUsedNetworkProvider(),
            keyVault: vault,
            appBackedProvider: app
        )
        let configuration = ProviderExecutionConfiguration.appBacked(
            AppBackedProviderConfiguration(
                packageID: "ai.custom.demo.app",
                displayName: "Demo",
                bundleID: "com.example.demo",
                agentSessionID: UUID()
            )
        )

        var tokens = ""
        for try await event in router.stream(
            configuration: configuration,
            messages: [ChatMessage(role: .user, content: "hello")],
            tools: []
        ) {
            if case .token(let value) = event { tokens += value }
        }

        let keyReads = await vault.readCount()
        let appStreams = await app.streamCount()
        XCTAssertEqual(tokens, "app-backed-ok")
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual(appStreams, 1)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodeAppProviderTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor CountingKeyVault: APIKeyVault {
    private var reads = 0

    func key(for reference: String) async throws -> String {
        reads += 1
        return "unexpected-network-key"
    }

    func readCount() -> Int { reads }
}

private actor EchoAppBackedProvider: AppBackedProviderStreaming {
    private var streams = 0

    nonisolated func stream(
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordStream()
                continuation.yield(.token("app-backed-ok"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    private func recordStream() { streams += 1 }
    func streamCount() -> Int { streams }
}

private struct NeverUsedNetworkProvider: ProviderStreaming {
    func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.transport("network path must not run"))
        }
    }
}
