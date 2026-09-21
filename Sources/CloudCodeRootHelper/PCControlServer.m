#import "PCControlServer.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <netinet/in.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/file.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

extern char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#define CLOUDCODE_PC_CONTROL_PROTOCOL 2
#define CLOUDCODE_PC_CONTROL_PORT 47651
#define CLOUDCODE_PC_CONTROL_TOKEN_BYTES 32
#define CLOUDCODE_PC_CONTROL_MAX_REQUEST_BYTES (64 * 1024)
#define CLOUDCODE_PC_CONTROL_CHILD_TIMEOUT_MS 5000
#define CLOUDCODE_PC_CONTROL_LAUNCH_TIMEOUT_MS 12000
#define CLOUDCODE_PC_CONTROL_OCR_TIMEOUT_MS 15000
#define CLOUDCODE_PC_CONTROL_INSTALL_TIMEOUT_MS 110000

static NSString * const CloudCodePCControlTokenPath = @"/var/mobile/Media/Downloads/CloudCode-PC-Control.json";
static NSString * const CloudCodePCControlLockPath = @"/var/mobile/Media/Downloads/CloudCode-PC-Control.lock";

typedef NS_ENUM(NSInteger, CloudCodePCExistingTransport) {
    CloudCodePCExistingTransportAmbiguous = 0,
    CloudCodePCExistingTransportResponse = 1,
    CloudCodePCExistingTransportAbsent = 2,
};

static double CloudCodePCMonotonicSeconds(void)
{
    struct timespec ts = {0, 0};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) { return 0; }
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static BOOL CloudCodePCWriteAll(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written > 0) {
            cursor += (size_t)written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) { continue; }
        return NO;
    }
    return YES;
}

static NSString *CloudCodePCRandomToken(void)
{
    uint8_t bytes[CLOUDCODE_PC_CONTROL_TOKEN_BYTES] = {0};
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *token = [NSMutableString stringWithCapacity:sizeof(bytes) * 2];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) {
        [token appendFormat:@"%02x", bytes[index]];
    }
    return token;
}

static NSDictionary *CloudCodePCReadTokenRecordRaw(void)
{
    NSData *data = [NSData dataWithContentsOfFile:CloudCodePCControlTokenPath];
    if (!data.length) { return nil; }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) { return nil; }
    NSDictionary *record = object;
    NSNumber *port = [record[@"port"] isKindOfClass:NSNumber.class] ? record[@"port"] : nil;
    NSString *token = [record[@"token"] isKindOfClass:NSString.class] ? record[@"token"] : nil;
    if (port.integerValue != CLOUDCODE_PC_CONTROL_PORT || token.length != CLOUDCODE_PC_CONTROL_TOKEN_BYTES * 2) {
        return nil;
    }
    return record;
}

static NSDictionary *CloudCodePCReadTokenRecord(void)
{
    NSDictionary *record = CloudCodePCReadTokenRecordRaw();
    NSNumber *protocol = [record[@"protocol"] isKindOfClass:NSNumber.class] ? record[@"protocol"] : nil;
    return protocol.integerValue == CLOUDCODE_PC_CONTROL_PROTOCOL ? record : nil;
}

static BOOL CloudCodePCWriteTokenRecord(NSString *token)
{
    if (token.length != CLOUDCODE_PC_CONTROL_TOKEN_BYTES * 2) { return NO; }
    NSDictionary *record = @{
        @"protocol": @(CLOUDCODE_PC_CONTROL_PROTOCOL),
        @"port": @(CLOUDCODE_PC_CONTROL_PORT),
        @"token": token,
        @"pid": @(getpid()),
        @"transport": @"usbmux-loopback"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data.length) { return NO; }
    if (![data writeToFile:CloudCodePCControlTokenPath options:NSDataWritingAtomic error:nil]) { return NO; }
    // AFC serves /var/mobile/Media as the mobile user. Keep the bearer credential readable only
    // by that owner instead of leaving a root-owned world-readable token in Downloads.
    (void)chown(CloudCodePCControlTokenPath.fileSystemRepresentation, 501, 501);
    (void)chmod(CloudCodePCControlTokenPath.fileSystemRepresentation, 0600);
    return YES;
}

static BOOL CloudCodePCSendJSON(int fd, NSDictionary *payload)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
    if (!data.length) { return NO; }
    NSMutableData *line = [data mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    return CloudCodePCWriteAll(fd, line.bytes, line.length);
}

static NSData *CloudCodePCReadRequest(int fd, BOOL *tooLarge)
{
    if (tooLarge) { *tooLarge = NO; }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[2048];
    while (data.length <= CLOUDCODE_PC_CONTROL_MAX_REQUEST_BYTES) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count > 0) {
            void *newline = memchr(buffer, '\n', (size_t)count);
            size_t appendLength = newline ? (size_t)((uint8_t *)newline - buffer) : (size_t)count;
            [data appendBytes:buffer length:appendLength];
            if (newline) { return data; }
            continue;
        }
        if (count == 0) { return data.length ? data : nil; }
        if (errno == EINTR) { continue; }
        return nil;
    }
    if (tooLarge) { *tooLarge = YES; }
    return nil;
}

