#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bounded in-process ios_system bridge. These functions never request root/persona authority.
/// Capability snapshots validate runtime symbols, both packaged command dictionaries, and each
/// command's embedded framework/function before the Agent may see the command.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CloudCodeIOSSystemCapabilitySnapshot(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *CloudCodeIOSSystemRunCommand(
    NSString *command,
    NSString *invocationID,
    NSString *sessionID,
    NSString *workspaceRoot,
    NSString *workingDirectory,
    NSString *homeDirectory,
    NSString *temporaryDirectory,
    NSTimeInterval timeout
);

/// Cancels only the currently active exact invocation. Upstream ios_kill() cancels the command's
/// root pthread; this bridge never sends a process signal and never escalates to root/persona.
FOUNDATION_EXPORT void CloudCodeIOSSystemCancelInvocation(NSString *invocationID);

NS_ASSUME_NONNULL_END
