#import "RootHelperBridge.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdint.h>
#import <unistd.h>

#define CLOUDCODE_HOST_AX_MAX_NODES 220
#define CLOUDCODE_HOST_AX_MAX_DEPTH 14
#define CLOUDCODE_HOST_AX_MAX_BYTES (256 * 1024)
#define CLOUDCODE_HOST_AX_TIMEOUT_SECONDS 0.25f
#define CLOUDCODE_HOST_AX_TOTAL_BUDGET_SECONDS 1.20

typedef const struct __CloudCodeHostAXUIElement *CloudCodeHostAXUIElementRef;
typedef int32_t CloudCodeHostAXError;
typedef CloudCodeHostAXUIElementRef (*CloudCodeHostAXCreateApplicationFn)(pid_t);
typedef CloudCodeHostAXUIElementRef (*CloudCodeHostAXCreateSystemWideFn)(void);
typedef CloudCodeHostAXError (*CloudCodeHostAXGetPidFn)(CloudCodeHostAXUIElementRef, pid_t *);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyAttributeFn)(CloudCodeHostAXUIElementRef, CFStringRef, CFTypeRef *);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyMultipleAttributesFn)(CloudCodeHostAXUIElementRef, CFArrayRef, CFOptionFlags, CFArrayRef *);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyElementAtPositionFn)(CloudCodeHostAXUIElementRef, CloudCodeHostAXUIElementRef *, float, float);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyApplicationAtPositionFn)(CloudCodeHostAXUIElementRef, CloudCodeHostAXUIElementRef *, float, float);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyApplicationAndContextAtPositionFn)(CloudCodeHostAXUIElementRef, CloudCodeHostAXUIElementRef *, uint32_t *, float, float);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyElementWithParametersFn)(CloudCodeHostAXUIElementRef *, CFDictionaryRef);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyParameterizedAttributeValueFn)(CloudCodeHostAXUIElementRef, CFStringRef, CFTypeRef, CFTypeRef *);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyElementUsingContextIdAtPositionFn)(CloudCodeHostAXUIElementRef, uint32_t, CloudCodeHostAXUIElementRef *, int, float, float);
typedef CloudCodeHostAXError (*CloudCodeHostAXCopyElementUsingDisplayIdAtPositionFn)(CloudCodeHostAXUIElementRef, uint32_t, CloudCodeHostAXUIElementRef *, int, float, float);
typedef CFTypeRef (*CloudCodeHostAXValueCreateFn)(int, const void *);
typedef CloudCodeHostAXError (*CloudCodeHostAXSetTimeoutFn)(CloudCodeHostAXUIElementRef, float);
typedef void (*CloudCodeHostAXSetRequestingClientFn)(uint32_t);
typedef void (*CloudCodeHostAXAddAssociatedPidFn)(pid_t, pid_t, int);
typedef int (*CloudCodeHostAXAutomationEnabledFn)(void);
typedef void (*CloudCodeHostAXSetAutomationEnabledFn)(int);
typedef CFTypeID (*CloudCodeHostAXValueGetTypeIDFn)(void);
typedef int (*CloudCodeHostAXValueGetTypeFn)(CFTypeRef);
typedef Boolean (*CloudCodeHostAXValueGetValueFn)(CFTypeRef, int, void *);
typedef CFStringRef (*CloudCodeHostCopyFrontmostBundleIDFn)(void);
typedef CFStringRef (*CloudCodeHostCopyBundleIDForPidFn)(pid_t);
typedef int (*CloudCodeHostProcListAllPidsFn)(void *, int);
typedef int (*CloudCodeHostProcPidPathFn)(int, void *, uint32_t);

typedef struct {
    CloudCodeHostAXCreateApplicationFn createApplication;
    CloudCodeHostAXCreateApplicationFn createAppElementWithPid;
    CloudCodeHostAXCreateSystemWideFn createSystemWide;
    CloudCodeHostAXGetPidFn getPid;
    CloudCodeHostAXCopyAttributeFn copyAttribute;
    CloudCodeHostAXCopyMultipleAttributesFn copyMultipleAttributes;
    CloudCodeHostAXCopyElementAtPositionFn copyElementAtPosition;
    CloudCodeHostAXCopyApplicationAtPositionFn copyApplicationAtPosition;
    CloudCodeHostAXCopyApplicationAndContextAtPositionFn copyApplicationAndContextAtPosition;
    CloudCodeHostAXCopyElementWithParametersFn copyElementWithParameters;
    CloudCodeHostAXCopyParameterizedAttributeValueFn copyParameterizedAttributeValue;
    CloudCodeHostAXCopyElementUsingContextIdAtPositionFn copyElementUsingContextIdAtPosition;
    CloudCodeHostAXCopyElementUsingDisplayIdAtPositionFn copyElementUsingDisplayIdAtPosition;
    CloudCodeHostAXValueCreateFn valueCreate;
    CloudCodeHostAXSetTimeoutFn setTimeout;
    CloudCodeHostAXSetRequestingClientFn setRequestingClient;
    CloudCodeHostAXAddAssociatedPidFn addAssociatedPid;
    CloudCodeHostAXAutomationEnabledFn automationEnabled;
    CloudCodeHostAXSetAutomationEnabledFn setAutomationEnabled;
    CloudCodeHostAXValueGetTypeIDFn valueGetTypeID;
    CloudCodeHostAXValueGetTypeFn valueGetType;
    CloudCodeHostAXValueGetValueFn valueGetValue;
} CloudCodeHostAXRuntime;

static void *CloudCodeHostAXResolveAcrossFrameworks(const char *name)
{
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) { return symbol; }
    static const char *paths[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        "/usr/lib/libAccessibility.dylib"
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        void *handle = dlopen(paths[index], RTLD_NOW | RTLD_GLOBAL);
        if (!handle) { continue; }
        symbol = dlsym(handle, name);
        if (symbol) { return symbol; }
    }
    return NULL;
}

