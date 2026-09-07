import Foundation
import CryptoKit

public enum DiagnosticFailureLayer: String, Codable, CaseIterable, Sendable {
    case provider
    case providerRoute = "provider_route"
    case agentPlanning = "agent_planning"
    case toolRouting = "tool_routing"
    case nativeExecution = "native_execution"
    case privilegedHelper = "privileged_helper"
    case appResolution = "app_resolution"
    case axObservation = "ax_observation"
    case localVision = "local_vision"
    case guiGesture = "gui_gesture"
    case guiTextInput = "gui_text_input"
    case guiNavigation = "gui_navigation"
    case guiVerification = "gui_verification"
    case backgroundLifecycle = "background_lifecycle"
    case checkpointResume = "checkpoint_resume"
    case resourceIndex = "resource_index"
    case appKnowledge = "app_knowledge"
    case policy
    case unknown
}

public enum DiagnosticReplayability: String, Codable, Sendable {
    case deterministic
    case observationReplay = "observation_replay"
    case realDeviceRequired = "real_device_required"
}

public enum DiagnosticRegressionStatus: String, Codable, Sendable {
    case candidate
    case covered
    case realDeviceOnly = "real_device_only"
}

public struct DiagnosticPerformanceSnapshot: Codable, Equatable, Sendable {
    public var totalTaskLatencyMS: Int?
    public var providerRoundTrips: Int
    public var remoteVisionRoundTrips: Int
    public var screenshotCount: Int
    public var axObservationCount: Int
    public var localVisionCount: Int
    public var nativeToolCount: Int
    public var guiActionCount: Int
    public var fallbackCount: Int

    public init(
        totalTaskLatencyMS: Int? = nil,
        providerRoundTrips: Int = 0,
        remoteVisionRoundTrips: Int = 0,
        screenshotCount: Int = 0,
        axObservationCount: Int = 0,
        localVisionCount: Int = 0,
        nativeToolCount: Int = 0,
        guiActionCount: Int = 0,
        fallbackCount: Int = 0
    ) {
        self.totalTaskLatencyMS = totalTaskLatencyMS
        self.providerRoundTrips = max(0, providerRoundTrips)
        self.remoteVisionRoundTrips = max(0, remoteVisionRoundTrips)
        self.screenshotCount = max(0, screenshotCount)
        self.axObservationCount = max(0, axObservationCount)
        self.localVisionCount = max(0, localVisionCount)
        self.nativeToolCount = max(0, nativeToolCount)
        self.guiActionCount = max(0, guiActionCount)
        self.fallbackCount = max(0, fallbackCount)
    }
}

public struct DiagnosticBugCapsule: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var capsuleId: String
    public var sessionId: String?
    public var taskId: String?
    public var checkpointId: String?
    public var cloudCodeBuild: String
    public var commitSHA: String?
    public var iOSVersion: String
    public var deviceClass: String
    public var appBundleId: String?
    public var appVersion: String?
    public var providerId: String?
    public var modelId: String?
    public var protocolClass: String?
    public var userGoalSummary: String
    public var expectedOutcome: String
    public var observedOutcome: String
    public var failureLayer: DiagnosticFailureLayer
    public var failureStage: String
    public var failureSignature: String
    public var fallbackPath: String?
    public var verificationStatus: String
    public var replayability: DiagnosticReplayability
    public var regressionStatus: DiagnosticRegressionStatus
    public var performance: DiagnosticPerformanceSnapshot
    public var firstObservedAt: Date
    public var evidenceRecordIds: [String]

    public init(
        schemaVersion: Int = 1,
        capsuleId: String,
        sessionId: String?,
        taskId: String? = nil,
        checkpointId: String? = nil,
        cloudCodeBuild: String,
        commitSHA: String? = nil,
        iOSVersion: String,
        deviceClass: String,
        appBundleId: String? = nil,
        appVersion: String? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        protocolClass: String? = nil,
        userGoalSummary: String,
        expectedOutcome: String,
        observedOutcome: String,
        failureLayer: DiagnosticFailureLayer,
        failureStage: String,
        failureSignature: String,
        fallbackPath: String? = nil,
        verificationStatus: String,
        replayability: DiagnosticReplayability,
        regressionStatus: DiagnosticRegressionStatus,
        performance: DiagnosticPerformanceSnapshot,
        firstObservedAt: Date,
        evidenceRecordIds: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.capsuleId = capsuleId
        self.sessionId = sessionId
        self.taskId = taskId
        self.checkpointId = checkpointId
        self.cloudCodeBuild = cloudCodeBuild
        self.commitSHA = commitSHA
        self.iOSVersion = iOSVersion
        self.deviceClass = deviceClass
        self.appBundleId = appBundleId
        self.appVersion = appVersion
        self.providerId = providerId
        self.modelId = modelId
        self.protocolClass = protocolClass
        self.userGoalSummary = userGoalSummary
        self.expectedOutcome = expectedOutcome
        self.observedOutcome = observedOutcome
        self.failureLayer = failureLayer
        self.failureStage = failureStage
        self.failureSignature = failureSignature
        self.fallbackPath = fallbackPath
        self.verificationStatus = verificationStatus
        self.replayability = replayability
        self.regressionStatus = regressionStatus
        self.performance = performance
        self.firstObservedAt = firstObservedAt
        self.evidenceRecordIds = evidenceRecordIds
    }
}

