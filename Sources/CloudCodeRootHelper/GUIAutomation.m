#import "GUIAutomation.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdio.h>
#import <unistd.h>

#define CLOUDCODE_GUI_MAX_TREE_NODES 400
#define CLOUDCODE_GUI_MAX_TREE_BYTES (256 * 1024)
#define CLOUDCODE_GUI_MAX_SCREENSHOT_BYTES (700 * 1024)
#define CLOUDCODE_GUI_MAX_TEXT_UTF8_BYTES (16 * 1024)
#define CLOUDCODE_GUI_SENDER_ID 0x8000000817319371ULL
#define CLOUDCODE_GUI_PARENT_INDEX 0u
#define CLOUDCODE_GUI_PARENT_IDENTITY 0u
#define CLOUDCODE_GUI_FINGER_INDEX 2u
#define CLOUDCODE_GUI_FINGER_IDENTITY 2u
#define CLOUDCODE_HID_DIGITIZER_RANGE (1u << 0)
#define CLOUDCODE_HID_DIGITIZER_TOUCH (1u << 1)
#define CLOUDCODE_HID_DIGITIZER_POSITION (1u << 2)
#define CLOUDCODE_HID_DIGITIZER_IDENTITY (1u << 5)
#define CLOUDCODE_HID_DIGITIZER_ATTRIBUTE (1u << 6)

typedef const struct __CloudCodeIOHIDEvent *CloudCodeIOHIDEventRef;
typedef const struct __CloudCodeIOHIDEventSystemClient *CloudCodeIOHIDEventSystemClientRef;
typedef const struct __CloudCodeIOHIDEventSystemConnection *CloudCodeIOHIDEventSystemConnectionRef;
typedef uint32_t CloudCodeIOOptionBits;

typedef CloudCodeIOHIDEventSystemClientRef (*CloudCodeHIDClientCreateFn)(CFAllocatorRef);
typedef void (*CloudCodeHIDDispatchFn)(CloudCodeIOHIDEventSystemClientRef, CloudCodeIOHIDEventRef);
typedef void (*CloudCodeHIDConnectionDispatchFn)(CloudCodeIOHIDEventSystemConnectionRef, CloudCodeIOHIDEventRef);
typedef void (*CloudCodeBKSetDigitizerInfoFn)(CloudCodeIOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
typedef CloudCodeIOHIDEventRef (*CloudCodeDigitizerEventCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, CloudCodeIOOptionBits);
typedef CloudCodeIOHIDEventRef (*CloudCodeFingerEventCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, CloudCodeIOOptionBits);
typedef CloudCodeIOHIDEventRef (*CloudCodeUnicodeEventCreateFn)(CFAllocatorRef, uint64_t, const uint8_t *, uint32_t, uint32_t, CloudCodeIOOptionBits);
typedef void (*CloudCodeHIDAppendFn)(CloudCodeIOHIDEventRef, CloudCodeIOHIDEventRef, CloudCodeIOOptionBits);
typedef void (*CloudCodeHIDSetSenderFn)(CloudCodeIOHIDEventRef, uint64_t);
typedef void (*CloudCodeHIDSetIntegerFn)(CloudCodeIOHIDEventRef, uint32_t, int32_t);
typedef void (*CloudCodeHIDSetFloatFn)(CloudCodeIOHIDEventRef, uint32_t, double);

typedef const struct __CloudCodeAXUIElement *CloudCodeAXUIElementRef;
typedef int32_t CloudCodeAXError;
typedef CloudCodeAXUIElementRef (*CloudCodeAXCreateApplicationFn)(pid_t);
typedef CloudCodeAXUIElementRef (*CloudCodeAXCreateSystemWideFn)(void);
typedef CloudCodeAXError (*CloudCodeAXGetPidFn)(CloudCodeAXUIElementRef, pid_t *);
typedef CloudCodeAXError (*CloudCodeAXCopyAttributeFn)(CloudCodeAXUIElementRef, CFStringRef, CFTypeRef *);
typedef CloudCodeAXError (*CloudCodeAXSetAttributeFn)(CloudCodeAXUIElementRef, CFStringRef, CFTypeRef);
typedef CloudCodeAXError (*CloudCodeAXCopyElementAtPositionFn)(CloudCodeAXUIElementRef, float, float, CloudCodeAXUIElementRef *);
typedef CloudCodeAXError (*CloudCodeAXCopyApplicationAtPositionFn)(CloudCodeAXUIElementRef, CloudCodeAXUIElementRef *, float, float);
typedef CloudCodeAXError (*CloudCodeAXCopyApplicationAndContextAtPositionFn)(CloudCodeAXUIElementRef, CloudCodeAXUIElementRef *, uint32_t *, float, float);
typedef CloudCodeAXError (*CloudCodeAXSetTimeoutFn)(CloudCodeAXUIElementRef, float);
typedef void (*CloudCodeAXAddAssociatedPidFn)(pid_t, pid_t, int);
typedef void (*CloudCodeAXSetRequestingClientFn)(uint32_t);
typedef int (*CloudCodeProcListAllPidsFn)(void *, int);
typedef int (*CloudCodeProcPidPathFn)(int, void *, uint32_t);

typedef CFTypeID (*CloudCodeAXValueGetTypeIDFn)(void);
typedef int (*CloudCodeAXValueGetTypeFn)(CFTypeRef);
typedef Boolean (*CloudCodeAXValueGetValueFn)(CFTypeRef, int, void *);

typedef UIImage *(*CloudCodeCreateScreenImageFn)(void);
typedef CFTypeRef CloudCodeIOSurfaceRef;
typedef CloudCodeIOSurfaceRef (*CloudCodeIOSurfaceCreateFn)(CFDictionaryRef);
typedef int32_t (*CloudCodeIOSurfaceLockFn)(CloudCodeIOSurfaceRef, uint32_t, uint32_t *);
typedef int32_t (*CloudCodeIOSurfaceUnlockFn)(CloudCodeIOSurfaceRef, uint32_t, uint32_t *);
typedef void *(*CloudCodeIOSurfaceGetBaseAddressFn)(CloudCodeIOSurfaceRef);
typedef size_t (*CloudCodeIOSurfaceGetBytesPerRowFn)(CloudCodeIOSurfaceRef);
typedef CGImageRef (*CloudCodeCreateCGImageFromIOSurfaceFn)(CFTypeRef);
typedef void (*CloudCodeRenderServerRenderDisplayFn)(uint32_t, CFStringRef, CloudCodeIOSurfaceRef, int, int);
typedef CFStringRef (*CloudCodeCopyFrontmostBundleIDFn)(void);
typedef CFStringRef (*CloudCodeCopyBundleIDForPidFn)(pid_t);
typedef CFTypeRef (*CloudCodeMGCopyAnswerFn)(CFStringRef);

typedef struct {
    void *handle;
    CloudCodeHIDClientCreateFn createClient;
    CloudCodeHIDDispatchFn dispatch;
    CloudCodeHIDConnectionDispatchFn dispatchConnection;
    CloudCodeBKSetDigitizerInfoFn setDigitizerInfo;
    CloudCodeDigitizerEventCreateFn createDigitizer;
    CloudCodeFingerEventCreateFn createFinger;
    CloudCodeUnicodeEventCreateFn createUnicode;
    CloudCodeHIDAppendFn append;
    CloudCodeHIDSetSenderFn setSender;
    CloudCodeHIDSetIntegerFn setInteger;
    CloudCodeHIDSetFloatFn setFloat;
} CloudCodeHIDRuntime;

typedef struct {
    CloudCodeIOHIDEventSystemClientRef systemClient;
    CloudCodeIOHIDEventSystemConnectionRef routedConnection;
    uint32_t contextID;
    mach_port_t taskPort;
    BOOL usesBackBoardRoute;
    BOOL usesBundleRoute;
} CloudCodeHIDRoute;

static NSString *CloudCodeFrontmostBundleID(void);

typedef struct {
    void *handle;
    CloudCodeAXCreateApplicationFn createApplication;
    CloudCodeAXCreateApplicationFn createAppElementWithPid;
    CloudCodeAXCreateSystemWideFn createSystemWide;
    CloudCodeAXGetPidFn getPid;
    CloudCodeAXCopyAttributeFn copyAttribute;
    CloudCodeAXSetAttributeFn setAttribute;
    CloudCodeAXCopyElementAtPositionFn copyElementAtPosition;
    CloudCodeAXCopyApplicationAtPositionFn copyApplicationAtPosition;
    CloudCodeAXCopyApplicationAndContextAtPositionFn copyApplicationAndContextAtPosition;
    CloudCodeAXSetTimeoutFn setTimeout;
    CloudCodeAXAddAssociatedPidFn addAssociatedPid;
    CloudCodeAXSetRequestingClientFn setRequestingClient;
    CloudCodeAXValueGetTypeIDFn valueGetTypeID;
    CloudCodeAXValueGetTypeFn valueGetType;
    CloudCodeAXValueGetValueFn valueGetValue;
    CFStringRef attributeChildren;
    CFStringRef attributeFrame;
    CFStringRef attributeLabel;
    CFStringRef attributeIdentifier;
    CFStringRef attributeValue;
    CFStringRef attributePlaceholder;
    CFStringRef attributeElementType;
} CloudCodeAXRuntime;

static void *CloudCodeOpenFramework(NSArray<NSString *> *paths)
{
    for (NSString *path in paths) {
        void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
        if (handle) { return handle; }
    }
    return NULL;
}

static void *CloudCodeResolve(void *handle, const char *name)
{
    void *symbol = handle ? dlsym(handle, name) : NULL;
    return symbol ?: dlsym(RTLD_DEFAULT, name);
}

static CFStringRef CloudCodeResolveCFString(void *handle, const char *name, CFStringRef fallback)
{
    void *symbol = CloudCodeResolve(handle, name);
    if (!symbol) { return fallback; }
    CFStringRef value = *(CFStringRef *)symbol;
    return value ?: fallback;
}

static void *CloudCodeResolveAcrossFrameworks(NSArray<NSString *> *paths, const char *name)
{
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) { return symbol; }
    for (NSString *path in paths) {
        void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) { continue; }
        symbol = dlsym(handle, name);
        if (symbol) { return symbol; }
    }
    return NULL;
}

