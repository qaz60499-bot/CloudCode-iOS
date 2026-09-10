#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <unistd.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <string.h>
#import "GUIAutomation.h"

#define CLOUDCODE_PROC_PATH_MAX 4096
#define CLOUDCODE_ROOT_HELPER_PROTOCOL_MARKER "cloudcode-root-helper-protocol=1"
typedef int (*CloudCodeProcListAllPidsFn)(void *, int);
typedef int (*CloudCodeProcPidPathFn)(int, void *, uint32_t);
extern char **environ;
extern void *objc_autoreleasePoolPush(void);

static __attribute__((noreturn)) void CloudCodeExitOneShot(int code)
{
    // stdout/stderr are switched to unbuffered mode at process entry before any helper I/O occurs.
    // Build 108 real-device evidence showed that even an explicit stdout/stderr flush could wedge after a
    // private framework had already produced the final observable result, turning successful app
    // launch, screenshot and background-assert handshakes into false parent timeouts. Do not enter
    // stdio teardown/flush paths here: every write is already delivered synchronously to the bridge.
    _exit(code);
}

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

typedef CFStringRef (*CloudCodeCopyFrontmostApplicationDisplayIdentifierFn)(void);

static void *SpringBoardServicesHandle(void)
{
    static void *handle = NULL;
    if (handle) { return handle; }
    for (NSString *path in @[
        @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        @"/rootfs/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
    ]) {
        handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (handle) { break; }
    }
    return handle;
}

static NSString *FrontmostApplicationBundleID(void)
{
    void *handle = SpringBoardServicesHandle();
    if (!handle) { return nil; }
    CloudCodeCopyFrontmostApplicationDisplayIdentifierFn copyFrontmost =
        (CloudCodeCopyFrontmostApplicationDisplayIdentifierFn)dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    if (!copyFrontmost) { return nil; }
    CFStringRef raw = copyFrontmost();
    if (!raw) { return nil; }
    return CFBridgingRelease(raw);
}

static BOOL WaitForFrontmostApplication(NSString *bundleID, useconds_t timeoutMicroseconds)
{
    if (bundleID.length == 0) { return NO; }
    const useconds_t interval = 50000;
    useconds_t elapsed = 0;
    do {
        NSString *frontmost = FrontmostApplicationBundleID();
        if ([frontmost isEqualToString:bundleID]) { return YES; }
        if (elapsed >= timeoutMicroseconds) { break; }
        usleep(interval);
        elapsed += interval;
    } while (YES);
    return NO;
}

static int VerifyFrontmostApplication(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0 || bundleID.length > 255) { return 10; }
    return WaitForFrontmostApplication(bundleID, 1200000) ? 0 : 80;
}

static void LoadBoardFramework(NSString *frameworkName)
{
    if (frameworkName.length == 0) { return; }
    NSString *binary = [NSString stringWithFormat:@"%@.framework/%@", frameworkName, frameworkName];
    for (NSString *root in @[@"/System/Library/PrivateFrameworks", @"/rootfs/System/Library/PrivateFrameworks"]) {
        NSString *path = [root stringByAppendingPathComponent:binary];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (handle) { return; }
    }
}

static BOOL LaunchViaBoardSystemService(NSString *bundleID, NSString *className, NSString *frameworkName, NSString **diagnostic)
{
    LoadBoardFramework(frameworkName);
    Class cls = NSClassFromString(className);
    if (!cls) {
        if (diagnostic) { *diagnostic = [NSString stringWithFormat:@"%@ unavailable", className]; }
        return NO;
    }

    id service = nil;
    SEL sharedSelector = NSSelectorFromString(@"sharedService");
    if ([cls respondsToSelector:sharedSelector]) {
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        service = sendObject(cls, sharedSelector);
    }
    if (!service) { service = [[cls alloc] init]; }
    if (!service) {
        if (diagnostic) { *diagnostic = [NSString stringWithFormat:@"%@ service unavailable", className]; }
        return NO;
    }

    __block NSError *reportedError = nil;
    void (^completion)(NSError *) = ^(NSError *error) {
        reportedError = error;
    };
    @try {
        SEL simpleSelector = NSSelectorFromString(@"openApplication:options:withResult:");
        if ([service respondsToSelector:simpleSelector]) {
            void (*sendOpen)(id, SEL, id, id, void (^)(NSError *)) = (void *)objc_msgSend;
            sendOpen(service, simpleSelector, bundleID, @{}, completion);
        } else {
            SEL createPortSelector = NSSelectorFromString(@"createClientPort");
            SEL clientSelector = NSSelectorFromString(@"openApplication:options:clientPort:withResult:");
            if (![service respondsToSelector:createPortSelector] || ![service respondsToSelector:clientSelector]) {
                if (diagnostic) { *diagnostic = [NSString stringWithFormat:@"%@ openApplication selector unavailable", className]; }
                return NO;
            }
            unsigned int (*sendPort)(id, SEL) = (void *)objc_msgSend;
            unsigned int port = sendPort(service, createPortSelector);
            void (*sendOpenWithPort)(id, SEL, id, id, unsigned int, void (^)(NSError *)) = (void *)objc_msgSend;
            sendOpenWithPort(service, clientSelector, bundleID, @{}, port, completion);
        }
    } @catch (NSException *exception) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:@"%@ launch raised %@", className, exception.name ?: @"exception"];
        }
        return NO;
    }

    if (WaitForFrontmostApplication(bundleID, 1500000)) {
        if (diagnostic) { *diagnostic = [NSString stringWithFormat:@"%@ foreground verification passed", className]; }
        return YES;
    }
    if (diagnostic) {
        *diagnostic = reportedError
            ? [NSString stringWithFormat:@"%@ launch rejected: %@", className, reportedError.localizedDescription ?: @"error"]
            : [NSString stringWithFormat:@"%@ did not establish target foreground", className];
    }
    return NO;
}

