#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <unistd.h>
#import <signal.h>

#define CLOUDCODE_PROC_PATH_MAX 4096
typedef int (*CloudCodeProcListAllPidsFn)(void *, int);
typedef int (*CloudCodeProcPidPathFn)(int, void *, uint32_t);

static NSString *NormalizePath(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) { return nil; }
    return path.stringByStandardizingPath;
}

static BOOL HasAnyPrefix(NSString *path, NSArray<NSString *> *prefixes)
{
    for (NSString *prefix in prefixes) {
        if ([path hasPrefix:prefix]) { return YES; }
    }
    return NO;
}

static BOOL IsSafeBundlePath(NSString *path)
{
    NSString *normalized = NormalizePath(path);
    if (!normalized || ![normalized.pathExtension.lowercaseString isEqualToString:@"app"]) { return NO; }
    return HasAnyPrefix(normalized, @[
        @"/var/containers/Bundle/Application/",
        @"/private/var/containers/Bundle/Application/"
    ]);
}

static BOOL IsSafeBundleContainerPath(NSString *path)
{
    NSString *normalized = NormalizePath(path);
    if (!normalized) { return NO; }
    if (!HasAnyPrefix(normalized, @[
        @"/var/containers/Bundle/Application/",
        @"/private/var/containers/Bundle/Application/"
    ])) { return NO; }
    NSString *parent = normalized.stringByDeletingLastPathComponent;
    return [parent isEqualToString:@"/var/containers/Bundle/Application"] || [parent isEqualToString:@"/private/var/containers/Bundle/Application"];
}

static BOOL IsSafeDataPath(NSString *path)
{
    NSString *normalized = NormalizePath(path);
    if (!normalized) { return NO; }
    return HasAnyPrefix(normalized, @[
        @"/var/mobile/Containers/Data/Application/",
        @"/private/var/mobile/Containers/Data/Application/",
        @"/var/mobile/Containers/Data/PluginKitPlugin/",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin/"
    ]);
}

static void LoadLaunchServices(void)
{
    if (NSClassFromString(@"LSApplicationWorkspace")) { return; }
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    if (!NSClassFromString(@"LSApplicationWorkspace")) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    }
}

static id Workspace(void)
{
    LoadLaunchServices();
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (!cls || ![cls respondsToSelector:selector]) { return nil; }
    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
    return sendObject(cls, selector);
}

static BOOL ApplicationIsInstalled(id workspace, NSString *bundleID, BOOL *known)
{
    SEL selector = NSSelectorFromString(@"applicationIsInstalled:");
    if (!workspace || ![workspace respondsToSelector:selector]) {
        if (known) { *known = NO; }
        return NO;
    }
    BOOL (*sendBool)(id, SEL, id) = (void *)objc_msgSend;
    if (known) { *known = YES; }
    return sendBool(workspace, selector, bundleID);
}

static BOOL UnregisterApplication(id workspace, NSString *appPath)
{
    SEL selector = NSSelectorFromString(@"unregisterApplication:");
    if (!workspace || ![workspace respondsToSelector:selector]) { return NO; }
    BOOL (*sendBool)(id, SEL, id) = (void *)objc_msgSend;
    return sendBool(workspace, selector, [NSURL fileURLWithPath:appPath]);
}

static BOOL SystemUninstall(id workspace, NSString *bundleID)
{
    SEL errorSelector = NSSelectorFromString(@"uninstallApplication:withOptions:error:");
    if (workspace && [workspace respondsToSelector:errorSelector]) {
        BOOL (*sendBool)(id, SEL, id, id, NSError **) = (void *)objc_msgSend;
        NSError *error = nil;
        if (sendBool(workspace, errorSelector, bundleID, @{}, &error)) { return YES; }
        if (error) { fprintf(stderr, "LaunchServices(error-aware): %s\n", error.localizedDescription.UTF8String ?: "error"); }
    }

    SEL legacySelector = NSSelectorFromString(@"uninstallApplication:withOptions:");
    if (workspace && [workspace respondsToSelector:legacySelector]) {
        BOOL (*sendBool)(id, SEL, id, id) = (void *)objc_msgSend;
        if (sendBool(workspace, legacySelector, bundleID, @{})) { return YES; }
    }
    return NO;
}