public struct DiagnosticReplayArtifact: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var capsuleId: String
    public var replayability: DiagnosticReplayability
    public var failureSignature: String
    public var sanitizedEvidence: [DiagnosticReplayEvidence]
    public var requiresLiveSideEffect: Bool

    public init(capsule: DiagnosticBugCapsule, sanitizedEvidence: [DiagnosticReplayEvidence]) {
        schemaVersion = 1
        capsuleId = capsule.capsuleId
        replayability = capsule.replayability
        failureSignature = capsule.failureSignature
        self.sanitizedEvidence = sanitizedEvidence
        requiresLiveSideEffect = capsule.replayability == .realDeviceRequired
    }
}

public struct DiagnosticReplayEvidence: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var subsystem: String
    public var action: String
    public var result: String
    public var errorDomain: String?
    public var errorCode: Int?
    public var metadata: [String: String]

    public init(record: DiagnosticLogRecord) {
        let safe = DiagnosticRedactor.redact(record: record)
        timestamp = safe.timestamp
        subsystem = safe.subsystem
        action = safe.action
        result = safe.result
        errorDomain = safe.errorDomain
        errorCode = safe.errorCode
        metadata = Self.replaySafeMetadata(safe.metadata)
    }

    private static func replaySafeMetadata(_ metadata: [String: String]) -> [String: String] {
        let allowed = Set([
            "provider", "providerID", "providerId", "model", "modelID", "modelId", "protocol", "protocolClass",
            "statusCode", "httpStatus", "errorClass", "retryReason", "fallbackReason", "fallbackDepth", "route", "routeCandidates",
            "authMode", "host", "endpointPath", "transportState", "responseStarted", "streamEstablished", "bodyDataReceived",
            "foregroundBundleID", "bundleID", "bundleId", "appVersion", "verification", "effectVerification",
            "perceptionClass", "perceptionAXAttempted", "perceptionAXSucceeded", "perceptionAnchorCacheHit",
            "perceptionOCRInvoked", "perceptionOCRSucceeded", "perceptionOCRLatencyMS", "perceptionLocalSufficient",
            "perceptionRemoteVisionRequired", "perceptionFallbackReason", "providerVisualRoundTripAvoided",
            "sha256", "screenPointWidth", "screenPointHeight", "localVisionOCR", "localVisionElementCount",
            "localVisionCoordinateSpace", "localVisionLatencyMS", "localVisionRegion", "localVisionRecognitionLevel", "localVisionFallbackUsed",
            "localVisionErrorDomain", "localVisionErrorCode", "localVisionPrimaryErrorDomain", "localVisionPrimaryErrorCode", "treeHash",
            "coordinateSafety", "providerImageRoute", "keyboardLikely", "focusStrategy", "textInputSafety", "cache", "idempotency",
            "routeSelectionLatencyMS", "executionLatencyMS", "totalLatencyMS"
        ])
        var result: [String: String] = [:]
        for key in metadata.keys.sorted() where allowed.contains(key) {
            result[key] = DiagnosticRedactor.redact(metadata[key] ?? "")
        }
        return result
    }
}