static id SafeValue(id object, NSString *key)
{
    if (!object || key.length == 0 || ![object respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *InstalledApplicationProxies(id workspace, NSString **backend)
{
    if (!workspace) { return @[]; }
    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
    for (NSString *selectorName in @[@"allInstalledApplications", @"allApplications"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) { continue; }
        id raw = sendObject(workspace, selector);
        if ([raw isKindOfClass:NSArray.class] && [raw count] > 0) {
            if (backend) { *backend = [@"LaunchServices " stringByAppendingString:selectorName]; }
            return raw;
        }
    }

    SEL enumerateSelector = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
    if ([workspace respondsToSelector:enumerateSelector]) {
        void (*enumerate)(id, SEL, NSUInteger, void (^)(id)) = (void *)objc_msgSend;
        NSMutableArray *collected = [NSMutableArray array];
        void (^block)(id) = ^(id object) {
            if (object) { [collected addObject:object]; }
        };
        enumerate(workspace, enumerateSelector, 0, block);
        enumerate(workspace, enumerateSelector, 1, block);
        if (collected.count > 0) {
            if (backend) { *backend = @"LaunchServices enumerateApplicationsOfType"; }
            return collected.copy;
        }
    }
    return @[];
}

static BOOL ApplicationIsInstalled(id workspace, NSString *bundleID, BOOL *known);

static NSString *BundlePathForIdentifierFromFilesystem(NSString *bundleID)
{
    if (bundleID.length == 0 || bundleID.length > 255) { return nil; }
    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *containers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundleRoot error:nil] ?: @[];
    for (NSString *containerName in containers) {
        NSString *containerPath = [bundleRoot stringByAppendingPathComponent:containerName];
        if (!IsSafeBundleContainerPath(containerPath)) { continue; }
        NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:containerPath error:nil] ?: @[];
        for (NSString *entry in entries) {
            if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) { continue; }
            NSString *bundlePath = [containerPath stringByAppendingPathComponent:entry];
            if (!IsSafeBundlePath(bundlePath)) { continue; }
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *candidate = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
            if ([candidate isEqualToString:bundleID]) { return bundlePath.stringByStandardizingPath; }
        }
    }
    return nil;
}

static NSString *InstalledBundlePath(id workspace, NSString *bundleID)
{
    NSString *filesystemPath = BundlePathForIdentifierFromFilesystem(bundleID);
    if (filesystemPath.length > 0) { return filesystemPath; }
    if (!workspace || bundleID.length == 0) { return nil; }
    NSArray *proxies = InstalledApplicationProxies(workspace, NULL);
    for (id proxy in proxies) {
        NSString *candidate = SafeValue(proxy, @"applicationIdentifier");
        if (![candidate isKindOfClass:NSString.class] || candidate.length == 0) {
            candidate = SafeValue(proxy, @"bundleIdentifier");
        }
        if (![candidate isEqualToString:bundleID]) { continue; }
        NSURL *bundleURL = SafeValue(proxy, @"bundleURL");
        if (![bundleURL isKindOfClass:NSURL.class]) { return nil; }
        NSString *path = bundleURL.path.stringByStandardizingPath;
        return IsSafeBundlePath(path) ? path : nil;
    }
    return nil;
}

static BOOL IsSafeIPAPath(NSString *path)
{
    NSString *normalized = NormalizePath(path);
    NSString *extension = normalized.pathExtension.lowercaseString;
    if (!normalized || (![extension isEqualToString:@"ipa"] && ![extension isEqualToString:@"tipa"])) { return NO; }
    if (!HasAnyPrefix(normalized, @[
        @"/var/mobile/",
        @"/private/var/mobile/"
    ])) { return NO; }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:normalized error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) { return NO; }
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    return size > 0 && size <= (4ULL * 1024ULL * 1024ULL * 1024ULL);
}

static NSString *TrollStoreHelperPathFromFilesystem(void)
{
    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *containers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundleRoot error:nil] ?: @[];
    for (NSString *containerName in containers) {
        NSString *containerPath = [bundleRoot stringByAppendingPathComponent:containerName];
        if (!IsSafeBundleContainerPath(containerPath)) { continue; }
        NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:containerPath error:nil] ?: @[];
        for (NSString *entry in entries) {
            if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) { continue; }
            NSString *bundlePath = [containerPath stringByAppendingPathComponent:entry];
            if (!IsSafeBundlePath(bundlePath)) { continue; }
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleID = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? [info[@"CFBundleIdentifier"] lowercaseString] : @"";
            // Current TrollStore uses com.opa334.TrollStore; stealth builds keep that namespace and
            // append a randomized TS suffix. Never execute an arbitrary app-provided helper merely
            // because it happens to be named trollstorehelper.
            if (![bundleID hasPrefix:@"com.opa334.trollstore"]) { continue; }
            NSString *helper = [bundlePath stringByAppendingPathComponent:@"trollstorehelper"];
            if ([NSFileManager.defaultManager fileExistsAtPath:helper] && [NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
                return helper.stringByStandardizingPath;
            }
        }
    }
    return nil;
}

static int ProbeIPAInstallCapability(void)
{
    if (getuid() != 0 || geteuid() != 0) { CloudCodeExitOneShot(11); }
    NSString *helper = TrollStoreHelperPathFromFilesystem();
    if (helper.length == 0) { CloudCodeExitOneShot(83); }
    fputs("trollstore-install-backend=available\n", stdout);
    CloudCodeExitOneShot(0);
}