static CFStringRef CloudCodeResolveCFStringAcrossFrameworks(NSArray<NSString *> *paths, const char *name, CFStringRef fallback)
{
    void *symbol = CloudCodeResolveAcrossFrameworks(paths, name);
    if (!symbol) { return fallback; }
    CFStringRef value = *(CFStringRef *)symbol;
    return value ?: fallback;
}

static CloudCodeHIDRuntime CloudCodeResolveHID(void)
{
    CloudCodeHIDRuntime runtime = {0};
    runtime.handle = CloudCodeOpenFramework(@[
        @"/System/Library/Frameworks/IOKit.framework/IOKit",
        @"/rootfs/System/Library/Frameworks/IOKit.framework/IOKit"
    ]);
    runtime.createClient = (CloudCodeHIDClientCreateFn)CloudCodeResolve(runtime.handle, "IOHIDEventSystemClientCreate");
    runtime.dispatch = (CloudCodeHIDDispatchFn)CloudCodeResolve(runtime.handle, "IOHIDEventSystemClientDispatchEvent");
    runtime.dispatchConnection = (CloudCodeHIDConnectionDispatchFn)CloudCodeResolve(runtime.handle, "IOHIDEventSystemConnectionDispatchEvent");
    void *backBoard = CloudCodeOpenFramework(@[
        @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        @"/rootfs/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices"
    ]);
    runtime.setDigitizerInfo = (CloudCodeBKSetDigitizerInfoFn)CloudCodeResolve(backBoard, "BKSHIDEventSetDigitizerInfo");
    runtime.createDigitizer = (CloudCodeDigitizerEventCreateFn)CloudCodeResolve(runtime.handle, "IOHIDEventCreateDigitizerEvent");
    runtime.createFinger = (CloudCodeFingerEventCreateFn)CloudCodeResolve(runtime.handle, "IOHIDEventCreateDigitizerFingerEvent");
    runtime.createUnicode = (CloudCodeUnicodeEventCreateFn)CloudCodeResolve(runtime.handle, "IOHIDEventCreateUnicodeEvent");
    if (!runtime.createUnicode) {
        runtime.createUnicode = (CloudCodeUnicodeEventCreateFn)CloudCodeResolve(runtime.handle, "_IOHIDEventCreateUnicodeEvent");
    }
    runtime.append = (CloudCodeHIDAppendFn)CloudCodeResolve(runtime.handle, "IOHIDEventAppendEvent");
    runtime.setSender = (CloudCodeHIDSetSenderFn)CloudCodeResolve(runtime.handle, "IOHIDEventSetSenderID");
    runtime.setInteger = (CloudCodeHIDSetIntegerFn)CloudCodeResolve(runtime.handle, "IOHIDEventSetIntegerValue");
    runtime.setFloat = (CloudCodeHIDSetFloatFn)CloudCodeResolve(runtime.handle, "IOHIDEventSetFloatValue");
    return runtime;
}

static BOOL CloudCodeResolveBackBoardRouteAtPoint(CGPoint point, CloudCodeHIDRuntime runtime, CloudCodeHIDRoute *route)
{
    if (!route || !runtime.dispatchConnection) { return NO; }
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW | RTLD_GLOBAL);

    id (*sendObject0)(id, SEL) = (void *)objc_msgSend;
    Class accessibilityClass = NSClassFromString(@"BKAccessibility");
    SEL managerSelector = NSSelectorFromString(@"_eventRoutingClientConnectionManager");
    if (!accessibilityClass || ![accessibilityClass respondsToSelector:managerSelector]) { return NO; }
    id manager = nil;
    @try { manager = sendObject0(accessibilityClass, managerSelector); } @catch (__unused NSException *exception) { manager = nil; }
    if (!manager) { return NO; }

    uint32_t contextID = 0;
    mach_port_t taskPort = MACH_PORT_NULL;
    Class serverClass = NSClassFromString(@"CAWindowServer");
    SEL serverSelector = NSSelectorFromString(@"serverIfRunning");
    if (serverClass && [serverClass respondsToSelector:serverSelector]) {
        id server = nil;
        @try { server = sendObject0(serverClass, serverSelector); } @catch (__unused NSException *exception) { server = nil; }
        if (server && [server respondsToSelector:NSSelectorFromString(@"displays")]) {
            NSArray *displays = nil;
            @try { displays = sendObject0(server, NSSelectorFromString(@"displays")); } @catch (__unused NSException *exception) { displays = nil; }
            id display = ([displays isKindOfClass:NSArray.class] && displays.count > 0) ? displays.firstObject : nil;
            SEL contextSelector = NSSelectorFromString(@"contextIdAtPosition:");
            SEL taskPortSelector = NSSelectorFromString(@"taskPortOfContextId:");
            if (display && [display respondsToSelector:contextSelector]) {
                uint32_t (*sendContext)(id, SEL, CGPoint) = (void *)objc_msgSend;
                @try { contextID = sendContext(display, contextSelector, point); } @catch (__unused NSException *exception) { contextID = 0; }
                if (contextID > 0 && [display respondsToSelector:taskPortSelector]) {
                    mach_port_t (*sendTaskPort)(id, SEL, uint32_t) = (void *)objc_msgSend;
                    @try { taskPort = sendTaskPort(display, taskPortSelector, contextID); } @catch (__unused NSException *exception) { taskPort = MACH_PORT_NULL; }
                }
            }
        }
    }

    NSString *bundleID = CloudCodeFrontmostBundleID();
    SEL bundleSelector = NSSelectorFromString(@"clientForBundleID:");
    if (bundleID.length > 0 && [manager respondsToSelector:bundleSelector]) {
        CloudCodeIOHIDEventSystemConnectionRef (*sendConnectionForBundle)(id, SEL, id) = (void *)objc_msgSend;
        CloudCodeIOHIDEventSystemConnectionRef connection = NULL;
        @try { connection = sendConnectionForBundle(manager, bundleSelector, bundleID); } @catch (__unused NSException *exception) { connection = NULL; }
        if (connection) {
            route->routedConnection = connection;
            route->contextID = contextID;
            route->taskPort = taskPort;
            route->usesBackBoardRoute = YES;
            route->usesBundleRoute = YES;
            fprintf(stderr, "gui-hid-route: profile=modern-trollstore route=backboard-bundle bundle=%s contextID=%u taskPort=%u\n", bundleID.UTF8String ?: "", contextID, taskPort);
            return YES;
        }
    }

    SEL connectionSelector = NSSelectorFromString(@"clientForTaskPort:");
    if (MACH_PORT_VALID(taskPort) && [manager respondsToSelector:connectionSelector]) {
        CloudCodeIOHIDEventSystemConnectionRef (*sendConnectionForPort)(id, SEL, mach_port_t) = (void *)objc_msgSend;
        CloudCodeIOHIDEventSystemConnectionRef connection = NULL;
        @try { connection = sendConnectionForPort(manager, connectionSelector, taskPort); } @catch (__unused NSException *exception) { connection = NULL; }
        if (connection) {
            route->routedConnection = connection;
            route->contextID = contextID;
            route->taskPort = taskPort;
            route->usesBackBoardRoute = YES;
            route->usesBundleRoute = NO;
            fprintf(stderr, "gui-hid-route: profile=modern-trollstore route=backboard-context bundle=%s contextID=%u taskPort=%u\n", bundleID.UTF8String ?: "", contextID, taskPort);
            return YES;
        }
    }

    fprintf(stderr, "gui-hid-route: profile=modern-trollstore route=backboard-unavailable bundle=%s contextID=%u taskPort=%u\n", bundleID.UTF8String ?: "", contextID, taskPort);
    return NO;
}

static BOOL CloudCodeHIDReady(CloudCodeHIDRuntime runtime, CGPoint point, CloudCodeHIDRoute *route)
{
    if (!route || !runtime.createDigitizer || !runtime.createFinger || !runtime.append || !runtime.setInteger || !runtime.setFloat) {
        return NO;
    }
    *route = (CloudCodeHIDRoute){0};
    // Current TrollVNC uses the global IOHID event-system client with sender 0x8000000817319371.
    // Prefer that route first for TrollStore/root-helper injection. BackBoard targeted routing is
    // retained only as a compatibility fallback when a system client cannot be created.
    if (runtime.createClient && runtime.dispatch) {
        route->systemClient = runtime.createClient(kCFAllocatorDefault);
        if (route->systemClient) {
            fprintf(stderr, "gui-hid-route: profile=modern-trollstore route=system-client\n");
            return YES;
        }
    }
    return CloudCodeResolveBackBoardRouteAtPoint(point, runtime, route);
}

static void CloudCodeReleaseHIDRoute(CloudCodeHIDRoute *route)
{
    if (!route) { return; }
    if (route->systemClient) { CFRelease(route->systemClient); }
    *route = (CloudCodeHIDRoute){0};
}

