#import "GUIAutomation.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
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
#define CLOUDCODE_GUI_SENDER_ID 0x8000000817319372ULL

typedef const struct __CloudCodeIOHIDEvent *CloudCodeIOHIDEventRef;
typedef const struct __CloudCodeIOHIDEventSystemClient *CloudCodeIOHIDEventSystemClientRef;
typedef uint32_t CloudCodeIOOptionBits;

typedef CloudCodeIOHIDEventSystemClientRef (*CloudCodeHIDClientCreateFn)(CFAllocatorRef);
typedef void (*CloudCodeHIDDispatchFn)(CloudCodeIOHIDEventSystemClientRef, CloudCodeIOHIDEventRef);
typedef CloudCodeIOHIDEventRef (*CloudCodeDigitizerEventCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, double, Boolean, Boolean, CloudCodeIOOptionBits);
typedef CloudCodeIOHIDEventRef (*CloudCodeFingerEventCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, CloudCodeIOOptionBits);
typedef CloudCodeIOHIDEventRef (*CloudCodeUnicodeEventCreateFn)(CFAllocatorRef, uint64_t, const uint8_t *, uint32_t, uint32_t, CloudCodeIOOptionBits);
typedef void (*CloudCodeHIDAppendFn)(CloudCodeIOHIDEventRef, CloudCodeIOHIDEventRef, CloudCodeIOOptionBits);
typedef void (*CloudCodeHIDSetSenderFn)(CloudCodeIOHIDEventRef, uint64_t);
typedef void (*CloudCodeHIDSetIntegerFn)(CloudCodeIOHIDEventRef, uint32_t, int32_t);
typedef void (*CloudCodeHIDSetFloatFn)(CloudCodeIOHIDEventRef, uint32_t, double);

typedef const struct __CloudCodeAXUIElement *CloudCodeAXUIElementRef;
typedef int32_t CloudCodeAXError;
typedef CloudCodeAXUIElementRef (*CloudCodeAXCreateApplicationFn)(pid_t);
typedef CloudCodeAXError (*CloudCodeAXCopyAttributeFn)(CloudCodeAXUIElementRef, CFStringRef, CFTypeRef *);
typedef CloudCodeAXError (*CloudCodeAXSetTimeoutFn)(CloudCodeAXUIElementRef, float);
typedef void (*CloudCodeAXAddAssociatedPidFn)(pid_t, pid_t, int);
typedef void (*CloudCodeAXSetRequestingClientFn)(uint32_t);
typedef int (*CloudCodeProcListAllPidsFn)(void *, int);
typedef int (*CloudCodeProcPidPathFn)(int, void *, uint32_t);

typedef CFTypeID (*CloudCodeAXValueGetTypeIDFn)(void);
typedef int (*CloudCodeAXValueGetTypeFn)(CFTypeRef);
typedef Boolean (*CloudCodeAXValueGetValueFn)(CFTypeRef, int, void *);

typedef UIImage *(*CloudCodeCreateScreenImageFn)(void);
typedef CFStringRef (*CloudCodeCopyFrontmostBundleIDFn)(void);

typedef struct {
    void *handle;
    CloudCodeHIDClientCreateFn createClient;
    CloudCodeHIDDispatchFn dispatch;
    CloudCodeDigitizerEventCreateFn createDigitizer;
    CloudCodeFingerEventCreateFn createFinger;
    CloudCodeUnicodeEventCreateFn createUnicode;
    CloudCodeHIDAppendFn append;
    CloudCodeHIDSetSenderFn setSender;
    CloudCodeHIDSetIntegerFn setInteger;
    CloudCodeHIDSetFloatFn setFloat;
} CloudCodeHIDRuntime;