static int InstallIPAThroughTrollStore(NSString *ipaPath, NSString *expectedBundleID, NSString *expectedBuild)
{
    if (getuid() != 0 || geteuid() != 0) { CloudCodeExitOneShot(11); }
    NSString *normalized = NormalizePath(ipaPath);
    if (!IsSafeIPAPath(normalized) || expectedBundleID.length == 0 || expectedBundleID.length > 255 || expectedBuild.length > 128) {
        CloudCodeExitOneShot(82);
    }
    NSString *helper = TrollStoreHelperPathFromFilesystem();
    if (helper.length == 0) { CloudCodeExitOneShot(83); }

    const char *helperPath = helper.fileSystemRepresentation;
    const char *command = "install";
    const char *mode = "custom";
    const char *archive = normalized.fileSystemRepresentation;
    char *const childArgv[] = {(char *)helperPath, (char *)command, (char *)mode, (char *)archive, NULL};
    pid_t child = 0;
    int spawnError = posix_spawn(&child, helperPath, NULL, NULL, childArgv, environ);
    if (spawnError != 0 || child <= 1) {
        fprintf(stderr, "trollstore-install: spawn failed error=%d\n", spawnError);
        CloudCodeExitOneShot(84);
    }

    int status = 0;
    BOOL reaped = NO;
    for (int attempt = 0; attempt < 900; attempt++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) { reaped = YES; break; }
        if (waited == -1 && errno != EINTR) { break; }
        usleep(100000);
    }
    if (!reaped) {
        (void)kill(child, SIGKILL);
        do { } while (waitpid(child, &status, 0) == -1 && errno == EINTR);
        fprintf(stderr, "trollstore-install: timed out after 90 seconds\n");
        CloudCodeExitOneShot(84);
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        fprintf(stderr, "trollstore-install: helper returned %d\n", code);
        CloudCodeExitOneShot(84);
    }

    NSString *installedBundlePath = BundlePathForIdentifierFromFilesystem(expectedBundleID);
    NSDictionary *installedInfo = installedBundlePath.length > 0
        ? [NSDictionary dictionaryWithContentsOfFile:[installedBundlePath stringByAppendingPathComponent:@"Info.plist"]]
        : nil;
    NSString *installedBundleID = [installedInfo[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? installedInfo[@"CFBundleIdentifier"] : @"";
    NSString *installedBuild = [installedInfo[@"CFBundleVersion"] isKindOfClass:NSString.class] ? installedInfo[@"CFBundleVersion"] : @"";
    if (![installedBundleID isEqualToString:expectedBundleID] || (expectedBuild.length > 0 && ![installedBuild isEqualToString:expectedBuild])) {
        fprintf(stderr, "trollstore-install: postcondition mismatch expectedBundle=%s expectedBuild=%s actualBundle=%s actualBuild=%s\n",
                expectedBundleID.UTF8String ?: "", expectedBuild.UTF8String ?: "",
                installedBundleID.UTF8String ?: "", installedBuild.UTF8String ?: "");
        CloudCodeExitOneShot(85);
    }
    fprintf(stdout, "trollstore-install: verified bundle=%s build=%s\n", installedBundleID.UTF8String ?: "", installedBuild.UTF8String ?: "");
    CloudCodeExitOneShot(0);
}

static NSDictionary<NSString *, NSString *> *DataContainerPathsByBundleID(void)
{
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    for (NSString *entry in entries) {
        NSString *path = [root stringByAppendingPathComponent:entry];
        if (!IsSafeDataPath(path)) { continue; }
        NSString *metadataPath = [path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *bundleID = [metadata[@"MCMMetadataIdentifier"] isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
        if (bundleID.length > 0 && result[bundleID] == nil) { result[bundleID] = path; }
    }
    return result.copy;
}

static int PrintInstalledApplicationsJSON(void)
{
    // Read-only discovery must not depend on LaunchServices. On the TrollStore iOS 16.6 device,
    // allInstalledApplications/allApplications can block until the parent watchdog while the same
    // app bundles and MCM metadata are immediately readable through the privileged filesystem view.
    // Treat physical presence as discovery evidence only; exact launch/uninstall still revalidate
    // installation state through their own bounded system routes.
    NSMutableDictionary<NSString *, NSDictionary *> *byBundleID = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSString *> *dataPathsByBundleID = DataContainerPathsByBundleID();
    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *containers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundleRoot error:nil] ?: @[];
    for (NSString *containerName in containers) {
        NSString *containerPath = [bundleRoot stringByAppendingPathComponent:containerName];
        if (!IsSafeBundleContainerPath(containerPath)) { continue; }
        NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:containerPath error:nil] ?: @[];
        for (NSString *entry in entries) {
            if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) { continue; }
            NSString *bundlePath = [containerPath stringByAppendingPathComponent:entry];
            if (!IsSafeBundlePath(bundlePath)) { continue; }
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleID = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
            if (bundleID.length == 0 || byBundleID[bundleID] != nil) { continue; }
            NSString *name = [info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"] : nil;
            if (name.length == 0 && [info[@"CFBundleName"] isKindOfClass:NSString.class]) { name = info[@"CFBundleName"]; }
            if (name.length == 0) { name = bundleID; }
            NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
            byBundleID[bundleID] = @{
                @"bundleID": bundleID,
                @"name": name,
                @"version": version ?: @"",
                @"bundlePath": bundlePath,
                @"dataContainerPath": dataPathsByBundleID[bundleID] ?: @"",
                @"registered": @YES
            };
        }
    }
    if (byBundleID.count == 0) { CloudCodeExitOneShot(40); }
    NSArray *apps = [[byBundleID allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        return [lhs[@"name"] localizedCaseInsensitiveCompare:rhs[@"name"]];
    }];
    NSDictionary *payload = @{@"backend": @"BundleFilesystem(read-only-discovery)", @"apps": apps};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error) { CloudCodeExitOneShot(41); }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    CloudCodeExitOneShot(0);
}

static int ProbePrivilegedFilesystemJSON(void)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *sharedPath = @"/var/mobile/Media";
    NSString *preferencesPath = @"/var/mobile/Library/Preferences";
    BOOL sharedUserFiles = [fileManager isReadableFileAtPath:sharedPath];
    BOOL unrestricted = NO;
    NSString *detail = @"root helper could not prove unrestricted read/write access";

    if ([fileManager isReadableFileAtPath:preferencesPath] && [fileManager isWritableFileAtPath:preferencesPath]) {
        NSString *name = [@".cloudcode-capability-" stringByAppendingString:[NSUUID UUID].UUIDString];
        NSString *canary = [preferencesPath stringByAppendingPathComponent:name];
        NSData *expected = [@"CCPR" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *writeError = nil;
        BOOL wrote = [expected writeToFile:canary options:NSDataWritingAtomic error:&writeError];
        if (wrote) {
            NSData *actual = [NSData dataWithContentsOfFile:canary options:0 error:nil];
            unrestricted = [actual isEqualToData:expected];
        }
        NSError *removeError = nil;
        if ([fileManager fileExistsAtPath:canary]) {
            [fileManager removeItemAtPath:canary error:&removeError];
        }
        if (unrestricted) {
            detail = @"root helper verified bounded read/write/delete access outside the app container";
        } else if (writeError) {
            detail = [@"root helper write probe failed: " stringByAppendingString:writeError.localizedDescription ?: @"unknown error"];
        } else if (removeError) {
            detail = [@"root helper cleanup probe failed: " stringByAppendingString:removeError.localizedDescription ?: @"unknown error"];
        }
    }

    NSDictionary *payload = @{
        @"sharedUserFiles": @(sharedUserFiles),
        @"unrestricted": @(unrestricted),
        @"detail": detail
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error) { CloudCodeExitOneShot(41); }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    CloudCodeExitOneShot(0);
}

