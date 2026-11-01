/* V146 macOS arm64 isolated true dyld + Swift concurrency execution client.
 * This is NOT official ChatGPT and does not access user financial records.
 * It is a controlled behavior test of the self-written research modules.
 */
import Foundation
import Darwin
import FinanceKit
import MarketplaceKit

@main
struct V146IsolatedDyldSwiftClient {
    static func main() async {
        guard !FinanceStore.isDataAvailable(.financialData) else {
            fputs("FAIL_FINANCE_UNEXPECTED_DATA\n",stderr); exit(10)
        }
        do {
            let current = try await FinanceStore.shared.authorizationStatus()
            guard current == .denied else {
                fputs("FAIL_FINANCE_AUTHORIZATION_STATUS\n",stderr); exit(11)
            }
            let requested = try await FinanceStore.shared.requestAuthorization()
            guard requested == .denied else {
                fputs("FAIL_FINANCE_REQUEST_SEMANTICS\n",stderr); exit(12)
            }
        } catch {
            fputs("FAIL_FINANCE_ASYNC_THROW\n",stderr); exit(13)
        }
        do {
            _ = try await AppDistributor.current
            fputs("FAIL_MARKET_DID_NOT_THROW\n",stderr); exit(14)
        } catch {
            // Correct for the research provider: it throws UnsupportedProvider.
        }
        print("PASS_MACOS_ARM64_REAL_DYLD_SWIFT_ASYNC_ABI_DENY_SEMANTICS")
        print("NOT_IOS16_DEVICE_NOT_APPLE_FRAMEWORK_NOT_OFFICIAL_CHATGPT")
    }
}
