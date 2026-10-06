#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts (or reuses) the detached authenticated PC-control worker.
/// The worker listens on a fixed device-local TCP port and publishes its random token to
/// /var/mobile/Media/Downloads/CloudCode-PC-Control.json for USB/AFC retrieval.
int CloudCodePCControlServerStart(const char *executablePath);

/// Long-lived worker entry point. This is invoked only as a detached root-helper child.
int CloudCodePCControlServerWorker(const char *executablePath, NSString *token, int handshakeFD);

NS_ASSUME_NONNULL_END