static BOOL MobileInstallationUninstallApp(NSString *bundleID)
{
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "MobileInstallation: framework unavailable\n");
        return NO;
    }
    typedef int (*MobileInstallationUninstallFn)(NSString *, NSDictionary *, void *);
    MobileInstallationUninstallFn uninstall = (MobileInstallationUninstallFn)dlsym(handle, "MobileInstallationUninstall");
    if (!uninstall) {
        fprintf(stderr, "MobileInstallation: uninstall symbol unavailable\n");
        dlclose(handle);
        return NO;
    }
    int code = uninstall(bundleID, nil, NULL);
    dlclose(handle);
    if (code == 0) { return YES; }
    fprintf(stderr, "MobileInstallationUninstall: %d\n", code);
    return NO;
}

static id ApplicationProxy(NSString *bundleID)
{
    LoadLaunchServices();
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:selector]) { return nil; }
    id (*sendObject)(id, SEL, id) = (void *)objc_msgSend;
    return sendObject(cls, selector, bundleID);
}

static NSArray<NSString *> *PluginDataPaths(NSString *bundleID)
{
    id proxy = ApplicationProxy(bundleID);
    if (!proxy) { return @[]; }
    NSArray *plugins = nil;
    @try {
        if ([proxy respondsToSelector:NSSelectorFromString(@"plugInKitPlugins")]) {
            plugins = [proxy valueForKey:@"plugInKitPlugins"];
        }
    } @catch (__unused NSException *exception) {
        plugins = nil;
    }
    if (![plugins isKindOfClass:NSArray.class]) { return @[]; }

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (id plugin in plugins) {
        NSURL *url = nil;
        @try {
            if ([plugin respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
                url = [plugin valueForKey:@"dataContainerURL"];
            }
        } @catch (__unused NSException *exception) {
            url = nil;
        }
        if ([url isKindOfClass:NSURL.class] && IsSafeDataPath(url.path)) {
            [paths addObject:url.path];
        }
    }
    return paths.copy;
}

static BOOL RemovePath(NSString *path, BOOL required)
{
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) { return YES; }

    NSError *lastError = nil;
    for (NSUInteger attempt = 0; attempt < 4; attempt++) {
        NSError *error = nil;
        if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return YES;
        }
        lastError = error;
        if (attempt < 3) { usleep(150000); }
    }

    if (required) {
        fprintf(
            stderr,
            "remove failed: path=%s domain=%s code=%ld description=%s\n",
            path.UTF8String ?: "",
            lastError.domain.UTF8String ?: "unknown",
            (long)lastError.code,
            lastError.localizedDescription.UTF8String ?: "unknown"
        );
    }
    return !required;
}

static CloudCodeProcListAllPidsFn ProcListAllPids(void)
{
    return (CloudCodeProcListAllPidsFn)dlsym(RTLD_DEFAULT, "proc_listallpids");
}

static CloudCodeProcPidPathFn ProcPidPath(void)
{
    return (CloudCodeProcPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
}

static BOOL HasProcessInspectionBackend(void)
{
    return ProcListAllPids() != NULL && ProcPidPath() != NULL;
}

static NSArray<NSNumber *> *ProcessesUnderBundlePath(NSString *bundlePath)
{
    NSString *normalized = NormalizePath(bundlePath);
    if (!IsSafeBundlePath(normalized)) { return @[]; }
    CloudCodeProcListAllPidsFn listAllPids = ProcListAllPids();
    CloudCodeProcPidPathFn pidPath = ProcPidPath();
    if (!listAllPids || !pidPath) { return @[]; }

    NSString *prefix = [normalized stringByAppendingString:@"/"];
    pid_t pids[4096] = {0};
    int count = listAllPids(pids, sizeof(pids));
    if (count <= 0) { return @[]; }

    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    for (int index = 0; index < count && index < 4096; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) { continue; }
        char pathBuffer[CLOUDCODE_PROC_PATH_MAX] = {0};
        int length = pidPath(pid, pathBuffer, sizeof(pathBuffer));
        if (length <= 0) { continue; }
        NSString *processPath = [NSString stringWithUTF8String:pathBuffer];
        if ([processPath isEqualToString:normalized] || [processPath hasPrefix:prefix]) {
            [matches addObject:@(pid)];
        }
    }
    return matches.copy;
}

static int TerminateApplication(NSString *bundlePath)
{
    if (!IsSafeBundlePath(bundlePath)) { return 20; }
    if (!HasProcessInspectionBackend()) { return 33; }
    NSArray<NSNumber *> *pids = ProcessesUnderBundlePath(bundlePath);
    if (pids.count == 0) { return 0; }

    for (NSNumber *value in pids) {
        kill((pid_t)value.intValue, SIGTERM);
    }
    for (NSUInteger attempt = 0; attempt < 12; attempt++) {
        if (ProcessesUnderBundlePath(bundlePath).count == 0) { return 0; }
        usleep(100000);
    }
    for (NSNumber *value in ProcessesUnderBundlePath(bundlePath)) {
        kill((pid_t)value.intValue, SIGKILL);
    }
    for (NSUInteger attempt = 0; attempt < 10; attempt++) {
        if (ProcessesUnderBundlePath(bundlePath).count == 0) { return 0; }
        usleep(100000);
    }
    return 32;
}

