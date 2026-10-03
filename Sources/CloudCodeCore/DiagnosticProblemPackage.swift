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
    public var providerTTFTMS: Int?
    public var providerTotalMS: Int?
    public var localTaskExecutionMS: Int?
    public var axTotalMS: Int?
    public var ocrTotalMS: Int?
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
        providerTTFTMS: Int? = nil,
        providerTotalMS: Int? = nil,
        localTaskExecutionMS: Int? = nil,
        axTotalMS: Int? = nil,
        ocrTotalMS: Int? = nil,
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
        self.providerTTFTMS = providerTTFTMS.map { max(0, $0) }
        self.providerTotalMS = providerTotalMS.map { max(0, $0) }
        self.localTaskExecutionMS = localTaskExecutionMS.map { max(0, $0) }
        self.axTotalMS = axTotalMS.map { max(0, $0) }
        self.ocrTotalMS = ocrTotalMS.map { max(0, $0) }
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
            "providerRoundTrips", "providerTTFTMS", "providerTotalMS", "providerRoundTripAvoided", "localTaskExecutionMS",
            "statusCode", "httpStatus", "errorClass", "retryReason", "fallbackReason", "fallbackDepth", "route", "routeCandidates",
            "authMode", "host", "endpointPath", "transportState", "responseStarted", "streamEstablished", "bodyDataReceived",
            "foregroundBundleID", "bundleID", "bundleId", "appVersion", "verification", "effectVerification",
            "perceptionClass", "perceptionAXAttempted", "perceptionAXSucceeded", "perceptionAnchorCacheHit",
            "perceptionOCRInvoked", "perceptionOCRSucceeded", "perceptionOCRLatencyMS", "perceptionLocalSufficient",
            "perceptionRemoteVisionRequired", "perceptionFallbackReason", "providerVisualRoundTripAvoided",
            "sha256", "screenPointWidth", "screenPointHeight", "localVisionOCR", "localVisionElementCount",
            "localVisionCoordinateSpace", "localVisionLatencyMS", "localVisionRegion", "localVisionRegionExecution", "localVisionHelperInputWidth", "localVisionHelperInputHeight", "localVisionRecognitionLevel", "localVisionMinimumTextHeight", "localVisionPass", "localVisionAttemptSequence", "localVisionPrecisionRecommended", "localVisionPrecisionReason", "localVisionCacheHit", "localVisionRequestCoalesced", "localVisionFallbackUsed", "localVisionBackend",
            "localVisionFailureClass", "localVisionErrorDomain", "localVisionErrorCode", "localVisionPrimaryErrorDomain", "localVisionPrimaryErrorCode",
            "localVisionSecondaryBackend", "localVisionSecondaryStatus", "localVisionSecondaryErrorDomain", "localVisionSecondaryErrorCode", "treeHash",
            "coordinateSafety", "providerImageRoute", "keyboardLikely", "focusStrategy", "textInputSafety", "localMetric", "localMetricSelection", "localMetricExtraction", "cache", "idempotency",
            "axBackend", "axStage", "axScope", "axNodeCount", "axSemanticNodeCount", "axFailureClass", "axErrorDomain", "axErrorCode", "axLatencyMS",
            "providerVisionCapability", "providerVisionCapabilitySource", "selectedPerceptionRoute",
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

public struct DiagnosticFailureExplanation: Codable, Equatable, Sendable {
    public var failureSignature: String
    public var failureLayer: DiagnosticFailureLayer
    public var failureStage: String
    public var observedOutcome: String
    public var verificationStatus: String
    public var affectedSubsystem: String
    public var recentAttemptCount: Int
    public var routeCandidates: [String]
    public var selectedRoute: String?
    public var fallbackReason: String?
    public var fallbackDepth: Int
    public var axAttempted: Bool
    public var axSucceeded: Bool
    public var axLatencyMS: Int?
    public var ocrInvoked: Bool
    public var ocrSucceeded: Bool
    public var ocrLatencyMS: Int?
    public var screenshotStatus: String
    public var localVisionStatus: String
    public var foregroundVerificationStatus: String
    public var relevantCapabilities: [String: String]
    public var probableCauses: [String]
    public var evidenceSummary: [String]
    public var recommendedNextAction: String
    public var automaticRecoveryAllowed: Bool
    public var recoveryReason: String
    public var developerPatchLikelyRequired: Bool
    public var previousFailureSignature: String?
    public var currentFailureSignature: String
    public var changedLayer: String?
    public var progressObserved: Bool?
    public var remainingFailure: String

