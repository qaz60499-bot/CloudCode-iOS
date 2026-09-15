#import "RootHelperBridge.h"

#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#define CLOUDCODE_HELPER_CAPTURE_LIMIT (1024 * 1024)
#define CLOUDCODE_HELPER_DEFAULT_TIMEOUT 8.0

typedef int (*PersonaSetFn)(const posix_spawnattr_t * _Nonnull __restrict, uid_t, uint32_t);
typedef int (*PersonaUIDFn)(const posix_spawnattr_t * _Nonnull __restrict, uid_t);
typedef int (*PersonaGIDFn)(const posix_spawnattr_t * _Nonnull __restrict, gid_t);
typedef pid_t (*CloudCodeWaitPidFn)(pid_t, int *, int);

static CloudCodeWaitPidFn CloudCodeDarwinWaitPidFunction(void)
{
    static CloudCodeWaitPidFn function = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // IOSSystemRuntime deliberately embeds ios_system.framework, which exports its own waitpid
        // implementation for virtual shell processes. RootHelperBridge manages real Darwin children
        // created by posix_spawn, so binding that interposed symbol makes real-helper polling spin in
        // ios_system instead of waiting on the kernel. Resolve the system implementation from an
        // explicit Apple image and reject any accidental ios_system resolution.
        static const char *candidates[] = {
            "/usr/lib/libSystem.B.dylib",
            "/usr/lib/system/libsystem_c.dylib",
        };
        for (size_t index = 0; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
            void *handle = dlopen(candidates[index], RTLD_LAZY | RTLD_LOCAL);
            if (!handle) { continue; }
            void *symbol = dlsym(handle, "waitpid");
            if (!symbol) { continue; }
            Dl_info info = {0};
            if (dladdr(symbol, &info) == 0 || !info.dli_fname) { continue; }
            if (strstr(info.dli_fname, "ios_system.framework") != NULL) { continue; }
            function = (CloudCodeWaitPidFn)symbol;
            break;
        }
    });
    return function;
}

static pid_t CloudCodeDarwinWaitPid(pid_t pid, int *status, int options)
{
    CloudCodeWaitPidFn function = CloudCodeDarwinWaitPidFunction();
    if (!function) {
        errno = ENOSYS;
        return -1;
    }
    return function(pid, status, options);
}

static double CloudCodeMonotonicSeconds(void)
{
    struct timespec ts = {0, 0};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) { return 0; }
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static void CloudCodeFreeArgv(char **argv, NSUInteger count)
{
    if (!argv) { return; }
    for (NSUInteger index = 0; index < count; index++) {
        if (argv[index]) { free(argv[index]); }
    }
    free(argv);
}

// Admission includes timed-out children until the kernel has reaped them. No PID scans or
// signals to unrelated processes: the registry only owns children spawned by this bridge.
static NSMutableSet<NSString *> *CloudCodeHelperRegistry(void)
{
    static NSMutableSet<NSString *> *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableSet set]; });
    return registry;
}

static void CloudCodeReleaseHelper(NSString *key)
{
    NSMutableSet *registry = CloudCodeHelperRegistry();
    @synchronized (registry) { [registry removeObject:key]; }
}

static void CloudCodeDrainPipe(int *descriptor, NSMutableData *captured, BOOL *truncated)
{
    int fd = *descriptor;
    if (fd < 0 || !captured) { return; }
    uint8_t buffer[2048];
    // A continuously writing child must not starve waitpid/deadline checks.
    for (NSUInteger chunk = 0; chunk < 128; chunk++) {
        ssize_t readCount = read(fd, buffer, sizeof(buffer));
        if (readCount > 0) {
            NSUInteger incoming = (NSUInteger)readCount;
            if (captured.length < CLOUDCODE_HELPER_CAPTURE_LIMIT) {
                NSUInteger remaining = CLOUDCODE_HELPER_CAPTURE_LIMIT - captured.length;
                NSUInteger appendLength = MIN(incoming, remaining);
                [captured appendBytes:buffer length:appendLength];
                if (appendLength < incoming && truncated) { *truncated = YES; }
            } else if (truncated) {
                *truncated = YES;
            }
            continue;
        }
        if (readCount == 0) { close(fd); *descriptor = -1; return; }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) { return; }
        close(fd); *descriptor = -1; return;
    }
}

