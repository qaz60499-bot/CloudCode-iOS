/*
 * IPA Total V144 - RESEARCH PROVIDER ONLY, not Apple's FinanceKit.
 * Intentionally deny all financial data access. No wallet data, authorization
 * UI or entitlements. Symbol-shape experiment for arm64 iOS16.6. Never ship
 * under Apple's framework name to replace a system-installed framework.
 */
public enum AuthorizationStatus: Equatable {
    case authorized, denied, notDetermined
}

public final class FinanceStore {
    public enum DataType {
        case financialData
    }
    public static let shared = FinanceStore()
    private init() {}

    public static func isDataAvailable(_ type: DataType) -> Bool {
        _ = type
        return false
    }

    public func authorizationStatus() async throws -> AuthorizationStatus {
        return .denied
    }

    #if !V144_NEGATIVE
    public func requestAuthorization() async throws -> AuthorizationStatus {
        // No consent UI; fail closed, not a replacement for Apple's framework.
        return .denied
    }
    #endif
}