    public init(
        failureSignature: String,
        failureLayer: DiagnosticFailureLayer,
        failureStage: String,
        observedOutcome: String,
        verificationStatus: String,
        affectedSubsystem: String,
        recentAttemptCount: Int,
        routeCandidates: [String],
        selectedRoute: String?,
        fallbackReason: String?,
        fallbackDepth: Int,
        axAttempted: Bool,
        axSucceeded: Bool,
        axLatencyMS: Int?,
        ocrInvoked: Bool,
        ocrSucceeded: Bool,
        ocrLatencyMS: Int?,
        screenshotStatus: String,
        localVisionStatus: String,
        foregroundVerificationStatus: String,
        relevantCapabilities: [String: String],
        probableCauses: [String],
        evidenceSummary: [String],
        recommendedNextAction: String,
        automaticRecoveryAllowed: Bool,
        recoveryReason: String,
        developerPatchLikelyRequired: Bool,
        previousFailureSignature: String?,
        currentFailureSignature: String,
        changedLayer: String?,
        progressObserved: Bool?,
        remainingFailure: String
    ) {
        self.failureSignature = failureSignature
        self.failureLayer = failureLayer
        self.failureStage = failureStage
        self.observedOutcome = observedOutcome
        self.verificationStatus = verificationStatus
        self.affectedSubsystem = affectedSubsystem
        self.recentAttemptCount = max(1, recentAttemptCount)
        self.routeCandidates = Array(routeCandidates.prefix(8))
        self.selectedRoute = selectedRoute
        self.fallbackReason = fallbackReason
        self.fallbackDepth = max(0, fallbackDepth)
        self.axAttempted = axAttempted
        self.axSucceeded = axSucceeded
        self.axLatencyMS = axLatencyMS
        self.ocrInvoked = ocrInvoked
        self.ocrSucceeded = ocrSucceeded
        self.ocrLatencyMS = ocrLatencyMS
        self.screenshotStatus = screenshotStatus
        self.localVisionStatus = localVisionStatus
        self.foregroundVerificationStatus = foregroundVerificationStatus
        self.relevantCapabilities = relevantCapabilities
        self.probableCauses = Array(probableCauses.prefix(6))
        self.evidenceSummary = Array(evidenceSummary.prefix(12))
        self.recommendedNextAction = recommendedNextAction
        self.automaticRecoveryAllowed = automaticRecoveryAllowed
        self.recoveryReason = recoveryReason
        self.developerPatchLikelyRequired = developerPatchLikelyRequired
        self.previousFailureSignature = previousFailureSignature
        self.currentFailureSignature = currentFailureSignature
        self.changedLayer = changedLayer
        self.progressObserved = progressObserved
        self.remainingFailure = remainingFailure
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

    /// Builds one bounded, redacted, Agent-consumable explanation from evidence that already exists.
    /// This function never probes capabilities, executes a tool, captures a screenshot, or mutates state.
    public static func explainFailure(
        records: [DiagnosticLogRecord],
        executionMetrics: [ExecutionPathMetric],
        capabilities: CapabilityProfile,
        sessionID: UUID? = nil,
        toolCallID: UUID? = nil,
        recoveryAttemptCount: Int = 0,
        maximumRecoveryAttempts: Int = 2
    ) -> DiagnosticFailureExplanation? {
        let safeSessionRecords = records.map(DiagnosticRedactor.redact(record:)).filter { record in
            if let sessionID, record.sessionID != sessionID { return false }
            return true
        }
        let targetRecords: [DiagnosticLogRecord]
        if let toolCallID {
            targetRecords = safeSessionRecords.filter { $0.toolCallID == toolCallID }
        } else {
            targetRecords = safeSessionRecords
        }
        let candidates = targetRecords.filter(isCapsuleCandidate)
        guard let latest = candidates.last else { return nil }

        let sessionCandidates = safeSessionRecords.filter(isCapsuleCandidate)
        let latestHistoryIndex = sessionCandidates.lastIndex(where: { $0.id == latest.id })
        let historyThroughLatest: [DiagnosticLogRecord]
        if let latestHistoryIndex {
            historyThroughLatest = Array(sessionCandidates[...latestHistoryIndex])
        } else {
            historyThroughLatest = candidates
        }

        let layer = failureLayer(for: latest)
        let stage = failureStage(for: latest, layer: layer)
        let signature = failureSignature(for: latest, layer: layer, stage: stage)
        let reason = specificFailureReason(for: latest, layer: layer)
        let matchingAttemptKeys = historyThroughLatest.compactMap { record -> String? in
            let candidateLayer = failureLayer(for: record)
            let candidateStage = failureStage(for: record, layer: candidateLayer)
            guard failureSignature(for: record, layer: candidateLayer, stage: candidateStage) == signature else { return nil }
            if let toolCallID = record.toolCallID { return "tool:\(toolCallID.uuidString)" }
            return "record:\(record.id.uuidString)"
        }
        let matchingAttempts = Set(matchingAttemptKeys).count

        let latestMetric: ExecutionPathMetric? = {
            if let toolCallID = latest.toolCallID,
               let exact = executionMetrics.last(where: { $0.toolCallID == toolCallID && $0.recordedAt <= latest.timestamp }) {
                return exact
            }
            if let recordSessionID = latest.sessionID,
               let sessionScoped = executionMetrics.last(where: {
                   $0.sessionID == recordSessionID
                       && $0.tool == latest.action
                       && $0.recordedAt <= latest.timestamp
               }) {
                return sessionScoped
            }
            // Legacy diagnostic packages predate metric session/tool-call identity. Keep them
            // decodable and useful, but never use a metric recorded after the target failure.
            return executionMetrics.last(where: { $0.tool == latest.action && $0.recordedAt <= latest.timestamp })
        }()
        let routeCandidates = latestMetric?.routeCandidates.map(\.rawValue)
            ?? splitCSV(safeMetadata(latest, keys: ["routeCandidates"]))
        let selectedRoute = latestMetric?.selectedRoute?.rawValue ?? safeMetadata(latest, keys: ["route"])
        let metricFallback = latestMetric?.fallbackReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackReason = (metricFallback?.isEmpty == false ? metricFallback : nil)
            ?? safeMetadata(latest, keys: ["fallbackReason", "perceptionFallbackReason"])
        let fallbackDepth = latestMetric?.fallbackDepth
            ?? safeMetadata(latest, keys: ["fallbackDepth"]).flatMap(Int.init)
            ?? 0

        let axAttempted = latestMetric?.axAttempted
            ?? boolMetadata(latest, "perceptionAXAttempted")
            ?? (layer == .axObservation)
        let axSucceeded = latestMetric?.axSucceeded
            ?? boolMetadata(latest, "perceptionAXSucceeded")
            ?? false
        let ocrInvoked = latestMetric?.ocrInvoked
            ?? boolMetadata(latest, "perceptionOCRInvoked")
            ?? latest.metadata["localVisionOCR"].map { _ in true }
            ?? false
        let localVisionStatus = safeMetadata(latest, keys: ["localVisionOCR"])
            ?? (ocrInvoked ? (latestMetric?.ocrSucceeded == true ? "recognized" : "unavailable") : "not_invoked")
        let ocrSucceeded = latestMetric?.ocrSucceeded
            ?? boolMetadata(latest, "perceptionOCRSucceeded")
            ?? (localVisionStatus == "recognized" || localVisionStatus == "available_empty")
        let screenshotStatus: String = {
            if safeMetadata(latest, keys: ["sha256", "frameSHA256"]) != nil { return "succeeded" }
            if latest.action.lowercased().contains("screenshot") && (latest.level == .error || latest.result.lowercased().contains("fail")) { return "failed" }
            return "unknown"
        }()
        let foregroundStatus = safeMetadata(latest, keys: ["foregroundVerified", "verification"])
            ?? (reason == "foreground_target_mismatch" ? "mismatch" : "unknown")

        var causes = probableCauses(for: latest, layer: layer, reason: reason)
        let providerVisionContext = historyThroughLatest.reversed().compactMap { record -> (capability: String, source: String?)? in
            guard let capability = record.metadata["providerVisionCapability"], !capability.isEmpty else { return nil }
            return (capability, record.metadata["providerVisionCapabilitySource"])
        }.first
        if providerVisionContext?.capability == "text_only",
           !causes.contains("provider_route_cannot_consume_image_observation") {
            causes.append("provider_route_cannot_consume_image_observation")
        }
        causes = Array(Set(causes)).sorted()
        let maxRecovery = max(0, min(maximumRecoveryAttempts, 4))
        let recoverable = isAutomaticRecoverySafe(reason: reason, layer: layer)
        // When no Agent checkpoint count is supplied (for example an explicit
        // diagnostics.explainFailure call), repeated same-signature *recoverable failures* are
        // bounded evidence of already-consumed re-plan opportunities. Diagnostic-only degradation
        // such as a successful deep route fallback must never consume the failure recovery budget.
        // Deduplication above prevents helper and outer logs from double-counting one tool call.
        let inferredRecoveryUse = recoverable ? max(0, matchingAttempts - 1) : 0
        let usedRecovery = max(max(0, recoveryAttemptCount), inferredRecoveryUse)
        let diagnosticOnlyRouteDegradation = reason == "deep_route_fallback"
        let recoveryAllowed = !diagnosticOnlyRouteDegradation && recoverable && usedRecovery < maxRecovery
        let recoveryReason: String
        if diagnosticOnlyRouteDegradation {
            recoveryReason = "diagnostic_only_route_degradation"
        } else if !recoverable {
            recoveryReason = "failure_requires_developer_or_manual_resolution"
        } else if usedRecovery >= maxRecovery {
            recoveryReason = "recovery_budget_exhausted"
        } else {
            recoveryReason = "bounded_replan_available"
        }
        let developerPatchLikelyRequired = usedRecovery >= maxRecovery
            || ["ax_backend_unavailable", "ax_request_failed", "coreml_runtime_failed", "corevideo_allocation_failed", "ocr_coordinate_normalization_failed", "right_rail_anchor_classification_failed", "provider_text_only_local_fallback_missing"].contains(reason) && matchingAttempts >= 2

        var evidence: [String] = []
        evidence.append("result=\(stableToken(latest.result))")
        evidence.append("layer=\(layer.rawValue)")
        evidence.append("stage=\(stage)")
        evidence.append("ax_attempted=\(axAttempted);ax_succeeded=\(axSucceeded)")
        evidence.append("ocr_invoked=\(ocrInvoked);ocr_succeeded=\(ocrSucceeded);local_vision=\(stableToken(localVisionStatus))")
        evidence.append("screenshot=\(screenshotStatus);foreground=\(stableToken(foregroundStatus))")
        if let providerVisionContext {
            let source = providerVisionContext.source.map(stableToken) ?? "unknown"
            evidence.append("provider_vision=\(stableToken(providerVisionContext.capability));source=\(source)")
        }
        if let domain = safeMetadata(latest, keys: ["localVisionErrorDomain", "errorDomain"]), !domain.isEmpty {
            evidence.append("error_domain=\(stableToken(domain))")
        }
        if let code = safeMetadata(latest, keys: ["localVisionErrorCode", "errorCode"]), !code.isEmpty {
            evidence.append("error_code=\(stableToken(code))")
        }
        if let fallbackReason, !fallbackReason.isEmpty { evidence.append("fallback=\(String(stableToken(fallbackReason).prefix(120)))") }
        if let metric = latestMetric {
            evidence.append("latency_ms=route:\(metric.routeSelectionLatencyMS),execute:\(metric.executionLatencyMS),total:\(metric.totalLatencyMS)")
        }

        let previous = historyThroughLatest.dropLast().last(where: { record in
            guard let latestToolCallID = latest.toolCallID else { return true }
            return record.toolCallID != latestToolCallID
        })
        let previousSignature: String? = previous.map { record in
            let previousLayer = failureLayer(for: record)
            return failureSignature(for: record, layer: previousLayer, stage: failureStage(for: record, layer: previousLayer))
        }
        let previousLayer = previous.map { failureLayer(for: $0) }
        let changedLayer = previousLayer.flatMap { $0 == layer ? nil : "\($0.rawValue)->\(layer.rawValue)" }
        let progressObserved = previousSignature.map { $0 != signature }

        return DiagnosticFailureExplanation(
            failureSignature: signature,
            failureLayer: layer,
            failureStage: stage,
            observedOutcome: observedOutcome(for: latest),
            verificationStatus: verificationStatus(for: latest),
            affectedSubsystem: stableToken(latest.subsystem),
            recentAttemptCount: matchingAttempts,
            routeCandidates: routeCandidates,
            selectedRoute: selectedRoute,
            fallbackReason: fallbackReason,
            fallbackDepth: fallbackDepth,
            axAttempted: axAttempted,
            axSucceeded: axSucceeded,
            axLatencyMS: latestMetric?.axLatencyMS,
            ocrInvoked: ocrInvoked,
            ocrSucceeded: ocrSucceeded,
            ocrLatencyMS: latestMetric?.ocrLatencyMS ?? safeMetadata(latest, keys: ["perceptionOCRLatencyMS", "localVisionLatencyMS"]).flatMap(Int.init),
            screenshotStatus: screenshotStatus,
            localVisionStatus: localVisionStatus,
            foregroundVerificationStatus: foregroundStatus,
            relevantCapabilities: relevantCapabilities(for: layer, capabilities: capabilities),
            probableCauses: causes,
            evidenceSummary: evidence,
            recommendedNextAction: recommendedNextAction(for: reason, layer: layer, recoveryAllowed: recoveryAllowed),
            automaticRecoveryAllowed: recoveryAllowed,
            recoveryReason: recoveryReason,
            developerPatchLikelyRequired: developerPatchLikelyRequired,
            previousFailureSignature: previousSignature,
            currentFailureSignature: signature,
            changedLayer: changedLayer,
            progressObserved: progressObserved,
            remainingFailure: reason
        )
    }

    private static func isCapsuleCandidate(_ record: DiagnosticLogRecord) -> Bool {
        if record.level == .error { return true }
        let result = record.result.lowercased()
        let diagnostic = (record.diagnostic ?? "").lowercased()
        let action = record.action.lowercased()
        let localVisionStatus = (record.metadata["localVisionOCR"] ?? "").lowercased()

        // Helper success diagnostics intentionally include bounded-execution evidence such as
        // `timeoutSeconds` and `parentTimeout:false`. Treating the mere word "timeout" in an info
        // diagnostic as a failure created dozens of fake tap/swipe/background/SQLite capsules in
        // build 92. Result state is authoritative for info records; diagnostic prose is only used
        // as a generic failure signal on warning/error records.
        let hardResultMarkers = ["failed", "failure", "exhausted", "timeout", "timed out", "interrupted", "insufficient", "no_effect", "no effect", "premature"]
        if hardResultMarkers.contains(where: { result.contains($0) }) { return true }
        if record.level == .warning,
           hardResultMarkers.contains(where: { diagnostic.contains($0) }) { return true }

        // "dispatched-unverified" is the normal low-level helper contract: the enclosing tool must
        // observe the postcondition. Do not turn every successful primitive into a bug capsule.
        // Foreground launch uncertainty is different because subsequent target-specific actions can
        // otherwise run against the wrong App; preserve that explicit top-level state.
        if result.contains("unverified"), !action.hasSuffix(".helper") { return true }
        if record.metadata["foregroundVerified"] == "false",
           (action.contains("openapp") || action.contains("launch")) { return true }

        // A screenshot/action can succeed while a required perception sub-stage fails. Preserve that
        // partial failure as a capsule candidate instead of letting the outer tool success hide it.
        if localVisionStatus.hasPrefix("unavailable") { return true }
        if let failureClass = record.metadata["localVisionFailureClass"], !failureClass.isEmpty { return true }
        if record.metadata["localMetricExtraction"] == "incomplete_or_ambiguous" { return true }
        if record.metadata["perceptionOCRInvoked"] == "true" && record.metadata["perceptionOCRSucceeded"] == "false" { return true }
        if record.metadata["perceptionAXAttempted"] == "true" && record.metadata["perceptionAXSucceeded"] == "false" { return true }
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
        // Multi-stage semantic tools can fail AX first and then fail the OCR fallback. When the
        // record carries explicit OCR failure evidence, diagnose the last failing perception stage
        // rather than letting the earlier AX attempt mask a concrete Vision/CoreVideo root cause.
        let explicitLocalVisionFailure = record.metadata["perceptionOCRInvoked"] == "true" && (
            record.metadata["perceptionOCRSucceeded"] == "false"
                || record.metadata["localVisionFailureClass"]?.isEmpty == false
                || (record.metadata["localVisionOCR"] ?? "").lowercased().hasPrefix("unavailable")
        )
        if explicitLocalVisionFailure { return .localVision }
        // An AX observation executed through the privileged/root helper is still fundamentally an
        // AX failure when the helper returned semantic-empty/AX evidence. Classify the failing
        // subsystem before the transport implementation so timeout fields in helper diagnostics do
        // not turn an AX semantic failure into privileged_helper.*.timeout.
        if action == "gui.tree"
            || combined.contains("empty-semantic-tree")
            || combined.contains("no semantic/actionable foreground ui nodes")
            || record.metadata["perceptionFallbackReason"] == "ax_transport_returned_semantically_empty_tree" {
            return .axObservation
        }
        if combined.contains("privileged") || combined.contains("roothelper") || combined.contains("root helper") { return .privilegedHelper }
        if combined.contains("resolveapp") || combined.contains("app_resolution") || combined.contains("foreground") && action.contains("launch") { return .appResolution }
        // Completion-guard perception failures can carry both a prior AX failure and the current
        // OCR/local-vision outcome. Prefer the most recent local-perception stage here so the
        // diagnosis can distinguish OCR not-invoked/empty/semantic-fallback failures instead of
        // collapsing the whole chain back to "AX unavailable".
        if record.metadata["perceptionStatus"] == "perception_insufficient",
           record.metadata["perceptionOCRInvoked"] != nil || record.metadata["localVisionOCR"] != nil {
            return .localVision
        }
        if action == "gui.tree" || action.contains("findelement") || action.contains("waitforelement")
            || action.contains("tapelementobserve") || action.contains("typeelementobserve") || action.contains("runstructuredplan")
            || combined.contains("accessibility") || combined.contains(" ax")
            || record.metadata["perceptionAXAttempted"] == "true" && record.metadata["perceptionAXSucceeded"] == "false" { return .axObservation }
        if action.contains("verify") || combined.contains("verification") {
            return .guiVerification
        }
        let ocrInvoked = record.metadata["perceptionOCRInvoked"] == "true"
        let localVisionSemanticFailure = ocrInvoked && (
            record.result.lowercased().contains("fail")
                || record.metadata["localVisionFailureClass"] != nil
                || record.metadata["perceptionOCRSucceeded"] == "false"
                || record.metadata["perceptionLocalSufficient"] == "false" && record.metadata["perceptionFallbackReason"] != nil
        )
        if action.contains("screenshot") || combined.contains("localvision") || combined.contains("ocr")
            || (record.metadata["localVisionOCR"] ?? "").lowercased().hasPrefix("unavailable")
            || record.metadata["perceptionOCRInvoked"] == "true" && record.metadata["perceptionOCRSucceeded"] == "false"
            || localVisionSemanticFailure { return .localVision }
        if action.contains("type") { return .guiTextInput }
        if action.contains("swipe") || action.contains("scroll") || action.contains("feedsample") || action.contains("tap") { return .guiGesture }
        if action.contains("navigate") || action.contains("openapp") || action.contains("openurl") { return .guiNavigation }
        // Route-selection records use the dedicated `tool-route` subsystem, while execution
        // completion records use `tool`. Both carry the same bounded route/fallback evidence and
        // must classify identically; otherwise async log ordering can turn a successful deep
        // fallback into an unknown/manual-resolution failure.
        if (subsystem == "tool" || subsystem == "tool-route") && record.metadata["route"] != nil { return .toolRouting }
        if combined.contains("native") || combined.contains("cli") { return .nativeExecution }
        if subsystem.contains("agent") || combined.contains("planner") || combined.contains("planning") { return .agentPlanning }
        return .unknown
    }

    private static func failureStage(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer) -> String {
        if let explicit = safeMetadata(record, keys: ["failureStage", "stage"]) { return stableToken(explicit) }
        let action = record.action.lowercased()
        if layer == .localVision {
            let failureClass = (record.metadata["localVisionFailureClass"] ?? "").lowercased()
            if failureClass.contains("right_rail") || failureClass.contains("compact_count") || failureClass.contains("metric_anchor") {
                return "metric_extraction"
            }
            if failureClass.contains("target_not_recognized") || failureClass.contains("unique_match") {
                return "semantic_matching"
            }
            if failureClass.contains("coordinate") || failureClass.contains("bounding_box") {
                return "coordinate_normalization"
            }
            if failureClass.contains("region") || failureClass.contains("crop") { return "region_selection" }
            let primaryText = [record.result, record.diagnostic ?? ""].joined(separator: " ").lowercased()
            let screenshotFailed = action.contains("screenshot")
                && (record.level == .error || (primaryText.contains("screenshot") && primaryText.contains("failed")))
            if screenshotFailed { return "screenshot_capture" }
            if record.metadata["perceptionOCRInvoked"] == "false" { return "ocr_invocation" }
            let localStatus = (record.metadata["localVisionOCR"] ?? "").lowercased()
            if record.metadata["perceptionOCRSucceeded"] == "false"
                || localStatus == "available_empty"
                || localStatus.hasPrefix("unavailable") {
                return "ocr_recognition"
            }
            if action.contains("screenshot") { return "screenshot_capture" }
            if record.metadata["selectedPerceptionRoute"] == "local_only_provider_vision_unavailable" {
                return "semantic_fallback"
            }
            return "local_vision"
        }
        if action.contains("launch") || action.contains("openapp") { return "post_launch" }
        if action.contains("verify") { return "verification" }
        if action.contains("type") { return "text_input" }
        if action.contains("swipe") || action.contains("scroll") || action.contains("feed") { return "gesture_execution" }
        if action.contains("find") || action.contains("wait") { return "observation" }
        if layer == .provider || layer == .providerRoute { return "request" }
        return stableToken(record.action.isEmpty ? "unknown" : record.action)
    }

    private static func failureSignature(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer, stage: String) -> String {
        "\(layer.rawValue).\(stage).\(specificFailureReason(for: record, layer: layer))"
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
        if let failureClass = safeMetadata(record, keys: ["localVisionFailureClass"]), !failureClass.isEmpty {
            return "perception_substage_failed_\(stableToken(failureClass))"
        }
        if record.metadata["localMetricExtraction"] == "incomplete_or_ambiguous" {
            return "perception_substage_failed_local_metric_incomplete_or_ambiguous"
        }
        if let statusCode = record.metadata["statusCode"], !statusCode.isEmpty { return "http_\(stableToken(statusCode))" }
        if result.contains("timeout") { return "timeout" }
        if result.contains("failed") || record.level == .error { return "failed" }
        if result.contains("interrupted") { return "interrupted" }
        if result.contains("unverified") || result.contains("insufficient") { return "verification_insufficient" }
        return String(stableToken(record.result).prefix(96))
    }

    private static func verificationStatus(for record: DiagnosticLogRecord) -> String {
        if let failureClass = safeMetadata(record, keys: ["localVisionFailureClass"]), !failureClass.isEmpty {
            return "perception_failed"
        }
        if record.metadata["localMetricExtraction"] == "incomplete_or_ambiguous" { return "insufficient" }
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
        var providerTTFTTotalMS = 0
        var providerTTFTObserved = false
        var providerTotalMS = 0
        var providerTotalObserved = false
        var localTaskExecutionMS: Int?
        var axTotalMS = 0
        var axLatencyObserved = false
        var ocrTotalMS = 0
        var ocrLatencyObserved = false
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
            if record.subsystem.lowercased().contains("provider") {
                let action = record.action.lowercased()
                let result = record.result.lowercased()
                if action.contains("request") || (action == "stream" && result == "started") {
                    providerRoundTrips += 1
                }
                if let value = record.metadata["providerTTFTMS"].flatMap(Int.init), value >= 0 {
                    providerTTFTTotalMS += value
                    providerTTFTObserved = true
                }
                if let value = record.metadata["providerTotalMS"].flatMap(Int.init), value >= 0 {
                    providerTotalMS += value
                    providerTotalObserved = true
                }
            }
            if let value = record.metadata["localTaskExecutionMS"].flatMap(Int.init), value >= 0 {
                localTaskExecutionMS = max(localTaskExecutionMS ?? 0, value)
            }
            if let value = record.metadata["axLatencyMS"].flatMap(Int.init), value >= 0 {
                axTotalMS += value
                axLatencyObserved = true
            }
            let ocrLatency = [record.metadata["perceptionOCRLatencyMS"], record.metadata["localVisionLatencyMS"]]
                .compactMap { $0.flatMap(Int.init) }
                .filter { $0 >= 0 }
                .max()
            if let ocrLatency {
                ocrTotalMS += ocrLatency
                ocrLatencyObserved = true
            }
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
            providerTTFTMS: providerTTFTObserved ? providerTTFTTotalMS : nil,
            providerTotalMS: providerTotalObserved ? providerTotalMS : nil,
            localTaskExecutionMS: localTaskExecutionMS,
            axTotalMS: axLatencyObserved ? axTotalMS : nil,
            ocrTotalMS: ocrLatencyObserved ? ocrTotalMS : nil,
            remoteVisionRoundTrips: remoteVisionRoundTrips,
            screenshotCount: screenshotCount,
            axObservationCount: axCount,
            localVisionCount: localVisionCount,
            nativeToolCount: nativeCount,
            guiActionCount: guiCount,
            fallbackCount: fallbackCount
        )
    }