static int CloudCodePCRunOneShotWithTimeout(const char *executablePath, NSArray<NSString *> *arguments, uint64_t timeoutMS)
{
    if (!executablePath || !*executablePath || arguments.count == 0 || timeoutMS == 0 || timeoutMS > 120000) { return 10; }
    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:[NSString stringWithUTF8String:executablePath]];
    [argvStrings addObjectsFromArray:arguments];
    // Keep the child self-watchdog just inside the parent deadline. A fixed 4.5s watchdog is
    // appropriate for ordinary GUI primitives but would kill the bounded TrollStore install
    // child long before the dedicated 110s install window can complete.
    uint64_t watchdogMS = timeoutMS > 150 ? timeoutMS - 150 : timeoutMS;
    [argvStrings addObject:[NSString stringWithFormat:@"--cloudcode-watchdog-ms=%llu", (unsigned long long)watchdogMS]];

    NSUInteger count = argvStrings.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) { return 70; }
    BOOL argvOK = YES;
    for (NSUInteger index = 0; index < count; index++) {
        argv[index] = strdup(argvStrings[index].UTF8String ?: "");
        if (!argv[index]) { argvOK = NO; break; }
    }
    if (!argvOK) {
        for (NSUInteger index = 0; index < count; index++) { if (argv[index]) free(argv[index]); }
        free(argv);
        return 70;
    }

    posix_spawn_file_actions_t actions;
    int actionsResult = posix_spawn_file_actions_init(&actions);
    if (actionsResult != 0) {
        for (NSUInteger index = 0; index < count; index++) free(argv[index]);
        free(argv);
        return 70;
    }
    (void)posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    (void)posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    (void)posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, executablePath, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < count; index++) free(argv[index]);
    free(argv);
    if (spawnResult != 0 || pid <= 1) { return 71; }

    const double deadline = CloudCodePCMonotonicSeconds() + ((double)timeoutMS / 1000.0);
    int status = 0;
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            if (WIFEXITED(status)) { return WEXITSTATUS(status); }
            if (WIFSIGNALED(status)) { return 128 + WTERMSIG(status); }
            return 72;
        }
        if (waited < 0 && errno != EINTR) { return 73; }
        if (CloudCodePCMonotonicSeconds() >= deadline) {
            (void)kill(pid, SIGKILL);
            do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
            return 124;
        }
        usleep(10000);
    }
}

static int CloudCodePCRunOneShot(const char *executablePath, NSArray<NSString *> *arguments)
{
    return CloudCodePCRunOneShotWithTimeout(executablePath, arguments, CLOUDCODE_PC_CONTROL_CHILD_TIMEOUT_MS);
}

typedef int (*CloudCodePCPersonaSetFn)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*CloudCodePCPersonaUIDFn)(posix_spawnattr_t *, uid_t);
typedef int (*CloudCodePCPersonaGIDFn)(posix_spawnattr_t *, gid_t);

static void CloudCodePCDrainFD(int *fd, NSMutableData *data, NSUInteger limit)
{
    if (!fd || *fd < 0 || !data) { return; }
    uint8_t buffer[4096];
    for (;;) {
        ssize_t count = read(*fd, buffer, sizeof(buffer));
        if (count > 0) {
            if (data.length < limit) {
                NSUInteger remaining = limit - data.length;
                [data appendBytes:buffer length:MIN((NSUInteger)count, remaining)];
            }
            continue;
        }
        if (count == 0) {
            close(*fd);
            *fd = -1;
            return;
        }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) { return; }
        close(*fd);
        *fd = -1;
        return;
    }
}

