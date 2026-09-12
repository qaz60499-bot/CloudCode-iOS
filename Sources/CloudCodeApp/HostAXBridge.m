#import "RootHelperBridge.h"
#import "PerceptionProcessEvidence.h"

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
#define CLOUDCODE_HOST_AX_PROBE_BUDGET_SECONDS 2.50

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
    CloudCodeHostAXValueGetTypeIDFn valueGetTypeID;
    CloudCodeHostAXValueGetTypeFn valueGetType;
    CloudCodeHostAXValueGetValueFn valueGetValue;
    CFStringRef xcElementType;
    CFStringRef xcElementBaseType;
    CFStringRef xcLabel;
    CFStringRef xcValue;
    CFStringRef xcIdentifier;
    CFStringRef xcPlaceholderValue;
    CFStringRef xcFrame;
    CFStringRef xcVisibleFrame;
    CFStringRef xcChildren;
    CFStringRef xcChildrenCount;
    CFStringRef xcUserTestingElements;
    CFStringRef xcUserTestingSnapshot;
    CFStringRef xcWindowContextId;
    CFStringRef xcWindowDisplayId;
    CFStringRef xcIsRemoteElement;
    CFStringRef xcIsVisible;
    CFStringRef xcIsUserInteractionEnabled;
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

static CFStringRef CloudCodeHostAXResolveCFStringConstant(const char *name)
{
    void *symbol = CloudCodeHostAXResolveAcrossFrameworks(name);
    if (!symbol) { return NULL; }
    @try { return *(CFStringRef *)symbol; }
    @catch (__unused NSException *exception) { return NULL; }
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
    runtime.valueGetTypeID = (CloudCodeHostAXValueGetTypeIDFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetTypeID");
    runtime.valueGetType = (CloudCodeHostAXValueGetTypeFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetType");
    runtime.valueGetValue = (CloudCodeHostAXValueGetValueFn)CloudCodeHostAXResolveAcrossFrameworks("AXValueGetValue");
    runtime.xcElementType = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeElementType");
    runtime.xcElementBaseType = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeElementBaseType");
    runtime.xcLabel = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeLabel");
    runtime.xcValue = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeValue");
    runtime.xcIdentifier = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeIdentifier");
    runtime.xcPlaceholderValue = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributePlaceholderValue");
    runtime.xcFrame = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeFrame");
    runtime.xcVisibleFrame = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeVisibleFrame");
    runtime.xcChildren = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeChildren");
    runtime.xcChildrenCount = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeChildrenCount");
    runtime.xcUserTestingElements = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeUserTestingElements");
    runtime.xcUserTestingSnapshot = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeUserTestingSnapshot");
    runtime.xcWindowContextId = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeWindowContextId");
    runtime.xcWindowDisplayId = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeWindowDisplayId");
    runtime.xcIsRemoteElement = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeIsRemoteElement");
    runtime.xcIsVisible = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeIsVisible");
    runtime.xcIsUserInteractionEnabled = CloudCodeHostAXResolveCFStringConstant("kAXXCAttributeIsUserInteractionEnabled");
    if (runtime.setRequestingClient) {
        @try { runtime.setRequestingClient(2); } @catch (__unused NSException *exception) {}
    }
    return runtime;
}

typedef struct {
    int observed;
    BOOL active;
} CloudCodeHostAXAutomationLease;

static CloudCodeHostAXAutomationLease CloudCodeHostAXObserveAutomationState(CloudCodeHostAXRuntime runtime)
{
    CloudCodeHostAXAutomationLease lease = {.observed = -1, .active = NO};
    if (!runtime.automationEnabled) { return lease; }
    @try { lease.observed = runtime.automationEnabled(); } @catch (__unused NSException *exception) { lease.observed = -1; }
    lease.active = lease.observed > 0;
    // Read-only by design. Never enable the system-wide Automation bit from the host process: if
    // the App is terminated while a private AX call is in flight there is no reliable cleanup path,
    // and the leaked global state can render the visible green automation frame over normal UI.
    return lease;
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

static BOOL CloudCodeHostAXValueRepresentsError(CloudCodeHostAXRuntime runtime, id value);

static id CloudCodeHostAXCopyFirst(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, const CFStringRef *attributes, NSUInteger count, NSString **sourceOut)
{
    if (!runtime.copyAttribute || !element || !attributes) { return nil; }
    for (NSUInteger index = 0; index < count; index++) {
        CFStringRef attribute = attributes[index];
        if (!attribute) { continue; }
        id value = CloudCodeHostAXCopy(runtime, element, attribute);
        if (!value || CloudCodeHostAXValueRepresentsError(runtime, value)) { continue; }
        if (sourceOut) {
            if ((uintptr_t)attribute < 0x10000) {
                *sourceOut = [NSString stringWithFormat:@"numeric:%lu", (unsigned long)(uintptr_t)attribute];
            } else {
                *sourceOut = @"xc";
            }
        }
        return value;
    }
    return nil;
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

static void CloudCodeHostAXAppendCandidateChildren(CloudCodeHostAXRuntime runtime, NSMutableArray *children, NSMutableSet<NSString *> *seen, id value)
{
    if (![value isKindOfClass:NSArray.class]) { return; }
    for (id child in (NSArray *)value) {
        if (!child || child == NSNull.null || CloudCodeHostAXValueRepresentsError(runtime, child)) { continue; }
        NSString *key = [NSString stringWithFormat:@"%p", (__bridge const void *)child];
        if ([seen containsObject:key]) { continue; }
        [seen addObject:key];
        [children addObject:child];
    }
}

static NSArray *CloudCodeHostAXFallbackChildren(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, NSString **sourceOut)
{
    NSMutableArray *children = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    const struct { CFStringRef attribute; __unsafe_unretained NSString *name; } candidates[] = {
        { runtime.xcChildren, @"xcChildren" },
        { runtime.xcUserTestingElements, @"xcUserTestingElements" },
        { (CFStringRef)(uintptr_t)3015, @"numeric3015VisibleElements" },
        { (CFStringRef)(uintptr_t)3022, @"numeric3022ExplorerElements" },
        { (CFStringRef)(uintptr_t)3025, @"numeric3025SemanticContext" },
        { (CFStringRef)(uintptr_t)3029, @"numeric3029NativeFocusable" },
        { (CFStringRef)(uintptr_t)5001, @"numeric5001PrivateChildren" }
    };
    for (NSUInteger index = 0; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
        if (!candidates[index].attribute) { continue; }
        id value = CloudCodeHostAXCopy(runtime, element, candidates[index].attribute);
        NSUInteger before = children.count;
        CloudCodeHostAXAppendCandidateChildren(runtime, children, seen, value);
        if (children.count > before) { [sources addObject:candidates[index].name]; }
    }
    if (sourceOut && sources.count > 0) { *sourceOut = [sources componentsJoinedByString:@"+"]; }
    return children;
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

    if (!node[@"role"]) {
        const CFStringRef fallbacks[] = { runtime.xcElementType, runtime.xcElementBaseType };
        NSString *source = nil;
        NSString *text = CloudCodeHostAXBoundedString(CloudCodeHostAXCopyFirst(runtime, element, fallbacks, 2, &source));
        if (text) { node[@"role"] = text; node[@"roleSource"] = source ?: @"xc"; }
    }
    if (!node[@"label"] && runtime.xcLabel) {
        NSString *text = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, runtime.xcLabel));
        if (text) { node[@"label"] = text; node[@"labelSource"] = @"xc"; }
    }
    if (!node[@"value"] && runtime.xcValue) {
        NSString *text = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, runtime.xcValue));
        if (text) { node[@"value"] = text; node[@"valueSource"] = @"xc"; }
    }
    if (!node[@"identifier"] && runtime.xcIdentifier) {
        NSString *text = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, runtime.xcIdentifier));
        if (text) { node[@"identifier"] = text; node[@"identifierSource"] = @"xc"; }
    }
    if (!node[@"placeholder"] && runtime.xcPlaceholderValue) {
        NSString *text = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, runtime.xcPlaceholderValue));
        if (text) { node[@"placeholder"] = text; node[@"placeholderSource"] = @"xc"; }
    }
    if (!node[@"frame"]) {
        const CFStringRef fallbacks[] = { runtime.xcVisibleFrame, runtime.xcFrame, (CFStringRef)(uintptr_t)2057 };
        NSString *source = nil;
        NSDictionary *frame = CloudCodeHostAXFrame(runtime, CloudCodeHostAXCopyFirst(runtime, element, fallbacks, 3, &source));
        if (frame) { node[@"frame"] = frame; node[@"frameSource"] = source ?: @"xc"; }
    }

    NSArray *candidateChildren = [childrenValue isKindOfClass:NSArray.class] ? (NSArray *)childrenValue : nil;
    NSString *childrenSource = candidateChildren.count > 0 ? @"AXChildren" : nil;
    if (candidateChildren.count == 0 && depth < CLOUDCODE_HOST_AX_MAX_DEPTH && CFAbsoluteTimeGetCurrent() < deadline) {
        candidateChildren = CloudCodeHostAXFallbackChildren(runtime, element, &childrenSource);
    }
    if (candidateChildren.count == 0 && depth <= 1 && runtime.xcUserTestingSnapshot && CFAbsoluteTimeGetCurrent() < deadline) {
        NSString *summary = CloudCodeHostAXBoundedString(CloudCodeHostAXCopy(runtime, element, runtime.xcUserTestingSnapshot));
        if (summary) { node[@"userTestingSnapshotSummary"] = summary; }
    }
    if (candidateChildren.count > 0 && depth < CLOUDCODE_HOST_AX_MAX_DEPTH) {
        NSMutableArray *children = [NSMutableArray array];
        for (id child in candidateChildren) {
            if (*nodeCount >= CLOUDCODE_HOST_AX_MAX_NODES || CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            CloudCodeHostAXUIElementRef childElement = (CloudCodeHostAXUIElementRef)(__bridge CFTypeRef)child;
            NSDictionary *childNode = CloudCodeHostAXNode(runtime, childElement, depth + 1, nodeCount, deadline);
            if (childNode) { [children addObject:childNode]; }
        }
        if (children.count > 0) {
            node[@"children"] = children;
            node[@"childrenSource"] = childrenSource ?: @"fallback";
        }
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
        [role localizedCaseInsensitiveContainsString:@"Switch"] ||
        [role localizedCaseInsensitiveContainsString:@"RadioButton"] ||
        [role localizedCaseInsensitiveContainsString:@"TabButton"] ||
        [role localizedCaseInsensitiveCompare:@"AXTab"] == NSOrderedSame
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
        // When CloudCode itself is frontmost, the System-app host is the process we want. Build
        // 123 incorrectly filtered getpid() here and therefore reported a real foreground bundle
        // with pid=0. Bundle-path matching below is already the identity guard.
        if (pid <= 1) { continue; }
        char buffer[4096] = {0};
        if (pidPath(pid, buffer, sizeof(buffer)) <= 0) { continue; }
        NSString *path = CloudCodeHostCanonicalProcessPath([NSString stringWithUTF8String:buffer]);
        if ([path isEqualToString:canonicalBundlePath] || [path hasPrefix:prefix]) { return pid; }
    }
    return 0;
}