    private static func specificFailureReason(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer) -> String {
        let primaryText = [record.result, record.diagnostic ?? ""].joined(separator: " ").lowercased()
        let combined = ([record.result, record.diagnostic ?? ""] + record.metadata.values).joined(separator: " ").lowercased()
        if let latency = record.metadata["totalLatencyMS"].flatMap(Int.init), latency >= 30_000 { return "latency_threshold_exceeded" }
        let explicitStatusCode = record.metadata["statusCode"]
        if explicitStatusCode == "401"
            || primaryText.contains("unauthorized")
            || primaryText.contains("http 401")
            || primaryText.contains("http_401")
            || primaryText.contains("status 401") { return "unauthorized" }
        if explicitStatusCode == "400"
            || primaryText.contains("bad request")
            || primaryText.contains("http 400")
            || primaryText.contains("http_400")
            || primaryText.contains("status 400") { return "bad_request" }

        if layer == .toolRouting,
           let fallbackDepth = record.metadata["fallbackDepth"].flatMap(Int.init),
           fallbackDepth >= 2 {
            return "deep_route_fallback"
        }

        if layer == .axObservation {
            if combined.contains("required axruntime") || combined.contains("creation/copy symbols are unavailable") || combined.contains("missingcapability") || combined.contains("noexecutionroute") {
                return "ax_backend_unavailable"
            }
            if combined.contains("output exceeded") || combined.contains("tree_bytes") || combined.contains("tree nodes") || combined.contains("node budget") {
                return "ax_tree_budget_truncated"
            }
            if combined.contains("stale") { return "ax_stale_tree" }
            if combined.contains("frame") && (combined.contains("invalid") || combined.contains("coordinate")) { return "ax_frame_coordinate_invalid" }
            if combined.contains("ambiguous") { return "ax_semantic_match_ambiguous" }
            if (combined.contains("target") && (combined.contains("not found") || combined.contains("no match")))
                || combined.contains("structured element query returned no usable visible match")
                || combined.contains("structured element did not appear before timeout")
                || combined.contains("structured plan local expectation did not become true before timeout") {
                return "ax_target_absent"
            }
            if combined.contains("no readable ui nodes")
                || combined.contains("empty tree")
                || combined.contains("empty-semantic-tree")
                || combined.contains("no semantic/actionable foreground ui nodes")
                || combined.contains("semantically empty tree")
                || record.metadata["perceptionFallbackReason"] == "ax_transport_returned_semantically_empty_tree" {
                return "ax_tree_empty"
            }
            let explicitAXTimeout = primaryText == "timeout"
                || primaryText.contains("timed out")
                || primaryText.contains("transport_timeout")
                || primaryText.contains("transport timeout")
                || primaryText.contains("helper timeout")
                || combined.contains("\"parenttimeout\":true")
                || combined.contains("parenttimeout=true")
                || record.metadata["parentTimeout"] == "true"
            if explicitAXTimeout { return "ax_request_timeout" }
            return "ax_request_failed"
        }

        if layer == .localVision || record.metadata["perceptionOCRInvoked"] != nil || record.metadata["localVisionOCR"] != nil {
            let ocrInvoked = boolMetadata(record, "perceptionOCRInvoked") ?? (record.metadata["localVisionOCR"] != nil)
            let localStatus = record.metadata["localVisionOCR"]?.lowercased() ?? ""
            // A successful gui.screenshot may still carry local OCR failure metadata. Only the
            // screenshot operation's own result/diagnostic may classify capture failure; generic
            // metadata such as localVisionSecondaryStatus=unavailable_helper_failed must not turn
            // a valid JPEG into screenshot_capture_failed.
            if record.action.lowercased().contains("screenshot")
                && (record.level == .error || (primaryText.contains("screenshot") && primaryText.contains("failed"))) {
                return "screenshot_capture_failed"
            }
            if !ocrInvoked { return "ocr_not_invoked" }
            // Preserve the concrete CoreVideo status ahead of the generic tool-layer
            // localVisionFailureClass=ocr_request_failed. This lets the recovery policy trip its
            // non-retryable -6662 circuit breaker instead of spending recovery budget blindly.
            if record.metadata["localVisionErrorDomain"] == NSOSStatusErrorDomain,
               record.metadata["localVisionErrorCode"] == "-6662" {
                return "corevideo_allocation_failed"
            }
            if record.metadata["localVisionFailureClass"]?.isEmpty == false {
                return stableToken(record.metadata["localVisionFailureClass"] ?? "ocr_request_failed")
            }
            if (record.metadata["localVisionErrorDomain"] ?? "").localizedCaseInsensitiveContains("CoreML") {
                return "coreml_runtime_failed"
            }
            if localStatus == "available_empty" { return "ocr_completed_no_text" }
            if ocrInvoked && record.metadata["perceptionOCRSucceeded"] == "false" { return "ocr_request_failed" }
            if combined.contains("right_rail") || combined.contains("right rail") || combined.contains("anchor classification") { return "right_rail_anchor_classification_failed" }
            if combined.contains("compact") && combined.contains("count") { return "compact_count_normalization_failed" }
            if combined.contains("region") || combined.contains("crop") { return "ocr_region_invalid" }
            if combined.contains("coordinate") || combined.contains("bounding box") || combined.contains("bounding_box") { return "ocr_coordinate_normalization_failed" }
            if combined.contains("ambiguous") || combined.contains("unique") && combined.contains("match") { return "ocr_unique_match_ambiguous" }
            if combined.contains("target") && (combined.contains("not found") || combined.contains("no match") || combined.contains("not recognized")) { return "ocr_target_not_recognized" }
            if record.metadata["perceptionLocalSufficient"] == "true" && record.metadata["perceptionRemoteVisionRequired"] == "true" {
                return "local_sufficient_remote_vision_routing_error"
            }
            if record.metadata["providerVisionCapability"] == "text_only",
               record.metadata["perceptionLocalSufficient"] != "true",
               record.metadata["selectedPerceptionRoute"] == "local_only_provider_vision_unavailable",
               localStatus == "recognized" {
                return "provider_text_only_local_fallback_missing"
            }
            if localStatus.contains("unavailable") || combined.contains("ocr") && combined.contains("failed") { return "ocr_request_failed" }
        }

        if record.result.lowercased().contains("route_failed") { return "route_selection_failed" }
        if record.metadata["foregroundVerified"] == "false" { return "foreground_unverified" }
        if combined.contains("foreground") && (combined.contains("mismatch") || combined.contains("wrong app")) { return "foreground_target_mismatch" }
        if combined.contains("foreground") && combined.contains("verify") { return "foreground_unverified" }
        if combined.contains("no effect") || combined.contains("no_effect") { return "no_observed_effect" }
        if combined.contains("premature") { return "premature_completion" }
        if combined.contains("action dispatch") || combined.contains("dispatch failed") { return "action_dispatch_failed" }
        if combined.contains("route") && combined.contains("exhaust") { return "route_exhausted" }
        if record.metadata["verification"] == "failed" || combined.contains("verification_failed") { return "verification_failed" }
        if combined.contains("timeout") || combined.contains("timed out") { return "timeout" }
        if combined.contains("ambiguous") { return "ambiguous_observation" }
        if let fallback = record.metadata["perceptionFallbackReason"], !fallback.isEmpty { return stableToken(fallback) }
        return stableToken(record.result.isEmpty ? "failed" : record.result)
    }