static CGSize CloudCodeScreenSize(void)
{
    @try {
        CGRect bounds = UIScreen.mainScreen.bounds;
        if (bounds.size.width > 1 && bounds.size.height > 1) { return bounds.size; }
    } @catch (__unused NSException *exception) {
    }

    // A standalone TrollStore/root helper can have no UIApplication scene, in which case
    // UIScreen may not expose a usable logical coordinate space. Fall back to MobileGestalt's
    // physical dimensions divided by display scale. This remains read-only and dynamically
    // resolved so unsupported runtimes simply fail closed.
    void *handle = CloudCodeOpenFramework(@[
        @"/usr/lib/libMobileGestalt.dylib",
        @"/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt",
        @"/rootfs/usr/lib/libMobileGestalt.dylib"
    ]);
    CloudCodeMGCopyAnswerFn copyAnswer = (CloudCodeMGCopyAnswerFn)CloudCodeResolve(handle, "MGCopyAnswer");
    if (!copyAnswer) { return CGSizeZero; }
    CFTypeRef widthValue = copyAnswer(CFSTR("main-screen-width"));
    CFTypeRef heightValue = copyAnswer(CFSTR("main-screen-height"));
    CFTypeRef scaleValue = copyAnswer(CFSTR("main-screen-scale"));
    double width = 0, height = 0, scale = 0;
    if (widthValue && CFGetTypeID(widthValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)widthValue, kCFNumberDoubleType, &width);
    }
    if (heightValue && CFGetTypeID(heightValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)heightValue, kCFNumberDoubleType, &height);
    }
    if (scaleValue && CFGetTypeID(scaleValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)scaleValue, kCFNumberDoubleType, &scale);
    }
    if (widthValue) { CFRelease(widthValue); }
    if (heightValue) { CFRelease(heightValue); }
    if (scaleValue) { CFRelease(scaleValue); }
    if (width > 1 && height > 1 && scale >= 1 && isfinite(width) && isfinite(height) && isfinite(scale)) {
        return CGSizeMake(width / scale, height / scale);
    }
    return CGSizeZero;
}

static BOOL CloudCodeValidPoint(double x, double y, CGSize size)
{
    return isfinite(x) && isfinite(y) && size.width > 1 && size.height > 1 && x >= 0 && y >= 0 && x <= size.width && y <= size.height;
}

static CloudCodeIOHIDEventRef CloudCodeCreateTouchParent(CloudCodeHIDRuntime runtime, double x, double y, uint32_t phaseMask, BOOL range, BOOL touching)
{
    CGSize size = CloudCodeScreenSize();
    if (!CloudCodeValidPoint(x, y, size)) { return NULL; }
    double nx = x / size.width;
    double ny = y / size.height;

    // Match the modern iOS hand/finger shape used by current WebKit test injection and current
    // TrollStore remote-control implementations: collection index/identity 0/0, one finger 2/2,
    // Touch|Identity for contact transitions and Position|Attribute while moving. The older
    // SpringBoard-tweak 1<<22 / 3,2 profile produced valid-looking packets on this device but the
    // foreground app ignored them.
    uint32_t eventMask = phaseMask;
    if ((phaseMask & CLOUDCODE_HID_DIGITIZER_POSITION) != 0 && touching) {
        eventMask = CLOUDCODE_HID_DIGITIZER_POSITION | CLOUDCODE_HID_DIGITIZER_ATTRIBUTE;
    } else {
        eventMask = CLOUDCODE_HID_DIGITIZER_TOUCH | CLOUDCODE_HID_DIGITIZER_IDENTITY;
    }

    CloudCodeIOHIDEventRef parent = runtime.createDigitizer(
        kCFAllocatorDefault, mach_absolute_time(), 3,
        CLOUDCODE_GUI_PARENT_INDEX, CLOUDCODE_GUI_PARENT_IDENTITY, eventMask, 0,
        0, 0, 0, 0, 0,
        NO, touching, 0
    );
    if (!parent) { return NULL; }

    CloudCodeIOHIDEventRef child = runtime.createFinger(
        kCFAllocatorDefault, mach_absolute_time(),
        CLOUDCODE_GUI_FINGER_INDEX, CLOUDCODE_GUI_FINGER_IDENTITY, eventMask,
        nx, ny, 0, 0, 90.0, range && touching, touching, 0
    );
    if (!child) {
        CFRelease(parent);
        return NULL;
    }
    runtime.setFloat(child, 0xB0014, 5.0);
    runtime.setFloat(child, 0xB0015, 5.0);
    runtime.append(parent, child, 0);
    CFRelease(child);

    runtime.setInteger(parent, 0x4, 1);
    runtime.setInteger(parent, 0xB0019, 1);
    return parent;
}

static BOOL CloudCodeDispatchTouch(CloudCodeHIDRuntime runtime, CloudCodeHIDRoute route, double x, double y, uint32_t mask, BOOL range, BOOL touching)
{
    CloudCodeIOHIDEventRef event = CloudCodeCreateTouchParent(runtime, x, y, mask, range, touching);
    if (!event) { return NO; }
    if (route.contextID > 0 && runtime.setDigitizerInfo) {
        runtime.setDigitizerInfo(event, route.contextID, 0, 0, NULL, 0, 0);
    }
    if (route.usesBackBoardRoute && route.routedConnection && runtime.dispatchConnection) {
        runtime.dispatchConnection(route.routedConnection, event);
    } else if (route.systemClient && runtime.dispatch) {
        if (runtime.setSender) { runtime.setSender(event, CLOUDCODE_GUI_SENDER_ID); }
        runtime.dispatch(route.systemClient, event);
    } else {
        CFRelease(event);
        return NO;
    }
    CFRelease(event);
    return YES;
}

static BOOL CloudCodePerformTap(double x, double y)
{
    CloudCodeHIDRuntime runtime = CloudCodeResolveHID();
    CloudCodeHIDRoute route = {0};
    if (!CloudCodeHIDReady(runtime, CGPointMake(x, y), &route)) { return NO; }
    CGSize size = CloudCodeScreenSize();
    double nx = size.width > 1 ? x / size.width : 0;
    double ny = size.height > 1 ? y / size.height : 0;
    BOOL ok = CloudCodeDispatchTouch(runtime, route, x, y, CLOUDCODE_HID_DIGITIZER_RANGE | CLOUDCODE_HID_DIGITIZER_TOUCH, YES, YES);
    if (ok) { usleep(50000); ok = CloudCodeDispatchTouch(runtime, route, x, y, CLOUDCODE_HID_DIGITIZER_RANGE | CLOUDCODE_HID_DIGITIZER_TOUCH, NO, NO); }
    if (ok) {
        // The helper is intentionally short-lived. Keep the selected HID route alive briefly after
        // the final lift packet so the last BackBoard/Mach delivery cannot be torn down with the process.
        usleep(100000);
        fprintf(stderr, "gui-hid: profile=modern-trollstore result=dispatched-unverified route=%s contextID=%u taskPort=%u screen=%.0fx%.0f point=(%.2f,%.2f) normalized=(%.5f,%.5f) parentIndex=%u fingerIndex=%u fingerIdentity=%u sender=0x%llx\n",
                route.usesBackBoardRoute ? (route.usesBundleRoute ? "backboard-bundle" : "backboard-context") : "system-client",
                route.contextID, route.taskPort,
                size.width, size.height, x, y, nx, ny,
                CLOUDCODE_GUI_PARENT_INDEX, CLOUDCODE_GUI_FINGER_INDEX, CLOUDCODE_GUI_FINGER_IDENTITY,
                (unsigned long long)CLOUDCODE_GUI_SENDER_ID);
    }
    CloudCodeReleaseHIDRoute(&route);
    return ok;
}

static BOOL CloudCodePerformSwipe(double fromX, double fromY, double toX, double toY, double durationSeconds)
{
    CGSize size = CloudCodeScreenSize();
    if (!CloudCodeValidPoint(fromX, fromY, size) || !CloudCodeValidPoint(toX, toY, size) || !isfinite(durationSeconds) || durationSeconds < 0.05 || durationSeconds > 5.0) { return NO; }
    CloudCodeHIDRuntime runtime = CloudCodeResolveHID();
    CloudCodeHIDRoute route = {0};
    if (!CloudCodeHIDReady(runtime, CGPointMake(fromX, fromY), &route)) { return NO; }
    const int steps = 20;
    useconds_t delay = (useconds_t)((durationSeconds * 1000000.0) / steps);
    BOOL ok = CloudCodeDispatchTouch(runtime, route, fromX, fromY, CLOUDCODE_HID_DIGITIZER_RANGE | CLOUDCODE_HID_DIGITIZER_TOUCH, YES, YES);
    for (int index = 1; ok && index <= steps; index++) {
        usleep(delay);
        double t = (double)index / (double)steps;
        double x = fromX + (toX - fromX) * t;
        double y = fromY + (toY - fromY) * t;
        ok = CloudCodeDispatchTouch(runtime, route, x, y, CLOUDCODE_HID_DIGITIZER_POSITION, YES, YES);
    }
    if (ok) {
        usleep(10000);
        ok = CloudCodeDispatchTouch(runtime, route, toX, toY, CLOUDCODE_HID_DIGITIZER_RANGE | CLOUDCODE_HID_DIGITIZER_TOUCH, NO, NO);
    }
    if (ok) {
        usleep(100000);
        fprintf(stderr, "gui-hid: profile=modern-trollstore result=dispatched-unverified route=%s contextID=%u taskPort=%u screen=%.0fx%.0f from=(%.2f,%.2f) to=(%.2f,%.2f) normalizedFrom=(%.5f,%.5f) normalizedTo=(%.5f,%.5f) duration=%.3f steps=%d parentIndex=%u fingerIndex=%u fingerIdentity=%u sender=0x%llx\n",
                route.usesBackBoardRoute ? (route.usesBundleRoute ? "backboard-bundle" : "backboard-context") : "system-client",
                route.contextID, route.taskPort,
                size.width, size.height, fromX, fromY, toX, toY,
                fromX / size.width, fromY / size.height, toX / size.width, toY / size.height,
                durationSeconds, steps,
                CLOUDCODE_GUI_PARENT_INDEX, CLOUDCODE_GUI_FINGER_INDEX, CLOUDCODE_GUI_FINGER_IDENTITY,
                (unsigned long long)CLOUDCODE_GUI_SENDER_ID);
    }
    CloudCodeReleaseHIDRoute(&route);
    return ok;
}