static NSString *CloudCodeCapturedText(NSData *captured, NSString *suffix)
{
    NSString *text = nil;
    if (captured.length > 0) {
        text = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [NSString stringWithFormat:@"<helper returned %lu non-UTF8 bytes>", (unsigned long)captured.length];
        }
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (suffix.length == 0) { return text ?: @""; }
    if (text.length == 0) { return suffix; }
    return [NSString stringWithFormat:@"%@\n%@", text, suffix];
}

static NSString *CloudCodeCombinedOutput(NSString *standardOutput, NSString *standardError)
{
    NSString *stdoutText = standardOutput ?: @"";
    NSString *stderrText = standardError ?: @"";
    if (stdoutText.length == 0) { return stderrText; }
    if (stderrText.length == 0) { return stdoutText; }
    return [NSString stringWithFormat:@"%@\n%@", stdoutText, stderrText];
}

static NSInteger CloudCodeSpawnHelperInternal(
    NSString *path,
    NSArray<NSString *> *arguments,
    BOOL asRoot,
    NSTimeInterval timeout,
    NSString * _Nullable * _Nullable standardOutput,
    NSString * _Nullable * _Nullable standardError
)
{
    if (standardOutput) { *standardOutput = nil; }
    if (standardError) { *standardError = nil; }
    if (path.length == 0) { return -1001; }
    if (asRoot && [path.lastPathComponent isEqualToString:@"CloudCodeVisionHelper"]) {
        // CloudCodeVisionHelper is intentionally not a TSRootBinary. Vision must never inherit
        // persona-99/root; prior iOS 16.6 device evidence showed root-persona Vision traps.
        return -1911;
    }

    // Build 120 proved that an anonymous one-shot CloudCodeRootHelper can have working AXRuntime
    // symbols/transport yet still receive an empty semantic tree on iOS 16.6. For the two passive
    // semantic reads, preserve the existing helper API but execute the first (non-root) attempt in
    // the real System-app host identity. If that raw AXRuntime route is empty, continue into the
    // isolated helper so AccessibilityUI/AXAudit gets one bounded attempt before PlatformAdapters
    // performs its existing single persona-99 fallback.
    if (!asRoot
        && [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.cloudcode.ios"]
        && [path.lastPathComponent isEqualToString:@"CloudCodeRootHelper"]
        && arguments.count > 0) {
        NSString *command = arguments.firstObject;
        NSString *hostDiagnostic = nil;
        NSString *hostPayload = nil;
        if ([command isEqualToString:@"gui-tree-json"]) {
            hostPayload = CloudCodeHostAXTreeJSON(&hostDiagnostic);
        } else if ([command isEqualToString:@"gui-focused-text-input-json"]) {
            hostPayload = CloudCodeHostAXFocusedTextInputJSON(&hostDiagnostic);
        }
        if ([command isEqualToString:@"gui-tree-json"] || [command isEqualToString:@"gui-focused-text-input-json"]) {
            if (hostPayload.length > 0) {
                if (standardOutput) { *standardOutput = hostPayload; }
                if (standardError && hostDiagnostic.length > 0) { *standardError = hostDiagnostic; }
                return 0;
            }
            // Build 123 adds a materially different standalone route: AccessibilityUI's AXAudit
            // broker (AXUIClient + AXElement.primaryApp/explorerElements). If the System-app host's
            // raw AXRuntime path is empty, allow the normal isolated helper spawn below to try that
            // broker for both semantic-tree and focused-text observation before PlatformAdapters
            // proceeds to its single persona-99 fallback.
        }
    }

    if (timeout <= 0) { timeout = CLOUDCODE_HELPER_DEFAULT_TIMEOUT; }
    // Fail before spawning a real child if we cannot prove that process observation/reaping will
    // use Darwin's waitpid rather than ios_system's virtual-process implementation.
    if (!CloudCodeDarwinWaitPidFunction()) { return -1950; }

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:path];
    [argvStrings addObjectsFromArray:arguments ?: @[]];
    // A mobile parent cannot reliably SIGKILL a persona-99/UID-0 child after the child has changed
    // credentials. Real-device Build 113 left many timed-out CloudCodeRootHelper processes alive,
    // which then amplified AX latency and Vision/CoreVideo allocation pressure. Arm the privileged
    // helper with its own bounded watchdog so it can hard-exit itself shortly before the parent
    // deadline. The long-lived background-assert worker is spawned directly by the helper and does
    // not inherit this one-shot argument.
    if (asRoot && [path.lastPathComponent isEqualToString:@"CloudCodeRootHelper"]) {
        NSInteger watchdogMS = MAX(250, (NSInteger)(timeout * 1000.0) - 150);
        [argvStrings addObject:[NSString stringWithFormat:@"--cloudcode-watchdog-ms=%ld", (long)watchdogMS]];
    }

    const NSUInteger count = argvStrings.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) { return -1002; }
    for (NSUInteger index = 0; index < count; index++) {
        argv[index] = strdup(argvStrings[index].UTF8String ?: "");
        if (!argv[index]) {
            CloudCodeFreeArgv(argv, count);
            return -1003;
        }
    }
    argv[count] = NULL;

    posix_spawnattr_t attributes;
    int attrInit = posix_spawnattr_init(&attributes);
    if (attrInit != 0) {
        CloudCodeFreeArgv(argv, count);
        return -1100 - attrInit;
    }

    int personaError = 0;
    if (asRoot) {
        PersonaSetFn setPersona = (PersonaSetFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        PersonaUIDFn setPersonaUID = (PersonaUIDFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        PersonaGIDFn setPersonaGID = (PersonaGIDFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        if (!setPersona || !setPersonaUID || !setPersonaGID) {
            posix_spawnattr_destroy(&attributes);
            CloudCodeFreeArgv(argv, count);
            return -1900;
        }
        personaError = setPersona(&attributes, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        if (personaError == 0) { personaError = setPersonaUID(&attributes, 0); }
        if (personaError == 0) { personaError = setPersonaGID(&attributes, 0); }
    }

    posix_spawn_file_actions_t actions;
    int actionsInit = posix_spawn_file_actions_init(&actions);
    if (actionsInit != 0) {
        posix_spawnattr_destroy(&attributes);
        CloudCodeFreeArgv(argv, count);
        return -1200 - actionsInit;
    }

    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    BOOL captureStdout = standardOutput != NULL;
    BOOL captureStderr = standardError != NULL;
    BOOL captureOutput = captureStdout || captureStderr;
    NSInteger earlyFailure = 0;

    if (captureStdout && pipe(stdoutPipe) != 0) {
        earlyFailure = -6000 - errno;
    }
    if (earlyFailure == 0 && captureStderr && pipe(stderrPipe) != 0) {
        earlyFailure = -6000 - errno;
    }
    if (earlyFailure == 0 && captureOutput) {
        int actionError = 0;
        if (captureStdout) {
            actionError = posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]); }
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]); }
        }
        if (actionError == 0 && captureStderr) {
            actionError = posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO);
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, stderrPipe[0]); }
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, stderrPipe[1]); }
        }
        if (actionError != 0) { earlyFailure = -6100 - actionError; }
    }

    NSInteger result = 0;
    NSMutableData *capturedStdout = captureStdout ? [NSMutableData data] : nil;
    NSMutableData *capturedStderr = captureStderr ? [NSMutableData data] : nil;
    BOOL stdoutTruncated = NO;
    BOOL stderrTruncated = NO;
    NSString *diagnosticSuffix = @"";

    if (earlyFailure != 0) {
        result = earlyFailure;
    } else if (personaError != 0) {
        result = -2000 - personaError;
    } else {
        NSString *command = arguments.firstObject ?: @"";
        NSSet<NSString *> *serializedAXCommands = [NSSet setWithArray:@[
            @"gui-tree-json", @"gui-ax-probe-json", @"gui-focused-text-input-json", @"gui-type-base64"
        ]];
        BOOL usesSerializedAXRuntime = [path.lastPathComponent isEqualToString:@"CloudCodeRootHelper"]
            && [serializedAXCommands containsObject:command];
        // Keep detached AXRuntime calls serialized so their private requesting-client/context state
        // cannot overlap. Production perception no longer writes the system-wide Accessibility
        // Automation bit; serialization is now only an AXRuntime isolation boundary.
        NSString *registryKey = usesSerializedAXRuntime
            ? [NSString stringWithFormat:@"%@|ax-runtime-serialized", path]
            : [NSString stringWithFormat:@"%@|%@", path, command];
        NSMutableSet *registry = CloudCodeHelperRegistry();
        BOOL admitted = NO;
        @synchronized (registry) {
            if (registry.count < 4 && ![registry containsObject:registryKey]) {
                [registry addObject:registryKey];
                admitted = YES;
            }
        }
        pid_t pid = 0;
        int spawnError = admitted ? posix_spawn(&pid, path.fileSystemRepresentation, captureOutput ? &actions : NULL, &attributes, argv, NULL) : EBUSY;
        if (spawnError != 0) {
            if (admitted) { CloudCodeReleaseHelper(registryKey); }
            if (!admitted) { diagnosticSuffix = @"runtime_degraded: helper admission limit, same command, or serialized AX runtime still active/unreaped"; }
            result = -3000 - spawnError;
        } else {
            const BOOL tracePerception = [path.lastPathComponent hasPrefix:@"CloudCode"];
            BOOL parentTimeout = NO;
            int timeoutKillResult = 0;
            int timeoutKillErrno = 0;
            if (captureStdout) {
                close(stdoutPipe[1]);
                stdoutPipe[1] = -1;
                int flags = fcntl(stdoutPipe[0], F_GETFL, 0);
                if (flags >= 0) { (void)fcntl(stdoutPipe[0], F_SETFL, flags | O_NONBLOCK); }
            }
            if (captureStderr) {
                close(stderrPipe[1]);
                stderrPipe[1] = -1;
                int flags = fcntl(stderrPipe[0], F_GETFL, 0);
                if (flags >= 0) { (void)fcntl(stderrPipe[0], F_SETFL, flags | O_NONBLOCK); }
            }

            const double start = CloudCodeMonotonicSeconds();
            int status = 0;
            BOOL statusObserved = NO;
            BOOL reapDeferred = NO;
            BOOL finished = NO;
            while (!finished) {
                if (captureStdout) { CloudCodeDrainPipe(&stdoutPipe[0], capturedStdout, &stdoutTruncated); }
                if (captureStderr) { CloudCodeDrainPipe(&stderrPipe[0], capturedStderr, &stderrTruncated); }

                pid_t waited = CloudCodeDarwinWaitPid(pid, &status, WNOHANG);
                if (waited == pid) {
                    statusObserved = YES;
                    finished = YES;
                    break;
                }
                if (waited == -1) {
                    if (errno == EINTR) { continue; }
                    result = -4000 - errno;
                    finished = YES;
                    break;
                }

                double elapsed = CloudCodeMonotonicSeconds() - start;
                if (elapsed >= timeout) {
                    parentTimeout = YES;
                    timeoutKillResult = kill(pid, SIGKILL);
                    timeoutKillErrno = timeoutKillResult == 0 ? 0 : errno;
                    // A helper can be wedged inside private AX IPC. A blocking waitpid after SIGKILL
                    // made the nominal 3s AX deadline stretch past 15s on-device. Reap synchronously
                    // only for a short bounded grace period; if the kernel has not released the child
                    // yet, finish the user-facing timeout immediately and reap it off the caller path.
                    BOOL reaped = NO;
                    double reapDeadline = CloudCodeMonotonicSeconds() + 0.25;
                    do {
                        waited = CloudCodeDarwinWaitPid(pid, &status, WNOHANG);
                        if (waited == pid || (waited == -1 && errno == ECHILD)) {
                            statusObserved = waited == pid;
                            reaped = YES;
                            break;
                        }
                        if (waited == -1 && errno != EINTR) { break; }
                        usleep(10000);
                    } while (CloudCodeMonotonicSeconds() < reapDeadline);
                    reapDeferred = !reaped;
                    result = -7000 - ETIMEDOUT;
                    diagnosticSuffix = [NSString stringWithFormat:@"helper timed out after %.1f seconds; killResult=%d killErrno=%d%@", timeout, timeoutKillResult, timeoutKillErrno, reaped ? @"; process reaped" : @"; process reap deferred"];
                    finished = YES;
                    break;
                }

                if (captureOutput) {
                    struct pollfd pollFDs[2];
                    nfds_t countFDs = 0;
                    if (stdoutPipe[0] >= 0) {
                        pollFDs[countFDs++] = (struct pollfd){.fd = stdoutPipe[0], .events = POLLIN | POLLHUP, .revents = 0};
                    }
                    if (stderrPipe[0] >= 0) {
                        pollFDs[countFDs++] = (struct pollfd){.fd = stderrPipe[0], .events = POLLIN | POLLHUP, .revents = 0};
                    }
                    // poll with zero descriptors sleeps too. Closed pipes must never remain
                    // in this set: POLLHUP is level-triggered and otherwise spins at 100% CPU.
                    (void)poll(pollFDs, countFDs, 50);
                } else {
                    usleep(50000);
                }
            }

            if (captureStdout) { CloudCodeDrainPipe(&stdoutPipe[0], capturedStdout, &stdoutTruncated); }
            if (captureStderr) { CloudCodeDrainPipe(&stderrPipe[0], capturedStderr, &stderrTruncated); }
            if (reapDeferred || (!statusObserved && result != -4000 - ECHILD)) {
                pid_t timedOutPID = pid;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    int reaperStatus = 0;
                    pid_t reaperWaited;
                    do {
                        reaperWaited = CloudCodeDarwinWaitPid(timedOutPID, &reaperStatus, 0);
                    } while (reaperWaited == -1 && errno == EINTR);
                    int reaperErrno = reaperWaited < 0 ? errno : 0;
                    if (reaperWaited == timedOutPID || reaperErrno == ECHILD) { CloudCodeReleaseHelper(registryKey); }
                    NSLog(@"[CloudCodeHelperReaper] pid=%d waited=%d errno=%d status=%d", timedOutPID, reaperWaited, reaperErrno, reaperStatus);
                });
            } else {
                CloudCodeReleaseHelper(registryKey);
            }
            if (result == 0) {
                if (WIFEXITED(status)) {
                    result = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    result = -5000 - WTERMSIG(status);
                    diagnosticSuffix = [NSString stringWithFormat:@"helper terminated by signal %d", WTERMSIG(status)];
                } else {
                    result = -5001;
                }
            }
            if (tracePerception) {
                Dl_info waitImage = {0};
                dladdr((void *)CloudCodeDarwinWaitPidFunction(), &waitImage);
                NSDictionary *exitEvidence = @{
                    @"schemaVersion": @1, @"stage": @"helper-exit",
                    @"helper": path.lastPathComponent, @"pid": @(pid), @"parentPID": @(getpid()),
                    @"parentUID": @(getuid()), @"parentGID": @(getgid()), @"rootRequested": @(asRoot),
                    @"elapsedMS": @((NSInteger)((CloudCodeMonotonicSeconds() - start) * 1000)),
                    @"timeoutSeconds": @(timeout), @"parentTimeout": @(parentTimeout),
                    @"timeoutKillResult": @(timeoutKillResult), @"timeoutKillErrno": @(timeoutKillErrno),
                    @"result": @(result),
                    @"waitStatusObserved": @(statusObserved),
                    @"reapDeferred": @(reapDeferred),
                    @"waitpidImage": waitImage.dli_fname ? @(waitImage.dli_fname) : @"unknown",
                    @"signal": statusObserved && WIFSIGNALED(status) ? @(WTERMSIG(status)) : NSNull.null,
                    @"exitCode": statusObserved && WIFEXITED(status) ? @(WEXITSTATUS(status)) : NSNull.null,
                    @"systemTerminationReason": @"requires_correlated_system_report"
                };
                NSData *json = [NSJSONSerialization dataWithJSONObject:exitEvidence options:0 error:nil];
                NSString *record = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
                if (record.length) {
                    diagnosticSuffix = CloudCodeCombinedOutput(diagnosticSuffix, record);
                }
            }
            if (stdoutTruncated || stderrTruncated) {
                NSMutableArray<NSString *> *streams = [NSMutableArray array];
                if (stdoutTruncated) { [streams addObject:@"stdout"]; }
                if (stderrTruncated) { [streams addObject:@"stderr"]; }
                NSString *overflow = [NSString stringWithFormat:@"helper %@ capture truncated at %d bytes", [streams componentsJoinedByString:@"+"], CLOUDCODE_HELPER_CAPTURE_LIMIT];
                diagnosticSuffix = diagnosticSuffix.length > 0
                    ? [NSString stringWithFormat:@"%@\n%@", diagnosticSuffix, overflow]
                    : overflow;
                // Machine-readable helper responses must never be accepted after truncation. A
                // distinct negative result prevents a partial JSON/text payload from masquerading
                // as a successful exact-operation probe.
                if (result == 0) { result = -8000 - EOVERFLOW; }
            }
        }
    }

    if (standardOutput && captureStdout) {
        NSString *text = CloudCodeCapturedText(capturedStdout ?: [NSData data], @"");
        if (text.length > 0) { *standardOutput = text; }
    }
    if (standardError && captureStderr) {
        NSString *text = CloudCodeCapturedText(capturedStderr ?: [NSData data], diagnosticSuffix);
        if (text.length > 0) { *standardError = text; }
    }

    if (stdoutPipe[0] >= 0) { close(stdoutPipe[0]); }
    if (stdoutPipe[1] >= 0) { close(stdoutPipe[1]); }
    if (stderrPipe[0] >= 0) { close(stderrPipe[0]); }
    if (stderrPipe[1] >= 0) { close(stderrPipe[1]); }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    CloudCodeFreeArgv(argv, count);
    return result;
}

