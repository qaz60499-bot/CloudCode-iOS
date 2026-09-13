import Foundation
import UIKit
import CryptoKit
import CloudCodeCore

actor AppBackedProviderAuthorizationStore {
    private let defaults: UserDefaults
    private static let key = "provider.appBacked.authorizedPackageIdentities"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAuthorized(identity: String) -> Bool {
        Set(defaults.stringArray(forKey: Self.key) ?? []).contains(identity)
    }

    func setAuthorized(_ authorized: Bool, identity: String, packageID: String) {
        var identities = Set(defaults.stringArray(forKey: Self.key) ?? [])
        identities = Set(identities.filter { !$0.hasPrefix(packageID + "|") })
        if authorized { identities.insert(identity) }
        defaults.set(identities.sorted(), forKey: Self.key)
    }
}

actor AppBackedProviderLearningStore {
    struct Evidence: Codable, Equatable, Sendable {
        var packageID: String
        var selectorKey: String
        var successCount: Int
        var failureCount: Int
        var lastValidatedAppVersion: String?
        var averageLatencyMS: Double
        var lastUpdatedAt: Date

        var reliability: Double {
            let total = successCount + failureCount
            guard total > 0 else { return 0.5 }
            return Double(successCount) / Double(total)
        }
    }

    private struct State: Codable { var evidence: [String: Evidence] }
    private let fileURL: URL
    private var loaded = false
    private var evidence: [String: Evidence] = [:]

    init(fileURL: URL) { self.fileURL = fileURL }

    func record(packageID: String, selectorKey: String, success: Bool, appVersion: String?, latencyMS: Int) {
        loadIfNeeded()
        let key = packageID + "\u{001F}" + selectorKey
        var item = evidence[key] ?? Evidence(
            packageID: packageID,
            selectorKey: selectorKey,
            successCount: 0,
            failureCount: 0,
            lastValidatedAppVersion: nil,
            averageLatencyMS: 0,
            lastUpdatedAt: Date()
        )
        if success { item.successCount += 1 } else { item.failureCount += 1 }
        let samples = max(1, item.successCount + item.failureCount)
        item.averageLatencyMS += (Double(latencyMS) - item.averageLatencyMS) / Double(samples)
        item.lastValidatedAppVersion = appVersion ?? item.lastValidatedAppVersion
        item.lastUpdatedAt = Date()
        evidence[key] = item
        persist()
    }

    func reliability(packageID: String, selectorKey: String) -> Double? {
        loadIfNeeded()
        return evidence[packageID + "\u{001F}" + selectorKey]?.reliability
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data) else { return }
        evidence = state.evidence
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(State(evidence: evidence)), data.count <= 2 * 1024 * 1024 else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum AppBackedProviderRuntimeError: Error, CustomStringConvertible {
    case notInstalled(String)
    case needsAuthorization(String)
    case needsLogin(String)
    case pluginUpdateRequired(String)
    case foregroundVerificationFailed(String)
    case composerUnavailable(String)
    case submissionFailed(String)
    case generationTimeout(String)
    case responseExtractionFailed(String)
    case responseValidationFailed(String)
    case targetRestoreFailed(String)

    var description: String {
        switch self {
        case .notInstalled(let value): return "App Provider 未安装：\(value)"
        case .needsAuthorization(let value): return "App Provider 尚未授权：\(value)"
        case .needsLogin(let value): return "App Provider 需要在官方 App 内登录：\(value)"
        case .pluginUpdateRequired(let value): return "App Provider UI 适配需要更新：\(value)"
        case .foregroundVerificationFailed(let value): return "App Provider 前台验证失败：\(value)"
        case .composerUnavailable(let value): return "App Provider 输入区域不可用：\(value)"
        case .submissionFailed(let value): return "App Provider Prompt 提交失败：\(value)"
        case .generationTimeout(let value): return "App Provider generation timeout：\(value)"
        case .responseExtractionFailed(let value): return "App Provider response extraction failed：\(value)"
        case .responseValidationFailed(let value): return "App Provider response validation failed：\(value)"
        case .targetRestoreFailed(let value): return "App Provider 目标 App 恢复失败：\(value)"
        }
    }
}

public actor AppBackedProviderRuntime: AppBackedProviderStreaming {
    struct SetupProbe: Sendable {
        var displayName: String
        var bundleID: String
        var appVersion: String
        var launchSchemes: [String]
        var visibleCandidates: [String]
        var proposedComposer: String?
        var proposedSend: String?
        var proposedReadyIndicator: String?
    }

    struct StatusSnapshot: Sendable {
        var state: AppBackedProviderAvailabilityState
        var hostState: AppBackedProviderHostState
        var detail: String
        var appVersion: String?
        var responseExtractionRoute: String?
        var generationLatencyMS: Int?
    }

    private struct Observation {
        var screenshot: Data
        var localVision: LocalVisionTextObservation.Observation
        var axElements: [LocalPerceptionTextElement]
        var appVersion: String
        var deviceClass: String
        var orientation: String
        var screenWidth: Double
        var screenHeight: Double
        var capturedAt: Date
    }

    private struct ResolvedSelector {
        var selector: AppProviderSelector
        var element: LocalPerceptionTextElement
        var source: String
        var score: Double
    }

    private let packageStore: AppProviderPackageStore
    private let appResolver: IOSAppResolver
    private let gui: GUIAutomationBackend
    private let authorizationStore: AppBackedProviderAuthorizationStore
    private let learningStore: AppBackedProviderLearningStore
    private let diagnosticLogger: DiagnosticLogStore?
    private var activePackageID: String?
    private var lastSnapshots: [String: StatusSnapshot] = [:]

    init(
        packageStore: AppProviderPackageStore,
        appResolver: IOSAppResolver,
        gui: GUIAutomationBackend,
        authorizationStore: AppBackedProviderAuthorizationStore = AppBackedProviderAuthorizationStore(),
        learningStore: AppBackedProviderLearningStore,
        diagnosticLogger: DiagnosticLogStore? = nil
    ) {
        self.packageStore = packageStore
        self.appResolver = appResolver
        self.gui = gui
        self.authorizationStore = authorizationStore
        self.learningStore = learningStore
        self.diagnosticLogger = diagnosticLogger
    }

    nonisolated public func imageCapability(configuration: AppBackedProviderConfiguration) async -> ProviderImageCapabilityAssessment {
        // First release transports text/context through the target App composer. Image attachment UI
        // is intentionally not claimed until a package has a proven attachment workflow.
        ProviderImageCapabilityAssessment(capability: .textOnly, source: "app_backed_text_composer")
    }

    public func setAuthorized(_ authorized: Bool, packageID: String) async {
        if authorized, let package = try? await packageStore.package(id: packageID) {
            await authorizationStore.setAuthorized(true, identity: Self.authorizationIdentity(for: package), packageID: packageID)
        } else {
            await authorizationStore.setAuthorized(false, identity: "", packageID: packageID)
        }
    }

    func status(packageID: String) -> StatusSnapshot? { lastSnapshots[packageID] }

    func setupProbe(packageID: String) async throws -> SetupProbe {
        let package = try await packageStore.package(id: packageID)
        guard let introspection = await appResolver.appIntrospection(bundleID: package.summary.manifest.bundleID) else {
            throw AppBackedProviderRuntimeError.notInstalled(package.summary.manifest.bundleID)
        }
        let launch = try await gui.openApp(bundleID: package.summary.manifest.bundleID)
        guard launch.accepted, launch.foregroundVerified else {
            throw AppBackedProviderRuntimeError.foregroundVerificationFailed(launch.detail)
        }
        let observation = try await observe(appVersion: introspection.version)
        var seen = Set<String>()
        let ordered = (observation.axElements + observation.localVision.elements)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard !value.isEmpty, value.count <= 160 else { return false }
                return seen.insert(value).inserted
            }
        func first(matching terms: [String]) -> String? {
            ordered.first { value in
                let lowered = value.lowercased()
                return terms.contains { lowered.contains($0.lowercased()) }
            }
        }
        let composer = first(matching: ["ask", "message", "问问", "发消息", "输入", "prompt"])
        let send = first(matching: ["send", "发送"])
        let ready = composer ?? ordered.first
        return SetupProbe(
            displayName: introspection.displayName,
            bundleID: introspection.bundleID,
            appVersion: introspection.version,
            launchSchemes: introspection.urlSchemes,
            visibleCandidates: Array(ordered.prefix(40)),
            proposedComposer: composer,
            proposedSend: send,
            proposedReadyIndicator: ready
        )
    }

    nonisolated public func stream(
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.runWithRecovery(configuration: configuration, messages: messages, tools: tools, continuation: continuation)
                    if !result.text.isEmpty { continuation.yield(.token(result.text)) }
                    for call in result.toolCalls {
                        continuation.yield(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ParsedResult {
        var text: String
        var toolCalls: [(id: String, name: String, argumentsJSON: String)]
    }

    private func runWithRecovery(
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema],
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws -> ParsedResult {
        var completedRetries = 0
        while true {
            do {
                return try await run(
                    configuration: configuration,
                    messages: messages,
                    tools: tools,
                    continuation: continuation
                )
            } catch let error as AppBackedProviderRuntimeError {
                let package = try await packageStore.package(id: configuration.packageID)
                let retryLimit = min(
                    package.workflow.retryBudget,
                    package.recovery.rules
                        .filter { $0.failure == "foreground_mismatch" && $0.action == "relaunch_once" }
                        .map(\.maxAttempts)
                        .max() ?? 0
                )
                guard case .foregroundVerificationFailed = error,
                      completedRetries < retryLimit else {
                    throw error
                }
                completedRetries += 1
                continuation.yield(.status("App Provider 前台验证失败；按 Package recovery 有界重试 \(completedRetries)/\(retryLimit)…"))
            }
        }
    }

    private func run(
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema],
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws -> ParsedResult {
        guard activePackageID == nil else {
            throw AppBackedProviderRuntimeError.submissionFailed("另一个 App-backed Provider inference 正在运行；手机前台 Provider 只能串行执行。")
        }
        activePackageID = configuration.packageID
        defer { activePackageID = nil }

        let package = try await packageStore.package(id: configuration.packageID)
        guard package.summary.enabled else {
            throw AppBackedProviderRuntimeError.needsAuthorization("Provider Package 已停用")
        }
        try await transition(.checkInstalled, state: .busy, detail: "检查目标 App 安装状态", package: package)
        guard let introspection = await appResolver.appIntrospection(bundleID: package.summary.manifest.bundleID) else {
            try await transition(.classify, state: .notInstalled, detail: package.summary.manifest.bundleID, package: package)
            throw AppBackedProviderRuntimeError.notInstalled(package.summary.manifest.bundleID)
        }

        try await transition(.checkAuthorization, state: .busy, detail: "检查 Cloud Code Provider 授权", package: package, appVersion: introspection.version)
        guard await authorizationStore.isAuthorized(identity: Self.authorizationIdentity(for: package)) else {
            try await transition(.classify, state: .needsAuthorization, detail: "等待用户授权使用已登录官方 App", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.needsAuthorization(package.summary.manifest.displayName)
        }

        try await transition(.checkCompatibility, state: .busy, detail: "检查 App 版本与 selector revision", package: package, appVersion: introspection.version)
        if !Self.versionCompatible(introspection.version, compatibility: package.summary.manifest.compatibility) {
            try await transition(.classify, state: .needsPluginUpdate, detail: "当前 App 版本 \(introspection.version) 超出 Provider Package 声明兼容范围", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.pluginUpdateRequired(introspection.version)
        }

        try await transition(.launchApp, state: .busy, detail: "启动 \(package.summary.manifest.displayName)", package: package, appVersion: introspection.version)
        try Task.checkCancellation()
        let launch = try await gui.openApp(bundleID: package.summary.manifest.bundleID)
        guard launch.accepted, launch.foregroundVerified else {
            try await transition(.classify, state: .degraded, detail: launch.detail, package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.foregroundVerificationFailed(launch.detail)
        }
        try await transition(.verifyForeground, state: .busy, detail: launch.detail, package: package, appVersion: introspection.version)

        var observation = try await observe(appVersion: introspection.version)
        try await transition(.verifyLogin, state: .busy, detail: "验证登录/可用状态", package: package, appVersion: introspection.version)
        if package.summary.manifest.requiresLogin,
           matchesAny(package.selectors.needsLoginIndicators, observation: observation, packageID: package.summary.id) {
            try await transition(.classify, state: .needsLogin, detail: "检测到登录入口/未登录状态", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.needsLogin(package.summary.manifest.displayName)
        }
        if package.summary.manifest.requiresLogin,
           !package.selectors.readyIndicators.isEmpty,
           !matchesAny(package.selectors.readyIndicators, observation: observation, packageID: package.summary.id) {
            // Do not guess between UI incompatibility and logged-out state. A package with mandatory
            // readiness evidence fails closed until a visible signal is recovered.
            try await transition(.classify, state: .degraded, detail: "未发现声明的 READY indicator", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.pluginUpdateRequired("READY selector 未匹配")
        }

        try await transition(.prepareSession, state: .busy, detail: "准备隔离的 Provider 请求上下文", package: package, appVersion: introspection.version)
        if package.workflow.preferNewConversation,
           let newConversation = await resolve(package.selectors.newConversation, observation: observation, packageID: package.summary.id, appVersion: introspection.version) {
            try Task.checkCancellation()
            try await gui.tap(x: newConversation.element.centerX, y: newConversation.element.centerY)
            try await Self.sleep(seconds: 0.35)
            observation = try await observe(appVersion: introspection.version)
        }

        let requestID = UUID().uuidString.uppercased()
        let expectedTag = Self.expectedTag(for: requestID)
        let prompt = Self.providerPrompt(
            requestID: requestID,
            package: package,
            configuration: configuration,
            messages: messages,
            tools: tools
        )

        continuation.yield(.status("App Provider 正在定位输入区域…"))
        try await transition(.locateComposer, state: .busy, detail: "定位输入区域", package: package, appVersion: introspection.version)
        guard let composer = await resolve(package.selectors.composer, observation: observation, packageID: package.summary.id, appVersion: introspection.version) else {
            try await transition(.classify, state: .needsPluginUpdate, detail: "composer selector 未匹配", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.composerUnavailable("没有高置信 composer selector")
        }
        try Task.checkCancellation()
        try await gui.tap(x: composer.element.centerX, y: composer.element.centerY)
        try await Self.sleep(seconds: 0.15)

        try await transition(.submit, state: .busy, detail: "输入带 request nonce 的 Provider Prompt", package: package, appVersion: introspection.version)
        try Task.checkCancellation()
        try await gui.type(prompt)
        observation = try await observe(appVersion: introspection.version)
        guard let send = await resolve(package.selectors.send, observation: observation, packageID: package.summary.id, appVersion: introspection.version) else {
            try await transition(.classify, state: .needsPluginUpdate, detail: "send selector 未匹配；不会使用未绑定坐标盲点", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.submissionFailed("send selector 未匹配")
        }
        try Task.checkCancellation()
        try await gui.tap(x: send.element.centerX, y: send.element.centerY)
        try await transition(.verifySubmission, state: .busy, detail: "Prompt 已派发；等待 generation 状态变化", package: package, appVersion: introspection.version)

        let generationStartedAt = Date()
        continuation.yield(.status("App Provider 正在生成…"))
        try await transition(.waitGenerationStart, state: .busy, detail: "等待 generation start", package: package, appVersion: introspection.version)
        let startDeadline = Date().addingTimeInterval(package.workflow.generationStartTimeoutSeconds)
        var lastObservedText = ""
        var sawGenerationSignal = package.selectors.generationStart.isEmpty
        while Date() < startDeadline {
            try Task.checkCancellation()
            observation = try await observe(appVersion: introspection.version)
            if matchesAny(package.selectors.generationStart, observation: observation, packageID: package.summary.id) {
                sawGenerationSignal = true
                break
            }
            let text = Self.visibleText(observation)
            if text != lastObservedText && !text.isEmpty {
                sawGenerationSignal = true
                break
            }
            lastObservedText = text
            try await Self.sleep(seconds: package.workflow.pollIntervalSeconds)
        }
        guard sawGenerationSignal else {
            try await transition(.classify, state: .timeout, detail: "generation start timeout", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.generationTimeout("generation start timeout")
        }

        try await transition(.waitGeneration, state: .busy, detail: "等待 bounded stable window", package: package, appVersion: introspection.version)
        let generationDeadline = Date().addingTimeInterval(package.workflow.generationTimeoutSeconds)
        var stableSince: Date?
        var previousSignature = ""
        var finalObservation = observation
        while Date() < generationDeadline {
            try Task.checkCancellation()
            let current = try await observe(appVersion: introspection.version)
            finalObservation = current
            let signature = Self.visibleText(current)
            let completionSignal = package.selectors.generationComplete.isEmpty
                || matchesAny(package.selectors.generationComplete, observation: current, packageID: package.summary.id)
            if signature == previousSignature, !signature.isEmpty, completionSignal {
                if stableSince == nil { stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) >= package.workflow.stableWindowSeconds { break }
            } else {
                previousSignature = signature
                stableSince = nil
            }
            try await Self.sleep(seconds: package.workflow.pollIntervalSeconds)
        }
        guard let stableSince, Date().timeIntervalSince(stableSince) >= package.workflow.stableWindowSeconds else {
            try await transition(.classify, state: .timeout, detail: "generation completion timeout", package: package, appVersion: introspection.version)
            throw AppBackedProviderRuntimeError.generationTimeout("generation completion timeout")
        }

        try await transition(.extractResponse, state: .busy, detail: "按 AX → Copy/Clipboard → OCR 顺序提取回答", package: package, appVersion: introspection.version)
        let extraction = try await extractResponse(package: package, observation: finalObservation, expectedTag: expectedTag, appVersion: introspection.version)
        let latencyMS = max(0, Int(Date().timeIntervalSince(generationStartedAt) * 1_000))
        try await transition(.validateResponse, state: .busy, detail: "验证本轮响应标签，防止把输入回显或旧回答误当成本轮结果", package: package, appVersion: introspection.version, extractionRoute: extraction.route, latencyMS: latencyMS)
        guard let boundedText = Self.boundText(extraction.text, expectedTag: expectedTag) else {
            try await transition(.classify, state: .degraded, detail: "当前回答未包含本轮响应标签", package: package, appVersion: introspection.version, extractionRoute: extraction.route, latencyMS: latencyMS)
            throw AppBackedProviderRuntimeError.responseValidationFailed("当前回答无法绑定本轮响应")
        }

        let parsed = Self.parseResponse(boundedText, expectedTag: expectedTag, tools: tools)
        try await restoreTargetIfNeeded(configuration: configuration, package: package, appVersion: introspection.version, extractionRoute: extraction.route, latencyMS: latencyMS)
        try await transition(.done, state: .ready, detail: "App-backed Provider inference 完成", package: package, appVersion: introspection.version, extractionRoute: extraction.route, latencyMS: latencyMS)
        return parsed
    }

    private func observe(appVersion: String) async throws -> Observation {
        let screenshot = try await gui.screenshot()
        async let local = LocalVisionTextObservation.observe(for: screenshot, maximumElements: 48, requiresText: false)
        var ax: [LocalPerceptionTextElement] = []
        if ProductionPerceptionPolicy.accessibilityRuntimeAllowed,
           let tree = try? await gui.tree() {
            ax = LocalAXTreeTextExtractor.extract(from: tree, maximumElements: 96)
        }
        let deviceContext = await MainActor.run { () -> (String, Double, Double) in
            let bounds = UIScreen.main.bounds
            return (UIDevice.current.model, Double(bounds.width), Double(bounds.height))
        }
        let deviceClass = deviceContext.0
        let width = deviceContext.1
        let height = deviceContext.2
        return Observation(
            screenshot: screenshot,
            localVision: await local,
            axElements: ax,
            appVersion: appVersion,
            deviceClass: deviceClass,
            orientation: width > height ? "landscape" : "portrait",
            screenWidth: width,
            screenHeight: height,
            capturedAt: Date()
        )
    }

    private func matchesAny(_ selectors: [AppProviderSelector], observation: Observation, packageID: String) -> Bool {
        for selector in selectors {
            if Self.match(selector, observation: observation) != nil { return true }
        }
        return false
    }

    private func resolve(
        _ selectors: [AppProviderSelector],
        observation: Observation,
        packageID: String,
        appVersion: String?
    ) async -> ResolvedSelector? {
        var matches: [ResolvedSelector] = []
        for selector in selectors {
            guard let resolved = Self.match(selector, observation: observation) else { continue }
            let key = Self.selectorKey(selector)
            let learned = await learningStore.reliability(packageID: packageID, selectorKey: key) ?? 0.5
            var candidate = resolved
            candidate.score = resolved.score * 0.85 + learned * 0.15
            matches.append(candidate)
        }
        guard let winner = matches.max(by: { $0.score < $1.score }), winner.score >= winner.selector.minimumConfidence else { return nil }
        return winner
    }

    private static func match(_ selector: AppProviderSelector, observation: Observation) -> ResolvedSelector? {
        let candidates: [LocalPerceptionTextElement]
        let source: String
        switch selector.strategy {
        case .accessibilityIdentifier, .axRole, .semanticLabel:
            guard ProductionPerceptionPolicy.accessibilityRuntimeAllowed else { return nil }
            candidates = observation.axElements
            source = "ax"
        case .visibleText, .ocrText, .relativeLayout:
            candidates = observation.localVision.elements
            source = "ocr"
        case .coordinateFallback:
            guard let coordinate = selector.coordinate,
                  coordinate.deviceClass.caseInsensitiveCompare(observation.deviceClass) == .orderedSame,
                  coordinate.orientation.caseInsensitiveCompare(observation.orientation) == .orderedSame,
                  coordinate.appVersion == observation.appVersion,
                  abs(coordinate.screenWidth - observation.screenWidth) <= 1,
                  abs(coordinate.screenHeight - observation.screenHeight) <= 1 else { return nil }
            let element = LocalPerceptionTextElement(text: "coordinate-fallback", confidence: 0.5, x: coordinate.x, y: coordinate.y, width: 1, height: 1)
            return ResolvedSelector(selector: selector, element: element, source: "coordinate_fallback", score: 0.5)
        }

        if selector.strategy == .axRole, let role = selector.role, !role.isEmpty {
            // Current LocalPerceptionTextElement intentionally strips raw AX role. A role-only
            // selector therefore cannot be considered high-confidence after extraction; packages
            // should pair it with identifier/semantic text until the host exposes structured role.
            if let value = selector.value, !value.isEmpty,
               case .unique(let element) = LocalPerceptionTextMatcher.resolve(query: value, mode: .contains, elements: candidates) {
                return ResolvedSelector(selector: selector, element: element, source: source, score: max(0.8, element.confidence))
            }
            return nil
        }
        let value = selector.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        let mode: GUIElementMatchMode = selector.strategy == .visibleText || selector.strategy == .ocrText ? .contains : .exact
        switch LocalPerceptionTextMatcher.resolve(query: value, mode: mode, elements: candidates) {
        case .unique(let element):
            return ResolvedSelector(selector: selector, element: element, source: source, score: max(0.5, element.confidence))
        case .notFound, .ambiguous:
            return nil
        }
    }

    private func extractResponse(
        package: AppProviderPackage,
        observation: Observation,
        expectedTag: String,
        appVersion: String?
    ) async throws -> (text: String, route: String) {
        for extractor in package.summary.manifest.responseExtractors {
            let started = Date()
            switch extractor.kind {
            case .axText:
                guard ProductionPerceptionPolicy.accessibilityRuntimeAllowed else { continue }
                let text = observation.axElements.map(\.text).joined(separator: "\n")
                if let bound = Self.boundText(text, expectedTag: expectedTag), bound.count >= extractor.minimumCharacters {
                    await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.ax", success: true, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
                    return (bound, "ax_text")
                }
                await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.ax", success: false, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
            case .copyClipboard:
                guard let copy = await resolve(package.selectors.copyButton + extractor.selectors, observation: observation, packageID: package.summary.id, appVersion: appVersion) else { continue }
                let beforeItems = await MainActor.run { UIPasteboard.general.items }
                do { try await gui.tap(x: copy.element.centerX, y: copy.element.centerY) }
                catch { continue }
                try? await Task.sleep(nanoseconds: 250_000_000)
                let after = await MainActor.run { UIPasteboard.general.string }
                await MainActor.run { UIPasteboard.general.items = beforeItems }
                if let after, let bound = Self.boundText(after, expectedTag: expectedTag), bound.count >= extractor.minimumCharacters {
                    await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.clipboard", success: true, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
                    return (bound, "copy_clipboard")
                }
                await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.clipboard", success: false, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
            case .ocrRegion:
                let text: String
                if let region = extractor.region,
                   let image = UIImage(data: observation.screenshot) {
                    let rect = CGRect(
                        x: region.x * image.size.width,
                        y: region.y * image.size.height,
                        width: region.width * image.size.width,
                        height: region.height * image.size.height
                    )
                    let regionObservation = await LocalVisionTextObservation.observe(
                        for: observation.screenshot,
                        maximumElements: 48,
                        regionInScreenPoints: rect,
                        requiresText: true,
                        forcePrecise: true
                    )
                    text = regionObservation.elements.map(\.text).joined(separator: "\n")
                } else {
                    text = observation.localVision.elements.map(\.text).joined(separator: "\n")
                }
                if let bound = Self.boundText(text, expectedTag: expectedTag), bound.count >= extractor.minimumCharacters {
                    await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.ocr", success: true, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
                    return (bound, "ocr_region")
                }
                await learningStore.record(packageID: package.summary.id, selectorKey: "extractor.ocr", success: false, appVersion: appVersion, latencyMS: Int(Date().timeIntervalSince(started) * 1_000))
            }
        }
        throw AppBackedProviderRuntimeError.responseExtractionFailed("AX/Clipboard/OCR 均未提取到绑定本轮响应标签的回答")
    }

    private func restoreTargetIfNeeded(
        configuration: AppBackedProviderConfiguration,
        package: AppProviderPackage,
        appVersion: String,
        extractionRoute: String,
        latencyMS: Int
    ) async throws {
        guard let targetBundleID = configuration.restoreTargetBundleID,
              targetBundleID != package.summary.manifest.bundleID else {
            try await transition(.restoreTarget, state: .busy, detail: "本轮没有可验证的先前目标 App；不执行猜测性切换", package: package, appVersion: appVersion, extractionRoute: extractionRoute, latencyMS: latencyMS)
            return
        }
        try await transition(.restoreTarget, state: .busy, detail: "恢复 Provider 调用前的目标 App", package: package, appVersion: appVersion, extractionRoute: extractionRoute, latencyMS: latencyMS)
        do {
            let restored = try await gui.openApp(bundleID: targetBundleID)
            guard restored.accepted, restored.foregroundVerified else {
                try await transition(.restoreTarget, state: .degraded, detail: restored.detail, package: package, appVersion: appVersion, extractionRoute: extractionRoute, latencyMS: latencyMS)
                throw AppBackedProviderRuntimeError.targetRestoreFailed(restored.detail)
            }
            try await transition(.restoreTarget, state: .busy, detail: restored.detail, package: package, appVersion: appVersion, extractionRoute: extractionRoute, latencyMS: latencyMS)
        } catch let error as AppBackedProviderRuntimeError {
            throw error
        } catch {
            try await transition(.restoreTarget, state: .degraded, detail: "目标 App 恢复失败：\(error)", package: package, appVersion: appVersion, extractionRoute: extractionRoute, latencyMS: latencyMS)
            throw AppBackedProviderRuntimeError.targetRestoreFailed(String(describing: error))
        }
    }

    private func transition(
        _ hostState: AppBackedProviderHostState,
        state: AppBackedProviderAvailabilityState,
        detail: String,
        package: AppProviderPackage,
        appVersion: String? = nil,
        extractionRoute: String? = nil,
        latencyMS: Int? = nil
    ) async throws {
        lastSnapshots[package.summary.id] = StatusSnapshot(
            state: state,
            hostState: hostState,
            detail: detail,
            appVersion: appVersion,
            responseExtractionRoute: extractionRoute,
            generationLatencyMS: latencyMS
        )
        try? await diagnosticLogger?.log(
            level: state == .degraded || state == .needsPluginUpdate || state == .timeout ? .warning : .info,
            subsystem: "app-provider",
            action: hostState.rawValue,
            result: state.rawValue,
            diagnostic: detail,
            metadata: [
                "packageID": package.summary.id,
                "bundleID": package.summary.manifest.bundleID,
                "appVersion": appVersion ?? "",
                "selectorRevision": package.summary.manifest.compatibility.selectorRevision,
                "responseExtractionRoute": extractionRoute ?? "",
                "generationLatencyMS": latencyMS.map(String.init) ?? ""
            ]
        )
    }

    private static func providerPrompt(
        requestID: String,
        package: AppProviderPackage,
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> String {
        let boundedMessages = messages.suffix(18).map { message in
            let role = message.role.rawValue.uppercased()
            return "[\(role)]\n\(String(message.content.prefix(12_000)))"
        }.joined(separator: "\n\n")
        let toolText = tools.prefix(40).map { tool in
            let required = tool.required.joined(separator: ",")
            let props = tool.properties.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            return "- \(tool.name)(\(props)) required=[\(required)]: \(tool.description)"
        }.joined(separator: "\n")
        let prefix = package.workflow.requestPrefix.replacingOccurrences(of: "{{request_id}}", with: requestID)
        let suffix = package.workflow.requestSuffix.replacingOccurrences(of: "{{request_id}}", with: requestID)
        let packagePrompt = String((package.prompts ?? "").prefix(8_000))
        return String("""
        \(prefix)
        PACKAGE INSTRUCTIONS (declarative, non-authoritative for device execution):
        \(packagePrompt)
        APP_PROVIDER_PACKAGE=\(package.summary.id)
        AGENT_SESSION_ID=\(configuration.agentSessionID.uuidString)
        RESPONSE CONTRACT:
        Begin the final answer with CLOUDCODE_RESPONSE_ID= followed by the CLOUDCODE_REQUEST_ID characters reversed exactly, including hyphens. Do not repeat the original request ID in the final answer.
        You may return normal text. If a Cloud Code tool is needed, return JSON using one of these provider-safe tool names. The App Provider itself never executes tools or root/helper commands.
        AVAILABLE TOOLS:
        \(toolText)

        CURRENT CLOUD CODE CONTEXT:
        \(boundedMessages)
        \(suffix)
        """.prefix(48_000))
    }

    private static func expectedTag(for requestID: String) -> String {
        "CLOUDCODE_RESPONSE_ID=" + String(requestID.reversed())
    }

    private static func boundText(_ raw: String, expectedTag: String) -> String? {
        guard let range = raw.range(of: expectedTag, options: [.backwards, .caseInsensitive]) else { return nil }
        let suffix = String(raw[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.range(of: expectedTag, options: [.anchored, .caseInsensitive]) != nil else { return nil }
        return suffix
    }

    private static func parseResponse(_ raw: String, expectedTag: String, tools: [ProviderToolSchema]) -> ParsedResult {
        let allowed = Set(tools.map(\.name))
        guard let bounded = boundText(raw, expectedTag: expectedTag) else {
            return ParsedResult(text: "", toolCalls: [])
        }
        var cleaned = String(bounded.dropFirst(expectedTag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        var calls: [(id: String, name: String, argumentsJSON: String)] = []

        func appendCall(name: String, arguments: Any, id: String?) {
            guard allowed.contains(name), JSONSerialization.isValidJSONObject(arguments),
                  let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            calls.append((id?.isEmpty == false ? id! : "app-provider-\(UUID().uuidString)", name, json))
        }

        if cleaned.hasPrefix("{"), cleaned.hasSuffix("}"),
           let data = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tool = object["tool"] as? String,
               let arguments = object["arguments"] as? [String: Any] {
                appendCall(name: tool, arguments: arguments, id: object["id"] as? String)
                cleaned = ""
            } else if let items = object["tool_calls"] as? [[String: Any]] {
                for item in items {
                    guard let name = item["name"] as? String,
                          let arguments = item["arguments"] as? [String: Any] else { continue }
                    appendCall(name: name, arguments: arguments, id: item["id"] as? String)
                }
                cleaned = object["text"] as? String ?? ""
            }
        }
        return ParsedResult(text: cleaned, toolCalls: calls)
    }

    private static func authorizationIdentity(for package: AppProviderPackage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var material = Data()
        let documents: [Data] = [
            try? encoder.encode(package.summary.manifest),
            try? encoder.encode(package.selectors),
            try? encoder.encode(package.workflow),
            try? encoder.encode(package.recovery),
            package.prompts?.data(using: .utf8)
        ].compactMap { $0 }
        for document in documents {
            material.append(document)
            material.append(0)
        }
        let digest = SHA256.hash(data: material)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return package.summary.id + "|" + hex
    }

    private static func visibleText(_ observation: Observation) -> String {
        let ax = observation.axElements.map(\.text)
        let ocr = observation.localVision.elements.map(\.text)
        return (ax + ocr).joined(separator: "\n")
    }

    private static func selectorKey(_ selector: AppProviderSelector) -> String {
        [selector.strategy.rawValue, selector.value ?? "", selector.role ?? "", selector.relation ?? ""].joined(separator: "|")
    }

    private static func versionCompatible(_ version: String, compatibility: AppProviderCompatibility) -> Bool {
        if let min = compatibility.minimumAppVersion, compareVersion(version, min) == .orderedAscending { return false }
        if let max = compatibility.maximumAppVersion, compareVersion(version, max) == .orderedDescending { return false }
        return true
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func sleep(seconds: Double) async throws {
        let ns = UInt64(max(0.05, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
    }
}