static NSString *CloudCodePCTextFromData(NSData *data)
{
    if (!data.length) { return @""; }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static NSDictionary *CloudCodePCRunCapturedWithTimeout(NSString *path, NSArray<NSString *> *arguments, uint64_t timeoutMS, BOOL runAsMobile)
{
    if (path.length == 0 || arguments.count == 0 || timeoutMS == 0 || timeoutMS > 120000) {
        return @{@"code": @10, @"stdout": @"", @"stderr": @""};
    }
    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:path];
    [argvStrings addObjectsFromArray:arguments];
    uint64_t watchdogMS = timeoutMS > 150 ? timeoutMS - 150 : timeoutMS;
    [argvStrings addObject:[NSString stringWithFormat:@"--cloudcode-watchdog-ms=%llu", (unsigned long long)watchdogMS]];

    NSUInteger count = argvStrings.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) { return @{@"code": @70, @"stdout": @"", @"stderr": @"argv allocation failed"}; }
    for (NSUInteger index = 0; index < count; index++) {
        argv[index] = strdup(argvStrings[index].UTF8String ?: "");
        if (!argv[index]) {
            for (NSUInteger cleanup = 0; cleanup < count; cleanup++) { if (argv[cleanup]) { free(argv[cleanup]); } }
            free(argv);
            return @{@"code": @70, @"stdout": @"", @"stderr": @"argv allocation failed"};
        }
    }

    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        if (stdoutPipe[0] >= 0) { close(stdoutPipe[0]); }
        if (stdoutPipe[1] >= 0) { close(stdoutPipe[1]); }
        if (stderrPipe[0] >= 0) { close(stderrPipe[0]); }
        if (stderrPipe[1] >= 0) { close(stderrPipe[1]); }
        for (NSUInteger index = 0; index < count; index++) { free(argv[index]); }
        free(argv);
        return @{@"code": @70, @"stdout": @"", @"stderr": @"pipe failed"};
    }

    posix_spawn_file_actions_t actions;
    int actionsResult = posix_spawn_file_actions_init(&actions);
    if (actionsResult != 0) {
        close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1]);
        for (NSUInteger index = 0; index < count; index++) { free(argv[index]); }
        free(argv);
        return @{@"code": @(70), @"stdout": @"", @"stderr": @"spawn actions failed"};
    }
    (void)posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    (void)posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    (void)posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO);
    (void)posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]);
    (void)posix_spawn_file_actions_addclose(&actions, stderrPipe[0]);
    (void)posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]);
    (void)posix_spawn_file_actions_addclose(&actions, stderrPipe[1]);

    posix_spawnattr_t attributes;
    int attrResult = posix_spawnattr_init(&attributes);
    if (attrResult != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1]);
        for (NSUInteger index = 0; index < count; index++) { free(argv[index]); }
        free(argv);
        return @{@"code": @(70), @"stdout": @"", @"stderr": @"spawn attributes failed"};
    }

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, path.fileSystemRepresentation, &actions, &attributes, argv, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(stdoutPipe[1]); stdoutPipe[1] = -1;
    close(stderrPipe[1]); stderrPipe[1] = -1;
    for (NSUInteger index = 0; index < count; index++) { free(argv[index]); }
    free(argv);
    if (spawnResult != 0 || pid <= 1) {
        close(stdoutPipe[0]); close(stderrPipe[0]);
        return @{@"code": @71, @"stdout": @"", @"stderr": [NSString stringWithFormat:@"spawn failed: %d", spawnResult]};
    }
    int flags = fcntl(stdoutPipe[0], F_GETFL, 0);
    if (flags >= 0) { (void)fcntl(stdoutPipe[0], F_SETFL, flags | O_NONBLOCK); }
    flags = fcntl(stderrPipe[0], F_GETFL, 0);
    if (flags >= 0) { (void)fcntl(stderrPipe[0], F_SETFL, flags | O_NONBLOCK); }

    NSMutableData *stdoutData = [NSMutableData data];
    NSMutableData *stderrData = [NSMutableData data];
    const NSUInteger captureLimit = 262144;
    const double deadline = CloudCodePCMonotonicSeconds() + ((double)timeoutMS / 1000.0);
    int status = 0;
    int code = 124;
    BOOL finished = NO;
    while (!finished) {
        CloudCodePCDrainFD(&stdoutPipe[0], stdoutData, captureLimit);
        CloudCodePCDrainFD(&stderrPipe[0], stderrData, captureLimit);
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            if (WIFEXITED(status)) { code = WEXITSTATUS(status); }
            else if (WIFSIGNALED(status)) { code = 128 + WTERMSIG(status); }
            else { code = 72; }
            finished = YES;
            break;
        }
        if (waited < 0 && errno != EINTR) { code = 73; finished = YES; break; }
        if (CloudCodePCMonotonicSeconds() >= deadline) {
            (void)kill(pid, SIGKILL);
            do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
            code = 124;
            finished = YES;
            break;
        }
        struct pollfd fds[2];
        nfds_t nfds = 0;
        if (stdoutPipe[0] >= 0) { fds[nfds++] = (struct pollfd){.fd = stdoutPipe[0], .events = POLLIN | POLLHUP, .revents = 0}; }
        if (stderrPipe[0] >= 0) { fds[nfds++] = (struct pollfd){.fd = stderrPipe[0], .events = POLLIN | POLLHUP, .revents = 0}; }
        (void)poll(fds, nfds, 25);
    }
    CloudCodePCDrainFD(&stdoutPipe[0], stdoutData, captureLimit);
    CloudCodePCDrainFD(&stderrPipe[0], stderrData, captureLimit);
    if (stdoutPipe[0] >= 0) { close(stdoutPipe[0]); }
    if (stderrPipe[0] >= 0) { close(stderrPipe[0]); }
    return @{
        @"code": @(code),
        @"stdout": CloudCodePCTextFromData(stdoutData),
        @"stderr": CloudCodePCTextFromData(stderrData),
        @"pid": @(pid)
    };
}

