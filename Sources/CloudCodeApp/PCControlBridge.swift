import Foundation

/// Compatibility marker for the original app-process PC-control prototype.
///
/// The active implementation moved to `PCControlBootstrap` + the detached
/// `CloudCodeRootHelper` worker so control remains reachable while another app is foreground.
/// This file intentionally owns no listener and dispatches no device actions.
enum PCControlBridge {
    static let implementation = "detached-root-helper"
}
