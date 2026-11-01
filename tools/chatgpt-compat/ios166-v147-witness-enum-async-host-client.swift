/* V147 new host-level proof, not official ChatGPT and not iOS16 device.
 * Exercises real exported Swift protocol-conformance witness lookup,
 * resilient enum payload metadata and imported async calls in concurrent tasks.
 * All financial operations remain self-written fail-closed research semantics.
 */
import Foundation
import Darwin
import FinanceKit
import MarketplaceKit

private func witnessEqual<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool {
    lhs == rhs
}

private protocol AsyncStatusBridge {
    func readStatus() async throws -> AuthorizationStatus
}

private struct ResearchStatusBridge: AsyncStatusBridge {
    func readStatus() async throws -> AuthorizationStatus {
        try await FinanceStore.shared.authorizationStatus()
    }
}

private func throughAsyncWitness(_ bridge: any AsyncStatusBridge) async throws -> AuthorizationStatus {
    try await bridge.readStatus()
}

private func unpackMarketplace(_ value: AppDistributor) -> String? {
    switch value {
    case .marketplace(let payload): return payload
    case .appStore, .testFlight, .web, .other: return nil
    }
}

@main
struct V147SwiftWitnessRuntime {
    static func main() async {
        // Conformance is declared by the separately compiled resilient FinanceKit dylib.
        guard witnessEqual(AuthorizationStatus.denied, .denied),
              !witnessEqual(AuthorizationStatus.denied, .authorized),
              String(reflecting: AuthorizationStatus.self).contains("FinanceKit") else {
            fputs("FAIL_V147_IMPORTED_EQUATABLE_WITNESS_OR_METADATA\n", stderr)
            exit(21)
        }

        // Exercise payload construction and extraction across a resilient module boundary.
        let boxed: Any = AppDistributor.marketplace("v147-runtime-payload")
        guard let imported = boxed as? AppDistributor,
              unpackMarketplace(imported) == "v147-runtime-payload",
              unpackMarketplace(.appStore) == nil else {
            fputs("FAIL_V147_RESILIENT_ENUM_PAYLOAD\n", stderr)
            exit(22)
        }

        do {
            let existential: any AsyncStatusBridge = ResearchStatusBridge()
            let throughWitness = try await throughAsyncWitness(existential)
            guard witnessEqual(throughWitness, .denied) else {
                fputs("FAIL_V147_ASYNC_PROTOCOL_WITNESS\n", stderr)
                exit(23)
            }

            let outcomes = try await withThrowingTaskGroup(of: AuthorizationStatus.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await FinanceStore.shared.authorizationStatus() }
                }
                var results: [AuthorizationStatus] = []
                for try await value in group { results.append(value) }
                return results
            }
            guard outcomes.count == 4, outcomes.allSatisfy({ witnessEqual($0, .denied) }) else {
                fputs("FAIL_V147_CONCURRENT_ASYNC_PROVIDER\n", stderr)
                exit(24)
            }
        } catch {
            fputs("FAIL_V147_ASYNC_PROVIDER_THROW\n", stderr)
            exit(25)
        }

        do {
            _ = try await AppDistributor.current
            fputs("FAIL_V147_MARKETPLACE_FAIL_OPEN\n", stderr)
            exit(26)
        } catch is AppDistributor.UnsupportedProvider {
            // Safe research contract: do not fabricate Apple MarketplaceKit state.
        } catch {
            fputs("FAIL_V147_UNEXPECTED_MARKETPLACE_ERROR\n", stderr)
            exit(27)
        }
        print("PASS_V147_REAL_IMPORTED_WITNESS_RESILIENT_ENUM_CONCURRENT_ASYNC")
        print("MACOS_ONLY_RESEARCH_PROVIDER_NOT_IOS16_NOT_OFFICIAL")
    }
}