public struct DiagnosticRegressionManifestEntry: Codable, Equatable, Sendable {
    public var capsuleId: String
    public var failureSignature: String
    public var scenarioId: String
    public var firstSeenBuild: String
    public var lastSeenBuild: String
    public var regressionExists: Bool
    public var regressionTestId: String?
    public var latestRegressionStatus: DiagnosticRegressionStatus
    public var requiresRealDevice: Bool
}

public struct DiagnosticRegressionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [DiagnosticRegressionManifestEntry]

    public init(capsules: [DiagnosticBugCapsule]) {
        schemaVersion = 1
        let grouped = Dictionary(grouping: capsules, by: \.failureSignature)
        entries = grouped.keys.sorted().compactMap { signature in
            guard let values = grouped[signature]?.sorted(by: { $0.firstObservedAt < $1.firstObservedAt }),
                  let first = values.first,
                  let last = values.last else { return nil }
            return DiagnosticRegressionManifestEntry(
                capsuleId: last.capsuleId,
                failureSignature: signature,
                scenarioId: "scenario.\(signature)",
                firstSeenBuild: first.cloudCodeBuild,
                lastSeenBuild: last.cloudCodeBuild,
                regressionExists: false,
                regressionTestId: nil,
                latestRegressionStatus: last.regressionStatus,
                requiresRealDevice: values.contains { $0.replayability == .realDeviceRequired }
            )
        }
    }
}

public struct DiagnosticProblemSummary: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var build: String
    public var timestamp: Date
    public var sessionsWithFailures: Int
    public var capsuleCount: Int
    public var topFailures: [String: Int]
    public var affectedSubsystems: [String: Int]
    public var providerFailures: Int
    public var guiFailures: Int
    public var backgroundFailures: Int
    public var replayableCapsules: Int
    public var realDeviceRequiredCapsules: Int
    public var executionMetricCount: Int

    public init(build: String, capsules: [DiagnosticBugCapsule], executionMetricCount: Int, timestamp: Date = Date()) {
        schemaVersion = 1
        self.build = build
        self.timestamp = timestamp
        sessionsWithFailures = Set(capsules.compactMap(\.sessionId)).count
        capsuleCount = capsules.count
        topFailures = Self.count(capsules.map(\.failureSignature))
        affectedSubsystems = Self.count(capsules.map { $0.failureLayer.rawValue })
        providerFailures = capsules.filter { $0.failureLayer == .provider || $0.failureLayer == .providerRoute }.count
        guiFailures = capsules.filter { $0.failureLayer.rawValue.hasPrefix("gui_") || $0.failureLayer == .axObservation || $0.failureLayer == .localVision }.count
        backgroundFailures = capsules.filter { $0.failureLayer == .backgroundLifecycle || $0.failureLayer == .checkpointResume }.count
        replayableCapsules = capsules.filter { $0.replayability != .realDeviceRequired }.count
        realDeviceRequiredCapsules = capsules.filter { $0.replayability == .realDeviceRequired }.count
        self.executionMetricCount = max(0, executionMetricCount)
    }

    private static func count(_ values: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for value in values where !value.isEmpty { result[value, default: 0] += 1 }
        return result
    }
}

public struct DiagnosticProblemContext: Sendable, Equatable {
    public var build: String
    public var commitSHA: String?
    public var iOSVersion: String
    public var deviceClass: String
    public var providerId: String?
    public var modelId: String?

    public init(build: String, commitSHA: String? = nil, iOSVersion: String, deviceClass: String, providerId: String? = nil, modelId: String? = nil) {
        self.build = build
        self.commitSHA = commitSHA
        self.iOSVersion = iOSVersion
        self.deviceClass = deviceClass
        self.providerId = providerId
        self.modelId = modelId
    }
}

public struct DiagnosticGoldenTaskScenario: Codable, Equatable, Sendable {
    public var scenarioId: String
    public var capability: String
    public var replayability: DiagnosticReplayability

    public init(scenarioId: String, capability: String, replayability: DiagnosticReplayability) {
        self.scenarioId = scenarioId
        self.capability = capability
        self.replayability = replayability
    }
}

