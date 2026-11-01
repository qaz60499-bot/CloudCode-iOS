/*
 * V143 real Apple iPhoneOS SDK import ABI client, COMPILE ONLY.
 * NEVER execute: FinanceStore.requestAuthorization() would show a consent UI.
 * Nothing in this file is a FinanceKit/MarketplaceKit implementation.
 */
import FinanceKit
import MarketplaceKit

@available(iOS 17.4, *)
@inline(never)
public func v143FinanceCompileOnlyDoNotExecute() async throws -> Bool {
    let store = FinanceStore.shared
    let available = FinanceStore.isDataAvailable(.financialData)
    let status = try await store.authorizationStatus()
    let authorization = try await store.requestAuthorization()
    return available && status == .authorized && authorization != .notDetermined
}

@available(iOS 17.4, *)
@inline(never)
public func v143MarketplaceCompileOnlyDoNotExecute() async throws -> Bool {
    let source = try await AppDistributor.current
    switch source {
    case .appStore:
        return true
    case .testFlight:
        return false
    case .marketplace(let id):
        return !id.isEmpty
    case .web:
        return false
    case .other:
        return false
    @unknown default:
        return false
    }
}

#if V143_NEGATIVE
@available(iOS 17.4, *)
public func v143InvalidSynchronousAuthorizationCall() {
    // Expected real Apple Swift compiler errors: async call in sync context
    // and throwing expression without 'try'. This case MUST NOT typecheck.
    let _ = FinanceStore.shared.requestAuthorization()
}
@available(iOS 17.4, *)
public func v143InvalidNoTryMarketplaceProperty() async {
    // Expected Apple Swift compiler error: access can throw, missing 'try'.
    let _ = await AppDistributor.current
}
#endif