NSInteger CloudCodeSpawnRootHelper(NSString *path, NSArray<NSString *> *arguments)
{
    return CloudCodeSpawnHelperInternal(path, arguments, YES, CLOUDCODE_HELPER_DEFAULT_TIMEOUT, NULL, NULL);
}

NSInteger CloudCodeSpawnRootHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, NSString * _Nullable * _Nullable diagnostic)
{
    NSString *standardOutput = nil;
    NSString *standardError = nil;
    NSInteger result = CloudCodeSpawnHelperInternal(path, arguments, YES, CLOUDCODE_HELPER_DEFAULT_TIMEOUT, &standardOutput, &standardError);
    if (diagnostic) {
        NSString *combined = CloudCodeCombinedOutput(standardOutput, standardError);
        if (combined.length > 0) { *diagnostic = combined; }
    }
    return result;
}

NSInteger CloudCodeSpawnHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, BOOL asRoot, NSTimeInterval timeout, NSString * _Nullable * _Nullable diagnostic)
{
    NSString *standardOutput = nil;
    NSString *standardError = nil;
    NSInteger result = CloudCodeSpawnHelperInternal(path, arguments, asRoot, timeout, &standardOutput, &standardError);
    if (diagnostic) {
        NSString *combined = CloudCodeCombinedOutput(standardOutput, standardError);
        if (combined.length > 0) { *diagnostic = combined; }
    }
    return result;
}

NSInteger CloudCodeSpawnHelperWithSeparatedOutput(NSString *path, NSArray<NSString *> *arguments, BOOL asRoot, NSTimeInterval timeout, NSString * _Nullable * _Nullable standardOutput, NSString * _Nullable * _Nullable standardError)
{
    return CloudCodeSpawnHelperInternal(path, arguments, asRoot, timeout, standardOutput, standardError);
}