public enum DiagnosticGoldenTaskMatrix {
    public static let scenarios: [DiagnosticGoldenTaskScenario] = [
        .init(scenarioId: "golden.native_file_lookup", capability: "native file lookup", replayability: .deterministic),
        .init(scenarioId: "golden.sqlite_query", capability: "sqlite query", replayability: .deterministic),
        .init(scenarioId: "golden.provider_switch_request", capability: "provider switch/request", replayability: .deterministic),
        .init(scenarioId: "golden.provider_tool_calling", capability: "provider tool calling", replayability: .deterministic),
        .init(scenarioId: "golden.app_launch", capability: "app launch", replayability: .realDeviceRequired),
        .init(scenarioId: "golden.gui_swipe_sequence", capability: "GUI swipe sequence", replayability: .realDeviceRequired),
        .init(scenarioId: "golden.feed_sample", capability: "feed sample", replayability: .observationReplay),
        .init(scenarioId: "golden.ax_element_lookup", capability: "AX element lookup", replayability: .observationReplay),
        .init(scenarioId: "golden.text_input", capability: "text input", replayability: .realDeviceRequired),
        .init(scenarioId: "golden.navigation_back", capability: "navigation back", replayability: .realDeviceRequired),
        .init(scenarioId: "golden.action_verification", capability: "action verification", replayability: .observationReplay),
        .init(scenarioId: "golden.ax_failure_screenshot_fallback", capability: "AX failure to screenshot fallback", replayability: .observationReplay),
        .init(scenarioId: "golden.background_checkpoint_resume", capability: "background checkpoint/resume", replayability: .realDeviceRequired),
        .init(scenarioId: "golden.provider_fallback_no_replay", capability: "provider fallback/no-replay safety", replayability: .deterministic)
    ]
}

public struct DiagnosticProblemPackage: Sendable {
    public var capsules: [DiagnosticBugCapsule]
    public var replayArtifacts: [DiagnosticReplayArtifact]
    public var regressionManifest: DiagnosticRegressionManifest
    public var summary: DiagnosticProblemSummary
    public var executionMetrics: [ExecutionPathMetric]

    public func generatedFiles() throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files: [String: Data] = [
            "diagnostics/summary.json": try encoder.encode(summary),
            "diagnostics/bug-capsules.json": try encoder.encode(capsules),
            "regression/regression-manifest.json": try encoder.encode(regressionManifest),
            "regression/golden-task-matrix.json": try encoder.encode(DiagnosticGoldenTaskMatrix.scenarios),
            "metrics/execution-path-metrics.json": try encoder.encode(executionMetrics)
        ]
        for artifact in replayArtifacts {
            files["replay/\(artifact.replayability.rawValue)/\(artifact.capsuleId).json"] = try encoder.encode(artifact)
        }
        return files
    }
}

public enum DiagnosticProblemPackageBuilder {
    public static func build(
        records: [DiagnosticLogRecord],
        executionMetrics: [ExecutionPathMetric],
        context: DiagnosticProblemContext,
        maximumCapsules: Int = 128
    ) -> DiagnosticProblemPackage {
        let safeRecords = records.map(DiagnosticRedactor.redact(record:))
        let candidates = safeRecords.filter(isCapsuleCandidate)
        let bounded = Array(candidates.suffix(min(max(maximumCapsules, 1), 256)))
        let groupedBySession = Dictionary(grouping: safeRecords, by: { $0.sessionID })

        var capsules: [DiagnosticBugCapsule] = []
        capsules.reserveCapacity(bounded.count)
        for record in bounded {
            let layer = failureLayer(for: record)
            let stage = failureStage(for: record, layer: layer)
            let signature = failureSignature(for: record, layer: layer, stage: stage)
            let sessionRecords = groupedBySession[record.sessionID] ?? [record]
            let replayability = replayability(for: record, layer: layer)
            let capsule = DiagnosticBugCapsule(
                capsuleId: capsuleID(record: record, signature: signature),
                sessionId: record.sessionID?.uuidString,
                taskId: safeMetadata(record, keys: ["taskId", "taskID"]),
                checkpointId: safeMetadata(record, keys: ["checkpointId", "checkpointID"]),
                cloudCodeBuild: safeMetadata(record, keys: ["build", "cloudCodeBuild"]) ?? context.build,
                commitSHA: context.commitSHA,
                iOSVersion: context.iOSVersion,
                deviceClass: context.deviceClass,
                appBundleId: safeMetadata(record, keys: ["foregroundBundleID", "bundleID", "bundleId", "appBundleID"]),
                appVersion: safeMetadata(record, keys: ["appVersion"]),
                providerId: safeMetadata(record, keys: ["providerID", "providerId", "provider"]) ?? context.providerId,
                modelId: safeMetadata(record, keys: ["modelID", "modelId", "model"]) ?? context.modelId,
                protocolClass: safeMetadata(record, keys: ["protocolClass", "protocol"]),
                userGoalSummary: userGoalSummary(for: record),
                expectedOutcome: expectedOutcome(for: record),
                observedOutcome: observedOutcome(for: record),
                failureLayer: layer,
                failureStage: stage,
                failureSignature: signature,
                fallbackPath: fallbackPath(for: record),
                verificationStatus: verificationStatus(for: record),
                replayability: replayability,
                regressionStatus: replayability == .realDeviceRequired ? .realDeviceOnly : .candidate,
                performance: performanceSnapshot(records: sessionRecords),
                firstObservedAt: record.timestamp,
                evidenceRecordIds: [record.id.uuidString]
            )
            capsules.append(capsule)
        }

        let replayArtifacts = capsules.map { capsule -> DiagnosticReplayArtifact in
            let relevant = safeRecords.filter { record in
                guard let sessionId = capsule.sessionId else { return capsule.evidenceRecordIds.contains(record.id.uuidString) }
                return record.sessionID?.uuidString == sessionId
            }
            let evidence = Array(relevant.suffix(48)).map(DiagnosticReplayEvidence.init(record:))
            return DiagnosticReplayArtifact(capsule: capsule, sanitizedEvidence: evidence)
        }
        return DiagnosticProblemPackage(
            capsules: capsules,
            replayArtifacts: replayArtifacts,
            regressionManifest: DiagnosticRegressionManifest(capsules: capsules),
            summary: DiagnosticProblemSummary(build: context.build, capsules: capsules, executionMetricCount: executionMetrics.count),
            executionMetrics: Array(executionMetrics.suffix(512))
        )
    }

