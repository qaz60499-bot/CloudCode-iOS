import Foundation

public protocol AppBackedProviderStreaming: Sendable {
    func stream(
        configuration: AppBackedProviderConfiguration,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error>

    func imageCapability(
        configuration: AppBackedProviderConfiguration
    ) async -> ProviderImageCapabilityAssessment
}

public extension AppBackedProviderStreaming {
    func imageCapability(
        configuration: AppBackedProviderConfiguration
    ) async -> ProviderImageCapabilityAssessment {
        ProviderImageCapabilityAssessment(capability: .textOnly, source: "app_backed_default_text_only")
    }
}

public protocol ProviderExecutionStreaming: Sendable {
    func stream(
        configuration: ProviderExecutionConfiguration,
        networkAPIKey: String?,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error>

    func imageCapability(
        configuration: ProviderExecutionConfiguration
    ) async -> ProviderImageCapabilityAssessment
}

public struct ProviderExecutionRouter: ProviderExecutionStreaming, Sendable {
    private let networkProvider: any ProviderStreaming
    private let keyVault: any APIKeyVault
    private let appBackedProvider: (any AppBackedProviderStreaming)?

    public init(
        networkProvider: any ProviderStreaming,
        keyVault: any APIKeyVault,
        appBackedProvider: (any AppBackedProviderStreaming)? = nil
    ) {
        self.networkProvider = networkProvider
        self.keyVault = keyVault
        self.appBackedProvider = appBackedProvider
    }

    public func stream(
        configuration: ProviderExecutionConfiguration,
        networkAPIKey: String? = nil,
        messages: [ChatMessage],
        tools: [ProviderToolSchema]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        switch configuration {
        case .network(let network):
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let key: String
                        if let networkAPIKey {
                            key = networkAPIKey
                        } else {
                            key = try await keyVault.key(for: network.apiKeyReference)
                        }
                        for try await event in networkProvider.stream(
                            configuration: network,
                            apiKey: key,
                            messages: messages,
                            tools: tools
                        ) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        case .appBacked(let app):
            guard let appBackedProvider else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ProviderError.transport("App-backed Provider Runtime 未配置"))
                }
            }
            return appBackedProvider.stream(configuration: app, messages: messages, tools: tools)
        }
    }

    public func imageCapability(
        configuration: ProviderExecutionConfiguration
    ) async -> ProviderImageCapabilityAssessment {
        switch configuration {
        case .network(let network):
            do {
                let key = try await keyVault.key(for: network.apiKeyReference)
                return await networkProvider.imageCapability(configuration: network, apiKey: key)
            } catch {
                return ProviderImageCapabilityAssessment(capability: .unknown, source: "network_key_unavailable")
            }
        case .appBacked(let app):
            guard let appBackedProvider else {
                return ProviderImageCapabilityAssessment(capability: .unknown, source: "app_backed_runtime_unavailable")
            }
            return await appBackedProvider.imageCapability(configuration: app)
        }
    }
}