static BOOL CloudCodePCIsSafeOCRPath(NSString *path)
{
    NSString *normalized = [path isKindOfClass:NSString.class] ? path.stringByStandardizingPath : nil;
    if (normalized.length == 0 || normalized.length > 4096) { return NO; }
    BOOL appContainer = [normalized hasPrefix:@"/var/mobile/Containers/Data/Application/"] || [normalized hasPrefix:@"/private/var/mobile/Containers/Data/Application/"];
    NSString *parent = normalized.stringByDeletingLastPathComponent;
    NSString *filename = normalized.lastPathComponent;
    return appContainer
        && [parent.lastPathComponent isEqualToString:@"tmp"]
        && [filename hasPrefix:@"CloudCode-GUI-OCR-"]
        && [filename.pathExtension.lowercaseString isEqualToString:@"jpg"]
        && ![normalized containsString:@".."];
}

static NSDictionary *CloudCodePCOCRSmokeResponse(const char *executablePath, NSDictionary *request)
{
    NSString *container = [request[@"container"] isKindOfClass:NSString.class] ? request[@"container"] : nil;
    if (container.length == 0 || container.length > 4096 || [container containsString:@".."] || !([container hasPrefix:@"/var/mobile/Containers/Data/Application/"] || [container hasPrefix:@"/private/var/mobile/Containers/Data/Application/"])) {
        return @{@"ok": @NO, @"op": @"ocr-smoke", @"error": @"invalid-container"};
    }
    NSString *tmpDir = [container.stringByStandardizingPath stringByAppendingPathComponent:@"tmp"];
    NSString *screenshotPath = [tmpDir stringByAppendingPathComponent:@"CloudCode-GUI-OCR-pc-smoke.jpg"];
    if (!CloudCodePCIsSafeOCRPath(screenshotPath)) {
        return @{@"ok": @NO, @"op": @"ocr-smoke", @"error": @"invalid-screenshot-path"};
    }
    NSString *rootHelperPath = [NSString stringWithUTF8String:executablePath ?: ""];
    NSString *visionHelperPath = [rootHelperPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"CloudCodeVisionHelper"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:visionHelperPath]) {
        return @{@"ok": @NO, @"op": @"ocr-smoke", @"error": @"missing-vision-helper"};
    }
    int screenshotCode = CloudCodePCRunOneShotWithTimeout(executablePath, @[@"gui-screenshot-file", screenshotPath], CLOUDCODE_PC_CONTROL_LAUNCH_TIMEOUT_MS);
    NSDictionary *vision = screenshotCode == 0
        ? CloudCodePCRunCapturedWithTimeout(visionHelperPath, @[@"ocr-file", screenshotPath, @"48", @"accurate", @"pc-control-root-ocr-ok"], CLOUDCODE_PC_CONTROL_OCR_TIMEOUT_MS, NO)
        : @{@"code": @(-1), @"stdout": @"", @"stderr": @"screenshot failed"};
    NSString *stdoutText = [vision[@"stdout"] isKindOfClass:NSString.class] ? vision[@"stdout"] : @"";
    NSData *stdoutData = [stdoutText dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    id parsed = stdoutData.length ? [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:nil] : nil;
    BOOL parsedJSON = [parsed isKindOfClass:NSDictionary.class];
    NSNumber *visionCode = [vision[@"code"] isKindOfClass:NSNumber.class] ? vision[@"code"] : @(-1);
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @(screenshotCode == 0 && visionCode.integerValue == 0 && parsedJSON),
        @"op": @"ocr-smoke",
        @"screenshotCode": @(screenshotCode),
        @"visionCode": visionCode,
        @"screenshotPath": screenshotPath,
        @"visionStdoutBytes": @(stdoutData.length),
        @"visionStderr": [vision[@"stderr"] isKindOfClass:NSString.class] ? vision[@"stderr"] : @""
    }];
    if (parsedJSON) { response[@"ocr"] = parsed; }
    else { response[@"visionStdoutPreview"] = stdoutText.length > 2000 ? [stdoutText substringToIndex:2000] : stdoutText; }
    return response;
}

static BOOL CloudCodePCIsSafeBundleID(NSString *bundleID)
{
    if (!bundleID.length || bundleID.length > 255) { return NO; }
    NSCharacterSet *bundleAllowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [[bundleID stringByTrimmingCharactersInSet:bundleAllowed] length] == 0;
}

static BOOL CloudCodePCIsSafeInstallRequest(NSString *path, NSString *bundleID, NSString *build)
{
    if (!path.length || !CloudCodePCIsSafeBundleID(bundleID) || !build.length) { return NO; }
    if (path.length > 4096 || build.length > 32) { return NO; }
    if (![path hasPrefix:@"/var/mobile/Media/Downloads/"] || ![path.lowercaseString hasSuffix:@".ipa"]) { return NO; }
    if ([path containsString:@".."] || [path containsString:@"\n"] || [path containsString:@"\r"]) { return NO; }
    NSCharacterSet *buildAllowed = NSCharacterSet.decimalDigitCharacterSet;
    if ([[build stringByTrimmingCharactersInSet:buildAllowed] length] != 0) { return NO; }
    return YES;
}

