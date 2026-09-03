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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func discover(baseURL: URL, apiKey: String) async throws -> ProviderDiscoveryResult {
        var firstCatalog: (models: [String], authMode: ProviderAuthMode)?
        var lastError: Error = ProviderError.missingAPIKey

        for authMode in [ProviderAuthMode.bearer, .xAPIKey, .both] {
            let models: [String]
            do {
                models = try await discoverModels(baseURL: baseURL, apiKey: apiKey, authMode: authMode)
            } catch {
                lastError = error
                continue
            }
            if firstCatalog == nil { firstCatalog = (models, authMode) }
            guard let model = models.first else { continue }

            var supported: [ProviderProtocol] = []
            for protocolName in ProviderProtocol.allCases {
                if try await probe(protocolName, baseURL: baseURL, apiKey: apiKey, authMode: authMode, model: model) {
                    supported.append(protocolName)
                }
            }
            if !supported.isEmpty {
                return ProviderDiscoveryResult(
                    models: models,
                    protocols: supported,
                    authMode: authMode,
                    readiness: .ready
                )
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
        let url = try discoveryEndpoint(baseURL: baseURL, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(apiKey, mode: authMode, request: &request)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.transport("Missing HTTP response") }
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
        let url = try discoveryEndpoint(baseURL: baseURL, path: path)
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

    private func discoveryEndpoint(baseURL: URL, path: String) throws -> URL {
        guard baseURL.scheme == "https" || baseURL.host == "localhost" else { throw ProviderError.invalidEndpoint }
        var url = baseURL
        let normalized = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix(path) { return url }
        if normalized.isEmpty { url.appendPathComponent("v1") }
        else if normalized != "v1" && !normalized.hasSuffix("/v1") { url.appendPathComponent("v1") }
        url.appendPathComponent(path)
        return url
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
