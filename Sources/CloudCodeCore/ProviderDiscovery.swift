import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderDiscoveryResult: Sendable, Equatable {
    public var models: [String]
    public var protocols: [ProviderProtocol]
    public var authMode: ProviderAuthMode
    public var readiness: ProviderReadiness

    public init(models: [String], protocols: [ProviderProtocol], authMode: ProviderAuthMode, readiness: ProviderReadiness) {
        self.models = models
        self.protocols = protocols
        self.authMode = authMode
        self.readiness = readiness
    }
}

public struct ProviderDiscoveryClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = ProviderURLSessionFactory.make()) {
        self.session = session
    }

    public func discover(
        baseURL: URL,
        apiKey: String,
        preferredAuthMode: ProviderAuthMode? = nil,
        allowPricingCatalogFallback: Bool = false
    ) async throws -> ProviderDiscoveryResult {
        var lastError: Error = ProviderError.missingAPIKey
        var sawAuthoritativeEmptyCatalog = false
        var authModes = [ProviderAuthMode.bearer, .xAPIKey, .both]
        if let preferredAuthMode {
            authModes.removeAll { $0.rawValue == preferredAuthMode.rawValue }
            authModes.insert(preferredAuthMode, at: 0)
        }

        // Catalog auth and inference auth are deliberately independent. Some compatible
        // gateways expose /models with one header mode while requiring a different mode
        // for /messages. Never downgrade inference auth just because catalog discovery
        // succeeded with a weaker/different header shape.
        var discoveredCatalog: (models: [String], authMode: ProviderAuthMode)?
        for catalogAuthMode in authModes {
            do {
                let models = try await discoverModels(baseURL: baseURL, apiKey: apiKey, authMode: catalogAuthMode)
                if !models.isEmpty {
                    discoveredCatalog = (models, catalogAuthMode)
                    break
                }
                sawAuthoritativeEmptyCatalog = true
                lastError = ProviderError.malformedEvent
            } catch {
                lastError = error
            }
        }

        if discoveredCatalog == nil, allowPricingCatalogFallback {
            do {
                let models = try await discoverModelsFromPricing(baseURL: baseURL)
                if !models.isEmpty {
                    discoveredCatalog = (models, preferredAuthMode ?? .both)
                } else {
                    sawAuthoritativeEmptyCatalog = true
                }
            } catch {
                lastError = error
            }
        }

        guard let discoveredCatalog else {
            if sawAuthoritativeEmptyCatalog {
                return ProviderDiscoveryResult(
                    models: [],
                    protocols: [],
                    authMode: preferredAuthMode ?? .both,
                    readiness: .unavailable
                )
            }
            throw lastError
        }
        let models = discoveredCatalog.models

        // Model catalogs from compatible gateways can mix chat, image, embedding,
        // and legacy entries. Do not assume the first row is inference-compatible.
        // Probe a bounded prefix under each inference auth mode, keeping the provider's
        // existing auth mode first when supplied by the caller.
        for inferenceAuthMode in authModes {
            for model in models.prefix(12) {
                var supported: [ProviderProtocol] = []
                for protocolName in ProviderProtocol.allCases {
                    if try await probe(protocolName, baseURL: baseURL, apiKey: apiKey, authMode: inferenceAuthMode, model: model) {
                        supported.append(protocolName)
                    }
                }
                if !supported.isEmpty {
                    let orderedModels = [model] + models.filter { $0 != model }
                    return ProviderDiscoveryResult(
                        models: orderedModels,
                        protocols: supported,
                        authMode: inferenceAuthMode,
                        readiness: .ready
                    )
                }
            }
        }

        return ProviderDiscoveryResult(
            models: models,
            protocols: [],
            authMode: preferredAuthMode ?? discoveredCatalog.authMode,
            readiness: .needsValidation
        )
    }

    public func discoverModels(baseURL: URL, apiKey: String, authMode: ProviderAuthMode = .bearer) async throws -> [String] {
        let url = try ProviderEndpoint.endpoint(baseURL: baseURL, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(apiKey, mode: authMode, request: &request)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("缺少 HTTP 响应") }
        if let error = ProviderHTTPClassifier.error(for: http.statusCode, body: data) { throw error }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = object["data"] ?? object["models"] else { throw ProviderError.malformedEvent }
        return Self.extractModelIdentifiers(from: catalog)
    }

    private func discoverModelsFromPricing(baseURL: URL) async throws -> [String] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidEndpoint
        }
        components.path = "/api/pricing"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ProviderError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("缺少 HTTP 响应") }
        if let error = ProviderHTTPClassifier.error(for: http.statusCode, body: data) { throw error }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedEvent
        }
        var sawCatalogField = false
        for key in ["data", "priced_model_details", "priced_models", "models"] {
            guard let catalog = object[key] else { continue }
            sawCatalogField = true
            let result = Self.extractModelIdentifiers(from: catalog)
            if !result.isEmpty { return result }
        }
        if sawCatalogField { return [] }
        throw ProviderError.malformedEvent
    }

    private static func extractModelIdentifiers(from value: Any) -> [String] {
        var result: [String] = []
        let preferredKeys = ["id", "model", "model_id", "modelId", "model_name", "modelName", "name", "slug", "value"]

        func append(_ raw: String) {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.count <= 256,
                  !candidate.contains("\n"),
                  !candidate.contains("\r"),
                  !result.contains(candidate) else { return }
            result.append(candidate)
        }

        func visit(_ node: Any, allowScalar: Bool) {
            if let string = node as? String {
                if allowScalar { append(string) }
                return
            }
            if let array = node as? [Any] {
                for item in array { visit(item, allowScalar: true) }
                return
            }
            guard let dictionary = node as? [String: Any] else { return }

            var matchedPreferredKey = false
            for key in preferredKeys {
                guard let child = dictionary[key] else { continue }
                matchedPreferredKey = true
                if let string = child as? String {
                    append(string)
                } else {
                    visit(child, allowScalar: true)
                }
            }
            if matchedPreferredKey { return }

            // Pricing catalogs sometimes use the model identifier as the dictionary key
            // and put price metadata in the value. Accept only keys that look like model
            // identifiers; do not ingest generic metadata keys such as `default` or vendor names.
            let modelMarkers = ["claude", "opus", "sonnet", "haiku", "gpt", "gemini", "deepseek", "glm", "kimi", "qwen", "grok", "minimax", "step"]
            for (key, child) in dictionary where child is [Any] || child is [String: Any] {
                let lowered = key.lowercased()
                if modelMarkers.contains(where: { lowered.contains($0) }) {
                    append(key)
                }
            }

            // Some compatible gateways wrap each model in a provider-specific object.
            // Traverse nested containers, but do not treat unrelated top-level metadata
            // scalars as model IDs unless they are the row itself.
            for child in dictionary.values where child is [Any] || child is [String: Any] {
                visit(child, allowScalar: false)
            }
        }

        visit(value, allowScalar: true)
        return result
    }

    private func probe(_ protocolName: ProviderProtocol, baseURL: URL, apiKey: String, authMode: ProviderAuthMode, model: String) async throws -> Bool {
        let path: String
        let body: [String: Any]
        switch protocolName {
        case .anthropic:
            path = "messages"
            body = ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "Reply OK"]]]
        case .openAIChat:
            path = "chat/completions"
            body = ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "Reply OK"]]]
        case .openAIResponses:
            path = "responses"
            body = ["model": model, "max_output_tokens": 1, "input": "Reply OK"]
        }
        let url = try ProviderEndpoint.endpoint(baseURL: baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if protocolName == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        applyAuth(apiKey, mode: authMode, request: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(http.statusCode) { return true }
            if case .capacityExhausted? = ProviderHTTPClassifier.error(for: http.statusCode, body: data) { return true }
            return false
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            return false
        }
    }

    private func applyAuth(_ key: String, mode: ProviderAuthMode, request: inout URLRequest) {
        switch mode {
        case .bearer:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .xAPIKey:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .both:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
    }
}
