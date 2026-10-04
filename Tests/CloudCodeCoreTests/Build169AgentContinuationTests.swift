import CryptoKit
import Foundation
import XCTest
@testable import CloudCodeCore

final class Build169AgentContinuationTests: XCTestCase {
    func testInterruptedProviderOutputIsDurableAndContinuationAddsOnlyNewSuffix() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = "Continue this response without repeating it."
        let partial = numberedText(1...94)
        let suffix = numberedText(95...100)
        let provider = SequencedContinuationProvider(responses: [
            .init(tokens: (1...94).map { String(format: "%03d", $0) }, interrupts: true),
            .init(tokens: (95...100).map { String(format: "%03d", $0) }, interrupts: false)
        ])
        let (agent, sessions, checkpoints) = makeAgent(provider: provider, root: root)
        let initialSession = AgentSession(permissionMode: .safe)
        let configuration = testProviderConfiguration()

        let initialStream = await agent.send(text: request, session: initialSession, providerConfiguration: configuration)
        do {
            _ = try await collectTokenText(initialStream)
            XCTFail("The first provider stream must interrupt after its partial response")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }

        let persistedPartial = try await sessions.load(initialSession.id)
        let firstInterruptedCheckpoints = await checkpoints.interrupted()
        let interruptedCheckpoint = try XCTUnwrap(firstInterruptedCheckpoints.first(where: { $0.sessionID == initialSession.id }))
        let partialMessageID = try XCTUnwrap(UUID(uuidString: interruptedCheckpoint.payload["provider.partial.messageID"] ?? ""))
        let matchingPartialMessages = persistedPartial.messages.filter { $0.id == partialMessageID }
        let partialMessage = try XCTUnwrap(matchingPartialMessages.first)
        let fingerprint = SHA256.hash(data: Data(partial.utf8)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(matchingPartialMessages.count, 1, "Repeated partial saves must retain one assistant message ID")
        XCTAssertEqual(partialMessage.role, .assistant)
        XCTAssertEqual(partialMessage.content, partial)
        XCTAssertEqual(partialMessage.providerMetadata["provider_partial_output"], "true")
        XCTAssertEqual(interruptedCheckpoint.payload["provider.partial.characters"], String(partial.count))
        XCTAssertEqual(interruptedCheckpoint.payload["provider.partial.utf8Bytes"], String(partial.utf8.count))
        XCTAssertEqual(interruptedCheckpoint.payload["provider.partial.fingerprint"], fingerprint)
        XCTAssertEqual(interruptedCheckpoint.payload["provider.partial.tail"], partial)
        XCTAssertEqual(interruptedCheckpoint.payload["provider.continuation.pending"], "true")
        XCTAssertEqual(interruptedCheckpoint.payload["provider.streamInterruptionAutoResumeCount"], "1")
        XCTAssertEqual(interruptedCheckpoint.payload["resume.mode"], "auto_provider_stream_interruption_once")

        let resumedStream = await agent.send(
            text: request,
            session: persistedPartial,
            providerConfiguration: configuration,
            appendUserMessage: false,
            resumeCheckpoint: interruptedCheckpoint
        )
        let resumedTokenText = try await collectTokenText(resumedStream)
        XCTAssertEqual(resumedTokenText, suffix)

        let persistedComplete = try await sessions.load(initialSession.id)
        let assistantMessages = persistedComplete.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map(\.content), [partial, suffix])
        XCTAssertEqual(assistantMessages.map(\.content).joined(), numberedText(1...100))
        XCTAssertEqual(assistantMessages.filter { $0.content == partial }.count, 1)
        XCTAssertEqual(assistantMessages.filter { $0.id == partialMessageID }.count, 1)
        XCTAssertEqual(persistedComplete.messages.filter { $0.role == .user && $0.content == request }.count, 1)

        let providerAttempts = await provider.recordedMessages()
        XCTAssertEqual(providerAttempts.count, 2)
        let resumeMessages = try XCTUnwrap(providerAttempts.last)
        XCTAssertTrue(resumeMessages.contains { $0.id == partialMessageID && $0.content == partial })
        let semanticSummary = try XCTUnwrap(resumeMessages.first {
            $0.providerMetadata["context_layer"] == "checkpoint_semantic_progress"
        })
        XCTAssertTrue(semanticSummary.content.contains("last durable boundary"))
        XCTAssertTrue(semanticSummary.content.contains(fingerprint))
        XCTAssertTrue(semanticSummary.content.contains("only a new suffix"))

