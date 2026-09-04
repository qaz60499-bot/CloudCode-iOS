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
        preferredAuthMode: ProviderAuthMode? = nil
    ) async throws -> ProviderDiscoveryResult {
        var firstCatalog: (models: [String], authMode: ProviderAuthMode)?
        var lastError: Error = ProviderError.missingAPIKey
        var authModes = [ProviderAuthMode.bearer, .xAPIKey, .both]
        if let preferredAuthMode {
            authModes.removeAll { $0.rawValue == preferredAuthMode.rawValue }
            authModes.insert(preferredAuthMode, at: 0)
        }

        for authMode in authModes {
            let models: [String]
            do {
                models = try await discoverModels(baseURL: baseURL, apiKey: apiKey, authMode: authMode)
            } catch {
                lastError = error
                continue
            }
            if firstCatalog == nil { firstCatalog = (models, authMode) }
            guard !models.isEmpty else { continue }

            // Model catalogs from compatible gateways can mix chat, image, embedding,
            // and legacy entries. Do not assume the first row is inference-compatible.
            // Probe a bounded prefix and move the first working model to the front so
            // selection defaults to a model that was actually accepted by the gateway.
            for model in models.prefix(12) {
                var supported: [ProviderProtocol] = []
                for protocolName in ProviderProtocol.allCases {
                    if try await probe(protocolName, baseURL: baseURL, apiKey: apiKey, authMode: authMode, model: model) {
                        supported.append(protocolName)
                    }
                }
                if !supported.isEmpty {
                    let orderedModels = [model] + models.filter { $0 != model }
                    return ProviderDiscoveryResult(
                        models: orderedModels,
                        protocols: supported,
                        authMode: authMode,
                        readiness: .ready
                    )
                }
            }
        }

        if let firstCatalog {
            return ProviderDiscoveryResult(
                models: firstCatalog.models,
                protocols: [],
                authMode: firstCatalog.authMode,
                readiness: .needsValidation
            )
        }
        throw lastError
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
              let rows = object["data"] as? [[String: Any]] else { throw ProviderError.malformedEvent }
        var result: [String] = []
        for row in rows {
            let value = (row["id"] as? String ?? row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
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