static CloudCodeHostAXRuntime CloudCodeHostAXResolve(void)
{
    CloudCodeHostAXRuntime runtime = {0};
    runtime.createApplication = (CloudCodeHostAXCreateApplicationFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCreateApplication");
    runtime.createAppElementWithPid = (CloudCodeHostAXCreateApplicationFn)CloudCodeHostAXResolveAcrossFrameworks("_AXUIElementCreateAppElementWithPid");
    runtime.createSystemWide = (CloudCodeHostAXCreateSystemWideFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCreateSystemWide");
    runtime.getPid = (CloudCodeHostAXGetPidFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementGetPid");
    if (!runtime.getPid) { runtime.getPid = (CloudCodeHostAXGetPidFn)CloudCodeHostAXResolveAcrossFrameworks("_AXUIElementGetPid"); }
    runtime.copyAttribute = (CloudCodeHostAXCopyAttributeFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyAttributeValue");
    runtime.copyMultipleAttributes = (CloudCodeHostAXCopyMultipleAttributesFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyMultipleAttributeValues");
    runtime.copyElementAtPosition = (CloudCodeHostAXCopyElementAtPositionFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyElementAtPosition");
    runtime.copyApplicationAtPosition = (CloudCodeHostAXCopyApplicationAtPositionFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyApplicationAtPosition");
    runtime.copyApplicationAndContextAtPosition = (CloudCodeHostAXCopyApplicationAndContextAtPositionFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyApplicationAndContextAtPosition");
    runtime.copyElementWithParameters = (CloudCodeHostAXCopyElementWithParametersFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyElementWithParameters");
    runtime.copyParameterizedAttributeValue = (CloudCodeHostAXCopyParameterizedAttributeValueFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyParameterizedAttributeValue");
    runtime.copyElementUsingContextIdAtPosition = (CloudCodeHostAXCopyElementUsingContextIdAtPositionFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyElementUsingContextIdAtPosition");
    runtime.copyElementUsingDisplayIdAtPosition = (CloudCodeHostAXCopyElementUsingDisplayIdAtPositionFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementCopyElementUsingDisplayIdAtPosition");
    runtime.valueCreate = (CloudCodeHostAXValueCreateFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueCreate");
    runtime.setTimeout = (CloudCodeHostAXSetTimeoutFn)CloudCodeHostAXResolveAcrossFrameworks("AXUIElementSetMessagingTimeout");
    runtime.setRequestingClient = (CloudCodeHostAXSetRequestingClientFn)CloudCodeHostAXResolveAcrossFrameworks("_AXSetRequestingClient");
    if (!runtime.setRequestingClient) { runtime.setRequestingClient = (CloudCodeHostAXSetRequestingClientFn)CloudCodeHostAXResolveAcrossFrameworks("__AXSetRequestingClient"); }
    if (!runtime.setRequestingClient) { runtime.setRequestingClient = (CloudCodeHostAXSetRequestingClientFn)CloudCodeHostAXResolveAcrossFrameworks("AXSetRequestingClient"); }
    runtime.addAssociatedPid = (CloudCodeHostAXAddAssociatedPidFn)CloudCodeHostAXResolveAcrossFrameworks("_AXAddAssociatedPid");
    if (!runtime.addAssociatedPid) { runtime.addAssociatedPid = (CloudCodeHostAXAddAssociatedPidFn)CloudCodeHostAXResolveAcrossFrameworks("AXAddAssociatedPid"); }
    runtime.automationEnabled = (CloudCodeHostAXAutomationEnabledFn)CloudCodeHostAXResolveAcrossFrameworks("_AXSAutomationEnabled");
    runtime.setAutomationEnabled = (CloudCodeHostAXSetAutomationEnabledFn)CloudCodeHostAXResolveAcrossFrameworks("_AXSSetAutomationEnabled");
    runtime.valueGetTypeID = (CloudCodeHostAXValueGetTypeIDFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetTypeID");
    runtime.valueGetType = (CloudCodeHostAXValueGetTypeFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetType");
    runtime.valueGetValue = (CloudCodeHostAXValueGetValueFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetValue");
    if (runtime.setRequestingClient) {
        @try { runtime.setRequestingClient(2); } @catch (__unused NSException *exception) {}
    }
    return runtime;
}

typedef struct {
    CloudCodeHostAXSetAutomationEnabledFn setter;
    int original;
    BOOL changed;
    BOOL active;
} CloudCodeHostAXAutomationLease;

static CloudCodeHostAXAutomationLease CloudCodeHostAXAcquireAutomationLease(CloudCodeHostAXRuntime runtime)
{
    CloudCodeHostAXAutomationLease lease = {0};
    lease.setter = runtime.setAutomationEnabled;
    lease.original = -1;
    if (!runtime.automationEnabled || !runtime.setAutomationEnabled) { return lease; }
    int before = -1;
    @try { before = runtime.automationEnabled(); } @catch (__unused NSException *exception) { before = -1; }
    lease.original = before;
    if (before == 0) {
        @try { runtime.setAutomationEnabled(1); } @catch (__unused NSException *exception) {}
        usleep(20000);
        int after = 0;
        @try { after = runtime.automationEnabled(); } @catch (__unused NSException *exception) { after = 0; }
        lease.changed = after != 0;
        lease.active = after != 0;
    } else {
        lease.active = before > 0;
    }
    return lease;
}

static void CloudCodeHostAXAutomationLeaseCleanup(CloudCodeHostAXAutomationLease *lease)
{
    if (!lease || !lease->changed || !lease->setter || lease->original < 0) { return; }
    @try { lease->setter(lease->original); } @catch (__unused NSException *exception) {}
    lease->changed = NO;
}

static os_unfair_lock CloudCodeHostAXProcessLock = OS_UNFAIR_LOCK_INIT;

typedef struct {
    BOOL held;
} CloudCodeHostAXCallLease;

static CloudCodeHostAXCallLease CloudCodeHostAXAcquireCallLease(void)
{
    CloudCodeHostAXCallLease lease = {0};
    lease.held = os_unfair_lock_trylock(&CloudCodeHostAXProcessLock);
    return lease;
}

static void CloudCodeHostAXCallLeaseCleanup(CloudCodeHostAXCallLease *lease)
{
    if (lease && lease->held) {
        os_unfair_lock_unlock(&CloudCodeHostAXProcessLock);
        lease->held = NO;
    }
}

static id CloudCodeHostAXCopy(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, CFStringRef attribute)
{
    if (!runtime.copyAttribute || !element || !attribute) { return nil; }
    CFTypeRef value = NULL;
    CloudCodeHostAXError code = -1;
    @try { code = runtime.copyAttribute(element, attribute, &value); }
    @catch (__unused NSException *exception) { value = NULL; }
    if (code != 0 || !value) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

static NSArray *CloudCodeHostAXCopyMany(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, NSArray *attributes)
{
    if (!runtime.copyMultipleAttributes || !element || attributes.count == 0) { return nil; }
    CFArrayRef values = NULL;
    CloudCodeHostAXError code = -1;
    @try { code = runtime.copyMultipleAttributes(element, (__bridge CFArrayRef)attributes, 0, &values); }
    @catch (__unused NSException *exception) { values = NULL; }
    if (code != 0 || !values) { if (values) CFRelease(values); return nil; }
    NSArray *bridged = CFBridgingRelease(values);
    return bridged.count == attributes.count ? bridged : nil;
}

static BOOL CloudCodeHostAXValueRepresentsError(CloudCodeHostAXRuntime runtime, id value)
{
    if (!value || !runtime.valueGetType || !runtime.valueGetTypeID) { return NO; }
    CFTypeRef ref = (__bridge CFTypeRef)value;
    @try { return CFGetTypeID(ref) == runtime.valueGetTypeID() && runtime.valueGetType(ref) == 5; }
    @catch (__unused NSException *exception) { return NO; }
}

static NSString *CloudCodeHostAXBoundedString(id value)
{
    if (!value || value == NSNull.null) { return nil; }
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) { text = value; }
    else if ([value isKindOfClass:NSNumber.class]) { text = [value stringValue]; }
    else {
        @try { text = [value description]; } @catch (__unused NSException *exception) { text = nil; }
    }
    if (text.length > 256) { text = [[text substringToIndex:256] stringByAppendingString:@"…"]; }
    return text.length > 0 ? text : nil;
}

static NSDictionary *CloudCodeHostAXFrame(CloudCodeHostAXRuntime runtime, id value)
{
    if (!value) { return nil; }
    CGRect frame = CGRectZero;
    BOOL ok = NO;
    if ([value isKindOfClass:NSValue.class]) {
        @try {
            [(NSValue *)value getValue:&frame size:sizeof(frame)];
            ok = YES;
        } @catch (__unused NSException *exception) { ok = NO; }
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

static NSDictionary *CloudCodeHostAXNode(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, NSUInteger depth, NSUInteger *nodeCount, CFAbsoluteTime deadline)
{
    if (!element || !nodeCount || depth > CLOUDCODE_HOST_AX_MAX_DEPTH || *nodeCount >= CLOUDCODE_HOST_AX_MAX_NODES || CFAbsoluteTimeGetCurrent() >= deadline) { return nil; }
    if (runtime.setTimeout) {
        @try { runtime.setTimeout(element, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {}
    }
    (*nodeCount)++;
    NSArray *keys = @[@"role", @"label", @"value", @"title", @"identifier", @"placeholder", @"frame", @"children"];
    NSArray *attrs = @[@"AXRole", @"AXLabel", @"AXValue", @"AXTitle", @"AXIdentifier", @"AXPlaceholderValue", @"AXFrame", @"AXChildren"];
    NSArray *values = CloudCodeHostAXCopyMany(runtime, element, attrs);
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    id childrenValue = nil;
    for (NSUInteger index = 0; index < attrs.count; index++) {
        if (!values && CFAbsoluteTimeGetCurrent() >= deadline) { break; }
        id raw = values ? values[index] : CloudCodeHostAXCopy(runtime, element, (__bridge CFStringRef)attrs[index]);
        if (raw == NSNull.null || CloudCodeHostAXValueRepresentsError(runtime, raw)) { raw = nil; }
        NSString *key = keys[index];
        if ([key isEqualToString:@"frame"]) {
            NSDictionary *frame = CloudCodeHostAXFrame(runtime, raw);
            if (frame) { node[key] = frame; }
        } else if ([key isEqualToString:@"children"]) {
            childrenValue = raw;
        } else {
            NSString *text = CloudCodeHostAXBoundedString(raw);
            if (text) { node[key] = text; }
        }
    }
    if ([childrenValue isKindOfClass:NSArray.class] && depth < CLOUDCODE_HOST_AX_MAX_DEPTH) {
        NSMutableArray *children = [NSMutableArray array];
        for (id child in (NSArray *)childrenValue) {
            if (*nodeCount >= CLOUDCODE_HOST_AX_MAX_NODES || CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            CloudCodeHostAXUIElementRef childElement = (CloudCodeHostAXUIElementRef)(__bridge CFTypeRef)child;
            NSDictionary *childNode = CloudCodeHostAXNode(runtime, childElement, depth + 1, nodeCount, deadline);
            if (childNode) { [children addObject:childNode]; }
        }
        if (children.count > 0) { node[@"children"] = children; }
    }
    return node;
}

static NSUInteger CloudCodeHostAXSemanticCount(NSDictionary *node)
{
    if (![node isKindOfClass:NSDictionary.class]) { return 0; }
    BOOL semantic = NO;
    for (NSString *key in @[@"label", @"value", @"title", @"identifier", @"placeholder"]) {
        NSString *text = [node[key] isKindOfClass:NSString.class] ? node[key] : nil;
        if (text.length > 0) { semantic = YES; break; }
    }
    NSString *role = [node[@"role"] isKindOfClass:NSString.class] ? node[@"role"] : nil;
    if (!semantic && role.length > 0 && ![role containsString:@"Application"] && ![role containsString:@"Window"] && [node[@"frame"] isKindOfClass:NSDictionary.class]) { semantic = YES; }
    NSUInteger total = semantic ? 1 : 0;
    for (id child in [node[@"children"] isKindOfClass:NSArray.class] ? node[@"children"] : @[]) {
        if ([child isKindOfClass:NSDictionary.class]) { total += CloudCodeHostAXSemanticCount(child); }
    }
    return total;
}

static NSUInteger CloudCodeHostAXActionableCount(NSDictionary *node)
{
    if (![node isKindOfClass:NSDictionary.class]) { return 0; }
    NSString *role = [node[@"role"] isKindOfClass:NSString.class] ? node[@"role"] : @"";
    BOOL actionable = [node[@"frame"] isKindOfClass:NSDictionary.class] && (
        [role localizedCaseInsensitiveContainsString:@"Button"] ||
        [role localizedCaseInsensitiveContainsString:@"TextField"] ||
        [role localizedCaseInsensitiveContainsString:@"TextArea"] ||
        [role localizedCaseInsensitiveContainsString:@"TextView"] ||
        [role localizedCaseInsensitiveContainsString:@"SearchField"] ||
        [role localizedCaseInsensitiveContainsString:@"Link"] ||
        [role localizedCaseInsensitiveContainsString:@"Cell"] ||
        [role localizedCaseInsensitiveContainsString:@"Tab"]
    );
    NSUInteger total = actionable ? 1 : 0;
    for (id child in [node[@"children"] isKindOfClass:NSArray.class] ? node[@"children"] : @[]) {
        if ([child isKindOfClass:NSDictionary.class]) { total += CloudCodeHostAXActionableCount(child); }
    }
    return total;
}

static NSString *CloudCodeHostFrontmostBundleID(void)
{
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY | RTLD_LOCAL);
    CloudCodeHostCopyFrontmostBundleIDFn fn = handle ? (CloudCodeHostCopyFrontmostBundleIDFn)dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier") : NULL;
    if (!fn) { fn = (CloudCodeHostCopyFrontmostBundleIDFn)dlsym(RTLD_DEFAULT, "SBSCopyFrontmostApplicationDisplayIdentifier"); }
    if (!fn) { return nil; }
    CFStringRef value = NULL;
    @try { value = fn(); } @catch (__unused NSException *exception) { value = NULL; }
    if (!value) { return nil; }
    NSString *bundle = [(__bridge NSString *)value copy];
    CFRelease(value);
    return bundle.length > 0 ? bundle : nil;
}

static NSString *CloudCodeHostBundleIDForPID(pid_t pid)
{
    if (pid <= 0) { return nil; }
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY | RTLD_LOCAL);
    CloudCodeHostCopyBundleIDForPidFn fn = handle ? (CloudCodeHostCopyBundleIDForPidFn)dlsym(handle, "SBSCopyDisplayIdentifierForProcessID") : NULL;
    if (!fn) { fn = (CloudCodeHostCopyBundleIDForPidFn)dlsym(RTLD_DEFAULT, "SBSCopyDisplayIdentifierForProcessID"); }
    if (!fn) { return nil; }
    CFStringRef value = NULL;
    @try { value = fn(pid); } @catch (__unused NSException *exception) { value = NULL; }
    if (!value) { return nil; }
    NSString *bundle = [(__bridge NSString *)value copy];
    CFRelease(value);
    return bundle.length > 0 ? bundle : nil;
}

static NSString *CloudCodeHostBundlePath(NSString *bundleID)
{
    if (bundleID.length == 0) { return nil; }
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) { return nil; }
    id (*sendObject)(id, SEL, id) = (void *)objc_msgSend;
    id proxy = nil;
    @try { proxy = sendObject(proxyClass, selector, bundleID); } @catch (__unused NSException *exception) { proxy = nil; }
    NSURL *bundleURL = nil;
    @try { if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) { bundleURL = [proxy valueForKey:@"bundleURL"]; } }
    @catch (__unused NSException *exception) { bundleURL = nil; }
    return [bundleURL isKindOfClass:NSURL.class] ? bundleURL.path.stringByStandardizingPath : nil;
}

static NSString *CloudCodeHostCanonicalProcessPath(NSString *path)
{
    NSString *normalized = [path isKindOfClass:NSString.class] ? path.stringByStandardizingPath : nil;
    // On iOS 16.6 LaunchServices reports app bundles under /private/var while proc_pidpath/DVT can
    // report the same vnode under /var. Treat the /private alias as equivalent before comparing.
    if ([normalized hasPrefix:@"/private/var/"]) {
        normalized = [normalized substringFromIndex:@"/private".length];
    }
    return normalized;
}

static pid_t CloudCodeHostPIDForBundlePath(NSString *bundlePath)
{
    NSString *canonicalBundlePath = CloudCodeHostCanonicalProcessPath(bundlePath);
    if (canonicalBundlePath.length == 0) { return 0; }
    CloudCodeHostProcListAllPidsFn listPids = (CloudCodeHostProcListAllPidsFn)dlsym(RTLD_DEFAULT, "proc_listallpids");
    CloudCodeHostProcPidPathFn pidPath = (CloudCodeHostProcPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (!listPids || !pidPath) { return 0; }
    pid_t pids[4096] = {0};
    int count = listPids(pids, sizeof(pids));
    NSString *prefix = [canonicalBundlePath stringByAppendingString:@"/"];
    for (int index = 0; index < count && index < 4096; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) { continue; }
        char buffer[4096] = {0};
        if (pidPath(pid, buffer, sizeof(buffer)) <= 0) { continue; }
        NSString *path = CloudCodeHostCanonicalProcessPath([NSString stringWithUTF8String:buffer]);
        if ([path isEqualToString:canonicalBundlePath] || [path hasPrefix:prefix]) { return pid; }
    }
    return 0;
}

static CloudCodeHostAXUIElementRef CloudCodeHostAXRootForPID(CloudCodeHostAXRuntime runtime, pid_t pid)
{
    if (pid <= 0) { return NULL; }
    CloudCodeHostAXUIElementRef root = NULL;
    if (runtime.createApplication) {
        @try { root = runtime.createApplication(pid); } @catch (__unused NSException *exception) { root = NULL; }
    }
    if (!root && runtime.createAppElementWithPid) {
        @try { root = runtime.createAppElementWithPid(pid); } @catch (__unused NSException *exception) { root = NULL; }
    }
    if (root && runtime.setTimeout) {
        @try { runtime.setTimeout(root, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {}
    }
    return root;
}

static CloudCodeHostAXUIElementRef CloudCodeHostAXFocusedApplication(CloudCodeHostAXRuntime runtime, pid_t *pidOut)
{
    if (!runtime.createSystemWide || !runtime.copyAttribute) { return NULL; }
    CloudCodeHostAXUIElementRef systemWide = NULL;
    @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
    if (!systemWide) { return NULL; }
    if (runtime.setTimeout) { @try { runtime.setTimeout(systemWide, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {} }
    CloudCodeHostAXUIElementRef result = NULL;
    for (NSString *attribute in @[@"AXFocusedApplication", @"AXFrontmostApplication"]) {
        id value = CloudCodeHostAXCopy(runtime, systemWide, (__bridge CFStringRef)attribute);
        if (!value) { continue; }
        CloudCodeHostAXUIElementRef candidate = (CloudCodeHostAXUIElementRef)(__bridge CFTypeRef)value;
        pid_t pid = 0;
        CloudCodeHostAXError code = runtime.getPid ? runtime.getPid(candidate, &pid) : -1;
        if (code == 0 && pid > 0 && pid != getpid()) {
            CFRetain(candidate);
            result = candidate;
            if (pidOut) { *pidOut = pid; }
            break;
        }
    }
    CFRelease(systemWide);
    if (result && runtime.setTimeout) { @try { runtime.setTimeout(result, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {} }
    return result;
}

static CloudCodeHostAXUIElementRef CloudCodeHostAXFocusedElement(CloudCodeHostAXRuntime runtime, pid_t *pidOut)
{
    if (!runtime.createSystemWide || !runtime.copyAttribute) { return NULL; }
    CloudCodeHostAXUIElementRef systemWide = NULL;
    @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
    if (systemWide) {
        if (runtime.setTimeout) { @try { runtime.setTimeout(systemWide, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {} }
        for (NSString *attribute in @[@"AXFocusedUIElement", @"AXFocusedElement"]) {
            id value = CloudCodeHostAXCopy(runtime, systemWide, (__bridge CFStringRef)attribute);
            if (!value) { continue; }
            CloudCodeHostAXUIElementRef candidate = (CloudCodeHostAXUIElementRef)(__bridge CFTypeRef)value;
            CFRetain(candidate);
            if (runtime.getPid && pidOut) { pid_t pid = 0; if (runtime.getPid(candidate, &pid) == 0) { *pidOut = pid; } }
            CFRelease(systemWide);
            return candidate;
        }
        CFRelease(systemWide);
    }
    pid_t appPID = 0;
    CloudCodeHostAXUIElementRef app = CloudCodeHostAXFocusedApplication(runtime, &appPID);
    if (!app) { return NULL; }
    CloudCodeHostAXUIElementRef result = NULL;
    for (NSString *attribute in @[@"AXFocusedUIElement", @"AXFocusedElement"]) {
        id value = CloudCodeHostAXCopy(runtime, app, (__bridge CFStringRef)attribute);
        if (!value) { continue; }
        result = (CloudCodeHostAXUIElementRef)(__bridge CFTypeRef)value;
        CFRetain(result);
        break;
    }
    CFRelease(app);
    if (result && pidOut) { *pidOut = appPID; }
    return result;
}

static NSValue *CloudCodeHostAXPointValue(CGPoint point)
{
    return [[NSValue alloc] initWithBytes:&point objCType:@encode(CGPoint)];
}

static uint32_t CloudCodeHostAXContextIDAtPoint(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef seed, CGPoint point, pid_t expectedPID)
{
    if (!seed || !runtime.copyParameterizedAttributeValue) { return 0; }
    CFTypeRef axPoint = NULL;
    if (runtime.valueCreate) {
        @try { axPoint = runtime.valueCreate(1, &point); } @catch (__unused NSException *exception) { axPoint = NULL; }
    }
    id pointValue = axPoint ? (__bridge id)axPoint : CloudCodeHostAXPointValue(point);
    uint32_t contextID = 0;
    for (NSNumber *displayID in @[@1, @0]) {
        NSArray *parameter = @[pointValue, displayID];
        CFTypeRef value = NULL;
        CloudCodeHostAXError code = -1;
        @try {
            code = runtime.copyParameterizedAttributeValue(seed, (CFStringRef)(uintptr_t)0x16573, (__bridge CFTypeRef)parameter, &value);
        } @catch (__unused NSException *exception) {
            code = -1;
            value = NULL;
        }
        if (code == 0 && value) {
            id bridged = (__bridge id)value;
            if ([bridged respondsToSelector:@selector(unsignedIntValue)]) { contextID = [bridged unsignedIntValue]; }
            CFRelease(value);
        } else if (value) {
            CFRelease(value);
        }
        if (contextID > 0) { break; }
    }
    if (axPoint) { CFRelease(axPoint); }
    if (contextID == 0 || expectedPID <= 0) { return contextID; }

    NSDictionary *parameter = @{@"contextId": @(contextID)};
    CFTypeRef pidValue = NULL;
    CloudCodeHostAXError pidCode = -1;
    @try {
        pidCode = runtime.copyParameterizedAttributeValue(seed, (CFStringRef)(uintptr_t)0x16574, (__bridge CFTypeRef)parameter, &pidValue);
    } @catch (__unused NSException *exception) {
        pidCode = -1;
        pidValue = NULL;
    }
    pid_t contextPID = 0;
    if (pidCode == 0 && pidValue) {
        id bridged = (__bridge id)pidValue;
        if ([bridged respondsToSelector:@selector(intValue)]) { contextPID = (pid_t)[bridged intValue]; }
    }
    if (pidValue) { CFRelease(pidValue); }
    return contextPID > 0 && contextPID != expectedPID ? 0 : contextID;
}

static CloudCodeHostAXUIElementRef CloudCodeHostAXContextElementAtPoint(
    CloudCodeHostAXRuntime runtime,
    CloudCodeHostAXUIElementRef systemWide,
    pid_t expectedPID,
    CGPoint point,
    uint32_t *contextIDOut,
    NSString **routeOut
) {
    if (!systemWide || expectedPID <= 0) { return NULL; }
    CloudCodeHostAXUIElementRef application = NULL;
    uint32_t contextID = 0;
    CloudCodeHostAXError applicationCode = -1;
    if (runtime.copyApplicationAndContextAtPosition) {
        @try {
            applicationCode = runtime.copyApplicationAndContextAtPosition(systemWide, &application, &contextID, (float)point.x, (float)point.y);
        } @catch (__unused NSException *exception) {
            applicationCode = -1;
            application = NULL;
            contextID = 0;
        }
    }
    if ((applicationCode != 0 || !application) && runtime.copyApplicationAtPosition) {
        if (application) { CFRelease(application); application = NULL; }
        @try {
            applicationCode = runtime.copyApplicationAtPosition(systemWide, &application, (float)point.x, (float)point.y);
        } @catch (__unused NSException *exception) {
            applicationCode = -1;
            application = NULL;
        }
    }
    if (contextID == 0) { contextID = CloudCodeHostAXContextIDAtPoint(runtime, systemWide, point, expectedPID); }

    if (application && runtime.getPid) {
        pid_t applicationPID = 0;
        CloudCodeHostAXError pidCode = -1;
        @try { pidCode = runtime.getPid(application, &applicationPID); } @catch (__unused NSException *exception) { pidCode = -1; }
        if (pidCode == 0 && applicationPID > 0 && applicationPID != expectedPID) {
            CFRelease(application);
            application = NULL;
        }
    }
    if (!application) { application = CloudCodeHostAXRootForPID(runtime, expectedPID); }
    if (!application) { return NULL; }

    CloudCodeHostAXUIElementRef candidate = NULL;
    if (contextID > 0 && runtime.copyElementUsingContextIdAtPosition) {
        CloudCodeHostAXError code = -1;
        @try {
            code = runtime.copyElementUsingContextIdAtPosition(application, contextID, &candidate, 0, (float)point.x, (float)point.y);
        } @catch (__unused NSException *exception) {
            code = -1;
            candidate = NULL;
        }
        if (code == 0 && candidate && routeOut) { *routeOut = @"contextIdAtPosition"; }
        if (code != 0 && candidate) { CFRelease(candidate); candidate = NULL; }
    }
    if (!candidate && runtime.copyElementUsingDisplayIdAtPosition) {
        CloudCodeHostAXError code = -1;
        @try {
            code = runtime.copyElementUsingDisplayIdAtPosition(application, 1, &candidate, 0, (float)point.x, (float)point.y);
        } @catch (__unused NSException *exception) {
            code = -1;
            candidate = NULL;
        }
        if (code == 0 && candidate && routeOut) { *routeOut = @"displayIdAtPosition"; }
        if (code != 0 && candidate) { CFRelease(candidate); candidate = NULL; }
    }
    if (!candidate && runtime.copyElementWithParameters) {
        NSMutableDictionary *parameters = [@{
            @"application": (__bridge id)application,
            @"point": CloudCodeHostAXPointValue(point),
            @"displayId": @1
        } mutableCopy];
        if (contextID > 0) { parameters[@"contextId"] = @(contextID); }
        CloudCodeHostAXError code = -1;
        @try { code = runtime.copyElementWithParameters(&candidate, (__bridge CFDictionaryRef)parameters); }
        @catch (__unused NSException *exception) { code = -1; candidate = NULL; }
        if (code == 0 && candidate && routeOut) { *routeOut = @"elementWithParameters"; }
        if (code != 0 && candidate) { CFRelease(candidate); candidate = NULL; }
    }
    CFRelease(application);

    if (candidate && runtime.getPid) {
        pid_t candidatePID = 0;
        CloudCodeHostAXError pidCode = -1;
        @try { pidCode = runtime.getPid(candidate, &candidatePID); } @catch (__unused NSException *exception) { pidCode = -1; }
        if (pidCode == 0 && candidatePID > 0 && candidatePID != expectedPID) {
            CFRelease(candidate);
            candidate = NULL;
        }
    }
    if (candidate && runtime.setTimeout) {
        @try { runtime.setTimeout(candidate, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {}
    }
    if (candidate && contextIDOut) { *contextIDOut = contextID; }
    return candidate;
}

static CGSize CloudCodeHostAXScreenSize(void)
{
    Class screenClass = NSClassFromString(@"UIScreen");
    SEL mainScreenSelector = NSSelectorFromString(@"mainScreen");
    SEL boundsSelector = NSSelectorFromString(@"bounds");
    if (!screenClass || ![screenClass respondsToSelector:mainScreenSelector]) { return CGSizeZero; }
    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
    id screen = nil;
    @try { screen = sendObject(screenClass, mainScreenSelector); } @catch (__unused NSException *exception) { screen = nil; }
    if (!screen || ![screen respondsToSelector:boundsSelector]) { return CGSizeZero; }
    CGRect (*sendRect)(id, SEL) = (void *)objc_msgSend;
    CGRect bounds = CGRectZero;
    @try { bounds = sendRect(screen, boundsSelector); } @catch (__unused NSException *exception) { bounds = CGRectZero; }
    return bounds.size;
}

static NSDictionary *CloudCodeHostAXSampledTree(CloudCodeHostAXRuntime runtime, pid_t expectedPID, CFAbsoluteTime deadline, NSUInteger *nodeCountOut, NSString **routeOut)
{
    if (expectedPID <= 0 || !runtime.createSystemWide || (!runtime.copyElementAtPosition && !runtime.copyElementWithParameters && !runtime.copyElementUsingContextIdAtPosition)) { return nil; }
    CGSize size = CloudCodeHostAXScreenSize();
    if (size.width <= 1 || size.height <= 1) { return nil; }
    CloudCodeHostAXUIElementRef systemWide = NULL;
    @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
    if (!systemWide) { return nil; }
    if (runtime.setTimeout) {
        @try { runtime.setTimeout(systemWide, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {}
    }

    const CGPoint points[] = {
        {size.width * 0.50, size.height * 0.10},
        {size.width * 0.50, size.height * 0.22},
        {size.width * 0.50, size.height * 0.50},
        {size.width * 0.50, size.height * 0.84},
        {size.width * 0.88, size.height * 0.38},
        {size.width * 0.88, size.height * 0.58},
        {size.width * 0.88, size.height * 0.78}
    };
    NSMutableArray *hits = [NSMutableArray array];
    NSMutableSet<NSString *> *dedupe = [NSMutableSet set];
    NSUInteger totalNodes = 0;
    for (NSUInteger index = 0; index < sizeof(points) / sizeof(points[0]); index++) {
        if (CFAbsoluteTimeGetCurrent() >= deadline || totalNodes >= CLOUDCODE_HOST_AX_MAX_NODES) { break; }
        CloudCodeHostAXUIElementRef candidate = NULL;
        NSString *hitRoute = @"elementAtPosition";
        uint32_t contextID = 0;
        if (runtime.copyElementAtPosition) {
            CloudCodeHostAXError code = -1;
            @try { code = runtime.copyElementAtPosition(systemWide, &candidate, (float)points[index].x, (float)points[index].y); }
            @catch (__unused NSException *exception) { code = -1; candidate = NULL; }
            if (code != 0 && candidate) { CFRelease(candidate); candidate = NULL; }
        }
        if (candidate && runtime.getPid) {
            pid_t candidatePID = 0;
            CloudCodeHostAXError pidCode = -1;
            @try { pidCode = runtime.getPid(candidate, &candidatePID); } @catch (__unused NSException *exception) { pidCode = -1; }
            if (pidCode == 0 && candidatePID > 0 && candidatePID != expectedPID) {
                CFRelease(candidate);
                candidate = NULL;
            }
        }
        NSUInteger localCount = 0;
        CFAbsoluteTime sampleDeadline = MIN(deadline, CFAbsoluteTimeGetCurrent() + 0.14);
        NSDictionary *node = candidate ? CloudCodeHostAXNode(runtime, candidate, 0, &localCount, sampleDeadline) : nil;
        if (candidate) { CFRelease(candidate); candidate = NULL; }
        if (!node || CloudCodeHostAXSemanticCount(node) == 0) {
            candidate = CloudCodeHostAXContextElementAtPoint(runtime, systemWide, expectedPID, points[index], &contextID, &hitRoute);
            localCount = 0;
            sampleDeadline = MIN(deadline, CFAbsoluteTimeGetCurrent() + 0.14);
            node = candidate ? CloudCodeHostAXNode(runtime, candidate, 0, &localCount, sampleDeadline) : nil;
            if (candidate) { CFRelease(candidate); candidate = NULL; }
        }
        if (!node || CloudCodeHostAXSemanticCount(node) == 0) { continue; }
        NSMutableDictionary *annotated = [node mutableCopy];
        annotated[@"hitPoint"] = @{@"x": @(points[index].x), @"y": @(points[index].y)};
        annotated[@"hitRoute"] = hitRoute;
        if (contextID > 0) { annotated[@"contextId"] = @(contextID); }
        NSString *dedupeKey = [NSString stringWithFormat:@"%@|%@|%@|%@", annotated[@"role"] ?: @"", annotated[@"label"] ?: @"", annotated[@"identifier"] ?: @"", annotated[@"frame"] ?: @""];
        if ([dedupe containsObject:dedupeKey]) { continue; }
        [dedupe addObject:dedupeKey];
        totalNodes += MAX((NSUInteger)1, localCount);
        [hits addObject:annotated];
    }
    CFRelease(systemWide);
    if (hits.count == 0) { return nil; }
    if (nodeCountOut) { *nodeCountOut = totalNodes; }
    if (routeOut) { *routeOut = @"host-systemwide-context-hit-test"; }
    return @{
        @"role": @"AXHitTestSnapshot",
        @"scope": @"sampled_foreground_context",
        @"children": hits
    };
}

NSString *CloudCodeHostAXTreeJSON(NSString * _Nullable * _Nullable diagnostic)
{
    if (diagnostic) { *diagnostic = nil; }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    CloudCodeHostAXCallLease callLease __attribute__((cleanup(CloudCodeHostAXCallLeaseCleanup))) = CloudCodeHostAXAcquireCallLease();
    if (!callLease.held) {
        if (diagnostic) { *diagnostic = @"host AX semantic read already active; fail-fast to bounded fallback"; }
        return nil;
    }
    CloudCodeHostAXRuntime runtime = CloudCodeHostAXResolve();
    if ((!runtime.createApplication && !runtime.createAppElementWithPid && !runtime.createSystemWide) || !runtime.copyAttribute) {
        if (diagnostic) { *diagnostic = @"host AXRuntime required symbols unavailable"; }
        return nil;
    }
    CloudCodeHostAXAutomationLease automationLease __attribute__((cleanup(CloudCodeHostAXAutomationLeaseCleanup))) = CloudCodeHostAXAcquireAutomationLease(runtime);

    NSString *bundleID = CloudCodeHostFrontmostBundleID();
    NSString *bundlePath = CloudCodeHostBundlePath(bundleID);
    pid_t pid = CloudCodeHostPIDForBundlePath(bundlePath);
    CloudCodeHostAXUIElementRef root = NULL;
    NSString *route = @"frontmost-bundle";
    if (pid > 0) {
        if (runtime.addAssociatedPid) {
            runtime.addAssociatedPid(getpid(), pid, 0);
            runtime.addAssociatedPid(getpid(), pid, 1);
            runtime.addAssociatedPid(pid, getpid(), 0);
            runtime.addAssociatedPid(pid, getpid(), 1);
        }
        root = CloudCodeHostAXRootForPID(runtime, pid);
    }
    if (!root) {
        pid_t focusedPID = 0;
        root = CloudCodeHostAXFocusedApplication(runtime, &focusedPID);
        if (root) {
            pid = focusedPID;
            route = @"systemwide-focused-application";
            NSString *focusedBundle = CloudCodeHostBundleIDForPID(pid);
            if (focusedBundle.length > 0) { bundleID = focusedBundle; }
        }
    }
    if (!root) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"host AX foreground root unavailable; bundle=%@ pid=%d", bundleID ?: @"", pid];
        }
        return nil;
    }

    NSUInteger nodeCount = 0;
    CFAbsoluteTime deadline = started + CLOUDCODE_HOST_AX_TOTAL_BUDGET_SECONDS;
    NSDictionary *tree = CloudCodeHostAXNode(runtime, root, 0, &nodeCount, deadline);
    CFRelease(root);
    NSUInteger semanticNodeCount = CloudCodeHostAXSemanticCount(tree);
    NSUInteger actionableNodeCount = CloudCodeHostAXActionableCount(tree);
    NSUInteger directNodeCount = nodeCount;
    NSUInteger directSemanticNodeCount = semanticNodeCount;
    NSUInteger directActionableNodeCount = actionableNodeCount;
    NSString *scope = @"full_application_tree_opportunistic";
    if (!tree || nodeCount == 0 || semanticNodeCount == 0 || actionableNodeCount == 0) {
        NSUInteger sampledNodeCount = 0;
        NSString *sampledRoute = nil;
        NSDictionary *sampledTree = CloudCodeHostAXSampledTree(runtime, pid, deadline, &sampledNodeCount, &sampledRoute);
        NSUInteger sampledSemanticNodeCount = CloudCodeHostAXSemanticCount(sampledTree);
        NSUInteger sampledActionableNodeCount = CloudCodeHostAXActionableCount(sampledTree);
        if (sampledTree && sampledSemanticNodeCount > 0 && sampledActionableNodeCount > 0) {
            tree = sampledTree;
            nodeCount = sampledNodeCount;
            semanticNodeCount = sampledSemanticNodeCount;
            actionableNodeCount = sampledActionableNodeCount;
            route = sampledRoute ?: @"host-systemwide-context-hit-test";
            scope = @"sampled_foreground_context";
        }
    }
    if (!tree || nodeCount == 0 || semanticNodeCount == 0 || actionableNodeCount == 0) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"host AX transport responded but semantic/actionable tree insufficient after context-aware fallback; bundle=%@ pid=%d directNodes=%lu directSemantic=%lu directActionable=%lu finalNodes=%lu finalSemantic=%lu finalActionable=%lu latencyMS=%.1f", bundleID ?: @"", pid, (unsigned long)directNodeCount, (unsigned long)directSemanticNodeCount, (unsigned long)directActionableNodeCount, (unsigned long)nodeCount, (unsigned long)semanticNodeCount, (unsigned long)actionableNodeCount, (CFAbsoluteTimeGetCurrent() - started) * 1000.0];
        }
        return nil;
    }
    NSDictionary *payload = @{
        @"backend": @"AXRuntime.host-system-app",
        @"scope": scope,
        @"route": route,
        @"bundleId": bundleID ?: @"",
        @"pid": @(pid),
        @"automationLeaseActive": @(automationLease.active),
        @"nodeCount": @(nodeCount),
        @"semanticNodeCount": @(semanticNodeCount),
        @"actionableNodeCount": @(actionableNodeCount),
        @"latencyMS": @((NSInteger)MAX(0.0, (CFAbsoluteTimeGetCurrent() - started) * 1000.0)),
        @"tree": tree
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json || json.length == 0 || json.length > CLOUDCODE_HOST_AX_MAX_BYTES) {
        if (diagnostic) { *diagnostic = @"host AX tree JSON unavailable or exceeded 256 KiB"; }
        return nil;
    }
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"host AX semantic tree verified; bundle=%@ pid=%d route=%@ scope=%@ semantic=%lu actionable=%lu", bundleID ?: @"", pid, route, scope, (unsigned long)semanticNodeCount, (unsigned long)actionableNodeCount];
    }
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

NSString *CloudCodeHostAXFocusedTextInputJSON(NSString * _Nullable * _Nullable diagnostic)
{
    if (diagnostic) { *diagnostic = nil; }
    CloudCodeHostAXCallLease callLease __attribute__((cleanup(CloudCodeHostAXCallLeaseCleanup))) = CloudCodeHostAXAcquireCallLease();
    if (!callLease.held) {
        if (diagnostic) { *diagnostic = @"host AX focused-text read already active; fail-fast to bounded fallback"; }
        return nil;
    }
    CloudCodeHostAXRuntime runtime = CloudCodeHostAXResolve();
    BOOL runtimeAvailable = runtime.copyAttribute != NULL && runtime.createSystemWide != NULL;
    CloudCodeHostAXAutomationLease automationLease __attribute__((cleanup(CloudCodeHostAXAutomationLeaseCleanup))) = CloudCodeHostAXAcquireAutomationLease(runtime);
    BOOL focusedElementAvailable = NO;
    BOOL focusedTextInput = NO;
    pid_t pid = 0;
    NSString *role = @"";
    if (runtimeAvailable) {
        CloudCodeHostAXUIElementRef element = CloudCodeHostAXFocusedElement(runtime, &pid);
        if (element) {
            focusedElementAvailable = YES;
            role = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, CFSTR("AXRole"))) ?: @"";
            focusedTextInput =
                [role rangeOfString:@"TextField" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [role rangeOfString:@"TextArea" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [role rangeOfString:@"TextView" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [role rangeOfString:@"SearchField" options:NSCaseInsensitiveSearch].location != NSNotFound;
            CFRelease(element);
        }
    }
    NSDictionary *payload = @{
        @"runtimeAvailable": @(runtimeAvailable),
        @"focusedElementAvailable": @(focusedElementAvailable),
        @"focusedTextInput": @(focusedTextInput),
        @"role": role,
        @"backend": @"AXRuntime.host-system-app",
        @"automationLeaseActive": @(automationLease.active),
        @"pid": @(pid)
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json || json.length > 4096) {
        if (diagnostic) { *diagnostic = @"host AX focused-text JSON serialization failed"; }
        return nil;
    }
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"host AX focused text probe runtime=%d element=%d text=%d pid=%d role=%@", runtimeAvailable, focusedElementAvailable, focusedTextInput, pid, role];
    }
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}
