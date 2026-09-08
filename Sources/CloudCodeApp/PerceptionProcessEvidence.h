#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <unistd.h>

// Small shared evidence helpers, used only by explicit probes. They neither grant privileges
// nor change process class. Unknown OS state stays unknown rather than inferred from UID.
static NSDictionary *CCPerceptionProcessEvidence(NSString *role) {
    NSMutableDictionary *record = [@{
        @"processName": NSProcessInfo.processInfo.processName,
        @"pid": @(getpid()), @"parentPID": @(getppid()),
        @"uid": @(getuid()), @"effectiveUID": @(geteuid()), @"gid": @(getgid()),
        @"processRole": role, @"osVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"runningBoardState": @"requires_correlated_syslog",
        @"physicalFootprintBytes": NSNull.null, @"availableProcessMemoryBytes": @(os_proc_available_memory())
    } mutableCopy];
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t vmCode = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count);
    record[@"taskVMInfoKernReturn"] = @(vmCode);
    if (vmCode == KERN_SUCCESS) { record[@"physicalFootprintBytes"] = @(vm.phys_footprint); }
    int (*sandboxCheck)(pid_t, const char *, int, ...) = dlsym(RTLD_DEFAULT, "sandbox_check");
    record[@"sandboxCheckAvailable"] = @(sandboxCheck != NULL);
    if (sandboxCheck) {
        int result = sandboxCheck(getpid(), NULL, 0);
        record[@"sandboxCheckResult"] = @(result);
        record[@"sandboxState"] = result == 0 ? @"not_sandboxed" : (result > 0 ? @"sandboxed" : @"unknown");
    } else { record[@"sandboxState"] = @"unknown"; }
    int (*csopsFn)(pid_t, unsigned int, void *, size_t) = dlsym(RTLD_DEFAULT, "csops");
    if (csopsFn) {
        uint32_t flags = 0;
        int result = csopsFn(getpid(), 0, &flags, sizeof(flags));
        record[@"csopsStatusResult"] = @(result);
        if (result == 0) { record[@"codeSigningFlags"] = @(flags); }
        else { record[@"csopsErrno"] = @(errno); }
    }
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
    CFTypeRef (*createTask)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*copyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *) = security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    NSMutableDictionary *entitlements = [NSMutableDictionary dictionary];
    CFTypeRef task = createTask ? createTask(kCFAllocatorDefault) : NULL;
    record[@"entitlementEvidenceSource"] = task && copyEntitlement ? @"SecTask_self_values_allowlist" : @"unavailable";
    for (NSString *key in @[@"application-identifier", @"platform-application", @"get-task-allow",
            @"com.apple.private.security.no-sandbox", @"com.apple.private.security.container-required",
            @"com.apple.private.security.no-container", @"com.apple.private.persona-mgmt",
            @"com.apple.accessibility.api", @"com.apple.multitasking.unlimitedassertions",
            @"com.apple.private.IOSurface.protected-access", @"com.apple.QuartzCore.global-capture",
            @"com.apple.security.iokit-user-client-class", @"com.apple.security.exception.iokit-user-client-class"]) {
        if (!task || !copyEntitlement) { break; }
        CFErrorRef error = NULL;
        CFTypeRef value = copyEntitlement(task, (__bridge CFStringRef)key, &error);
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"value"] = value ? CFBridgingRelease(value) : NSNull.null;
        if (error) {
            entry[@"errorDomain"] = (__bridge NSString *)CFErrorGetDomain(error);
            entry[@"errorCode"] = @(CFErrorGetCode(error));
            CFRelease(error);
        }
        entitlements[key] = entry;
    }
    if (task) { CFRelease(task); }
    if (security) { dlclose(security); }
    record[@"entitlements"] = entitlements;
    return record;
}

static NSArray *CCPerceptionErrorChain(NSError *error) {
    NSMutableArray *chain = [NSMutableArray array];
    for (NSUInteger depth = 0; error && depth < 6; depth++) {
        [chain addObject:@{@"domain": error.domain, @"code": @(error.code),
                          @"description": [error.localizedDescription substringToIndex:MIN(error.localizedDescription.length, 1024)]}];
        error = error.userInfo[NSUnderlyingErrorKey];
    }
    return chain;
}