static pid_t CloudCodeHostPIDForBundleID(NSString *bundleID)
{
    if (bundleID.length == 0) { return 0; }
    CloudCodeHostProcListAllPidsFn listPids = (CloudCodeHostProcListAllPidsFn)dlsym(RTLD_DEFAULT, "proc_listallpids");
    if (!listPids) { return 0; }
    pid_t pids[4096] = {0};
    int count = listPids(pids, sizeof(pids));
    for (int index = 0; index < count && index < 4096; index++) {
        pid_t pid = pids[index];
        if (pid <= 1) { continue; }
        NSString *candidate = CloudCodeHostBundleIDForPID(pid);
        if ([candidate isEqualToString:bundleID]) { return pid; }
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

// ios-mcp resolves the visible application through two parameterized AX queries rather than
// trusting process-local FrontBoard state: point+display -> context id (0x16573), then
// context id -> pid (0x16574). Keep this as a bounded identity fallback for the System-app host.
// If SpringBoardServices already supplied a frontmost bundle id, require the resolved pid to map
// back to the same bundle so a host/helper-local AX context cannot silently become the target.
static pid_t CloudCodeHostAXPIDAtScreenContext(
    CloudCodeHostAXRuntime runtime,
    CloudCodeHostAXUIElementRef systemWide,
    NSString *expectedBundleID,
    uint32_t *contextIDOut
) {
    if (!systemWide || !runtime.copyParameterizedAttributeValue) { return 0; }
    CGSize size = CloudCodeHostAXScreenSize();
    if (size.width <= 1 || size.height <= 1) { return 0; }
    const CGPoint points[] = {
        {size.width * 0.50, size.height * 0.50},
        {size.width * 0.50, size.height * 0.25},
        {size.width * 0.50, size.height * 0.75}
    };
    for (NSUInteger pointIndex = 0; pointIndex < sizeof(points) / sizeof(points[0]); pointIndex++) {
        CGPoint point = points[pointIndex];
        CFTypeRef axPoint = NULL;
        if (runtime.valueCreate) {
            @try { axPoint = runtime.valueCreate(1, &point); } @catch (__unused NSException *exception) { axPoint = NULL; }
        }
        id pointValue = axPoint ? (__bridge id)axPoint : CloudCodeHostAXPointValue(point);
        for (NSNumber *displayID in @[@1, @0]) {
            NSArray *pointParameter = @[pointValue, displayID];
            CFTypeRef contextValue = NULL;
            CloudCodeHostAXError contextCode = -1;
            @try {
                contextCode = runtime.copyParameterizedAttributeValue(
                    systemWide,
                    (CFStringRef)(uintptr_t)0x16573,
                    (__bridge CFTypeRef)pointParameter,
                    &contextValue
                );
            } @catch (__unused NSException *exception) {
                contextCode = -1;
                contextValue = NULL;
            }
            uint32_t contextID = 0;
            if (contextCode == 0 && contextValue) {
                id bridged = (__bridge id)contextValue;
                if ([bridged respondsToSelector:@selector(unsignedIntValue)]) {
                    contextID = [bridged unsignedIntValue];
                }
            }
            if (contextValue) { CFRelease(contextValue); }
            if (contextID == 0) { continue; }

            NSDictionary *pidParameter = @{@"contextId": @(contextID)};
            CFTypeRef pidValue = NULL;
            CloudCodeHostAXError pidCode = -1;
            @try {
                pidCode = runtime.copyParameterizedAttributeValue(
                    systemWide,
                    (CFStringRef)(uintptr_t)0x16574,
                    (__bridge CFTypeRef)pidParameter,
                    &pidValue
                );
            } @catch (__unused NSException *exception) {
                pidCode = -1;
                pidValue = NULL;
            }
            pid_t candidatePID = 0;
            if (pidCode == 0 && pidValue) {
                id bridged = (__bridge id)pidValue;
                if ([bridged respondsToSelector:@selector(intValue)]) {
                    candidatePID = (pid_t)[bridged intValue];
                }
            }
            if (pidValue) { CFRelease(pidValue); }
            if (candidatePID <= 1) { continue; }
            if (expectedBundleID.length > 0) {
                NSString *candidateBundle = CloudCodeHostBundleIDForPID(candidatePID);
                if (![candidateBundle isEqualToString:expectedBundleID]) { continue; }
            }
            if (contextIDOut) { *contextIDOut = contextID; }
            if (axPoint) { CFRelease(axPoint); }
            return candidatePID;
        }
        if (axPoint) { CFRelease(axPoint); }
    }
    return 0;
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

static NSDictionary *CloudCodeHostAXSymbolEvidence(void *address)
{
    Dl_info info = {0};
    BOOL resolved = address && dladdr(address, &info) != 0;
    return @{
        @"present": @(address != NULL),
        @"sourceImage": resolved && info.dli_fname ? @(info.dli_fname) : NSNull.null
    };
}

static NSDictionary *CloudCodeHostAXValueSummary(id value)
{
    if (!value || value == NSNull.null) { return @{@"present": @NO}; }
    NSMutableDictionary *summary = [@{
        @"present": @YES,
        @"class": NSStringFromClass([value class]) ?: @"<unknown>"
    } mutableCopy];
    if ([value isKindOfClass:NSArray.class]) {
        summary[@"count"] = @([(NSArray *)value count]);
    } else if ([value isKindOfClass:NSDictionary.class]) {
        summary[@"count"] = @([(NSDictionary *)value count]);
    } else if ([value isKindOfClass:NSString.class]) {
        summary[@"value"] = CloudCodeHostAXBoundedString(value) ?: @"";
    } else if ([value isKindOfClass:NSNumber.class]) {
        summary[@"value"] = value;
    }
    NSString *description = CloudCodeHostAXBoundedString(value);
    if (description.length > 0) {
        summary[@"description"] = description;
        summary[@"remoteViewBridgeMarker"] = @([description containsString:@"RemoteViewBridge"]);
        summary[@"axRemoteElementMarker"] = @([description containsString:@"AXRemoteElement"]);
    }
    return summary;
}

static NSDictionary *CloudCodeHostAXProbeAttribute(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef element, CFStringRef attribute)
{
    if (!runtime.copyAttribute || !element || !attribute) {
        return @{@"attempted": @NO, @"reason": @"missing_runtime_element_or_attribute"};
    }
    CFTypeRef value = NULL;
    CloudCodeHostAXError code = -1;
    @try { code = runtime.copyAttribute(element, attribute, &value); }
    @catch (__unused NSException *exception) { code = -1; value = NULL; }
    NSMutableDictionary *result = [@{
        @"attempted": @YES,
        @"AXError": @(code),
        @"valuePresent": @(value != NULL)
    } mutableCopy];
    if (value) {
        result[@"summary"] = CloudCodeHostAXValueSummary((__bridge id)value);
        CFRelease(value);
    }
    return result;
}

static id CloudCodeHostAXProbeObject0(id object, NSString *selectorName)
{
    if (!object || selectorName.length == 0) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) { return nil; }
    id (*sendObject0)(id, SEL) = (void *)objc_msgSend;
    @try { return sendObject0(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSNumber *CloudCodeHostAXProbeUnsigned0(id object, NSString *selectorName)
{
    if (!object || selectorName.length == 0) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) { return nil; }
    unsigned long long (*sendUnsigned0)(id, SEL) = (void *)objc_msgSend;
    @try { return @(sendUnsigned0(object, selector)); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSArray *CloudCodeHostAXProbeArrayLike(id value)
{
    if ([value isKindOfClass:NSArray.class]) { return value; }
    id objects = CloudCodeHostAXProbeObject0(value, @"allObjects");
    return [objects isKindOfClass:NSArray.class] ? objects : nil;
}

static NSDictionary *CloudCodeHostAXFrontBoardEvidence(CFAbsoluteTime deadline)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    void *handle = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_NOW | RTLD_GLOBAL);
    result[@"frameworkLoaded"] = @(handle != NULL);
    NSArray<NSString *> *names = @[
        @"AXFrontBoardFocusedAppPID", @"AXFrontBoardFocusedAppPIDs", @"AXFrontBoardFocusedAppPIDsIgnoringSiri",
        @"AXFrontBoardFocusedApps", @"AXFrontBoardFocusedAppProcess", @"AXFrontBoardFocusedAppProcesses",
        @"AXFrontBoardVisibleAppProcesses", @"AXFrontBoardFBSceneManager"
    ];
    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    for (NSString *name in names) {
        void *symbol = handle ? dlsym(handle, name.UTF8String) : NULL;
        if (!symbol) { symbol = dlsym(RTLD_DEFAULT, name.UTF8String); }
        symbols[name] = CloudCodeHostAXSymbolEvidence(symbol);
    }
    result[@"symbols"] = symbols;
    result[@"AXFrontBoardFocusedAppPID"] = @{
        @"invoked": @NO,
        @"classification": @"abi_unverified_after_build122_physical_probe",
        @"reason": @"pid_t(void) call returned non-PID values; symbol presence is evidence only"
    };
    NSMutableDictionary *objects = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < names.count && CFAbsoluteTimeGetCurrent() < deadline; index++) {
        NSString *name = names[index];
        void *symbol = handle ? dlsym(handle, name.UTF8String) : NULL;
        if (!symbol) { symbol = dlsym(RTLD_DEFAULT, name.UTF8String); }
        if (!symbol) { continue; }
        CFTypeRef (*function)(void) = (CFTypeRef (*)(void))symbol;
        @try {
            CFTypeRef value = function();
            objects[name] = value ? CloudCodeHostAXValueSummary((__bridge id)value) : @{@"present": @NO};
        } @catch (__unused NSException *exception) {
            objects[name] = @{@"exception": @YES};
        }
    }
    result[@"objectResults"] = objects;
    result[@"invocationContext"] = @"CloudCode System-app host process";
    result[@"adoption"] = @"probe_only_until_physical_foreground_identity_matches_target_app";
    return result;
}

static NSDictionary *CloudCodeHostAXFBSWorkspaceEvidence(NSString *foregroundBundle, pid_t foregroundPID, CFAbsoluteTime deadline)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    void *framework = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW | RTLD_GLOBAL);
    result[@"frameworkLoaded"] = @(framework != NULL);
    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    result[@"classPresent"] = @(workspaceClass != Nil);
    if (!workspaceClass) { return result; }
    id workspace = CloudCodeHostAXProbeObject0(workspaceClass, @"_sharedWorkspaceIfExists");
    NSString *selector = @"_sharedWorkspaceIfExists";
    if (!workspace) {
        workspace = CloudCodeHostAXProbeObject0(workspaceClass, @"sharedWorkspace");
        selector = @"sharedWorkspace";
    }
    result[@"workspacePresent"] = @(workspace != nil);
    result[@"workspaceSelector"] = workspace ? selector : @"none";
    if (!workspace) { return result; }
    NSArray *scenes = CloudCodeHostAXProbeArrayLike(CloudCodeHostAXProbeObject0(workspace, @"scenes"));
    result[@"sceneCount"] = @(scenes.count);
    NSMutableArray *summaries = [NSMutableArray array];
    NSUInteger limit = MIN((NSUInteger)12, scenes.count);
    for (NSUInteger index = 0; index < limit && CFAbsoluteTimeGetCurrent() < deadline; index++) {
        id scene = scenes[index];
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        summary[@"class"] = NSStringFromClass([scene class]) ?: @"<unknown>";
        id identifierValue = CloudCodeHostAXProbeObject0(scene, @"identifier");
        id bundleValue = CloudCodeHostAXProbeObject0(scene, @"crs_applicationBundleIdentifier");
        NSString *identifier = [identifierValue isKindOfClass:NSString.class] ? identifierValue : nil;
        NSString *bundle = [bundleValue isKindOfClass:NSString.class] ? bundleValue : nil;
        if (identifier) { summary[@"identifier"] = identifier; }
        if (bundle) { summary[@"bundleId"] = bundle; }
        id clientProcess = CloudCodeHostAXProbeObject0(scene, @"clientProcess");
        id hostProcess = CloudCodeHostAXProbeObject0(scene, @"hostProcess");
        NSNumber *clientPID = CloudCodeHostAXProbeUnsigned0(clientProcess, @"pid");
        NSNumber *hostPID = CloudCodeHostAXProbeUnsigned0(hostProcess, @"pid");
        if (clientPID) { summary[@"clientPid"] = clientPID; }
        if (hostPID) { summary[@"hostPid"] = hostPID; }
        id display = CloudCodeHostAXProbeObject0(scene, @"display");
        NSNumber *displayID = CloudCodeHostAXProbeUnsigned0(display, @"displayId") ?: CloudCodeHostAXProbeUnsigned0(scene, @"displayId");
        if (displayID) { summary[@"displayId"] = displayID; }
        NSArray *contexts = CloudCodeHostAXProbeArrayLike(CloudCodeHostAXProbeObject0(scene, @"contexts"));
        NSMutableArray *contextIDs = [NSMutableArray array];
        NSUInteger contextLimit = MIN((NSUInteger)8, contexts.count);
        for (NSUInteger contextIndex = 0; contextIndex < contextLimit; contextIndex++) {
            id context = contexts[contextIndex];
            NSNumber *contextID = CloudCodeHostAXProbeUnsigned0(context, @"contextID")
                ?: CloudCodeHostAXProbeUnsigned0(context, @"contextId")
                ?: CloudCodeHostAXProbeUnsigned0(context, @"windowContextId");
            if (contextID) { [contextIDs addObject:contextID]; }
        }
        if (contextIDs.count > 0) { summary[@"contextIds"] = contextIDs; }
        BOOL bundleMatch = foregroundBundle.length > 0 && [bundle isEqualToString:foregroundBundle];
        BOOL pidMatch = foregroundPID > 0 && (clientPID.intValue == foregroundPID || hostPID.intValue == foregroundPID);
        summary[@"foregroundCandidate"] = @(bundleMatch || pidMatch);
        [summaries addObject:summary];
    }
    result[@"scenes"] = summaries;
    result[@"invocationContext"] = @"CloudCode System-app host process";
    result[@"adoption"] = @"probe_only_until_scene_identity_is_correlated_on_physical_device";
    return result;
}

static NSDictionary *CloudCodeHostAXContextEvidence(CloudCodeHostAXRuntime runtime, CloudCodeHostAXUIElementRef systemWide, CloudCodeHostAXUIElementRef root, pid_t expectedPID, CFAbsoluteTime deadline)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    CGSize size = CloudCodeHostAXScreenSize();
    CGPoint point = CGPointMake(size.width * 0.5, size.height * 0.5);
    result[@"screenPoints"] = @[@(size.width), @(size.height)];
    result[@"point"] = @[@(point.x), @(point.y)];
    if (!systemWide || size.width <= 1 || size.height <= 1 || CFAbsoluteTimeGetCurrent() >= deadline) {
        result[@"attempted"] = @NO;
        return result;
    }
    result[@"attempted"] = @YES;

    CloudCodeHostAXUIElementRef application = NULL;
    uint32_t contextID = 0;
    CloudCodeHostAXError applicationCode = -1;
    if (runtime.copyApplicationAndContextAtPosition) {
        @try { applicationCode = runtime.copyApplicationAndContextAtPosition(systemWide, &application, &contextID, (float)point.x, (float)point.y); }
        @catch (__unused NSException *exception) { applicationCode = -1; application = NULL; contextID = 0; }
    }
    result[@"applicationContextAXError"] = @(applicationCode);
    result[@"applicationPresent"] = @(application != NULL);
    result[@"applicationContextId"] = @(contextID);
    if (application && runtime.getPid) {
        pid_t appPID = 0;
        CloudCodeHostAXError code = -1;
        @try { code = runtime.getPid(application, &appPID); } @catch (__unused NSException *exception) { code = -1; }
        result[@"applicationPidAXError"] = @(code);
        result[@"applicationPid"] = @(appPID);
        result[@"applicationPidMatchesForeground"] = @(expectedPID > 0 && appPID == expectedPID);
    }

    uint32_t parameterizedContextID = 0;
    if (runtime.copyParameterizedAttributeValue && CFAbsoluteTimeGetCurrent() < deadline) {
        CFTypeRef axPoint = NULL;
        if (runtime.valueCreate) {
            @try { axPoint = runtime.valueCreate(1, &point); } @catch (__unused NSException *exception) { axPoint = NULL; }
        }
        id pointValue = axPoint ? (__bridge id)axPoint : CloudCodeHostAXPointValue(point);
        NSMutableArray *attempts = [NSMutableArray array];
        for (NSNumber *displayID in @[@1, @0]) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            NSArray *parameter = @[pointValue, displayID];
            CFTypeRef value = NULL;
            CloudCodeHostAXError code = -1;
            @try { code = runtime.copyParameterizedAttributeValue(systemWide, (CFStringRef)(uintptr_t)0x16573, (__bridge CFTypeRef)parameter, &value); }
            @catch (__unused NSException *exception) { code = -1; value = NULL; }
            NSMutableDictionary *entry = [@{@"displayId": displayID, @"AXError": @(code), @"valuePresent": @(value != NULL)} mutableCopy];
            if (value) {
                id bridged = (__bridge id)value;
                entry[@"summary"] = CloudCodeHostAXValueSummary(bridged);
                if ([bridged respondsToSelector:@selector(unsignedIntValue)]) { parameterizedContextID = [bridged unsignedIntValue]; }
                CFRelease(value);
            }
            [attempts addObject:entry];
            if (parameterizedContextID > 0) { break; }
        }
        result[@"parameterizedContextAttempts"] = attempts;
        if (axPoint) { CFRelease(axPoint); }
    }
    if (contextID == 0) { contextID = parameterizedContextID; }
    result[@"contextId"] = @(contextID);

    pid_t contextPID = 0;
    if (contextID > 0 && runtime.copyParameterizedAttributeValue && CFAbsoluteTimeGetCurrent() < deadline) {
        NSDictionary *parameter = @{@"contextId": @(contextID)};
        CFTypeRef value = NULL;
        CloudCodeHostAXError code = -1;
        @try { code = runtime.copyParameterizedAttributeValue(systemWide, (CFStringRef)(uintptr_t)0x16574, (__bridge CFTypeRef)parameter, &value); }
        @catch (__unused NSException *exception) { code = -1; value = NULL; }
        result[@"contextPidAXError"] = @(code);
        result[@"contextPidPresent"] = @(value != NULL);
        if (value) {
            id bridged = (__bridge id)value;
            result[@"contextPidSummary"] = CloudCodeHostAXValueSummary(bridged);
            if ([bridged respondsToSelector:@selector(intValue)]) { contextPID = (pid_t)[bridged intValue]; }
            CFRelease(value);
        }
    }
    result[@"contextPid"] = @(contextPID);
    result[@"contextPidMatchesForeground"] = @(expectedPID > 0 && contextPID == expectedPID);

    CloudCodeHostAXUIElementRef target = application;
    if (!target && root) { target = (CloudCodeHostAXUIElementRef)CFRetain(root); }
    uint32_t displayID = 0;
    if (target && CFAbsoluteTimeGetCurrent() < deadline) {
        NSDictionary *displayProbe = runtime.xcWindowDisplayId
            ? CloudCodeHostAXProbeAttribute(runtime, target, runtime.xcWindowDisplayId)
            : CloudCodeHostAXProbeAttribute(runtime, target, (CFStringRef)(uintptr_t)2123);
        result[@"displayAttribute"] = displayProbe;
        NSDictionary *summary = displayProbe[@"summary"];
        NSNumber *value = [summary[@"value"] isKindOfClass:NSNumber.class] ? summary[@"value"] : nil;
        if (value) { displayID = value.unsignedIntValue; }
    }
    result[@"displayId"] = @(displayID);

    if (target && contextID > 0 && runtime.copyElementUsingContextIdAtPosition && CFAbsoluteTimeGetCurrent() < deadline) {
        CloudCodeHostAXUIElementRef hit = NULL;
        CloudCodeHostAXError code = -1;
        @try { code = runtime.copyElementUsingContextIdAtPosition(target, contextID, &hit, 0, (float)point.x, (float)point.y); }
        @catch (__unused NSException *exception) { code = -1; hit = NULL; }
        NSMutableDictionary *entry = [@{@"AXError": @(code), @"present": @(hit != NULL)} mutableCopy];
        if (hit && runtime.getPid) {
            pid_t pid = 0;
            CloudCodeHostAXError pidCode = runtime.getPid(hit, &pid);
            entry[@"pidAXError"] = @(pidCode);
            entry[@"pid"] = @(pid);
            entry[@"pidMatchesForeground"] = @(expectedPID > 0 && pid == expectedPID);
        }
        if (hit) { CFRelease(hit); }
        result[@"contextHit"] = entry;
    }
    if (target && displayID > 0 && runtime.copyElementUsingDisplayIdAtPosition && CFAbsoluteTimeGetCurrent() < deadline) {
        CloudCodeHostAXUIElementRef hit = NULL;
        CloudCodeHostAXError code = -1;
        @try { code = runtime.copyElementUsingDisplayIdAtPosition(target, displayID, &hit, 0, (float)point.x, (float)point.y); }
        @catch (__unused NSException *exception) { code = -1; hit = NULL; }
        NSMutableDictionary *entry = [@{@"AXError": @(code), @"present": @(hit != NULL)} mutableCopy];
        if (hit && runtime.getPid) {
            pid_t pid = 0;
            CloudCodeHostAXError pidCode = runtime.getPid(hit, &pid);
            entry[@"pidAXError"] = @(pidCode);
            entry[@"pid"] = @(pid);
            entry[@"pidMatchesForeground"] = @(expectedPID > 0 && pid == expectedPID);
        }
        if (hit) { CFRelease(hit); }
        result[@"displayHit"] = entry;
    }
    if (target) { CFRelease(target); }
    return result;
}