    private static func probableCauses(for record: DiagnosticLogRecord, layer: DiagnosticFailureLayer, reason: String) -> [String] {
        var causes = [reason]
        if layer == .axObservation {
            if reason == "ax_request_timeout" || reason == "ax_request_failed" {
                causes.append("cross_process_accessibility_transport_unavailable_for_current_foreground")
            }
            if (record.diagnostic ?? "").localizedCaseInsensitiveContains("SpringBoardServices") {
                causes.append("frontmost_app_or_accessibility_server_resolution_failed")
            }
        }
        if layer == .localVision || reason.hasPrefix("ocr_") || reason.contains("coreml") || reason.contains("corevideo") {
            if record.metadata["localVisionBackend"]?.contains("root") == true {
                causes.append("vision_executed_in_privileged_helper_context")
            }
            if record.metadata["perceptionRemoteVisionRequired"] == "true", record.metadata["perceptionLocalSufficient"] == "true" {
                causes.append("router_ignored_sufficient_local_observation")
            }
        }
        if record.metadata["providerImageRoute"] == "text_only"
            || record.metadata["providerImageRoute"] == "unsupported"
            || record.metadata["providerVisionCapability"] == "text_only" {
            causes.append("provider_route_cannot_consume_image_observation")
        }
        if reason == "provider_text_only_local_fallback_missing" {
            causes.append("local_semantic_fallback_did_not_resolve_current_observation")
        }
        return Array(Set(causes)).sorted()
    }