typedef struct {
    void *handle;
    CloudCodeAXCreateApplicationFn createApplication;
    CloudCodeAXCopyAttributeFn copyAttribute;
    CloudCodeAXSetTimeoutFn setTimeout;
    CloudCodeAXAddAssociatedPidFn addAssociatedPid;
    CloudCodeAXSetRequestingClientFn setRequestingClient;
    CloudCodeAXValueGetTypeIDFn valueGetTypeID;
    CloudCodeAXValueGetTypeFn valueGetType;
    CloudCodeAXValueGetValueFn valueGetValue;
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

static CloudCodeHIDRuntime CloudCodeResolveHID(void)
{
    CloudCodeHIDRuntime runtime = {0};
    runtime.handle = CloudCodeOpenFramework(@[
        @"/System/Library/Frameworks/IOKit.framework/IOKit",
        @"/rootfs/System/Library/Frameworks/IOKit.framework/IOKit"
    ]);
    runtime.createClient = (CloudCodeHIDClientCreateFn)CloudCodeResolve(runtime.handle, "IOHIDEventSystemClientCreate");
    runtime.dispatch = (CloudCodeHIDDispatchFn)CloudCodeResolve(runtime.handle, "IOHIDEventSystemClientDispatchEvent");
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

static BOOL CloudCodeHIDReady(CloudCodeHIDRuntime runtime, CloudCodeIOHIDEventSystemClientRef *clientOut)
{
    if (!runtime.createClient || !runtime.dispatch || !runtime.createDigitizer || !runtime.createFinger || !runtime.append || !runtime.setSender || !runtime.setInteger || !runtime.setFloat) {
        return NO;
    }
    CloudCodeIOHIDEventSystemClientRef client = runtime.createClient(kCFAllocatorDefault);
    if (!client) { return NO; }
    if (clientOut) {
        *clientOut = client;
    } else {
        CFRelease(client);
    }
    return YES;
}

static CGSize CloudCodeScreenSize(void)
{
    @try {
        CGRect bounds = UIScreen.mainScreen.bounds;
        if (bounds.size.width > 1 && bounds.size.height > 1) { return bounds.size; }
    } @catch (__unused NSException *exception) {
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
    CloudCodeIOHIDEventRef parent = runtime.createDigitizer(
        kCFAllocatorDefault, mach_absolute_time(), 3, 99, 1, 0, 0,
        0, 0, 0, 0, 0, 0, false, false, 0
    );
    if (!parent) { return NULL; }
    CloudCodeIOHIDEventRef child = runtime.createFinger(
        kCFAllocatorDefault, mach_absolute_time(), 1, 3, phaseMask,
        nx, ny, 0, 0, 0, range, touching, 0
    );
    if (!child) {
        CFRelease(parent);
        return NULL;
    }
    runtime.setFloat(child, 0xB0014, 0.04);
    runtime.setFloat(child, 0xB0015, 0.04);
    runtime.append(parent, child, 0);
    CFRelease(child);
    runtime.setInteger(parent, 0xB0019, 1);
    runtime.setInteger(parent, 0x4, 1);
    runtime.setInteger(parent, 0xB0007, 0x23);
    runtime.setInteger(parent, 0xB0008, 0x1);
    runtime.setInteger(parent, 0xB0009, 0x1);
    runtime.setSender(parent, CLOUDCODE_GUI_SENDER_ID);
    return parent;
}

static BOOL CloudCodeDispatchTouch(CloudCodeHIDRuntime runtime, CloudCodeIOHIDEventSystemClientRef client, double x, double y, uint32_t mask, BOOL range, BOOL touching)
{
    CloudCodeIOHIDEventRef event = CloudCodeCreateTouchParent(runtime, x, y, mask, range, touching);
    if (!event) { return NO; }
    runtime.dispatch(client, event);
    CFRelease(event);
    return YES;
}

static BOOL CloudCodePerformTap(double x, double y)
{
    CloudCodeHIDRuntime runtime = CloudCodeResolveHID();
    CloudCodeIOHIDEventSystemClientRef client = NULL;
    if (!CloudCodeHIDReady(runtime, &client)) { return NO; }
    BOOL ok = CloudCodeDispatchTouch(runtime, client, x, y, (1u << 0) | (1u << 1), YES, YES);
    if (ok) { usleep(50000); ok = CloudCodeDispatchTouch(runtime, client, x, y, (1u << 2), YES, YES); }
    if (ok) { usleep(50000); ok = CloudCodeDispatchTouch(runtime, client, x, y, (1u << 1), NO, NO); }
    CFRelease(client);
    return ok;
}

static BOOL CloudCodePerformSwipe(double fromX, double fromY, double toX, double toY, double durationSeconds)
{
    CGSize size = CloudCodeScreenSize();
    if (!CloudCodeValidPoint(fromX, fromY, size) || !CloudCodeValidPoint(toX, toY, size) || !isfinite(durationSeconds) || durationSeconds < 0.05 || durationSeconds > 5.0) { return NO; }
    CloudCodeHIDRuntime runtime = CloudCodeResolveHID();
    CloudCodeIOHIDEventSystemClientRef client = NULL;
    if (!CloudCodeHIDReady(runtime, &client)) { return NO; }
    const int steps = 20;
    useconds_t delay = (useconds_t)((durationSeconds * 1000000.0) / steps);
    BOOL ok = CloudCodeDispatchTouch(runtime, client, fromX, fromY, (1u << 0) | (1u << 1), YES, YES);
    for (int index = 1; ok && index <= steps; index++) {
        usleep(delay);
        double t = (double)index / (double)steps;
        double x = fromX + (toX - fromX) * t;
        double y = fromY + (toY - fromY) * t;
        ok = CloudCodeDispatchTouch(runtime, client, x, y, (1u << 2), YES, YES);
    }
    if (ok) {
        usleep(10000);
        ok = CloudCodeDispatchTouch(runtime, client, toX, toY, (1u << 1), NO, NO);
    }
    CFRelease(client);
    return ok;
}

static NSData *CloudCodeScreenshotJPEG(void)
{
    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_LOCAL);
    CloudCodeCreateScreenImageFn createImage = (CloudCodeCreateScreenImageFn)CloudCodeResolve(uikit, "_UICreateScreenUIImage");
    if (!createImage) { return nil; }
    UIImage *image = nil;
    @try {
        image = createImage();
    } @catch (__unused NSException *exception) {
        image = nil;
    }
    if (!image) { return nil; }
    NSData *data = UIImageJPEGRepresentation(image, 0.55);
    if (data.length == 0 || data.length > CLOUDCODE_GUI_MAX_SCREENSHOT_BYTES) { return nil; }
    return data;
}

static NSString *CloudCodeFrontmostBundleID(void)
{
    void *handle = CloudCodeOpenFramework(@[
        @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        @"/rootfs/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
    ]);
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
        @"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        @"/System/Library/Frameworks/Accessibility.framework/Accessibility",
        @"/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility"
    ];
    runtime.handle = CloudCodeOpenFramework(paths);
    runtime.createApplication = (CloudCodeAXCreateApplicationFn)CloudCodeResolve(runtime.handle, "AXUIElementCreateApplication");
    if (!runtime.createApplication) {
        runtime.createApplication = (CloudCodeAXCreateApplicationFn)CloudCodeResolve(runtime.handle, "_AXUIElementCreateAppElementWithPid");
    }
    runtime.copyAttribute = (CloudCodeAXCopyAttributeFn)CloudCodeResolve(runtime.handle, "AXUIElementCopyAttributeValue");
    runtime.setTimeout = (CloudCodeAXSetTimeoutFn)CloudCodeResolve(runtime.handle, "AXUIElementSetMessagingTimeout");
    runtime.addAssociatedPid = (CloudCodeAXAddAssociatedPidFn)CloudCodeResolve(runtime.handle, "AXAddAssociatedPid");
    runtime.setRequestingClient = (CloudCodeAXSetRequestingClientFn)CloudCodeResolve(runtime.handle, "__AXSetRequestingClient");
    runtime.valueGetTypeID = (CloudCodeAXValueGetTypeIDFn)CloudCodeResolve(runtime.handle, "AXValueGetTypeID");
    runtime.valueGetType = (CloudCodeAXValueGetTypeFn)CloudCodeResolve(runtime.handle, "AXValueGetType");
    runtime.valueGetValue = (CloudCodeAXValueGetValueFn)CloudCodeResolve(runtime.handle, "AXValueGetValue");
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
    NSArray<NSArray *> *attributes = @[
        @[@"role", @"AXRole"], @[@"label", @"AXLabel"], @[@"value", @"AXValue"],
        @[@"title", @"AXTitle"], @[@"identifier", @"AXIdentifier"], @[@"placeholder", @"AXPlaceholderValue"]
    ];
    for (NSArray *pair in attributes) {
        id raw = CloudCodeAXCopy(runtime, element, (__bridge CFStringRef)pair[1]);
        NSString *text = CloudCodeBoundedString(raw);
        if (text) { node[pair[0]] = text; }
    }
    id frameValue = CloudCodeAXCopy(runtime, element, CFSTR("AXFrame"));
    NSDictionary *frame = CloudCodeFrameDictionary(runtime, frameValue);
    if (frame) { node[@"frame"] = frame; }

    id childrenValue = CloudCodeAXCopy(runtime, element, CFSTR("AXChildren"));
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

static NSData *CloudCodeFrontmostTreeData(void)
{
    NSString *bundleID = CloudCodeFrontmostBundleID();
    NSString *bundlePath = CloudCodeBundlePathForIdentifier(bundleID);
    pid_t pid = CloudCodePIDForBundlePath(bundlePath);
    if (bundleID.length == 0 || pid <= 0) { return nil; }
    CloudCodeAXRuntime runtime = CloudCodeResolveAX();
    if (!runtime.createApplication || !runtime.copyAttribute) { return nil; }
    if (runtime.setRequestingClient) { runtime.setRequestingClient(2); }
    if (runtime.addAssociatedPid) {
        runtime.addAssociatedPid(getpid(), pid, 0);
        runtime.addAssociatedPid(getpid(), pid, 1);
        runtime.addAssociatedPid(pid, getpid(), 0);
        runtime.addAssociatedPid(pid, getpid(), 1);
    }
    CloudCodeAXUIElementRef root = NULL;
    @try { root = runtime.createApplication(pid); } @catch (__unused NSException *exception) { root = NULL; }
    if (!root) { return nil; }
    if (runtime.setTimeout) { @try { runtime.setTimeout(root, 1.5f); } @catch (__unused NSException *exception) {} }
    NSUInteger nodeCount = 0;
    NSDictionary *rootNode = CloudCodeAXNode(runtime, root, 0, &nodeCount);
    CFRelease(root);
    if (!rootNode || nodeCount == 0) { return nil; }
    NSDictionary *payload = @{@"backend": @"AXRuntime", @"bundleId": bundleID, @"pid": @(pid), @"nodeCount": @(nodeCount), @"tree": rootNode};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error || data.length == 0 || data.length > CLOUDCODE_GUI_MAX_TREE_BYTES) { return nil; }
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
        CloudCodeHIDRuntime hid = CloudCodeResolveHID();
        CloudCodeIOHIDEventSystemClientRef client = NULL;
        BOOL hidReady = CloudCodeHIDReady(hid, &client);
        if (client) { CFRelease(client); }
        CGSize screenSize = CloudCodeScreenSize();
        BOOL coordinateSpaceReady = isfinite(screenSize.width) && isfinite(screenSize.height)
            && screenSize.width > 1 && screenSize.height > 1;
        BOOL touch = hidReady && coordinateSpaceReady;
        BOOL text = hidReady && hid.createUnicode != NULL;
        NSData *screenshot = CloudCodeScreenshotJPEG();
        NSData *tree = CloudCodeFrontmostTreeData();
        NSDictionary *payload = @{
            @"backend": @"trollstore-root-helper",
            @"touch": @(touch),
            @"gestures": @(touch),
            @"textInput": @(text),
            @"screenshot": @(screenshot.length > 0),
            @"tree": @(tree.length > 0),
            @"verify": @(tree.length > 0),
            @"screenWidth": @(screenSize.width),
            @"screenHeight": @(screenSize.height)
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
        if (!data) { return 63; }
        NSString *encoded = [data base64EncodedStringWithOptions:0];
        NSData *output = [encoded dataUsingEncoding:NSUTF8StringEncoding];
        if (!output || output.length > (CLOUDCODE_GUI_MAX_SCREENSHOT_BYTES * 2)) { return 63; }
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
        CloudCodeIOHIDEventSystemClientRef client = NULL;
        if (!CloudCodeHIDReady(runtime, &client) || !runtime.createUnicode) {
            if (client) { CFRelease(client); }
            return 68;
        }
        CloudCodeIOHIDEventRef event = runtime.createUnicode(kCFAllocatorDefault, mach_absolute_time(), unicode.bytes, (uint32_t)unicode.length, 1, 0);
        if (!event) { CFRelease(client); return 68; }
        runtime.setInteger(event, 4, 1);
        runtime.setSender(event, CLOUDCODE_GUI_SENDER_ID);
        runtime.dispatch(client, event);
        CFRelease(event);
        CFRelease(client);
        return 0;
    }
}
