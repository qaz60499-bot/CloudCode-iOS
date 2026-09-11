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

static pid_t CloudCodeHostPIDForBundlePath(NSString *bundlePath)
{
    if (bundlePath.length == 0) { return 0; }
    CloudCodeHostProcListAllPidsFn listPids = (CloudCodeHostProcListAllPidsFn)dlsym(RTLD_DEFAULT, "proc_listallpids");
    CloudCodeHostProcPidPathFn pidPath = (CloudCodeHostProcPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
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
    if (!tree || nodeCount == 0 || semanticNodeCount == 0 || actionableNodeCount == 0) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"host AX transport responded but semantic/actionable tree insufficient; bundle=%@ pid=%d nodes=%lu semantic=%lu actionable=%lu latencyMS=%.1f", bundleID ?: @"", pid, (unsigned long)nodeCount, (unsigned long)semanticNodeCount, (unsigned long)actionableNodeCount, (CFAbsoluteTimeGetCurrent() - started) * 1000.0];
        }
        return nil;
    }
    NSDictionary *payload = @{
        @"backend": @"AXRuntime.host-system-app",
        @"scope": @"full_application_tree_opportunistic",
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
        *diagnostic = [NSString stringWithFormat:@"host AX semantic tree verified; bundle=%@ pid=%d semantic=%lu actionable=%lu", bundleID ?: @"", pid, (unsigned long)semanticNodeCount, (unsigned long)actionableNodeCount];
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