    private static func isAutomaticRecoverySafe(reason: String, layer: DiagnosticFailureLayer) -> Bool {
        if ["unauthorized", "bad_request", "foreground_target_mismatch", "ax_backend_unavailable", "ax_tree_budget_truncated", "corevideo_allocation_failed", "ocr_coordinate_normalization_failed", "deep_route_fallback"].contains(reason) {
            // CoreVideo/Vision allocation failures are circuit-breaker events, not immediate
            // self-repair opportunities. Retrying the same runtime context can reproduce the same
            // entitlement/resource failure and amplify watchdog pressure; continue through an
            // already-available screenshot/AX route and require a later fresh context for OCR.
            return false
        }
        switch layer {
        case .axObservation, .localVision, .guiVerification, .guiGesture, .guiNavigation, .toolRouting, .providerRoute, .appResolution:
            return true
        default:
            return ["no_observed_effect", "verification_failed", "route_exhausted", "premature_completion", "ocr_not_invoked", "ocr_completed_no_text", "ocr_target_not_recognized", "ocr_unique_match_ambiguous", "right_rail_anchor_classification_failed", "compact_count_normalization_failed"].contains(reason)
        }
    }

    private static func recommendedNextAction(for reason: String, layer: DiagnosticFailureLayer, recoveryAllowed: Bool) -> String {
        if reason == "deep_route_fallback" {
            return "continue_with_successful_selected_route_and_record_degradation;do_not_replan_only_for_fallback_depth"
        }
        if reason == "corevideo_allocation_failed" {
            return "open_local_ocr_corevideo_circuit_breaker;avoid_same_context_vision_retry;continue_with_ax_or_fresh_screenshot_visual_fallback;require_fresh_runtime_or_developer_fix_before_local_ocr_retry"
        }
        guard recoveryAllowed else {
            if reason == "recovery_budget_exhausted" { return "stop_automatic_retry_and_emit_developer_diagnosis" }
            return "stop_same_route_retry_and_escalate_with_existing_bug_capsule"
        }
        switch reason {
        case "ax_request_timeout", "ax_request_failed", "ax_tree_empty", "ax_target_absent", "ax_semantic_match_ambiguous":
            return "avoid_repeating_ax_for_same_foreground;use_fresh_screenshot_then_local_ocr_or_existing_visual_fallback"
        case "corevideo_allocation_failed":
            return "open_local_ocr_corevideo_circuit_breaker;avoid_same_context_vision_retry;continue_with_ax_or_fresh_screenshot_visual_fallback"
        case "coreml_runtime_failed", "ocr_request_failed":
            return "capture_one_fresh_screenshot;retry_local_ocr_once_in_non_privileged_cpu_only_context;then_escalate"
        case "ocr_not_invoked":
            return "invoke_existing_local_ocr_path_once_before_remote_vision"
        case "ocr_completed_no_text", "ocr_target_not_recognized", "ocr_unique_match_ambiguous", "ocr_region_invalid":
            return "refresh_screenshot_and_replan_local_semantic_query_or_region_once"
        case "right_rail_anchor_classification_failed", "compact_count_normalization_failed":
            return "reuse_current_ocr_elements_and_replan_metric_anchor_extraction_once"
        case "local_sufficient_remote_vision_routing_error":
            return "consume_existing_local_observation_without_remote_image_round_trip"
        case "provider_text_only_local_fallback_missing":
            return "reuse_current_screenshot_ocr_elements_with_existing_semantic_local_tool_once;do_not_send_image_to_text_only_provider"
        case "no_observed_effect", "verification_failed":
            return "revalidate_foreground_and_replan_from_fresh_observation_without_repeating_same_write"
        case "route_selection_failed", "route_exhausted":
            return "replan_to_next_existing_compatible_route_once"
        default:
            return layer == .providerRoute ? "use_existing_provider_compatibility_fallback_once" : "obtain_one_fresh_bounded_observation_and_replan"
        }
    }