static NSDictionary *CloudCodePCActionResponse(const char *executablePath, NSDictionary *request, BOOL *shutdown)
{
    if (shutdown) { *shutdown = NO; }
    NSString *operation = [request[@"op"] isKindOfClass:NSString.class] ? request[@"op"] : nil;
    if (!operation.length) { return @{@"ok": @NO, @"error": @"missing-op"}; }

    if ([operation isEqualToString:@"status"]) {
        return @{@"ok": @YES, @"op": operation, @"protocol": @(CLOUDCODE_PC_CONTROL_PROTOCOL), @"pid": @(getpid())};
    }
    if ([operation isEqualToString:@"metrics"]) {
        UIScreen *screen = UIScreen.mainScreen;
        CGRect bounds = screen.bounds;
        CGRect nativeBounds = screen.nativeBounds;
        return @{
            @"ok": @YES,
            @"op": operation,
            @"protocol": @(CLOUDCODE_PC_CONTROL_PROTOCOL),
            @"pointWidth": @(CGRectGetWidth(bounds)),
            @"pointHeight": @(CGRectGetHeight(bounds)),
            @"pixelWidth": @(CGRectGetWidth(nativeBounds)),
            @"pixelHeight": @(CGRectGetHeight(nativeBounds)),
            @"scale": @(screen.scale),
            @"nativeScale": @(screen.nativeScale)
        };
    }
    if ([operation isEqualToString:@"shutdown"]) {
        if (shutdown) { *shutdown = YES; }
        return @{@"ok": @YES, @"op": operation, @"pid": @(getpid())};
    }
    if ([operation isEqualToString:@"ocr-smoke"]) {
        return CloudCodePCOCRSmokeResponse(executablePath, request);
    }

    NSArray<NSString *> *arguments = nil;
    if ([operation isEqualToString:@"tap"]) {
        NSNumber *x = [request[@"x"] isKindOfClass:NSNumber.class] ? request[@"x"] : nil;
        NSNumber *y = [request[@"y"] isKindOfClass:NSNumber.class] ? request[@"y"] : nil;
        if (!x || !y || !isfinite(x.doubleValue) || !isfinite(y.doubleValue)) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-coordinate"};
        }
        arguments = @[@"gui-tap", x.stringValue, y.stringValue];
    } else if ([operation isEqualToString:@"swipe"]) {
        NSNumber *x1 = [request[@"x1"] isKindOfClass:NSNumber.class] ? request[@"x1"] : nil;
        NSNumber *y1 = [request[@"y1"] isKindOfClass:NSNumber.class] ? request[@"y1"] : nil;
        NSNumber *x2 = [request[@"x2"] isKindOfClass:NSNumber.class] ? request[@"x2"] : nil;
        NSNumber *y2 = [request[@"y2"] isKindOfClass:NSNumber.class] ? request[@"y2"] : nil;
        NSNumber *duration = [request[@"duration"] isKindOfClass:NSNumber.class] ? request[@"duration"] : nil;
        if (!x1 || !y1 || !x2 || !y2 || !duration || !isfinite(x1.doubleValue) || !isfinite(y1.doubleValue) || !isfinite(x2.doubleValue) || !isfinite(y2.doubleValue) || !isfinite(duration.doubleValue) || duration.doubleValue <= 0 || duration.doubleValue > 3.0) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-swipe"};
        }
        arguments = @[@"gui-swipe", x1.stringValue, y1.stringValue, x2.stringValue, y2.stringValue, duration.stringValue];
    } else if ([operation isEqualToString:@"scroll"]) {
        NSNumber *dx = [request[@"dx"] isKindOfClass:NSNumber.class] ? request[@"dx"] : nil;
        NSNumber *dy = [request[@"dy"] isKindOfClass:NSNumber.class] ? request[@"dy"] : nil;
        if (!dx || !dy || !isfinite(dx.doubleValue) || !isfinite(dy.doubleValue)) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-scroll"};
        }
        arguments = @[@"gui-scroll", dx.stringValue, dy.stringValue];
    } else if ([operation isEqualToString:@"back"]) {
        NSString *strategy = [request[@"strategy"] isKindOfClass:NSString.class] ? request[@"strategy"] : @"edge";
        if (![@[@"edge", @"dismissDown"] containsObject:strategy]) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-back-strategy"};
        }
        arguments = @[@"gui-navigate-back", strategy];
    } else if ([operation isEqualToString:@"type"]) {
        NSString *text = [request[@"text"] isKindOfClass:NSString.class] ? request[@"text"] : nil;
        if (!text || text.length > 4096) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-text"};
        }
        NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encoded = [textData base64EncodedStringWithOptions:0];
        arguments = @[@"gui-type-base64", encoded];
    } else if ([operation isEqualToString:@"launch"] || [operation isEqualToString:@"is-frontmost"] || [operation isEqualToString:@"foreground-diagnostics"]) {
        NSString *bundleID = [request[@"bundleID"] isKindOfClass:NSString.class] ? request[@"bundleID"] : nil;
        if (!CloudCodePCIsSafeBundleID(bundleID)) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-bundle-id"};
        }
        NSString *command = [operation isEqualToString:@"foreground-diagnostics"] ? @"foreground-diagnostics-file" : operation;
        arguments = @[command, bundleID];
    } else if ([operation isEqualToString:@"clear-stale-automation"]) {
        // Bounded maintenance-only repair for the global Accessibility Automation bit that
        // legacy CloudCode builds could leave enabled after an interrupted AX diagnostic.
        // Production OCR/perception never calls this operation; it is exposed only through
        // the authenticated localhost PC-control channel so a stale device can be repaired
        // without re-enabling AX diagnostics or a visible foreground overlay.
        arguments = @[@"gui-clear-stale-automation"];
    } else if ([operation isEqualToString:@"install-ipa"]) {
        NSString *path = [request[@"path"] isKindOfClass:NSString.class] ? request[@"path"] : nil;
        NSString *bundleID = [request[@"bundleID"] isKindOfClass:NSString.class] ? request[@"bundleID"] : nil;
        NSString *build = [request[@"build"] isKindOfClass:NSString.class] ? request[@"build"] : nil;
        if (!CloudCodePCIsSafeInstallRequest(path, bundleID, build)) {
            return @{@"ok": @NO, @"op": operation, @"error": @"invalid-install-request"};
        }
        arguments = @[@"install-ipa", path, bundleID, build];
    } else {
        return @{@"ok": @NO, @"op": operation, @"error": @"unsupported-op"};
    }

    int code = 0;
    if ([operation isEqualToString:@"install-ipa"]) {
        code = CloudCodePCRunOneShotWithTimeout(executablePath, arguments, CLOUDCODE_PC_CONTROL_INSTALL_TIMEOUT_MS);
    } else if ([operation isEqualToString:@"launch"]) {
        code = CloudCodePCRunOneShotWithTimeout(executablePath, arguments, CLOUDCODE_PC_CONTROL_LAUNCH_TIMEOUT_MS);
    } else {
        code = CloudCodePCRunOneShot(executablePath, arguments);
    }
    return @{
        @"ok": @(code == 0),
        @"op": operation,
        @"code": @(code),
        @"serverPid": @(getpid())
    };
}