NSString *CloudCodeHostAXProbeJSON(NSString * _Nullable * _Nullable diagnostic)
{
    if (diagnostic) { *diagnostic = nil; }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime deadline = started + CLOUDCODE_HOST_AX_PROBE_BUDGET_SECONDS;
    CloudCodeHostAXCallLease callLease __attribute__((cleanup(CloudCodeHostAXCallLeaseCleanup))) = CloudCodeHostAXAcquireCallLease();
    if (!callLease.held) {
        if (diagnostic) { *diagnostic = @"host AX probe already active"; }
        return nil;
    }
    CloudCodeHostAXRuntime runtime = CloudCodeHostAXResolve();
    CloudCodeHostAXAutomationLease automationLease = CloudCodeHostAXObserveAutomationState(runtime);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"schemaVersion"] = @1;
    result[@"kind"] = @"host-ax-probe";
    result[@"process"] = CCPerceptionProcessEvidence(@"cloudcode_system_app_host_ax_probe");
    result[@"automationLeaseActive"] = @(automationLease.active);
    result[@"axManualAccessibilityTouched"] = @NO;
    result[@"executionContext"] = @"CloudCode System-app host process; no detached helper for host sections";

    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
#define CC_HOST_AX_SYMBOL(field) symbols[@#field] = CloudCodeHostAXSymbolEvidence((void *)runtime.field)
    CC_HOST_AX_SYMBOL(createApplication); CC_HOST_AX_SYMBOL(createAppElementWithPid); CC_HOST_AX_SYMBOL(createSystemWide);
    CC_HOST_AX_SYMBOL(getPid); CC_HOST_AX_SYMBOL(copyAttribute); CC_HOST_AX_SYMBOL(copyMultipleAttributes);
    CC_HOST_AX_SYMBOL(copyElementAtPosition); CC_HOST_AX_SYMBOL(copyApplicationAtPosition); CC_HOST_AX_SYMBOL(copyApplicationAndContextAtPosition);
    CC_HOST_AX_SYMBOL(copyElementWithParameters); CC_HOST_AX_SYMBOL(copyParameterizedAttributeValue);
    CC_HOST_AX_SYMBOL(copyElementUsingContextIdAtPosition); CC_HOST_AX_SYMBOL(copyElementUsingDisplayIdAtPosition);
    CC_HOST_AX_SYMBOL(setRequestingClient); CC_HOST_AX_SYMBOL(addAssociatedPid); CC_HOST_AX_SYMBOL(automationEnabled);