static int VerifyRemoved(id workspace, NSString *bundleID, NSString *bundlePath, NSString *dataPath)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger attempt = 0; attempt < 40; attempt++) {
        BOOL known = NO;
        BOOL installed = ApplicationIsInstalled(workspace, bundleID, &known);
        BOOL bundleGone = ![fm fileExistsAtPath:bundlePath];
        BOOL dataGone = dataPath.length == 0 || ![fm fileExistsAtPath:dataPath];
        if (bundleGone && dataGone && (!known || !installed)) { return 0; }
        usleep(250000);
    }
    return 31;
}

static int Uninstall(NSString *bundleID, NSString *bundlePath, NSString *dataPath)
{
    if ([bundleID isEqualToString:@"com.cloudcode.ios"]) { return 12; }
    if (!IsSafeBundlePath(bundlePath)) { return 20; }
    if (dataPath.length > 0 && !IsSafeDataPath(dataPath)) { return 21; }

    NSString *bundleContainer = NormalizePath(bundlePath).stringByDeletingLastPathComponent;
    if (!IsSafeBundleContainerPath(bundleContainer)) { return 22; }

    id workspace = Workspace();
    if (!workspace) { return 23; }
    NSArray<NSString *> *pluginPaths = PluginDataPaths(bundleID);

    int terminateResult = TerminateApplication(bundlePath);
    if (terminateResult != 0) {
        fprintf(stderr, "terminate before uninstall returned %d; continuing with verified uninstall flow\n", terminateResult);
    }

    if (SystemUninstall(workspace, bundleID)) {
        int verified = VerifyRemoved(workspace, bundleID, bundlePath, dataPath);
        if (verified == 0) { return 0; }
        fprintf(stderr, "LaunchServices accepted uninstall but final verification did not complete\n");
    }

    if (MobileInstallationUninstallApp(bundleID)) {
        int verified = VerifyRemoved(workspace, bundleID, bundlePath, dataPath);
        if (verified == 0) { return 0; }
        fprintf(stderr, "MobileInstallation accepted uninstall but final verification did not complete\n");
    }

    // Last-resort fallback. Keep shared group containers untouched. Crucially, remove the
    // bundle container before app-owned data so a bundle-removal failure cannot leave the
    // app installed after its data has already been destroyed.
    BOOL unregistered = UnregisterApplication(workspace, bundlePath);
    if (!unregistered) {
        fprintf(stderr, "LaunchServices unregisterApplication returned false; continuing with filesystem fallback and final verification\n");
    }

    if (!RemovePath(bundleContainer, YES)) {
        fprintf(stderr, "bundle-container removal failed; app data was intentionally left untouched\n");
        return 34;
    }

    for (NSString *pluginPath in pluginPaths) {
        RemovePath(pluginPath, NO);
    }
    if (dataPath.length > 0 && !RemovePath(dataPath, YES)) {
        fprintf(stderr, "app bundle is gone but the known data container could not be removed\n");
        return 35;
    }

    UnregisterApplication(workspace, bundlePath);
    BOOL bundleGone = ![[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
    BOOL dataGone = dataPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:dataPath];
    if (bundleGone && dataGone) { return 0; }
    return 31;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { return 10; }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"probe"]) {
            return (getuid() == 0 && geteuid() == 0) ? 0 : 11;
        }
        if ([command isEqualToString:@"probe-terminate"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
            return HasProcessInspectionBackend() ? 0 : 33;
        }
        if ([command isEqualToString:@"uninstall"]) {
            if (argc < 5) { return 10; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            NSString *bundlePath = [NSString stringWithUTF8String:argv[3]];
            NSString *dataPathArgument = [NSString stringWithUTF8String:argv[4]];
            NSString *dataPath = [dataPathArgument isEqualToString:@"-"] ? @"" : dataPathArgument;
            return Uninstall(bundleID, bundlePath, dataPath);
        }
        if ([command isEqualToString:@"terminate"]) {
            if (argc < 3) { return 10; }
            NSString *bundlePath = [NSString stringWithUTF8String:argv[2]];
            return TerminateApplication(bundlePath);
        }
        return 10;
    }
}