static NSDictionary *CloudCodePCRequestExisting(NSString *token, NSString *operation, CloudCodePCExistingTransport *transport)
{
    if (transport) { *transport = CloudCodePCExistingTransportAmbiguous; }
    if (token.length != CLOUDCODE_PC_CONTROL_TOKEN_BYTES * 2 || !operation.length) { return nil; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { return nil; }
#ifdef SO_NOSIGPIPE
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 350000};
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(CLOUDCODE_PC_CONTROL_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int connectError = errno;
        close(fd);
        if (transport && connectError == ECONNREFUSED) { *transport = CloudCodePCExistingTransportAbsent; }
        return nil;
    }

    NSDictionary *request = @{@"token": token, @"op": operation};
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!data.length) { close(fd); return nil; }
    NSMutableData *line = [data mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    if (!CloudCodePCWriteAll(fd, line.bytes, line.length)) { close(fd); return nil; }

    NSMutableData *responseData = [NSMutableData data];
    BOOL completeFrame = NO;
    uint8_t responseBytes[1024];
    const double responseDeadline = CloudCodePCMonotonicSeconds() + 1.0;
    while (responseData.length <= 4096) {
        double remaining = responseDeadline - CloudCodePCMonotonicSeconds();
        if (remaining <= 0) { break; }
        int waitMS = (int)(remaining * 1000.0);
        if (waitMS < 1) { waitMS = 1; }
        if (waitMS > 350) { waitMS = 350; }
        struct pollfd responsePoll = {.fd = fd, .events = POLLIN | POLLHUP, .revents = 0};
        int pollResult = 0;
        do {
            pollResult = poll(&responsePoll, 1, waitMS);
        } while (pollResult < 0 && errno == EINTR && CloudCodePCMonotonicSeconds() < responseDeadline);
        if (pollResult <= 0) { break; }

        ssize_t count = recv(fd, responseBytes, sizeof(responseBytes), 0);
        if (count > 0) {
            const void *newlineLocation = memchr(responseBytes, '\n', (size_t)count);
            size_t appendLength = newlineLocation ? (size_t)((const uint8_t *)newlineLocation - responseBytes) : (size_t)count;
            [responseData appendBytes:responseBytes length:appendLength];
            if (newlineLocation) { completeFrame = YES; break; }
            continue;
        }
        if (count < 0 && errno == EINTR) { continue; }
        break;
    }
    close(fd);
    if (!completeFrame || !responseData.length) { return nil; }
    id object = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) { return nil; }
    if (transport) { *transport = CloudCodePCExistingTransportResponse; }
    return object;
}