static CGSize CloudCodeScreenPixelSize(void)
{
    @try {
        CGRect nativeBounds = UIScreen.mainScreen.nativeBounds;
        if (nativeBounds.size.width > 1 && nativeBounds.size.height > 1) { return nativeBounds.size; }
        CGRect bounds = UIScreen.mainScreen.bounds;
        CGFloat scale = UIScreen.mainScreen.scale;
        if (bounds.size.width > 1 && bounds.size.height > 1 && scale >= 1) {
            return CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
        }
    } @catch (__unused NSException *exception) {
    }

    // A detached root helper often has no UIApplication scene, so UIScreen can be empty even
    // though the physical display is active. Use the same MobileGestalt source as the logical
    // coordinate fallback, but keep the native pixel dimensions here for IOSurface allocation.
    void *handle = CloudCodeOpenFramework(@[
        @"/usr/lib/libMobileGestalt.dylib",
        @"/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt",
        @"/rootfs/usr/lib/libMobileGestalt.dylib"
    ]);
    CloudCodeMGCopyAnswerFn copyAnswer = (CloudCodeMGCopyAnswerFn)CloudCodeResolve(handle, "MGCopyAnswer");
    if (!copyAnswer) { return CGSizeZero; }
    CFTypeRef widthValue = copyAnswer(CFSTR("main-screen-width"));
    CFTypeRef heightValue = copyAnswer(CFSTR("main-screen-height"));
    double width = 0, height = 0;
    if (widthValue && CFGetTypeID(widthValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)widthValue, kCFNumberDoubleType, &width);
    }
    if (heightValue && CFGetTypeID(heightValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)heightValue, kCFNumberDoubleType, &height);
    }
    if (widthValue) { CFRelease(widthValue); }
    if (heightValue) { CFRelease(heightValue); }
    if (width > 1 && height > 1 && width <= 8192 && height <= 8192 && isfinite(width) && isfinite(height)) {
        return CGSizeMake(width, height);
    }
    return CGSizeZero;
}

static UIImage *CloudCodeScreenshotImageFromRenderServer(void)
{
    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
    void *ioSurface = CloudCodeOpenFramework(@[
        @"/System/Library/Frameworks/IOSurface.framework/IOSurface",
        @"/rootfs/System/Library/Frameworks/IOSurface.framework/IOSurface"
    ]);
    CloudCodeRenderServerRenderDisplayFn render = (CloudCodeRenderServerRenderDisplayFn)CloudCodeResolve(quartzCore, "CARenderServerRenderDisplay");
    CloudCodeIOSurfaceCreateFn createSurface = (CloudCodeIOSurfaceCreateFn)CloudCodeResolve(ioSurface, "IOSurfaceCreate");
    CloudCodeIOSurfaceLockFn lockSurface = (CloudCodeIOSurfaceLockFn)CloudCodeResolve(ioSurface, "IOSurfaceLock");
    CloudCodeIOSurfaceUnlockFn unlockSurface = (CloudCodeIOSurfaceUnlockFn)CloudCodeResolve(ioSurface, "IOSurfaceUnlock");
    CloudCodeIOSurfaceGetBaseAddressFn getBaseAddress = (CloudCodeIOSurfaceGetBaseAddressFn)CloudCodeResolve(ioSurface, "IOSurfaceGetBaseAddress");
    CloudCodeIOSurfaceGetBytesPerRowFn getBytesPerRow = (CloudCodeIOSurfaceGetBytesPerRowFn)CloudCodeResolve(ioSurface, "IOSurfaceGetBytesPerRow");
    CGSize pixels = CloudCodeScreenPixelSize();
    if (!render || !createSurface || !lockSurface || !unlockSurface || !getBaseAddress || !getBytesPerRow || pixels.width <= 1 || pixels.height <= 1) {
        fprintf(stderr, "gui-screenshot/render-server: prerequisites unavailable render=%d create=%d lock=%d unlock=%d base=%d row=%d pixels=%.0fx%.0f\n", !!render, !!createSurface, !!lockSurface, !!unlockSurface, !!getBaseAddress, !!getBytesPerRow, pixels.width, pixels.height);
        return nil;
    }

    size_t width = (size_t)llround(pixels.width);
    size_t height = (size_t)llround(pixels.height);
    if (width == 0 || height == 0 || width > 8192 || height > 8192) { return nil; }
    size_t bytesPerRow = width * 4;
    size_t allocationSize = bytesPerRow * height;
    if (allocationSize == 0 || allocationSize > 256 * 1024 * 1024) { return nil; }

    NSDictionary *properties = @{
        @"IOSurfaceWidth": @(width),
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfaceBytesPerRow": @(bytesPerRow),
        @"IOSurfaceAllocSize": @(allocationSize),
        @"IOSurfacePixelFormat": @(0x42475241),
        @"IOSurfaceIsGlobal": @YES
    };
    CloudCodeIOSurfaceRef surface = createSurface((__bridge CFDictionaryRef)properties);
    if (!surface) {
        fprintf(stderr, "gui-screenshot/render-server: IOSurfaceCreate returned null for %zux%zu\n", width, height);
        return nil;
    }

    UIImage *detached = nil;
    int32_t lockCode = lockSurface(surface, 0, NULL);
    if (lockCode == 0) {
        @try { render(0, CFSTR("LCD"), surface, 0, 0); } @catch (__unused NSException *exception) {}
        void *baseAddress = getBaseAddress(surface);
        size_t surfaceBytesPerRow = getBytesPerRow(surface);
        if (baseAddress && surfaceBytesPerRow >= width * 4) {
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, baseAddress, surfaceBytesPerRow * height, NULL);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGImageRef cgImage = provider && colorSpace ? CGImageCreate(
                width, height, 8, 32, surfaceBytesPerRow, colorSpace,
                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                provider, NULL, true, kCGRenderingIntentDefault
            ) : NULL;
            if (cgImage) {
                UIImage *surfaceImage = [UIImage imageWithCGImage:cgImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
                if (surfaceImage) {
                    UIGraphicsBeginImageContextWithOptions(surfaceImage.size, YES, 1.0);
                    [surfaceImage drawAtPoint:CGPointZero];
                    detached = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                }
                CGImageRelease(cgImage);
            }
            if (colorSpace) { CGColorSpaceRelease(colorSpace); }
            if (provider) { CGDataProviderRelease(provider); }
        }
        unlockSurface(surface, 0, NULL);
    } else {
        fprintf(stderr, "gui-screenshot/render-server: IOSurfaceLock failed code=%d\n", lockCode);
    }
    CFRelease(surface);
    if (!detached) { fprintf(stderr, "gui-screenshot/render-server: render completed without a readable detached image\n"); }
    return detached;
}

static UIImage *CloudCodeScreenshotImageFromIOSurface(void)
{
    SEL selector = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:selector]) {
        fprintf(stderr, "gui-screenshot/uiwindow-iosurface: createScreenIOSurface selector unavailable\n");
        return nil;
    }
    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_LOCAL);
    CloudCodeCreateCGImageFromIOSurfaceFn createCGImage = (CloudCodeCreateCGImageFromIOSurfaceFn)CloudCodeResolve(uikit, "UICreateCGImageFromIOSurface");
    if (!createCGImage) {
        fprintf(stderr, "gui-screenshot/uiwindow-iosurface: UICreateCGImageFromIOSurface symbol unavailable\n");
        return nil;
    }
    id surfaceObject = nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        surfaceObject = [UIWindow performSelector:selector];
#pragma clang diagnostic pop
    } @catch (__unused NSException *exception) {
        surfaceObject = nil;
    }
    if (!surfaceObject) {
        fprintf(stderr, "gui-screenshot/uiwindow-iosurface: createScreenIOSurface returned null\n");
        return nil;
    }
    CGImageRef cgImage = NULL;
    @try { cgImage = createCGImage((__bridge CFTypeRef)surfaceObject); } @catch (__unused NSException *exception) { cgImage = NULL; }
    if (!cgImage) {
        fprintf(stderr, "gui-screenshot/uiwindow-iosurface: IOSurface could not be converted to CGImage\n");
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static UIImage *CloudCodePointSizedScreenshot(UIImage *image)
{
    if (!image) { return nil; }
    CGSize screen = CloudCodeScreenSize();
    if (screen.width <= 1 || screen.height <= 1) { return image; }
    BOOL imageLandscape = image.size.width > image.size.height;
    BOOL screenLandscape = screen.width > screen.height;
    CGSize target = imageLandscape == screenLandscape ? screen : CGSizeMake(screen.height, screen.width);
    if (target.width <= 1 || target.height <= 1) { return image; }
    if (image.size.width <= target.width * 1.05 && image.size.height <= target.height * 1.05) { return image; }
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaled ?: image;
}

static BOOL CloudCodeScreenshotLooksInformative(UIImage *image)
{
    CGImageRef source = image.CGImage;
    if (!source) { return NO; }
    const size_t sampleWidth = 20;
    const size_t sampleHeight = 20;
    uint8_t pixels[sampleWidth * sampleHeight];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = colorSpace ? CGBitmapContextCreate(
        pixels, sampleWidth, sampleHeight, 8, sampleWidth, colorSpace,
        (CGBitmapInfo)kCGImageAlphaNone
    ) : NULL;
    if (colorSpace) { CGColorSpaceRelease(colorSpace); }
    if (!context) { return NO; }
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, sampleWidth, sampleHeight), source);
    CGContextRelease(context);

    uint8_t minimum = 255;
    uint8_t maximum = 0;
    double sum = 0;
    double sumSquares = 0;
    for (size_t index = 0; index < sampleWidth * sampleHeight; index++) {
        uint8_t value = pixels[index];
        minimum = MIN(minimum, value);
        maximum = MAX(maximum, value);
        sum += value;
        sumSquares += (double)value * (double)value;
    }
    const double count = (double)(sampleWidth * sampleHeight);
    const double mean = sum / count;
    const double variance = MAX(0.0, (sumSquares / count) - (mean * mean));
    const int spread = (int)maximum - (int)minimum;

    // A real fullscreen App may be dark, but even a dark video normally contains text/icons and
    // therefore measurable luminance structure. Reject only near-uniform frames; this catches the
    // repeated black IOSurface false-success observed on device without rejecting ordinary dark UI.
    BOOL informative = spread >= 4 || variance >= 1.5;
    if (!informative) {
        fprintf(stderr, "gui-screenshot: rejected low-information frame mean=%.2f variance=%.3f spread=%d min=%u max=%u\n",
                mean, variance, spread, minimum, maximum);
    }
    return informative;
}