#undef CC_HOST_AX_SYMBOL
    result[@"symbols"] = symbols;

    NSString *bundleID = CloudCodeHostFrontmostBundleID();
    NSString *bundlePath = CloudCodeHostBundlePath(bundleID);
    pid_t foregroundPID = CloudCodeHostPIDForBundleID(bundleID);
    NSString *pidResolver = @"SBSCopyDisplayIdentifierForProcessID scan";
    if (foregroundPID <= 0) {
        foregroundPID = CloudCodeHostPIDForBundlePath(bundlePath);
        pidResolver = @"LSApplicationProxy.bundleURL -> proc_pidpath fallback";
    }
    CloudCodeHostAXUIElementRef systemWide = NULL;
    if (runtime.createSystemWide && CFAbsoluteTimeGetCurrent() < deadline) {
        @try { systemWide = runtime.createSystemWide(); } @catch (__unused NSException *exception) { systemWide = NULL; }
        if (systemWide && runtime.setTimeout) { @try { runtime.setTimeout(systemWide, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {} }
    }
    uint32_t foregroundContextID = 0;
    if (foregroundPID <= 0 && systemWide && CFAbsoluteTimeGetCurrent() < deadline) {
        foregroundPID = CloudCodeHostAXPIDAtScreenContext(runtime, systemWide, bundleID, &foregroundContextID);
        if (foregroundPID > 0) { pidResolver = @"AX parameterized point->context->pid fallback"; }
    }
    result[@"foreground"] = @{
        @"bundleId": bundleID ?: @"",
        @"bundlePathResolved": @(bundlePath.length > 0),
        @"pid": @(foregroundPID),
        @"resolver": pidResolver,
        @"contextId": @(foregroundContextID),
        @"resolved": @(bundleID.length > 0 && foregroundPID > 0),
        @"firstFailure": bundleID.length == 0 ? @"bundle-id" : (foregroundPID <= 0 ? @"pid" : @"none")
    };

    result[@"axFrontBoard"] = CloudCodeHostAXFrontBoardEvidence(deadline);
    if (CFAbsoluteTimeGetCurrent() < deadline) {
        result[@"fbsWorkspace"] = CloudCodeHostAXFBSWorkspaceEvidence(bundleID, foregroundPID, deadline);
    }
    NSMutableDictionary *systemWideEvidence = [NSMutableDictionary dictionary];
    systemWideEvidence[@"created"] = @(systemWide != NULL);
    if (systemWide) {
        for (NSString *attribute in @[@"AXFocusedApplication", @"AXFocusedUIElement", @"AXChildren", @"AXLabel"]) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            systemWideEvidence[attribute] = CloudCodeHostAXProbeAttribute(runtime, systemWide, (__bridge CFStringRef)attribute);
        }
    }
    result[@"systemWide"] = systemWideEvidence;

    CloudCodeHostAXUIElementRef root = NULL;
    if (foregroundPID > 0 && CFAbsoluteTimeGetCurrent() < deadline) {
        if (runtime.addAssociatedPid) {
            @try {
                runtime.addAssociatedPid(getpid(), foregroundPID, 0);
                runtime.addAssociatedPid(getpid(), foregroundPID, 1);
                runtime.addAssociatedPid(foregroundPID, getpid(), 0);
                runtime.addAssociatedPid(foregroundPID, getpid(), 1);
            } @catch (__unused NSException *exception) {}
        }
        root = CloudCodeHostAXRootForPID(runtime, foregroundPID);
    }
    result[@"foregroundRoot"] = @{
        @"created": @(root != NULL),
        @"pid": @(foregroundPID),
        @"createApplicationSymbol": @(runtime.createApplication != NULL),
        @"createAppElementWithPidSymbol": @(runtime.createAppElementWithPid != NULL)
    };

    if (root && CFAbsoluteTimeGetCurrent() < deadline) {
        const struct { uintptr_t attribute; __unsafe_unretained NSString *name; __unsafe_unretained NSString *group; } numeric[] = {
            {3015, @"visibleElements", @"children_visible"}, {3022, @"explorerElements", @"children_visible"},
            {3025, @"semanticContext", @"semantic"}, {3029, @"nativeFocusable", @"focus"},
            {3031, @"focusCandidates", @"focus"}, {3032, @"focusState", @"focus"},
            {2092, @"contextCandidate", @"context_display"}, {2123, @"windowDisplayId", @"context_display"},
            {2057, @"frameCandidate", @"semantic"}, {2070, @"visibilityCandidate", @"children_visible"},
            {2186, @"remoteCandidateA", @"remote_view"}, {2187, @"remoteCandidateB", @"remote_view"},
            {5001, @"privateChildren", @"children_visible"}
        };
        NSMutableDictionary *numericEvidence = [NSMutableDictionary dictionary];
        for (NSUInteger index = 0; index < sizeof(numeric) / sizeof(numeric[0]); index++) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            NSMutableDictionary *entry = [CloudCodeHostAXProbeAttribute(runtime, root, (CFStringRef)numeric[index].attribute) mutableCopy];
            entry[@"group"] = numeric[index].group;
            entry[@"name"] = numeric[index].name;
            numericEvidence[[NSString stringWithFormat:@"%lu", (unsigned long)numeric[index].attribute]] = entry;
        }
        result[@"numericAttributes"] = numericEvidence;

        const struct { CFStringRef attribute; __unsafe_unretained NSString *name; } xc[] = {
            {runtime.xcElementType, @"elementType"}, {runtime.xcElementBaseType, @"elementBaseType"},
            {runtime.xcLabel, @"label"}, {runtime.xcValue, @"value"}, {runtime.xcIdentifier, @"identifier"},
            {runtime.xcPlaceholderValue, @"placeholder"}, {runtime.xcFrame, @"frame"}, {runtime.xcVisibleFrame, @"visibleFrame"},
            {runtime.xcChildren, @"children"}, {runtime.xcChildrenCount, @"childrenCount"},
            {runtime.xcUserTestingElements, @"userTestingElements"}, {runtime.xcUserTestingSnapshot, @"userTestingSnapshot"},
            {runtime.xcWindowContextId, @"windowContextId"}, {runtime.xcWindowDisplayId, @"windowDisplayId"},
            {runtime.xcIsRemoteElement, @"isRemoteElement"}, {runtime.xcIsVisible, @"isVisible"},
            {runtime.xcIsUserInteractionEnabled, @"isUserInteractionEnabled"}
        };
        NSMutableDictionary *xcEvidence = [NSMutableDictionary dictionary];
        BOOL remoteViewBridgeMarker = NO;
        BOOL axRemoteElementMarker = NO;
        for (NSUInteger index = 0; index < sizeof(xc) / sizeof(xc[0]); index++) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) { break; }
            NSDictionary *entry = CloudCodeHostAXProbeAttribute(runtime, root, xc[index].attribute);
            xcEvidence[xc[index].name] = entry;
            NSDictionary *summary = entry[@"summary"];
            remoteViewBridgeMarker = remoteViewBridgeMarker || [summary[@"remoteViewBridgeMarker"] boolValue];
            axRemoteElementMarker = axRemoteElementMarker || [summary[@"axRemoteElementMarker"] boolValue];
        }
        result[@"xcAttributes"] = xcEvidence;
        result[@"remoteViewBridgeMarker"] = @(remoteViewBridgeMarker);
        result[@"axRemoteElementMarker"] = @(axRemoteElementMarker);
    }

    if (systemWide && CFAbsoluteTimeGetCurrent() < deadline) {
        result[@"contextDisplay"] = CloudCodeHostAXContextEvidence(runtime, systemWide, root, foregroundPID, deadline);
    }

    NSUInteger nodeCount = 0;
    NSDictionary *tree = nil;
    if (root && CFAbsoluteTimeGetCurrent() < deadline) {
        CFAbsoluteTime treeDeadline = MIN(deadline, CFAbsoluteTimeGetCurrent() + 0.45);
        tree = CloudCodeHostAXNode(runtime, root, 0, &nodeCount, treeDeadline);
    }
    NSUInteger semanticCount = CloudCodeHostAXSemanticCount(tree);
    NSUInteger actionableCount = CloudCodeHostAXActionableCount(tree);
    result[@"semanticSummary"] = @{
        @"nodeCount": @(nodeCount),
        @"semanticCount": @(semanticCount),
        @"actionableCount": @(actionableCount),
        @"targetPid": @(foregroundPID)
    };
    if (root) { CFRelease(root); }
    if (systemWide) { CFRelease(systemWide); }
    result[@"latencyMS"] = @((NSInteger)MAX(0.0, (CFAbsoluteTimeGetCurrent() - started) * 1000.0));
    result[@"budgetMS"] = @((NSInteger)(CLOUDCODE_HOST_AX_PROBE_BUDGET_SECONDS * 1000.0));
    result[@"budgetExhausted"] = @(CFAbsoluteTimeGetCurrent() >= deadline);
    result[@"probeClassification"] = @"read_only_host_context_evidence; production_adoption_requires_physical_device_match";

    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if (!json || json.length == 0 || json.length > CLOUDCODE_HOST_AX_MAX_BYTES) {
        if (diagnostic) { *diagnostic = @"host AX probe JSON unavailable or exceeded 256 KiB"; }
        return nil;
    }
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"host AX probe completed; foreground=%@ pid=%d semantic=%lu actionable=%lu latencyMS=%ld", bundleID ?: @"", foregroundPID, (unsigned long)semanticCount, (unsigned long)actionableCount, (long)[result[@"latencyMS"] integerValue]];
    }
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
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
    CloudCodeHostAXAutomationLease automationLease = CloudCodeHostAXObserveAutomationState(runtime);

    CFAbsoluteTime deadline = started + CLOUDCODE_HOST_AX_TOTAL_BUDGET_SECONDS;
    NSString *bundleID = CloudCodeHostFrontmostBundleID();
    NSString *bundlePath = CloudCodeHostBundlePath(bundleID);
    pid_t pid = CloudCodeHostPIDForBundleID(bundleID);
    NSString *route = @"frontmost-bundle-id";
    if (pid <= 0) {
        pid = CloudCodeHostPIDForBundlePath(bundlePath);
        route = @"frontmost-bundle-path";
    }
    if (pid <= 0 && runtime.createSystemWide && CFAbsoluteTimeGetCurrent() < deadline) {
        CloudCodeHostAXUIElementRef identitySeed = NULL;
        @try { identitySeed = runtime.createSystemWide(); } @catch (__unused NSException *exception) { identitySeed = NULL; }
        if (identitySeed && runtime.setTimeout) {
            @try { runtime.setTimeout(identitySeed, CLOUDCODE_HOST_AX_TIMEOUT_SECONDS); } @catch (__unused NSException *exception) {}
        }
        uint32_t contextID = 0;
        pid_t contextPID = CloudCodeHostAXPIDAtScreenContext(runtime, identitySeed, bundleID, &contextID);
        if (identitySeed) { CFRelease(identitySeed); }
        if (contextPID > 0) {
            pid = contextPID;
            route = @"parameterized-screen-context-pid";
        }
    }
    CloudCodeHostAXUIElementRef root = NULL;
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
    CloudCodeHostAXAutomationLease automationLease = CloudCodeHostAXObserveAutomationState(runtime);
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
    if (!focusedElementAvailable || pid <= 0) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"host AX focused text unavailable runtime=%d element=%d pid=%d; fail-fast to AXAudit fallback", runtimeAvailable, focusedElementAvailable, pid];
        }
        return nil;
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