static BOOL CloudCodePCShutdownExisting(NSString *token)
{
    CloudCodePCExistingTransport transport = CloudCodePCExistingTransportAmbiguous;
    NSDictionary *response = CloudCodePCRequestExisting(token, @"shutdown", &transport);
    return transport == CloudCodePCExistingTransportResponse && [response[@"ok"] boolValue];
}

static int CloudCodePCAcquireServerMigrationLock(void)
{
    int fd = open(CloudCodePCControlLockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) { return -1; }
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (flock(fd, LOCK_EX) != 0) { close(fd); return -1; }
    return fd;
}

static void CloudCodePCReleaseServerMigrationLock(int fd)
{
    if (fd < 0) { return; }
    (void)flock(fd, LOCK_UN);
    close(fd);
}

int CloudCodePCControlServerStart(const char *executablePath)
{
    if (getuid() != 0 || geteuid() != 0 || !executablePath || !*executablePath) { return 11; }

    int migrationLockFD = CloudCodePCAcquireServerMigrationLock();
    if (migrationLockFD < 0) {
        fprintf(stderr, "pc-control-server-start: unable to acquire migration lock\n");
        return 83;
    }

    NSDictionary *existing = CloudCodePCReadTokenRecordRaw();
    NSString *existingToken = [existing[@"token"] isKindOfClass:NSString.class] ? existing[@"token"] : nil;
    if (existingToken.length) {
        CloudCodePCExistingTransport statusTransport = CloudCodePCExistingTransportAmbiguous;
        NSDictionary *existingStatus = CloudCodePCRequestExisting(existingToken, @"status", &statusTransport);
        if (statusTransport == CloudCodePCExistingTransportResponse) {
            BOOL authenticated = [existingStatus[@"ok"] boolValue];
            NSInteger existingProtocol = [existingStatus[@"protocol"] integerValue];
            if (authenticated && existingProtocol == CLOUDCODE_PC_CONTROL_PROTOCOL) {
                NSDictionary *result = @{@"ok": @YES, @"reused": @YES, @"port": @(CLOUDCODE_PC_CONTROL_PORT)};
                NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
                if (json.length) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); }
                CloudCodePCReleaseServerMigrationLock(migrationLockFD);
                return 0;
            }
            if (!authenticated || existingProtocol != 1) {
                fprintf(stderr, "pc-control-server-start: existing listener did not authenticate as supported legacy protocol\n");
                CloudCodePCReleaseServerMigrationLock(migrationLockFD);
                return 83;
            }

            // Same-version TrollStore coverage installs can leave the detached worker from the
            // previous helper binary alive. Protocol v2 intentionally invalidates protocol v1.
            // Only an authenticated v1 status response is eligible for the shutdown migration.
            if (!CloudCodePCShutdownExisting(existingToken)) {
                fprintf(stderr, "pc-control-server-start: stale authenticated worker refused shutdown\n");
                CloudCodePCReleaseServerMigrationLock(migrationLockFD);
                return 83;
            }
            BOOL staleWorkerGone = NO;
            for (int attempt = 0; attempt < 30; attempt++) {
                usleep(50000);
                CloudCodePCExistingTransport probeTransport = CloudCodePCExistingTransportAmbiguous;
                (void)CloudCodePCRequestExisting(existingToken, @"status", &probeTransport);
                if (probeTransport == CloudCodePCExistingTransportAbsent) {
                    staleWorkerGone = YES;
                    break;
                }
            }
            if (!staleWorkerGone) {
                fprintf(stderr, "pc-control-server-start: stale authenticated worker kept the control port after shutdown\n");
                CloudCodePCReleaseServerMigrationLock(migrationLockFD);
                return 83;
            }
        } else if (statusTransport == CloudCodePCExistingTransportAmbiguous) {
            fprintf(stderr, "pc-control-server-start: existing token present but listener state is ambiguous\n");
            CloudCodePCReleaseServerMigrationLock(migrationLockFD);
            return 83;
        }
        // CloudCodePCExistingTransportAbsent proves ECONNREFUSED: the token record is stale and can
        // be removed safely while the migration lock prevents another starter from racing this one.
    }
    (void)unlink(CloudCodePCControlTokenPath.fileSystemRepresentation);

    NSString *token = CloudCodePCRandomToken();
    int handshake[2] = {-1, -1};
    if (pipe(handshake) != 0) {
        CloudCodePCReleaseServerMigrationLock(migrationLockFD);
        return 78;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(handshake[0]); close(handshake[1]);
        CloudCodePCReleaseServerMigrationLock(migrationLockFD);
        return 78;
    }
    (void)posix_spawn_file_actions_addclose(&actions, handshake[0]);
    (void)posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    (void)posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    (void)posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    NSString *fdString = [NSString stringWithFormat:@"%d", handshake[1]];
    const char *childArgv[] = {
        executablePath,
        "pc-control-server-worker",
        token.UTF8String,
        fdString.UTF8String,
        NULL
    };
    pid_t workerPID = 0;
    int spawnResult = posix_spawn(&workerPID, executablePath, &actions, NULL, (char * const *)childArgv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(handshake[1]);
    handshake[1] = -1;
    if (spawnResult != 0 || workerPID <= 1) {
        close(handshake[0]);
        CloudCodePCReleaseServerMigrationLock(migrationLockFD);
        return 78;
    }

    struct pollfd pollFD = {.fd = handshake[0], .events = POLLIN | POLLHUP, .revents = 0};
    int pollResult = poll(&pollFD, 1, 5000);
    uint8_t ready = 0;
    ssize_t count = pollResult > 0 ? read(handshake[0], &ready, sizeof(ready)) : -1;
    close(handshake[0]);
    if (count == 1 && ready == 1) {
        NSDictionary *result = @{
            @"ok": @YES,
            @"reused": @NO,
            @"port": @(CLOUDCODE_PC_CONTROL_PORT),
            @"workerPid": @(workerPID),
            @"tokenPath": CloudCodePCControlTokenPath
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if (json.length) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); }
        CloudCodePCReleaseServerMigrationLock(migrationLockFD);
        return 0;
    }

    (void)kill(workerPID, SIGKILL);
    CloudCodePCReleaseServerMigrationLock(migrationLockFD);
    return 79;
}