static int ProbeLaunchCapability(void)
{
    id workspace = Workspace();
    if (!workspace) { CloudCodeExitOneShot(23); }
    CloudCodeExitOneShot([workspace respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")] ? 0 : 42);
}

static int LaunchApplication(NSString *bundleID)
{
    if (bundleID.length == 0 || [bundleID isEqualToString:@"com.cloudcode.ios"]) { CloudCodeExitOneShot(10); }
    id workspace = Workspace();
    if (!workspace) { CloudCodeExitOneShot(23); }
    BOOL known = NO;
    BOOL installed = ApplicationIsInstalled(workspace, bundleID, &known);
    if (!known) { CloudCodeExitOneShot(43); }
    if (!installed) { CloudCodeExitOneShot(47); }

    if ([[FrontmostApplicationBundleID() lowercaseString] isEqualToString:bundleID.lowercaseString]) {
        fprintf(stderr, "launch: target already foreground route=springboard-frontmost\n");
        CloudCodeExitOneShot(0);
    }

    SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
    BOOL launchServicesAccepted = NO;
    if ([workspace respondsToSelector:selector]) {
        BOOL (*sendBool)(id, SEL, id) = (void *)objc_msgSend;
        @try {
            launchServicesAccepted = sendBool(workspace, selector, bundleID);
        } @catch (__unused NSException *exception) {
            launchServicesAccepted = NO;
        }
        if (launchServicesAccepted) {
            BOOL foregroundVerified = WaitForFrontmostApplication(bundleID, 750000);
            fprintf(stderr, "launch: route=launchservices accepted=1 foreground=%s\n", foregroundVerified ? "verified" : "unverified");
            if (foregroundVerified) { CloudCodeExitOneShot(0); }
        }
        if (WaitForFrontmostApplication(bundleID, 150000)) {
            fprintf(stderr, "launch: route=launchservices accepted=0 but target is foreground\n");
            CloudCodeExitOneShot(0);
        }
    }

    // The ordinary mobile-persona helper remains the least-privilege fast path. Only the signed
    // root helper is allowed to fall back to the same board-service activation path Apple's own
    // debugserver uses for device launches. The concrete launch is still bounded to one Bundle ID,
    // and success requires the requested App to become the actual frontmost application.
    if (geteuid() != 0) {
        fprintf(stderr, "launch: isolated LaunchServices path did not establish target foreground; privileged board fallback required\n");
        CloudCodeExitOneShot([workspace respondsToSelector:selector] ? 46 : 42);
    }

    NSString *frontBoardDiagnostic = nil;
    if (LaunchViaBoardSystemService(bundleID, @"FBSSystemService", @"FrontBoardServices", &frontBoardDiagnostic)) {
        fprintf(stderr, "launch: route=frontboard %s\n", frontBoardDiagnostic.UTF8String ?: "verified");
        CloudCodeExitOneShot(0);
    }

    NSString *backBoardDiagnostic = nil;
    if (LaunchViaBoardSystemService(bundleID, @"BKSSystemService", @"BackBoardServices", &backBoardDiagnostic)) {
        fprintf(stderr, "launch: route=backboard %s\n", backBoardDiagnostic.UTF8String ?: "verified");
        CloudCodeExitOneShot(0);
    }

    fprintf(stderr,
            "launch: route=launchservices+frontboard+backboard rejected lsSelector=%s fbs=%s bks=%s\n",
            [workspace respondsToSelector:selector] ? "available" : "unavailable",
            frontBoardDiagnostic.UTF8String ?: "unavailable",
            backBoardDiagnostic.UTF8String ?: "unavailable");
    CloudCodeExitOneShot([workspace respondsToSelector:selector] ? 46 : 42);
}

static int ProbeUninstallCapability(NSString *bundleID)
{
    id workspace = Workspace();
    if (!workspace) { return 23; }
    BOOL known = NO;
    BOOL installed = ApplicationIsInstalled(workspace, bundleID, &known);
    if (!known) { return 43; }
    if (!installed) { return 44; }
    BOOL hasLaunchServices = [workspace respondsToSelector:NSSelectorFromString(@"uninstallApplication:withOptions:error:")]
        || [workspace respondsToSelector:NSSelectorFromString(@"uninstallApplication:withOptions:")];
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    BOOL hasMobileInstallation = handle && dlsym(handle, "MobileInstallationUninstall") != NULL;
    if (handle) { dlclose(handle); }
    if (!hasLaunchServices && !hasMobileInstallation) { return 45; }

    // LaunchServices can report that an app is unregistered before its bundle container is gone.
    // Our exact uninstall path therefore needs a verified filesystem fallback when
    // MobileInstallation is unavailable. Probe that prerequisite read-only instead of claiming
    // availability from selector presence alone.
    if (!hasMobileInstallation) {
        NSString *bundlePath = InstalledBundlePath(workspace, bundleID);
        if (bundlePath.length == 0) { return 48; }
        NSString *bundleContainer = bundlePath.stringByDeletingLastPathComponent;
        NSString *bundleRoot = bundleContainer.stringByDeletingLastPathComponent;
        BOOL safeRoot = [bundleRoot isEqualToString:@"/var/containers/Bundle/Application"]
            || [bundleRoot isEqualToString:@"/private/var/containers/Bundle/Application"];
        if (!IsSafeBundleContainerPath(bundleContainer)
            || !safeRoot
            || ![NSFileManager.defaultManager isReadableFileAtPath:bundleContainer]
            || ![NSFileManager.defaultManager isWritableFileAtPath:bundleContainer]
            || ![NSFileManager.defaultManager isWritableFileAtPath:bundleRoot]) {
            return 48;
        }
    }
    return 0;
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

static int InstalledState(NSString *bundleID)
{
    if (bundleID.length == 0) { CloudCodeExitOneShot(10); }
    id workspace = Workspace();
    if (!workspace) { CloudCodeExitOneShot(23); }
    BOOL known = NO;
    BOOL installed = ApplicationIsInstalled(workspace, bundleID, &known);
    if (!known) { CloudCodeExitOneShot(43); }
    CloudCodeExitOneShot(installed ? 0 : 47);
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

static NSArray<NSString *> *CloudCodeBoundedStringArray(id value, NSUInteger limit)
{
    if (![value isKindOfClass:NSArray.class]) { return @[]; }
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (id item in (NSArray *)value) {
        if (result.count >= limit) { break; }
        if ([item isKindOfClass:NSString.class] && [(NSString *)item length] > 0 && [(NSString *)item length] <= 512) {
            [result addObject:item];
        }
    }
    return result.array;
}

static int PrintAppIntrospectionJSON(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0 || bundleID.length > 255) { CloudCodeExitOneShot(10); }
    // Exact metadata reads do not need an LSApplicationProxy. Resolve the real bundle and data
    // container directly from the bounded filesystem view so a degraded LaunchServices service
    // cannot turn a simple WeChat/Douyin lookup into a 5s watchdog timeout.
    NSString *bundlePath = BundlePathForIdentifierFromFilesystem(bundleID);
    NSString *dataPath = DataContainerPathsByBundleID()[bundleID];
    if (!IsSafeBundlePath(bundlePath)) { CloudCodeExitOneShot(44); }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:NSDictionary.class]) { CloudCodeExitOneShot(78); }
    NSString *actualBundleID = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
    if (![actualBundleID isEqualToString:bundleID]) { CloudCodeExitOneShot(78); }

    NSMutableOrderedSet<NSString *> *schemes = [NSMutableOrderedSet orderedSet];
    for (id rawType in ([info[@"CFBundleURLTypes"] isKindOfClass:NSArray.class] ? info[@"CFBundleURLTypes"] : @[])) {
        if (![rawType isKindOfClass:NSDictionary.class]) { continue; }
        for (NSString *scheme in CloudCodeBoundedStringArray(rawType[@"CFBundleURLSchemes"], 32)) {
            if (schemes.count >= 64) { break; }
            [schemes addObject:scheme];
        }
    }

    NSMutableOrderedSet<NSString *> *documentTypes = [NSMutableOrderedSet orderedSet];
    for (id rawType in ([info[@"CFBundleDocumentTypes"] isKindOfClass:NSArray.class] ? info[@"CFBundleDocumentTypes"] : @[])) {
        if (![rawType isKindOfClass:NSDictionary.class]) { continue; }
        for (NSString *uti in CloudCodeBoundedStringArray(rawType[@"LSItemContentTypes"], 32)) {
            if (documentTypes.count >= 64) { break; }
            [documentTypes addObject:uti];
        }
    }

    NSMutableOrderedSet<NSString *> *utTypes = [NSMutableOrderedSet orderedSetWithArray:documentTypes.array];
    for (NSString *key in @[@"UTExportedTypeDeclarations", @"UTImportedTypeDeclarations"]) {
        for (id rawDecl in ([info[key] isKindOfClass:NSArray.class] ? info[key] : @[])) {
            if (![rawDecl isKindOfClass:NSDictionary.class]) { continue; }
            NSString *identifier = [rawDecl[@"UTTypeIdentifier"] isKindOfClass:NSString.class] ? rawDecl[@"UTTypeIdentifier"] : nil;
            if (identifier.length > 0 && identifier.length <= 512 && utTypes.count < 96) { [utTypes addObject:identifier]; }
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *extensions = [NSMutableArray array];
    NSString *pluginsPath = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *entry in ([fm contentsOfDirectoryAtPath:pluginsPath error:nil] ?: @[])) {
        if (extensions.count >= 48) { break; }
        if ([entry.pathExtension.lowercaseString isEqualToString:@"appex"]) { [extensions addObject:entry]; }
    }
    NSMutableArray<NSString *> *frameworks = [NSMutableArray array];
    NSString *frameworksPath = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *entry in ([fm contentsOfDirectoryAtPath:frameworksPath error:nil] ?: @[])) {
        if (frameworks.count >= 64) { break; }
        if ([entry.pathExtension.lowercaseString isEqualToString:@"framework"] || [entry.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            [frameworks addObject:entry];
        }
    }

    // App-group container discovery is a secondary hint and previously forced LSApplicationProxy
    // back into this otherwise filesystem-only metadata path. Keep it empty when not available from
    // bounded static metadata; the runtime does not require app groups for app launch or GUI control.
    NSMutableOrderedSet<NSString *> *appGroups = [NSMutableOrderedSet orderedSet];

    NSMutableDictionary<NSString *, NSString *> *localData = [NSMutableDictionary dictionary];
    if (IsSafeDataPath(dataPath)) {
        NSDictionary<NSString *, NSString *> *aliases = @{
            @"preferences": [dataPath stringByAppendingPathComponent:@"Library/Preferences"],
            @"applicationSupport": [dataPath stringByAppendingPathComponent:@"Library/Application Support"],
            @"documents": [dataPath stringByAppendingPathComponent:@"Documents"],
            @"cache": [dataPath stringByAppendingPathComponent:@"Library/Caches"]
        };
        [aliases enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *path, BOOL *stop) {
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory && IsSafeDataPath(path)) { localData[key] = path; }
        }];
    }

    NSString *displayName = [info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"] : nil;
    if (displayName.length == 0 && [info[@"CFBundleName"] isKindOfClass:NSString.class]) { displayName = info[@"CFBundleName"]; }
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"";
    NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : @"";

    NSDictionary *payload = @{
        @"bundleID": actualBundleID ?: @"",
        @"displayName": displayName ?: bundleID,
        @"version": version ?: @"",
        @"build": build ?: @"",
        @"bundlePath": bundlePath ?: @"",
        @"dataContainerPath": IsSafeDataPath(dataPath) ? dataPath : @"",
        @"executable": executable ?: @"",
        @"urlSchemes": schemes.array ?: @[],
        @"documentTypes": documentTypes.array ?: @[],
        @"utTypes": utTypes.array ?: @[],
        @"extensions": extensions ?: @[],
        @"frameworks": frameworks ?: @[],
        @"appGroups": appGroups.array ?: @[],
        @"localData": localData ?: @{}
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error || data.length == 0 || data.length > (256 * 1024)) { CloudCodeExitOneShot(79); }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    // Do not return through ARC cleanup after touching app-container metadata. On-device evidence
    // shows private helper teardown can outlive the parent watchdog after the payload is complete.
    CloudCodeExitOneShot(0);
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

static int CleanupUnregisteredApplication(NSString *bundleID, NSString *bundlePath, NSString *dataPath)
{
    if ([bundleID isEqualToString:@"com.cloudcode.ios"]) { return 12; }
    if (!IsSafeBundlePath(bundlePath)) { return 20; }
    if (dataPath.length > 0 && !IsSafeDataPath(dataPath)) { return 21; }
    NSString *bundleContainer = NormalizePath(bundlePath).stringByDeletingLastPathComponent;
    if (!IsSafeBundleContainerPath(bundleContainer)) { return 22; }

    id workspace = Workspace();
    if (!workspace) { return 23; }
    BOOL known = NO;
    BOOL installed = ApplicationIsInstalled(workspace, bundleID, &known);
    if (!known) { return 43; }
    if (installed) {
        fprintf(stderr, "cleanup-unregistered refused: target is still registered as installed\n");
        return 49;
    }

    NSString *effectiveDataPath = dataPath;
    if (effectiveDataPath.length == 0) {
        effectiveDataPath = DataContainerPathsByBundleID()[bundleID];
    }
    if (effectiveDataPath.length > 0 && !IsSafeDataPath(effectiveDataPath)) { return 21; }

    NSArray<NSString *> *pluginPaths = PluginDataPaths(bundleID);
    if (!RemovePath(bundleContainer, YES)) { return 34; }
    for (NSString *pluginPath in pluginPaths) { RemovePath(pluginPath, NO); }
    if (effectiveDataPath.length > 0 && !RemovePath(effectiveDataPath, YES)) { return 35; }
    return VerifyRemoved(workspace, bundleID, bundlePath, effectiveDataPath);
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

static void RedirectStandardIOToNull(void)
{
    int nullFD = open("/dev/null", O_RDWR);
    if (nullFD < 0) { return; }
    (void)dup2(nullFD, STDIN_FILENO);
    (void)dup2(nullFD, STDOUT_FILENO);
    (void)dup2(nullFD, STDERR_FILENO);
    if (nullFD > STDERR_FILENO) { close(nullFD); }
}

static int BackgroundAssertionWorker(pid_t targetPID, int handshakeFD)
{
    if (getuid() != 0 || geteuid() != 0) { return 11; }
    if (targetPID <= 1 || handshakeFD < 0 || kill(targetPID, 0) != 0) { return 73; }

    (void)setsid();
    void *assertionHandle = dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_NOW | RTLD_GLOBAL);
    if (!assertionHandle) {
        uint8_t failed = 0;
        (void)write(handshakeFD, &failed, sizeof(failed));
        close(handshakeFD);
        return 75;
    }

    Class assertionClass = NSClassFromString(@"BKSProcessAssertion");
    SEL acquireSelector = NSSelectorFromString(@"initWithPID:flags:reason:name:withHandler:acquire:");
    SEL legacySelector = NSSelectorFromString(@"initWithPID:flags:reason:name:withHandler:");
    BOOL hasAcquireSelector = assertionClass && [assertionClass instancesRespondToSelector:acquireSelector];
    BOOL hasLegacySelector = assertionClass && [assertionClass instancesRespondToSelector:legacySelector];
    if (!hasAcquireSelector && !hasLegacySelector) {
        uint8_t failed = 0;
        (void)write(handshakeFD, &failed, sizeof(failed));
        close(handshakeFD);
        return 75;
    }

    __block BOOL callbackCalled = NO;
    __block BOOL acquired = NO;
    void (^handler)(BOOL) = ^(BOOL didAcquire) {
        acquired = didAcquire;
        callbackCalled = YES;
    };
    id allocated = ((id (*)(id, SEL))objc_msgSend)(assertionClass, NSSelectorFromString(@"alloc"));
    id assertion = nil;
    @try {
        if (hasAcquireSelector) {
            id (*sendInitAcquire)(id, SEL, pid_t, uint32_t, uint32_t, id, id, BOOL) = (void *)objc_msgSend;
            assertion = sendInitAcquire(allocated, acquireSelector, targetPID, 1u, 10004u, @"CloudCode.BackgroundAgent", handler, YES);
        } else {
            id (*sendInitLegacy)(id, SEL, pid_t, uint32_t, uint32_t, id, id) = (void *)objc_msgSend;
            assertion = sendInitLegacy(allocated, legacySelector, targetPID, 1u, 10004u, @"CloudCode.BackgroundAgent", handler);
        }
    } @catch (__unused NSException *exception) {
        assertion = nil;
    }

    for (int attempt = 0; assertion && !callbackCalled && attempt < 40; attempt++) { usleep(50000); }
    BOOL valid = assertion != nil;
    SEL validSelector = NSSelectorFromString(@"valid");
    if (assertion && [assertion respondsToSelector:validSelector]) {
        BOOL (*sendBool0)(id, SEL) = (void *)objc_msgSend;
        @try { valid = sendBool0(assertion, validSelector); } @catch (__unused NSException *exception) { valid = callbackCalled ? acquired : NO; }
    } else if (callbackCalled) {
        valid = acquired;
    }

    uint8_t status = valid ? 1 : 0;
    (void)write(handshakeFD, &status, sizeof(status));
    close(handshakeFD);
    if (!valid) { return 75; }

    RedirectStandardIOToNull();
    // A live worker PID is not proof that its RunningBoard/BKS assertion remains effective. The
    // previous implementation could therefore keep reporting "background assertion alive" after
    // the assertion itself had been invalidated and the target App was already suspendable. Keep
    // the worker lifetime coupled to the assertion's `valid` state so the existing status command
    // becomes meaningful: when validity is lost the worker exits and the App can fall back to its
    // checkpoint/restart recovery path instead of trusting a zombie guardian process.
    while (kill(targetPID, 0) == 0) {
        BOOL assertionStillValid = YES;
        if ([assertion respondsToSelector:validSelector]) {
            BOOL (*sendBool0)(id, SEL) = (void *)objc_msgSend;
            @try { assertionStillValid = sendBool0(assertion, validSelector); }
            @catch (__unused NSException *exception) { assertionStillValid = NO; }
        } else if (callbackCalled) {
            assertionStillValid = acquired;
        }
        if (!assertionStillValid) { break; }
        sleep(2);
    }
    SEL invalidateSelector = NSSelectorFromString(@"invalidate");
    if ([assertion respondsToSelector:invalidateSelector]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(assertion, invalidateSelector); } @catch (__unused NSException *exception) {}
    }
    return 0;
}

static int StartDetachedBackgroundAssertion(pid_t targetPID, const char *helperExecutablePath)
{
    if (getuid() != 0 || geteuid() != 0) { return 11; }
    if (targetPID <= 1 || kill(targetPID, 0) != 0) { return 73; }
    if (!helperExecutablePath || helperExecutablePath[0] != '/') { return 74; }

    int handshake[2] = {-1, -1};
    if (pipe(handshake) != 0) { return 74; }

    char targetArg[32] = {0};
    char handshakeArg[32] = {0};
    snprintf(targetArg, sizeof(targetArg), "%d", targetPID);
    snprintf(handshakeArg, sizeof(handshakeArg), "%d", handshake[1]);
    char *const workerArgv[] = {
        (char *)helperExecutablePath,
        (char *)"background-assert-worker",
        targetArg,
        handshakeArg,
        NULL
    };

    posix_spawn_file_actions_t actions;
    int actionsError = posix_spawn_file_actions_init(&actions);
    if (actionsError != 0) {
        close(handshake[0]);
        close(handshake[1]);
        return 74;
    }
    actionsError = posix_spawn_file_actions_addclose(&actions, handshake[0]);
    if (actionsError != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(handshake[0]);
        close(handshake[1]);
        return 74;
    }

    pid_t workerPID = 0;
    int spawnError = posix_spawn(&workerPID, helperExecutablePath, &actions, NULL, workerArgv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(handshake[1]);
    if (spawnError != 0 || workerPID <= 1) {
        close(handshake[0]);
        fprintf(stderr, "background-assert: spawn failed targetPID=%d error=%d\n", targetPID, spawnError);
        return 74;
    }

    uint8_t acquired = 0;
    struct pollfd pollFD = {.fd = handshake[0], .events = POLLIN | POLLHUP, .revents = 0};
    int pollResult = 0;
    do {
        pollResult = poll(&pollFD, 1, 2500);
    } while (pollResult < 0 && errno == EINTR);
    ssize_t count = pollResult > 0 ? read(handshake[0], &acquired, sizeof(acquired)) : -1;
    close(handshake[0]);
    if (count == sizeof(acquired) && acquired == 1) {
        fprintf(stderr, "background-assert: acquired targetPID=%d workerPID=%d spawn=posix_spawn flags=1 reason=10004\n", targetPID, workerPID);
        // This command's only observable result is the detached worker PID written above. Build 110
        // repeatedly reached this line and then still hit the parent watchdog. Cross the one-shot
        // boundary here instead of unwinding through any process-global Foundation/private state.
        CloudCodeExitOneShot(0);
    }

    (void)kill(workerPID, SIGKILL);
    fprintf(stderr, "background-assert: acquisition failed targetPID=%d workerPID=%d poll=%d errno=%d\n", targetPID, workerPID, pollResult, errno);
    CloudCodeExitOneShot(75);
}

static int StopDetachedBackgroundAssertion(pid_t workerPID)
{
    if (getuid() != 0 || geteuid() != 0) { return 11; }
    if (workerPID <= 1) { return 10; }
    if (kill(workerPID, SIGTERM) == 0 || errno == ESRCH) { return 0; }
    return 76;
}

static int BackgroundAssertionWorkerStatus(pid_t workerPID)
{
    if (getuid() != 0 || geteuid() != 0) { return 11; }
    if (workerPID <= 1) { return 10; }
    return kill(workerPID, 0) == 0 ? 0 : 77;
}

static int CloudCodeRunOneShotCommand(int argc, const char *argv[])
{
        if (argc < 2) { return 10; }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"probe"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
            fputs(CLOUDCODE_ROOT_HELPER_PROTOCOL_MARKER "\n", stdout);
            return 0;
        }
        if ([command isEqualToString:@"probe-terminate"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
            return HasProcessInspectionBackend() ? 0 : 33;
        }
        if ([command isEqualToString:@"probe-filesystem-json"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
            return ProbePrivilegedFilesystemJSON();
        }
        if ([command isEqualToString:@"enumerate-json"]) {
            return PrintInstalledApplicationsJSON();
        }
        if ([command isEqualToString:@"app-introspect-json"]) {
            if (argc < 3) { return 10; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            return PrintAppIntrospectionJSON(bundleID);
        }
        if ([command isEqualToString:@"probe-launch"]) {
            return ProbeLaunchCapability();
        }
        if ([command isEqualToString:@"probe-uninstall"]) {
            if (getuid() != 0 || geteuid() != 0 || argc < 3) { return 11; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            return ProbeUninstallCapability(bundleID);
        }
        if ([command isEqualToString:@"probe-ipa-install"]) {
            return ProbeIPAInstallCapability();
        }
        if ([command isEqualToString:@"install-ipa"]) {
            if (argc < 5) { return 10; }
            NSString *ipaPath = [NSString stringWithUTF8String:argv[2]];
            NSString *bundleID = [NSString stringWithUTF8String:argv[3]];
            NSString *build = [NSString stringWithUTF8String:argv[4]];
            return InstallIPAThroughTrollStore(ipaPath, bundleID, build);
        }
        if ([command isEqualToString:@"is-installed"]) {
            if (getuid() != 0 || geteuid() != 0 || argc < 3) { return 11; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            return InstalledState(bundleID);
        }
        if ([command isEqualToString:@"launch"]) {
            if (argc < 3) { return 10; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            return LaunchApplication(bundleID);
        }
        if ([command isEqualToString:@"is-frontmost"]) {
            if (argc < 3) { return 10; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            return VerifyFrontmostApplication(bundleID);
        }
        if ([command isEqualToString:@"gui-probe-json"]) {
            return CloudCodeGUIProbeJSON();
        }
        if ([command isEqualToString:@"gui-tree-json"]) {
            return CloudCodeGUITreeJSON();
        }
        if ([command isEqualToString:@"gui-ax-probe-json"]) {
            if (argc != 6) { return 10; }
            return CloudCodeGUIAXProbeJSON([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]],
                (pid_t)strtol(argv[4], NULL, 10), [NSString stringWithUTF8String:argv[5]]);
        }
        if ([command isEqualToString:@"gui-screenshot-base64"]) {
            return CloudCodeGUIScreenshotBase64();
        }
        if ([command isEqualToString:@"gui-screenshot-file"]) {
            if (argc < 3) { return 10; }
            NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
            return CloudCodeGUIScreenshotFile(outputPath);
        }
        if ([command isEqualToString:@"gui-tap"]) {
            if (argc < 4) { return 10; }
            return CloudCodeGUITap(strtod(argv[2], NULL), strtod(argv[3], NULL));
        }
        if ([command isEqualToString:@"gui-swipe"]) {
            if (argc < 7) { return 10; }
            return CloudCodeGUISwipe(strtod(argv[2], NULL), strtod(argv[3], NULL), strtod(argv[4], NULL), strtod(argv[5], NULL), strtod(argv[6], NULL));
        }
        if ([command isEqualToString:@"gui-scroll"]) {
            if (argc < 4) { return 10; }
            return CloudCodeGUIScroll(strtod(argv[2], NULL), strtod(argv[3], NULL));
        }
        if ([command isEqualToString:@"gui-navigate-back"]) {
            if (argc < 3) { return 10; }
            NSString *strategy = [NSString stringWithUTF8String:argv[2]];
            return CloudCodeGUINavigateBack(strategy);
        }
        if ([command isEqualToString:@"gui-focused-text-input-json"]) {
            return CloudCodeGUIFocusedTextInputJSON();
        }
        if ([command isEqualToString:@"gui-type-base64"]) {
            if (argc < 3) { return 10; }
            NSString *encoded = [NSString stringWithUTF8String:argv[2]];
            return CloudCodeGUITypeBase64(encoded);
        }
        if ([command isEqualToString:@"background-assert-worker"]) {
            if (argc < 4) { return 10; }
            return BackgroundAssertionWorker((pid_t)strtol(argv[2], NULL, 10), (int)strtol(argv[3], NULL, 10));
        }
        if ([command isEqualToString:@"background-assert-start"]) {
            if (argc < 3) { return 10; }
            return StartDetachedBackgroundAssertion((pid_t)strtol(argv[2], NULL, 10), argv[0]);
        }
        if ([command isEqualToString:@"background-assert-stop"]) {
            if (argc < 3) { return 10; }
            return StopDetachedBackgroundAssertion((pid_t)strtol(argv[2], NULL, 10));
        }
        if ([command isEqualToString:@"background-assert-status"]) {
            if (argc < 3) { return 10; }
            return BackgroundAssertionWorkerStatus((pid_t)strtol(argv[2], NULL, 10));
        }
        if ([command isEqualToString:@"cleanup-unregistered"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
            if (argc < 5) { return 10; }
            NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
            NSString *bundlePath = [NSString stringWithUTF8String:argv[3]];
            NSString *dataPathArgument = [NSString stringWithUTF8String:argv[4]];
            NSString *dataPath = [dataPathArgument isEqualToString:@"-"] ? @"" : dataPathArgument;
            return CleanupUnregisteredApplication(bundleID, bundlePath, dataPath);
        }
        if ([command isEqualToString:@"uninstall"]) {
            if (getuid() != 0 || geteuid() != 0) { return 11; }
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

int main(int argc, const char *argv[])
{
    // Make bridge-owned stdout/stderr synchronous before any Foundation/private-framework work.
    // This lets all one-shot commands hard-exit after their final write without calling fflush on
    // process-global stdio state that can wedge on-device after LaunchServices/BackBoard/AX use.
    (void)setvbuf(stdout, NULL, _IONBF, 0);
    (void)setvbuf(stderr, NULL, _IONBF, 0);

    // The background assertion worker is deliberately long-lived and is not observed by the
    // one-shot parent bridge after its handshake. Preserve normal Objective-C cleanup for it.
    if (argc > 1 && strcmp(argv[1], "background-assert-worker") == 0) {
        @autoreleasepool {
            return CloudCodeRunOneShotCommand(argc, argv);
        }
    }

    // Every other command is a one-shot helper. Some private iOS frameworks retain process-global
    // objects whose autorelease teardown can block after the command has already emitted its final
    // result. Build 98 therefore paid the full parent watchdog (5–6s) for successful work. Keep one
    // process-lifetime pool, flush observable output, and terminate without teardown after dispatch.
    // The kernel reclaims all helper memory immediately; no state is shared with the host process.
    (void)objc_autoreleasePoolPush();
    int result = CloudCodeRunOneShotCommand(argc, argv);
    // Streams are unbuffered from process entry, so returning commands can hard-exit without any
    // stdio flush/teardown. This is the same post-result boundary used by CloudCodeExitOneShot.
    _exit(result);
}