static NSData *CloudCodeBoundedScreenshotJPEG(UIImage *image)
{
    image = CloudCodePointSizedScreenshot(image);
    if (!image || !CloudCodeScreenshotLooksInformative(image)) { return nil; }
    const CGFloat qualities[] = {0.55, 0.45, 0.36, 0.28, 0.20};
    for (NSUInteger index = 0; index < sizeof(qualities) / sizeof(qualities[0]); index++) {
        NSData *data = UIImageJPEGRepresentation(image, qualities[index]);
        if (data.length > 0 && data.length <= CLOUDCODE_GUI_MAX_SCREENSHOT_BYTES) { return data; }
    }
    return nil;
}

static NSData *CloudCodeScreenshotJPEG(void)
{
    UIImage *image = CloudCodeScreenshotImageFromRenderServer();
    if (image) {
        NSData *data = CloudCodeBoundedScreenshotJPEG(image);
        if (data) { return data; }
        fprintf(stderr, "gui-screenshot/render-server: captured image could not satisfy bounded JPEG limit\n");
    }

    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_LOCAL);
    CloudCodeCreateScreenImageFn createImage = (CloudCodeCreateScreenImageFn)CloudCodeResolve(uikit, "_UICreateScreenUIImage");
    if (createImage) {
        @try { image = createImage(); } @catch (__unused NSException *exception) { image = nil; }
        if (image) {
            NSData *data = CloudCodeBoundedScreenshotJPEG(image);
            if (data) { return data; }
            fprintf(stderr, "gui-screenshot/uicreate: captured image could not satisfy bounded JPEG limit\n");
        } else {
            fprintf(stderr, "gui-screenshot/uicreate: _UICreateScreenUIImage returned null\n");
        }
    } else {
        fprintf(stderr, "gui-screenshot/uicreate: _UICreateScreenUIImage symbol unavailable\n");
    }

    image = CloudCodeScreenshotImageFromIOSurface();
    NSData *data = CloudCodeBoundedScreenshotJPEG(image);
    if (image && !data) { fprintf(stderr, "gui-screenshot/uiwindow-iosurface: captured image could not satisfy bounded JPEG limit\n"); }
    return data;
}

static void *CloudCodeOpenSpringBoardServices(void)
{
    return CloudCodeOpenFramework(@[
        @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        @"/rootfs/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
    ]);
}

static NSString *CloudCodeFrontmostBundleID(void)
{
    void *handle = CloudCodeOpenSpringBoardServices();
    CloudCodeCopyFrontmostBundleIDFn copyBundleID = (CloudCodeCopyFrontmostBundleIDFn)CloudCodeResolve(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    if (!copyBundleID) { return nil; }
    CFStringRef value = NULL;
    @try {
        value = copyBundleID();
    } @catch (__unused NSException *exception) {
        value = NULL;
    }
    if (!value) { return nil; }
    NSString *bundleID = [(__bridge NSString *)value copy];
    CFRelease(value);
    return bundleID.length > 0 ? bundleID : nil;
}

static NSString *CloudCodeBundleIDForPID(pid_t pid)
{
    if (pid <= 0) { return nil; }
    void *handle = CloudCodeOpenSpringBoardServices();
    CloudCodeCopyBundleIDForPidFn copyBundleID = (CloudCodeCopyBundleIDForPidFn)CloudCodeResolve(handle, "SBSCopyDisplayIdentifierForProcessID");
    if (!copyBundleID) { return nil; }
    CFStringRef value = NULL;
    @try {
        value = copyBundleID(pid);
    } @catch (__unused NSException *exception) {
        value = NULL;
    }
    if (!value) { return nil; }
    NSString *bundleID = [(__bridge NSString *)value copy];
    CFRelease(value);
    return bundleID.length > 0 ? bundleID : nil;
}

static NSString *CloudCodeBundlePathForIdentifier(NSString *bundleID)
{
    if (bundleID.length == 0) { return nil; }
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) { return nil; }
    id (*sendObject)(id, SEL, id) = (void *)objc_msgSend;
    id proxy = nil;
    @try {
        proxy = sendObject(proxyClass, selector, bundleID);
    } @catch (__unused NSException *exception) {
        proxy = nil;
    }
    NSURL *bundleURL = nil;
    @try {
        if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
            bundleURL = [proxy valueForKey:@"bundleURL"];
        }
    } @catch (__unused NSException *exception) {
        bundleURL = nil;
    }
    return [bundleURL isKindOfClass:NSURL.class] ? bundleURL.path.stringByStandardizingPath : nil;
}

static pid_t CloudCodePIDForBundlePath(NSString *bundlePath)
{
    if (bundlePath.length == 0) { return 0; }
    CloudCodeProcListAllPidsFn listPids = (CloudCodeProcListAllPidsFn)dlsym(RTLD_DEFAULT, "proc_listallpids");
    CloudCodeProcPidPathFn pidPath = (CloudCodeProcPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (!listPids || !pidPath) { return 0; }
    pid_t pids[4096] = {0};
    int count = listPids(pids, sizeof(pids));
    NSString *prefix = [bundlePath stringByAppendingString:@"/"];
    for (int index = 0; index < count && index < 4096; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) { continue; }
        char buffer[4096] = {0};
        if (pidPath(pid, buffer, sizeof(buffer)) <= 0) { continue; }
        NSString *path = [NSString stringWithUTF8String:buffer];
        if ([path hasPrefix:prefix]) { return pid; }
    }
    return 0;
}