    public static func replayClassification(_ artifact: DiagnosticReplayArtifact) -> DiagnosticReplayability {
        artifact.replayability
    }

    private static func isCapsuleCandidate(_ record: DiagnosticLogRecord) -> Bool {
        if record.level == .error { return true }
        let result = record.result.lowercased()
        let diagnostic = (record.diagnostic ?? "").lowercased()
        let failureMarkers = ["failed", "failure", "exhausted", "timeout", "timed out", "interrupted", "insufficient", "unverified", "no_effect", "no effect", "premature"]
        if failureMarkers.contains(where: { result.contains($0) || diagnostic.contains($0) }) { return true }
        if record.metadata["verification"] == "failed" || record.metadata["effectVerification"] == "failed" { return true }
        if let depth = record.metadata["fallbackDepth"].flatMap(Int.init), depth >= 2 { return true }
        if let latency = record.metadata["totalLatencyMS"].flatMap(Int.init), latency >= 30_000 { return true }
        return false
    }

    private static func failureLayer(for record: DiagnosticLogRecord) -> DiagnosticFailureLayer {
        let subsystem = record.subsystem.lowercased()
        let action = record.action.lowercased()
        let combined = subsystem + " " + action + " " + (record.diagnostic ?? "").lowercased()
        if combined.contains("checkpoint") || combined.contains("resume") { return .checkpointResume }
        if combined.contains("background") || combined.contains("assertion") || combined.contains("lifecycle") { return .backgroundLifecycle }
        if combined.contains("appknowledge") || combined.contains("app_knowledge") { return .appKnowledge }
        if combined.contains("resourceindex") || combined.contains("resource_index") || combined.contains("resource index") { return .resourceIndex }
        if combined.contains("policy") || combined.contains("approval") { return .policy }
        if subsystem.contains("provider") {
            if combined.contains("route") || action.contains("fallback") || action.contains("compatibility") || record.metadata["fallbackReason"] != nil { return .providerRoute }
            return .provider
        }
        if combined.contains("privileged") || combined.contains("roothelper") || combined.contains("root helper") { return .privilegedHelper }
        if combined.contains("resolveapp") || combined.contains("app_resolution") || combined.contains("foreground") && action.contains("launch") { return .appResolution }
        if action.contains("findelement") || action.contains("waitforelement") || combined.contains("accessibility") || combined.contains(" ax") { return .axObservation }
        if combined.contains("localvision") || combined.contains("ocr") { return .localVision }
        if action.contains("type") { return .guiTextInput }
        if action.contains("swipe") || action.contains("scroll") || action.contains("feedsample") || action.contains("tap") { return .guiGesture }
        if action.contains("navigate") || action.contains("openapp") || action.contains("openurl") { return .guiNavigation }
        if action.contains("verify") || combined.contains("verification") { return .guiVerification }
        if subsystem == "tool" && record.metadata["route"] != nil { return .toolRouting }
        if combined.contains("native") || combined.contains("cli") { return .nativeExecution }
        if subsystem.contains("agent") || combined.contains("planner") || combined.contains("planning") { return .agentPlanning }
        return .unknown
    }