        let loadedCompletedCheckpoint = await checkpoints.checkpoint(interruptedCheckpoint.id)
        let completedCheckpoint = try XCTUnwrap(loadedCompletedCheckpoint)
        let policy = HarnessContextManager.providerPolicy(for: request)
        let contextCharacters = try XCTUnwrap(Int(completedCheckpoint.payload["metric.providerContextEstimatedCharacters"] ?? ""))
        let contextMessageCount = try XCTUnwrap(Int(completedCheckpoint.payload["metric.providerContextMessageCount"] ?? ""))
        let contextPayloadBytes = try XCTUnwrap(Int64(completedCheckpoint.payload["metric.providerContextEstimatedPayloadBytes"] ?? ""))
        XCTAssertGreaterThan(contextCharacters, 0)
        XCTAssertLessThanOrEqual(contextCharacters, policy.maxCharacters)
        XCTAssertLessThanOrEqual(contextMessageCount, policy.maxMessages)
        XCTAssertLessThanOrEqual(contextPayloadBytes, 3 * 1_024 * 1_024)
        let attemptCount = await provider.attemptCount()
        XCTAssertEqual(attemptCount, 2)
    }

    func testSecondInterruptionRequiresManualResumeAndKeepsBothPartialOutputs() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = "Keep both interrupted response parts."
        let provider = SequencedContinuationProvider(responses: [
            .init(tokens: ["partial-1"], interrupts: true),
            .init(tokens: ["partial-2"], interrupts: true)
        ])
        let (agent, sessions, checkpoints) = makeAgent(provider: provider, root: root)
        let initialSession = AgentSession(permissionMode: .safe)
        let configuration = testProviderConfiguration()

        let firstStream = await agent.send(text: request, session: initialSession, providerConfiguration: configuration)
        do {
            _ = try await collectTokenText(firstStream)
            XCTFail("The first provider stream must interrupt")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }

        let persistedAfterFirst = try await sessions.load(initialSession.id)
        let firstInterruptedCheckpoints = await checkpoints.interrupted()
        let firstCheckpoint = try XCTUnwrap(firstInterruptedCheckpoints.first(where: { $0.sessionID == initialSession.id }))
        XCTAssertEqual(firstCheckpoint.payload["provider.streamInterruptionAutoResumeCount"], "1")
        XCTAssertEqual(firstCheckpoint.payload["resume.mode"], "auto_provider_stream_interruption_once")
        let firstPartialID = try XCTUnwrap(UUID(uuidString: firstCheckpoint.payload["provider.partial.messageID"] ?? ""))
        XCTAssertEqual(persistedAfterFirst.messages.first(where: { $0.id == firstPartialID })?.content, "partial-1")

        let secondStream = await agent.send(
            text: request,
            session: persistedAfterFirst,
            providerConfiguration: configuration,
            appendUserMessage: false,
            resumeCheckpoint: firstCheckpoint
        )
        do {
            _ = try await collectTokenText(secondStream)
            XCTFail("The second interruption must leave continuation manual")
        } catch {
            XCTAssertEqual(error as? ProviderError, .streamInterrupted)
        }

        let persistedAfterSecond = try await sessions.load(initialSession.id)
        let secondInterruptedCheckpoints = await checkpoints.interrupted()
        let secondCheckpoint = try XCTUnwrap(secondInterruptedCheckpoints.first(where: { $0.sessionID == initialSession.id }))
        XCTAssertEqual(secondCheckpoint.payload["provider.streamInterruptionAutoResumeCount"], "1")
        XCTAssertEqual(secondCheckpoint.payload["resume.mode"], "manual_provider_stream_interruption")
        let secondPartialID = try XCTUnwrap(UUID(uuidString: secondCheckpoint.payload["provider.partial.messageID"] ?? ""))
        XCTAssertNotEqual(firstPartialID, secondPartialID)
        XCTAssertEqual(persistedAfterSecond.messages.first(where: { $0.id == firstPartialID })?.content, "partial-1")
        XCTAssertEqual(persistedAfterSecond.messages.first(where: { $0.id == secondPartialID })?.content, "partial-2")
        XCTAssertEqual(
            persistedAfterSecond.messages.filter { $0.role == .assistant }.map(\.content),
            ["partial-1", "partial-2"]
        )
        XCTAssertEqual(persistedAfterSecond.messages.filter { $0.role == .user && $0.content == request }.count, 1)
        let attemptCount = await provider.attemptCount()
        XCTAssertEqual(attemptCount, 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Build169AgentContinuationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAgent(
        provider: ProviderStreaming,
        root: URL
    ) -> (AgentCore, SessionStore, TaskCheckpointStore) {
        let registry = ToolRegistry(descriptors: [])
        let sessions = SessionStore(root: root.appendingPathComponent("sessions", isDirectory: true))
        let checkpoints = TaskCheckpointStore(fileURL: root.appendingPathComponent("checkpoints.json"))
        let agent = AgentCore(
            provider: provider,
            keyVault: MemoryKeyVault(keys: ["test-key": "secret"]),
            toolRouter: ToolRouter(registry: registry, executors: []),
            registry: registry,
            capabilityProbe: Build169FixedCapabilityProbe(profile: CapabilityProfile(records: [])),
            sessionStore: sessions,
            checkpointStore: checkpoints,
            maxToolRounds: 2
        )
        return (agent, sessions, checkpoints)
    }

    private func testProviderConfiguration() -> ProviderConfiguration {
        ProviderConfiguration(
            name: "continuation-test",
            baseURL: URL(string: "https://example.com/v1")!,
            model: "test",
            apiKeyReference: "test-key"
        )
    }

    private func numberedText(_ range: ClosedRange<Int>) -> String {
        range.map { String(format: "%03d", $0) }.joined()
    }

    private func collectTokenText(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> String {
        var text = ""
        for try await event in stream {
            if case .token(let token) = event { text += token }
        }
        return text
    }
}

private struct Build169FixedCapabilityProbe: CapabilityProbing, Sendable {
    let profile: CapabilityProfile
    func probe() async -> CapabilityProfile { profile }
}

private actor SequencedContinuationProvider: ProviderStreaming {
    struct Response: Sendable {
        let tokens: [String]
        let interrupts: Bool
    }

    private let responses: [Response]
    private var callMessages: [[ChatMessage]] = []
    private var attempts = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    nonisolated func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let response = await nextResponse(messages: messages)
                for token in response.tokens {
                    continuation.yield(.token(token))
                }
                if response.interrupts {
                    continuation.finish(throwing: ProviderError.streamInterrupted)
                } else {
                    continuation.yield(.finished)
                    continuation.finish()
                }
            }
        }
    }

    func recordedMessages() -> [[ChatMessage]] { callMessages }
    func attemptCount() -> Int { attempts }

    private func nextResponse(messages: [ChatMessage]) -> Response {
        callMessages.append(messages)
        let index = attempts
        attempts += 1
        return responses[min(index, responses.count - 1)]
    }
}
