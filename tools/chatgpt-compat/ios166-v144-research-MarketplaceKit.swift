/*
 * IPA Total V144 - RESEARCH PROVIDER ONLY, not Apple's MarketplaceKit.
 * Do not infer an App Store / TestFlight source. The async current property
 * deterministically fails closed in this isolated ABI research candidate.
 */
public enum AppDistributor {
    case appStore
    case testFlight
    case web
    case other
    case marketplace(String)

    public struct UnsupportedProvider: Error {}
    public static var current: AppDistributor {
        get async throws {
            throw UnsupportedProvider()
        }
    }
}
