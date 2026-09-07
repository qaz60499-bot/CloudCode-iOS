#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a bounded JSON readiness snapshot. Read-only probes only; no synthetic input is dispatched.
int CloudCodeGUIProbeJSON(void);
int CloudCodeGUITreeJSON(void);
int CloudCodeGUIScreenshotBase64(void);
int CloudCodeGUIScreenshotFile(NSString *path);
/// Runs bounded Vision OCR against an app-owned tmp JPEG and emits only text/box JSON.
int CloudCodeGUIOCRFile(NSString *path, NSUInteger maximumElements);
int CloudCodeGUITap(double x, double y);
int CloudCodeGUISwipe(double fromX, double fromY, double toX, double toY, double durationSeconds);
int CloudCodeGUIScroll(double deltaX, double deltaY);
int CloudCodeGUINavigateBack(NSString *strategy);
int CloudCodeGUITypeBase64(NSString *base64Text);

NS_ASSUME_NONNULL_END