    private static func failureStage(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer) -> String {
        if let explicit = safeMetadata(record, keys: ["failureStage", "stage"]) { return stableToken(explicit) }
        let action = record.action.lowercased()
        if action.contains("launch") || action.contains("openapp") { return "post_launch" }
        if action.contains("verify") { return "verification" }
        if action.contains("type") { return "text_input" }
        if action.contains("swipe") || action.contains("scroll") || action.contains("feed") { return "gesture_execution" }
        if action.contains("find") || action.contains("wait") { return "observation" }
        if layer == .provider || layer == .providerRoute { return "request" }
        return stableToken(record.action.isEmpty ? "unknown" : record.action)
    }

    private static func failureSignature(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer, stage: String) -> String {
        let combined = (record.result + " " + (record.diagnostic ?? "")).lowercased()
        let reason: String
        if let latency = record.metadata["totalLatencyMS"].flatMap(Int.init), latency >= 30_000 { reason = "latency_threshold_exceeded" }
        else if record.metadata["statusCode"] == "401" || combined.contains("401") || combined.contains("unauthorized") { reason = "unauthorized" }
        else if record.metadata["statusCode"] == "400" || combined.contains("400") || combined.contains("bad request") { reason = "bad_request" }
        else if combined.contains("timeout") || combined.contains("timed out") { reason = "timeout" }
        else if combined.contains("foreground") && combined.contains("verify") { reason = "foreground_unverified" }
        else if combined.contains("no effect") || combined.contains("no_effect") { reason = "no_observed_effect" }
        else if combined.contains("premature") { reason = "premature_completion" }
        else if combined.contains("ambiguous") { reason = "ambiguous_observation" }
        else if combined.contains("exhaust") { reason = "route_exhausted" }
        else if record.metadata["verification"] == "failed" { reason = "verification_failed" }
        else if let fallback = record.metadata["perceptionFallbackReason"], !fallback.isEmpty { reason = stableToken(fallback) }
        else { reason = stableToken(record.result.isEmpty ? "failed" : record.result) }
        return "\(layer.rawValue).\(stage).\(reason)"
    }

    private static func replayability(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer) -> DiagnosticReplayability {
        switch layer {
        case .provider, .providerRoute, .toolRouting, .checkpointResume, .resourceIndex, .appKnowledge, .policy, .agentPlanning:
            return .deterministic
        case .axObservation, .localVision, .guiVerification:
            let hasObservationEvidence = record.metadata["treeHash"] != nil || record.metadata["sha256"] != nil || record.metadata["localVisionOCR"] != nil || record.metadata["perceptionOCRInvoked"] != nil
            return hasObservationEvidence ? .observationReplay : .realDeviceRequired
        case .nativeExecution, .privilegedHelper, .appResolution, .guiGesture, .guiTextInput, .guiNavigation, .backgroundLifecycle:
            return .realDeviceRequired
        case .unknown:
            return .realDeviceRequired
        }
    }

    private static func userGoalSummary(for record: DiagnosticLogRecord) -> String {
        let action = stableToken(record.action)
        if action.contains("feed") || action.contains("swipe") { return "gui_feed_navigation" }
        if action.contains("type") { return "gui_text_input" }
        if action.contains("launch") || action.contains("openapp") { return "app_launch_and_continue" }
        if record.subsystem.lowercased().contains("provider") { return "provider_request" }
        return "diagnostic_action_\(String(action.prefix(80)))"
    }

    private static func expectedOutcome(for record: DiagnosticLogRecord) -> String {
        let action = record.action.lowercased()
        if action.contains("feed") || action.contains("swipe") || action.contains("scroll") { return "requested_bounded_navigation_observed" }
        if action.contains("type") { return "text_input_effect_verified" }
        if action.contains("launch") || action.contains("openapp") { return "target_foreground_and_post_launch_task_continues" }
        if action.contains("verify") { return "semantic_verification_passed" }
        if record.subsystem.lowercased().contains("provider") { return "provider_route_returns_valid_response" }
        return "action_completed_with_required_verification"
    }

