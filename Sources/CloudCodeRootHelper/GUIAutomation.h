#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a bounded JSON readiness snapshot. Read-only probes only; no synthetic input is dispatched.
int CloudCodeGUIProbeJSON(void);
int CloudCodeGUITreeJSON(void);
int CloudCodeGUIAXProbeJSON(NSString *stage, NSString *seedKind, pid_t targetPID, NSString *preparation);
int CloudCodeGUIScreenshotBase64(void);
int CloudCodeGUIScreenshotFile(NSString *path);
int CloudCodeGUITap(double x, double y);
int CloudCodeGUISwipe(double fromX, double fromY, double toX, double toY, double durationSeconds);
int CloudCodeGUIScroll(double deltaX, double deltaY);
int CloudCodeGUINavigateBack(NSString *strategy);
int CloudCodeGUIFocusedTextInputJSON(void);
int CloudCodeGUITypeBase64(NSString *base64Text);

NS_ASSUME_NONNULL_END