    private static func relevantCapabilities(for layer: DiagnosticFailureLayer, capabilities: CapabilityProfile) -> [String: String] {
        let prefixes: [String]
        switch layer {
        case .axObservation:
            prefixes = ["automation.gui.tree", "automation.gui.screenshot", "execution.root_helper"]
        case .localVision:
            prefixes = ["automation.gui.screenshot", "automation.gui.tree"]
        case .guiGesture:
            prefixes = ["automation.gui.touch", "automation.gui.gestures", "automation.gui.screenshot"]
        case .guiTextInput:
            prefixes = ["automation.gui.text_input", "automation.gui.touch", "automation.gui.screenshot"]
        case .guiNavigation, .guiVerification:
            prefixes = ["automation.gui", "apps."]
        case .privilegedHelper:
            prefixes = ["execution.root_helper"]
        default:
            prefixes = []
        }
        var result: [String: String] = [:]
        for record in capabilities.records where prefixes.contains(where: { record.id == $0 || record.id.hasPrefix($0) }) {
            result[record.id] = record.status.rawValue
            if result.count >= 12 { break }
        }
        return result
    }

    private static func splitCSV(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(8).map { $0 }
    }

    private static func boolMetadata(_ record: DiagnosticLogRecord, _ key: String) -> Bool? {
        guard let value = record.metadata[key] else { return nil }
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
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