    private static func observedOutcome(for record: DiagnosticLogRecord) -> String {
        let result = record.result.lowercased()
        if let statusCode = record.metadata["statusCode"], !statusCode.isEmpty { return "http_\(stableToken(statusCode))" }
        if result.contains("timeout") { return "timeout" }
        if result.contains("failed") || record.level == .error { return "failed" }
        if result.contains("interrupted") { return "interrupted" }
        if result.contains("unverified") || result.contains("insufficient") { return "verification_insufficient" }
        return String(stableToken(record.result).prefix(96))
    }

    private static func verificationStatus(for record: DiagnosticLogRecord) -> String {
        if let value = safeMetadata(record, keys: ["verification", "effectVerification"]) { return stableToken(value) }
        if record.result.lowercased().contains("unverified") || record.result.lowercased().contains("insufficient") { return "insufficient" }
        return record.level == .error ? "failed_or_not_reached" : "unknown"
    }

    private static func fallbackPath(for record: DiagnosticLogRecord) -> String? {
        let candidates = safeMetadata(record, keys: ["routeCandidates"])
        let selected = safeMetadata(record, keys: ["route"])
        let reason = safeMetadata(record, keys: ["fallbackReason"])
        let parts = [candidates.map { "candidates=\($0)" }, selected.map { "selected=\($0)" }, reason.map { "reason=\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    private static func performanceSnapshot(records: [DiagnosticLogRecord]) -> DiagnosticPerformanceSnapshot {
        var totalLatency = 0
        var foundLatency = false
        var providerRoundTrips = 0
        var remoteVisionRoundTrips = 0
        var screenshotCount = 0
        var axCount = 0
        var localVisionCount = 0
        var nativeCount = 0
        var guiCount = 0
        var fallbackCount = 0
        for record in records {
            if let latency = record.metadata["totalLatencyMS"].flatMap(Int.init) {
                totalLatency += max(0, latency)
                foundLatency = true
            }
            if record.subsystem.lowercased().contains("provider") && record.action.lowercased().contains("request") { providerRoundTrips += 1 }
            if record.metadata["perceptionRemoteVisionRequired"] == "true" { remoteVisionRoundTrips += 1 }
            if record.action.lowercased().contains("screenshot") || record.metadata["sha256"] != nil { screenshotCount += 1 }
            if record.metadata["perceptionAXAttempted"] == "true" { axCount += 1 }
            if record.metadata["perceptionOCRInvoked"] == "true" { localVisionCount += 1 }
            if let route = record.metadata["route"], route != AppExecutionRoute.guiFallback.rawValue { nativeCount += 1 }
            if record.action.lowercased().hasPrefix("gui.") { guiCount += 1 }
            if let depth = record.metadata["fallbackDepth"].flatMap(Int.init), depth > 0 { fallbackCount += 1 }
        }
        return DiagnosticPerformanceSnapshot(
            totalTaskLatencyMS: foundLatency ? totalLatency : nil,
            providerRoundTrips: providerRoundTrips,
            remoteVisionRoundTrips: remoteVisionRoundTrips,
            screenshotCount: screenshotCount,
            axObservationCount: axCount,
            localVisionCount: localVisionCount,
            nativeToolCount: nativeCount,
            guiActionCount: guiCount,
            fallbackCount: fallbackCount
        )
    }

    private static func safeMetadata(_ record: DiagnosticLogRecord, keys: [String]) -> String? {
        for key in keys {
            if let value = record.metadata[key], !value.isEmpty, value != "<redacted>" {
                return DiagnosticRedactor.redact(value)
            }
        }
        return nil
    }

    private static func stableToken(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar)) }
            return "_"
        }
        var token = String(scalars)
        while token.contains("__") { token = token.replacingOccurrences(of: "__", with: "_") }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return token.isEmpty ? "unknown" : String(token.prefix(120))
    }

    private static func capsuleID(record: DiagnosticLogRecord, signature: String) -> String {
        let seed = [record.sessionID?.uuidString ?? "none", record.id.uuidString, signature].joined(separator: "|")
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "bug-" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