int CloudCodePCControlServerWorker(const char *executablePath, NSString *token, int handshakeFD)
{
    if (getuid() != 0 || geteuid() != 0 || !executablePath || !*executablePath || token.length != CLOUDCODE_PC_CONTROL_TOKEN_BYTES * 2 || handshakeFD < 0) {
        if (handshakeFD >= 0) { const uint8_t failed = 0; (void)write(handshakeFD, &failed, 1); close(handshakeFD); }
        return 11;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    (void)setsid();
    int serverFD = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFD < 0) {
        const uint8_t failed = 0; (void)write(handshakeFD, &failed, 1); close(handshakeFD);
        return 80;
    }
    int one = 1;
    (void)setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
    (void)setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(CLOUDCODE_PC_CONTROL_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(serverFD, 4) != 0) {
        const uint8_t failed = 0; (void)write(handshakeFD, &failed, 1); close(handshakeFD); close(serverFD);
        return 81;
    }

    // Keep the detached PC-control worker free of BKSProcessAssertion. On the iOS 16.6
    // TrollStore device, the assertion guardian itself was proven to keep the visible green status
    // indicator active even though screenshot + Vision OCR are overlay-free. This worker is already
    // a detached root process; if iOS later terminates it, the authenticated controller can start a
    // fresh worker instead of trading invisible OCR for a persistent user-visible system indicator.
    if (!CloudCodePCWriteTokenRecord(token)) {
        const uint8_t failed = 0; (void)write(handshakeFD, &failed, 1); close(handshakeFD); close(serverFD);
        return 82;
    }

    const uint8_t ready = 1;
    (void)write(handshakeFD, &ready, 1);
    close(handshakeFD);

    BOOL keepRunning = YES;
    while (keepRunning) {
        int clientFD = accept(serverFD, NULL, NULL);
        if (clientFD < 0) {
            if (errno == EINTR) { continue; }
            break;
        }
#ifdef SO_NOSIGPIPE
        (void)setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        struct timeval timeout = {.tv_sec = 3, .tv_usec = 0};
        (void)setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        (void)setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        @autoreleasepool {
            BOOL tooLarge = NO;
            NSData *requestData = CloudCodePCReadRequest(clientFD, &tooLarge);
            NSDictionary *response = nil;
            BOOL shutdown = NO;
            if (tooLarge) {
                response = @{@"ok": @NO, @"error": @"request-too-large"};
            } else if (!requestData.length) {
                response = @{@"ok": @NO, @"error": @"empty-request"};
            } else {
                id object = [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil];
                if (![object isKindOfClass:NSDictionary.class]) {
                    response = @{@"ok": @NO, @"error": @"invalid-json"};
                } else {
                    NSDictionary *request = object;
                    NSString *requestToken = [request[@"token"] isKindOfClass:NSString.class] ? request[@"token"] : nil;
                    if (![requestToken isEqualToString:token]) {
                        response = @{@"ok": @NO, @"error": @"unauthorized"};
                    } else {
                        response = CloudCodePCActionResponse(executablePath, request, &shutdown);
                    }
                }
            }
            (void)CloudCodePCSendJSON(clientFD, response ?: @{@"ok": @NO, @"error": @"internal-error"});
            if (shutdown) { keepRunning = NO; }
        }
        close(clientFD);
    }

    close(serverFD);
    NSDictionary *current = CloudCodePCReadTokenRecord();
    NSString *currentToken = [current[@"token"] isKindOfClass:NSString.class] ? current[@"token"] : nil;
    if ([currentToken isEqualToString:token]) {
        (void)unlink(CloudCodePCControlTokenPath.fileSystemRepresentation);
    }
    return 0;
}