static CloudCodeAXRuntime CloudCodeResolveAX(void)
{
    CloudCodeAXRuntime runtime = {0};
    NSArray<NSString *> *paths = @[
        @"/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        @"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        @"/System/Library/Frameworks/Accessibility.framework/Accessibility",
        @"/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        @"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        @"/System/Library/Frameworks/HIServices.framework/HIServices",
        @"/usr/lib/libAccessibility.dylib",
        @"/rootfs/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        @"/rootfs/System/Library/Frameworks/Accessibility.framework/Accessibility",
        @"/rootfs/usr/lib/libAccessibility.dylib"
    ];
    runtime.handle = CloudCodeOpenFramework(paths);
    runtime.createApplication = (CloudCodeAXCreateApplicationFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCreateApplication");
    runtime.createAppElementWithPid = (CloudCodeAXCreateApplicationFn)CloudCodeResolveAcrossFrameworks(paths, "_AXUIElementCreateAppElementWithPid");
    runtime.createSystemWide = (CloudCodeAXCreateSystemWideFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCreateSystemWide");
    runtime.getPid = (CloudCodeAXGetPidFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementGetPid");
    if (!runtime.getPid) {
        runtime.getPid = (CloudCodeAXGetPidFn)CloudCodeResolveAcrossFrameworks(paths, "_AXUIElementGetPid");
    }
    runtime.copyAttribute = (CloudCodeAXCopyAttributeFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCopyAttributeValue");
    runtime.setAttribute = (CloudCodeAXSetAttributeFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementSetAttributeValue");
    runtime.copyElementAtPosition = (CloudCodeAXCopyElementAtPositionFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCopyElementAtPosition");
    runtime.copyApplicationAtPosition = (CloudCodeAXCopyApplicationAtPositionFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCopyApplicationAtPosition");
    runtime.copyApplicationAndContextAtPosition = (CloudCodeAXCopyApplicationAndContextAtPositionFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementCopyApplicationAndContextAtPosition");
    runtime.setTimeout = (CloudCodeAXSetTimeoutFn)CloudCodeResolveAcrossFrameworks(paths, "AXUIElementSetMessagingTimeout");
    runtime.addAssociatedPid = (CloudCodeAXAddAssociatedPidFn)CloudCodeResolveAcrossFrameworks(paths, "_AXAddAssociatedPid");
    if (!runtime.addAssociatedPid) {
        runtime.addAssociatedPid = (CloudCodeAXAddAssociatedPidFn)CloudCodeResolveAcrossFrameworks(paths, "AXAddAssociatedPid");
    }
    runtime.setRequestingClient = (CloudCodeAXSetRequestingClientFn)CloudCodeResolveAcrossFrameworks(paths, "__AXSetRequestingClient");
    runtime.valueGetTypeID = (CloudCodeAXValueGetTypeIDFn)CloudCodeResolveAcrossFrameworks(paths, "AXValueGetTypeID");
    runtime.valueGetType = (CloudCodeAXValueGetTypeFn)CloudCodeResolveAcrossFrameworks(paths, "AXValueGetType");
    runtime.valueGetValue = (CloudCodeAXValueGetValueFn)CloudCodeResolveAcrossFrameworks(paths, "AXValueGetValue");
    runtime.attributeChildren = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeChildren", CFSTR("AXChildren"));
    runtime.attributeFrame = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeFrame", CFSTR("AXFrame"));
    runtime.attributeLabel = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeLabel", CFSTR("AXLabel"));
    runtime.attributeIdentifier = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeIdentifier", CFSTR("AXIdentifier"));
    runtime.attributeValue = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeValue", CFSTR("AXValue"));
    runtime.attributePlaceholder = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributePlaceholderValue", CFSTR("AXPlaceholderValue"));
    runtime.attributeElementType = CloudCodeResolveCFStringAcrossFrameworks(paths, "kAXXCAttributeElementType", CFSTR("AXRole"));
    return runtime;
}

static NSString *CloudCodeBoundedString(id value)
{
    if (!value || value == NSNull.null) { return nil; }
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) {
        text = value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        text = [value stringValue];
    } else {
        @try { text = [value description]; } @catch (__unused NSException *exception) { text = nil; }
    }
    if (text.length > 256) { text = [[text substringToIndex:256] stringByAppendingString:@"…"]; }
    return text.length > 0 ? text : nil;
}

static id CloudCodeAXCopy(CloudCodeAXRuntime runtime, CloudCodeAXUIElementRef element, CFStringRef attribute)
{
    if (!runtime.copyAttribute || !element || !attribute) { return nil; }
    CFTypeRef value = NULL;
    CloudCodeAXError code = -1;
    @try {
        code = runtime.copyAttribute(element, attribute, &value);
    } @catch (__unused NSException *exception) {
        value = NULL;
    }
    if (code != 0 || !value) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

static NSDictionary *CloudCodeFrameDictionary(CloudCodeAXRuntime runtime, id value)
{
    if (!value) { return nil; }
    CGRect frame = CGRectZero;
    BOOL ok = NO;
    if ([value isKindOfClass:NSValue.class]) {
        @try { frame = [value CGRectValue]; ok = YES; } @catch (__unused NSException *exception) { ok = NO; }
    }
    if (!ok && runtime.valueGetType && runtime.valueGetValue) {
        CFTypeRef ref = (__bridge CFTypeRef)value;
        @try {
            if (!runtime.valueGetTypeID || CFGetTypeID(ref) == runtime.valueGetTypeID()) {
                int type = runtime.valueGetType(ref);
                if (type == 3) { ok = runtime.valueGetValue(ref, 3, &frame); }
            }
        } @catch (__unused NSException *exception) { ok = NO; }
    }
    if (!ok || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) { return nil; }
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

static NSDictionary *CloudCodeAXNode(CloudCodeAXRuntime runtime, CloudCodeAXUIElementRef element, NSUInteger depth, NSUInteger *nodeCount)
{
    if (!element || depth > 20 || !nodeCount || *nodeCount >= CLOUDCODE_GUI_MAX_TREE_NODES) { return nil; }
    (*nodeCount)++;
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    NSArray<NSDictionary *> *attributes = @[
        @{@"key": @"role", @"attribute": (__bridge id)(runtime.attributeElementType ?: CFSTR("AXRole"))},
        @{@"key": @"label", @"attribute": (__bridge id)(runtime.attributeLabel ?: CFSTR("AXLabel"))},
        @{@"key": @"value", @"attribute": (__bridge id)(runtime.attributeValue ?: CFSTR("AXValue"))},
        @{@"key": @"title", @"attribute": @"AXTitle"},
        @{@"key": @"identifier", @"attribute": (__bridge id)(runtime.attributeIdentifier ?: CFSTR("AXIdentifier"))},
        @{@"key": @"placeholder", @"attribute": (__bridge id)(runtime.attributePlaceholder ?: CFSTR("AXPlaceholderValue"))}
    ];
    for (NSDictionary *pair in attributes) {
        id raw = CloudCodeAXCopy(runtime, element, (__bridge CFStringRef)pair[@"attribute"]);
        NSString *text = CloudCodeBoundedString(raw);
        if (text) { node[pair[@"key"]] = text; }
    }
    id frameValue = CloudCodeAXCopy(runtime, element, runtime.attributeFrame ?: CFSTR("AXFrame"));
    NSDictionary *frame = CloudCodeFrameDictionary(runtime, frameValue);
    if (frame) { node[@"frame"] = frame; }

    id childrenValue = CloudCodeAXCopy(runtime, element, runtime.attributeChildren ?: CFSTR("AXChildren"));
    if ([childrenValue isKindOfClass:NSArray.class] && depth < 20) {
        NSMutableArray *children = [NSMutableArray array];
        for (id child in (NSArray *)childrenValue) {
            if (*nodeCount >= CLOUDCODE_GUI_MAX_TREE_NODES) { break; }
            CloudCodeAXUIElementRef childElement = (CloudCodeAXUIElementRef)(__bridge CFTypeRef)child;
            NSDictionary *childNode = CloudCodeAXNode(runtime, childElement, depth + 1, nodeCount);
            if (childNode) { [children addObject:childNode]; }
        }
        if (children.count > 0) { node[@"children"] = children; }
    }
    return node;
}

static CloudCodeAXUIElementRef CloudCodeAXFindElementForPid(CloudCodeAXRuntime runtime, CloudCodeAXUIElementRef element, pid_t targetPid, NSUInteger depth, NSUInteger *visited)
{
    if (!element || targetPid <= 0 || !visited || depth > 8 || *visited >= CLOUDCODE_GUI_MAX_TREE_NODES) { return NULL; }
    (*visited)++;
    if (runtime.getPid) {
        pid_t candidatePid = 0;
        CloudCodeAXError code = -1;
        @try { code = runtime.getPid(element, &candidatePid); } @catch (__unused NSException *exception) { code = -1; }
        if (code == 0 && candidatePid == targetPid) {
            CFRetain(element);
            return element;
        }
    }
    id childrenValue = CloudCodeAXCopy(runtime, element, runtime.attributeChildren ?: CFSTR("AXChildren"));
    if (![childrenValue isKindOfClass:NSArray.class]) { return NULL; }
    for (id child in (NSArray *)childrenValue) {
        CloudCodeAXUIElementRef childElement = (CloudCodeAXUIElementRef)(__bridge CFTypeRef)child;
        CloudCodeAXUIElementRef match = CloudCodeAXFindElementForPid(runtime, childElement, targetPid, depth + 1, visited);
        if (match) { return match; }
    }
    return NULL;
}

static void CloudCodePrepareAXApplication(CloudCodeAXRuntime runtime, CloudCodeAXUIElementRef root)
{
    if (!root) { return; }
    if (runtime.setTimeout) {
        @try { runtime.setTimeout(root, 1.5f); } @catch (__unused NSException *exception) {}
    }
    if (runtime.setAttribute) {
        @try { runtime.setAttribute(root, CFSTR("AXManualAccessibility"), kCFBooleanTrue); } @catch (__unused NSException *exception) {}
    }
}

static CloudCodeAXUIElementRef CloudCodeAXRootForPid(CloudCodeAXRuntime runtime, pid_t pid, NSString **backend)
{
    CloudCodeAXUIElementRef root = NULL;
    if (runtime.createApplication) {
        @try { root = runtime.createApplication(pid); } @catch (__unused NSException *exception) { root = NULL; }
        if (root) {
            CloudCodePrepareAXApplication(runtime, root);
            if (backend) *backend = @"AXRuntime.application";
            return root;
        }
    }
    if (runtime.createAppElementWithPid) {
        @try { root = runtime.createAppElementWithPid(pid); } @catch (__unused NSException *exception) { root = NULL; }
        if (root) {
            CloudCodePrepareAXApplication(runtime, root);
            if (backend) *backend = @"AXRuntime.privateAppElement";
            return root;
        }
    }
    if (runtime.createSystemWide && runtime.getPid) {
        CloudCodeAXUIElementRef systemWide = NULL;
        @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
        if (systemWide) {
            if (runtime.setTimeout) { @try { runtime.setTimeout(systemWide, 1.5f); } @catch (__unused NSException *exception) {} }
            NSUInteger visited = 0;
            root = CloudCodeAXFindElementForPid(runtime, systemWide, pid, 0, &visited);
            CFRelease(systemWide);
            if (root) {
                CloudCodePrepareAXApplication(runtime, root);
                if (backend) *backend = @"AXRuntime.systemWide";
                return root;
            }
        }
    }
    return NULL;
}

static CloudCodeAXUIElementRef CloudCodeAXFocusedApplicationRoot(CloudCodeAXRuntime runtime, pid_t *pidOut, NSString **backend)
{
    if (!runtime.createSystemWide || !runtime.copyAttribute || !runtime.getPid) { return NULL; }
    CloudCodeAXUIElementRef systemWide = NULL;
    @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
    if (!systemWide) { return NULL; }
    if (runtime.setTimeout) { @try { runtime.setTimeout(systemWide, 1.5f); } @catch (__unused NSException *exception) {} }

    CloudCodeAXUIElementRef focusedRoot = NULL;
    for (NSString *attribute in @[@"AXFocusedApplication", @"AXFrontmostApplication"]) {
        id value = CloudCodeAXCopy(runtime, systemWide, (__bridge CFStringRef)attribute);
        if (!value) { continue; }
        CloudCodeAXUIElementRef candidate = (CloudCodeAXUIElementRef)(__bridge CFTypeRef)value;
        pid_t pid = 0;
        CloudCodeAXError code = -1;
        @try { code = runtime.getPid(candidate, &pid); } @catch (__unused NSException *exception) { code = -1; }
        if (code == 0 && pid > 0) {
            CFRetain(candidate);
            focusedRoot = candidate;
            if (pidOut) { *pidOut = pid; }
            if (backend) { *backend = [@"AXRuntime.systemWide." stringByAppendingString:attribute]; }
            break;
        }
    }
    CFRelease(systemWide);
    if (focusedRoot) { CloudCodePrepareAXApplication(runtime, focusedRoot); }
    return focusedRoot;
}

static CloudCodeAXUIElementRef CloudCodeAXApplicationAtPointFromSeed(CloudCodeAXRuntime runtime, CloudCodeAXUIElementRef seed, CGSize size, pid_t *pidOut, NSString **backend, NSString *backendPrefix)
{
    if (!seed || !runtime.getPid || (!runtime.copyApplicationAtPosition && !runtime.copyApplicationAndContextAtPosition)) { return NULL; }
    if (runtime.setTimeout) { @try { runtime.setTimeout(seed, 1.5f); } @catch (__unused NSException *exception) {} }
    const CGPoint points[] = {
        {size.width * 0.5, size.height * 0.5},
        {size.width * 0.5, size.height * 0.25},
        {size.width * 0.5, size.height * 0.75}
    };
    for (NSUInteger index = 0; index < sizeof(points) / sizeof(points[0]); index++) {
        CloudCodeAXUIElementRef candidate = NULL;
        CloudCodeAXError code = -1;
        uint32_t contextID = 0;
        if (runtime.copyApplicationAndContextAtPosition) {
            @try {
                code = runtime.copyApplicationAndContextAtPosition(seed, &candidate, &contextID, (float)points[index].x, (float)points[index].y);
            } @catch (__unused NSException *exception) {
                code = -1;
                candidate = NULL;
            }
        }
        if ((code != 0 || !candidate) && runtime.copyApplicationAtPosition) {
            if (candidate) { CFRelease(candidate); candidate = NULL; }
            @try {
                code = runtime.copyApplicationAtPosition(seed, &candidate, (float)points[index].x, (float)points[index].y);
            } @catch (__unused NSException *exception) {
                code = -1;
                candidate = NULL;
            }
        }
        if (code != 0 || !candidate) { if (candidate) CFRelease(candidate); continue; }
        pid_t candidatePID = 0;
        CloudCodeAXError pidCode = -1;
        @try { pidCode = runtime.getPid(candidate, &candidatePID); } @catch (__unused NSException *exception) { pidCode = -1; }
        if (pidCode == 0 && candidatePID > 0 && candidatePID != getpid()) {
            CloudCodePrepareAXApplication(runtime, candidate);
            if (pidOut) { *pidOut = candidatePID; }
            if (backend) {
                NSString *suffix = contextID > 0 ? [NSString stringWithFormat:@"context-%u", contextID] : @"application";
                *backend = [NSString stringWithFormat:@"%@.%@", backendPrefix ?: @"AXRuntime.position", suffix];
            }
            return candidate;
        }
        CFRelease(candidate);
    }
    return NULL;
}

static CloudCodeAXUIElementRef CloudCodeAXApplicationAtScreenPointRoot(CloudCodeAXRuntime runtime, pid_t *pidOut, NSString **backend)
{
    CGSize size = CloudCodeScreenSize();
    if (size.width <= 1 || size.height <= 1 || !runtime.getPid || (!runtime.copyApplicationAtPosition && !runtime.copyApplicationAndContextAtPosition)) { return NULL; }

    if (runtime.createSystemWide) {
        CloudCodeAXUIElementRef systemWide = NULL;
        @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
        if (systemWide) {
            CloudCodeAXUIElementRef result = CloudCodeAXApplicationAtPointFromSeed(runtime, systemWide, size, pidOut, backend, @"AXRuntime.position.systemWide");
            CFRelease(systemWide);
            if (result) { return result; }
        }
    }

    if (runtime.createAppElementWithPid) {
        CloudCodeAXUIElementRef pidZeroSeed = NULL;
        @try { pidZeroSeed = runtime.createAppElementWithPid(0); } @catch (__unused NSException *exception) { pidZeroSeed = NULL; }
        if (pidZeroSeed) {
            CloudCodeAXUIElementRef result = CloudCodeAXApplicationAtPointFromSeed(runtime, pidZeroSeed, size, pidOut, backend, @"AXRuntime.position.pid0");
            CFRelease(pidZeroSeed);
            if (result) { return result; }
        }
    }
    return NULL;
}

static NSDictionary *CloudCodeAXHitTestTree(CloudCodeAXRuntime runtime, NSUInteger *nodeCount, pid_t *pidOut, NSString **backend)
{
    if (!runtime.createSystemWide || !runtime.copyElementAtPosition || !runtime.getPid || !nodeCount) { return nil; }
    CGSize size = CloudCodeScreenSize();
    if (size.width <= 1 || size.height <= 1) { return nil; }

    CloudCodeAXUIElementRef systemWide = NULL;
    @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
    if (!systemWide) { return nil; }
    if (runtime.setTimeout) { @try { runtime.setTimeout(systemWide, 1.5f); } @catch (__unused NSException *exception) {} }

    // Sample a bounded grid rather than one center point. Video/social UIs commonly place primary
    // actions along the right edge, while the center is often an unlabeled media surface. Apple's
    // system-wide AX hit-test respects z-order, so these points can still recover useful foreground
    // elements when detached helpers cannot obtain a full application root.
    const CGPoint points[] = {
        {size.width * 0.50, size.height * 0.50},
        {size.width * 0.88, size.height * 0.30},
        {size.width * 0.88, size.height * 0.43},
        {size.width * 0.88, size.height * 0.56},
        {size.width * 0.88, size.height * 0.69},
        {size.width * 0.88, size.height * 0.82},
        {size.width * 0.50, size.height * 0.22},
        {size.width * 0.50, size.height * 0.78},
        {size.width * 0.12, size.height * 0.50}
    };
    NSMutableArray *hits = [NSMutableArray array];
    pid_t foregroundPID = 0;
    for (NSUInteger index = 0; index < sizeof(points) / sizeof(points[0]); index++) {
        if (*nodeCount >= CLOUDCODE_GUI_MAX_TREE_NODES) { break; }
        CloudCodeAXUIElementRef candidate = NULL;
        CloudCodeAXError code = -1;
        @try {
            code = runtime.copyElementAtPosition(systemWide, (float)points[index].x, (float)points[index].y, &candidate);
        } @catch (__unused NSException *exception) {
            code = -1;
            candidate = NULL;
        }
        if (code != 0 || !candidate) { if (candidate) CFRelease(candidate); continue; }

        pid_t candidatePID = 0;
        CloudCodeAXError pidCode = -1;
        @try { pidCode = runtime.getPid(candidate, &candidatePID); } @catch (__unused NSException *exception) { pidCode = -1; }
        if (pidCode != 0 || candidatePID <= 0 || candidatePID == getpid()) {
            CFRelease(candidate);
            continue;
        }
        if (foregroundPID == 0) { foregroundPID = candidatePID; }
        if (candidatePID != foregroundPID) {
            CFRelease(candidate);
            continue;
        }
        if (runtime.addAssociatedPid) {
            runtime.addAssociatedPid(getpid(), candidatePID, 0);
            runtime.addAssociatedPid(getpid(), candidatePID, 1);
            runtime.addAssociatedPid(candidatePID, getpid(), 0);
            runtime.addAssociatedPid(candidatePID, getpid(), 1);
        }

        NSDictionary *node = CloudCodeAXNode(runtime, candidate, 0, nodeCount);
        CFRelease(candidate);
        if (!node) { continue; }
        NSMutableDictionary *annotated = [node mutableCopy];
        annotated[@"hitPoint"] = @{@"x": @(points[index].x), @"y": @(points[index].y)};
        [hits addObject:annotated];
    }
    CFRelease(systemWide);
    if (hits.count == 0 || foregroundPID <= 0) { return nil; }
    if (pidOut) { *pidOut = foregroundPID; }
    if (backend) { *backend = @"AXRuntime.systemWide.elementAtPosition"; }
    return @{@"role": @"AXHitTestSnapshot", @"children": hits};
}

static NSData *CloudCodeFrontmostTreeData(void)
{
    CloudCodeAXRuntime runtime = CloudCodeResolveAX();
    if ((!runtime.createApplication && !runtime.createAppElementWithPid && !runtime.createSystemWide) || !runtime.copyAttribute) {
        fprintf(stderr, "gui-tree: required AXRuntime creation/copy symbols are unavailable\n");
        return nil;
    }
    if (runtime.setRequestingClient) { runtime.setRequestingClient(2); }

    NSString *bundleID = CloudCodeFrontmostBundleID();
    pid_t pid = 0;
    NSString *backend = nil;
    CloudCodeAXUIElementRef root = NULL;

    if (bundleID.length > 0) {
        NSString *bundlePath = CloudCodeBundlePathForIdentifier(bundleID);
        if (bundlePath.length > 0) {
            pid = CloudCodePIDForBundlePath(bundlePath);
            if (pid > 0) {
                if (runtime.addAssociatedPid) {
                    runtime.addAssociatedPid(getpid(), pid, 0);
                    runtime.addAssociatedPid(getpid(), pid, 1);
                    runtime.addAssociatedPid(pid, getpid(), 0);
                    runtime.addAssociatedPid(pid, getpid(), 1);
                }
                root = CloudCodeAXRootForPid(runtime, pid, &backend);
            }
        }
    }

    // On iOS 15+ the SpringBoardServices frontmost identifier can be unavailable to a detached
    // root helper even when Accessibility can still identify the focused application. Do not make
    // SBS a single point of failure: ask the system-wide AX root for its focused/frontmost app and
    // recover the display identifier from the resulting PID when possible.
    if (!root) {
        pid_t focusedPID = 0;
        root = CloudCodeAXFocusedApplicationRoot(runtime, &focusedPID, &backend);
        if (root && focusedPID > 0) {
            pid = focusedPID;
            NSString *focusedBundleID = CloudCodeBundleIDForPID(pid);
            if (focusedBundleID.length > 0) { bundleID = focusedBundleID; }
            if (runtime.addAssociatedPid) {
                runtime.addAssociatedPid(getpid(), pid, 0);
                runtime.addAssociatedPid(getpid(), pid, 1);
                runtime.addAssociatedPid(pid, getpid(), 0);
                runtime.addAssociatedPid(pid, getpid(), 1);
            }
        }
    }

    // Some detached helpers cannot read AXFocusedApplication even though AXRuntime can still
    // hit-test the visible display. Resolve the application element at a few bounded screen points
    // as another read-only fallback without depending on SpringBoard injection.
    if (!root) {
        pid_t positionPID = 0;
        root = CloudCodeAXApplicationAtScreenPointRoot(runtime, &positionPID, &backend);
        if (root && positionPID > 0) {
            pid = positionPID;
            NSString *positionBundleID = CloudCodeBundleIDForPID(pid);
            if (positionBundleID.length > 0) { bundleID = positionBundleID; }
            if (runtime.addAssociatedPid) {
                runtime.addAssociatedPid(getpid(), pid, 0);
                runtime.addAssociatedPid(getpid(), pid, 1);
                runtime.addAssociatedPid(pid, getpid(), 0);
                runtime.addAssociatedPid(pid, getpid(), 1);
            }
        }
    }

    // Public AXUIElementCopyElementAtPosition is a separate system-wide hit-test primitive. It can
    // still return topmost foreground elements when the application-level AX constructors above are
    // unavailable to a detached TrollStore root helper. Keep the result explicitly labeled as a
    // sampled snapshot so the agent never mistakes it for a complete hierarchy.
    NSUInteger nodeCount = 0;
    NSDictionary *rootNode = nil;
    if (!root) {
        rootNode = CloudCodeAXHitTestTree(runtime, &nodeCount, &pid, &backend);
        if (rootNode && pid > 0) {
            NSString *hitBundleID = CloudCodeBundleIDForPID(pid);
            if (hitBundleID.length > 0) { bundleID = hitBundleID; }
        }
    }

    if (!root && (!rootNode || pid <= 0)) {
        fprintf(stderr, "gui-tree: SpringBoardServices, AX focused-app, AX application-at-position, and AX element-at-position fallbacks all failed to produce readable foreground UI\n");
        return nil;
    }

    if (root) {
        rootNode = CloudCodeAXNode(runtime, root, 0, &nodeCount);
        CFRelease(root);
    }
    if (!rootNode || nodeCount == 0) {
        fprintf(stderr, "gui-tree: AX root existed but no readable UI nodes were returned\n");
        return nil;
    }
    NSDictionary *payload = @{@"backend": backend ?: @"AXRuntime", @"bundleId": bundleID ?: @"", @"pid": @(pid), @"nodeCount": @(nodeCount), @"tree": rootNode};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error || data.length == 0) {
        fprintf(stderr, "gui-tree: AX tree JSON serialization failed\n");
        return nil;
    }
    if (data.length > CLOUDCODE_GUI_MAX_TREE_BYTES) {
        fprintf(stderr, "gui-tree: AX tree output exceeded %d bytes\n", CLOUDCODE_GUI_MAX_TREE_BYTES);
        return nil;
    }
    return data;
}

static void CloudCodePrintData(NSData *data)
{
    if (!data.length) { return; }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

int CloudCodeGUIProbeJSON(void)
{
    @autoreleasepool {
        // Keep explicit capability refresh lightweight. Do not touch UIScreen, global screenshots,
        // AXRuntime, or dispatch synthetic touch events here; each exact GUI operation validates
        // those private runtimes in its own bounded helper invocation when the user requests it.
        CloudCodeHIDRuntime hid = CloudCodeResolveHID();
        BOOL symbolsReady = hid.createClient && hid.dispatch && hid.createDigitizer && hid.createFinger && hid.append && hid.setSender && hid.setInteger && hid.setFloat;
        CloudCodeIOHIDEventSystemClientRef client = symbolsReady ? hid.createClient(kCFAllocatorDefault) : NULL;
        BOOL hidReady = client != NULL;
        if (client) { CFRelease(client); }
        BOOL text = hidReady && hid.createUnicode != NULL;
        NSDictionary *payload = @{
            @"backend": @"trollstore-root-helper-lightweight",
            @"touch": @NO,
            @"gestures": @NO,
            @"textInput": @(text),
            @"screenshot": @NO,
            @"tree": @NO,
            @"verify": @NO,
            @"screenWidth": @0,
            @"screenHeight": @0
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!data) { return 61; }
        CloudCodePrintData(data);
        return 0;
    }
}

int CloudCodeGUITreeJSON(void)
{
    @autoreleasepool {
        NSData *data = CloudCodeFrontmostTreeData();
        if (!data) { return 62; }
        CloudCodePrintData(data);
        return 0;
    }
}

int CloudCodeGUIScreenshotBase64(void)
{
    @autoreleasepool {
        NSData *data = CloudCodeScreenshotJPEG();
        if (!data) {
            fprintf(stderr, "gui-screenshot: render-server IOSurface, _UICreateScreenUIImage, and UIWindow IOSurface backends all failed or could not produce a bounded JPEG\n");
            return 63;
        }
        NSString *encoded = [data base64EncodedStringWithOptions:0];
        NSData *output = [encoded dataUsingEncoding:NSUTF8StringEncoding];
        if (!output || output.length > (CLOUDCODE_GUI_MAX_SCREENSHOT_BYTES * 2)) {
            fprintf(stderr, "gui-screenshot: base64 output exceeded the app-layer capture bound\n");
            return 63;
        }
        CloudCodePrintData(output);
        return 0;
    }
}

int CloudCodeGUITap(double x, double y)
{
    @autoreleasepool {
        CGSize size = CloudCodeScreenSize();
        if (!CloudCodeValidPoint(x, y, size)) { return 64; }
        return CloudCodePerformTap(x, y) ? 0 : 65;
    }
}

int CloudCodeGUISwipe(double fromX, double fromY, double toX, double toY, double durationSeconds)
{
    @autoreleasepool {
        return CloudCodePerformSwipe(fromX, fromY, toX, toY, durationSeconds) ? 0 : 66;
    }
}

int CloudCodeGUIScroll(double deltaX, double deltaY)
{
    @autoreleasepool {
        if (!isfinite(deltaX) || !isfinite(deltaY) || (fabs(deltaX) < 0.5 && fabs(deltaY) < 0.5)) { return 64; }
        CGSize size = CloudCodeScreenSize();
        if (size.width <= 1 || size.height <= 1) { return 64; }
        double fromX = size.width * 0.5;
        double fromY = size.height * 0.5;
        double toX = MIN(MAX(fromX - deltaX, size.width * 0.1), size.width * 0.9);
        double toY = MIN(MAX(fromY - deltaY, size.height * 0.1), size.height * 0.9);
        return CloudCodePerformSwipe(fromX, fromY, toX, toY, 0.30) ? 0 : 66;
    }
}

int CloudCodeGUITypeBase64(NSString *base64Text)
{
    @autoreleasepool {
        if (![base64Text isKindOfClass:NSString.class] || base64Text.length == 0 || base64Text.length > (CLOUDCODE_GUI_MAX_TEXT_UTF8_BYTES * 2)) { return 67; }
        NSData *utf8 = [[NSData alloc] initWithBase64EncodedString:base64Text options:0];
        if (!utf8 || utf8.length == 0 || utf8.length > CLOUDCODE_GUI_MAX_TEXT_UTF8_BYTES) { return 67; }
        NSString *text = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
        if (!text || text.length == 0) { return 67; }
        NSData *unicode = [text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        if (!unicode || unicode.length == 0 || unicode.length > UINT32_MAX) { return 67; }
        CloudCodeHIDRuntime runtime = CloudCodeResolveHID();
        CGSize size = CloudCodeScreenSize();
        CloudCodeHIDRoute route = {0};
        CGPoint routingPoint = CGPointMake(size.width > 1 ? size.width * 0.5 : 1, size.height > 1 ? size.height * 0.5 : 1);
        if (!CloudCodeHIDReady(runtime, routingPoint, &route) || !runtime.createUnicode) {
            CloudCodeReleaseHIDRoute(&route);
            return 68;
        }
        CloudCodeIOHIDEventRef event = runtime.createUnicode(kCFAllocatorDefault, mach_absolute_time(), unicode.bytes, (uint32_t)unicode.length, 1, 0);
        if (!event) { CloudCodeReleaseHIDRoute(&route); return 68; }
        runtime.setInteger(event, 4, 1);
        if (route.usesBackBoardRoute && route.routedConnection && runtime.dispatchConnection) {
            runtime.dispatchConnection(route.routedConnection, event);
        } else if (route.systemClient && runtime.dispatch) {
            if (runtime.setSender) { runtime.setSender(event, CLOUDCODE_GUI_SENDER_ID); }
            runtime.dispatch(route.systemClient, event);
        } else {
            CFRelease(event);
            CloudCodeReleaseHIDRoute(&route);
            return 68;
        }
        CFRelease(event);
        CloudCodeReleaseHIDRoute(&route);
        return 0;
    }
}
