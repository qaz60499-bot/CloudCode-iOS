#import "PCControlServer.h"

#import <UIKit/UIKit.h>
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

#define CLOUDCODE_PC_CONTROL_PROTOCOL 2
#define CLOUDCODE_PC_CONTROL_PORT 47651
#define CLOUDCODE_PC_CONTROL_TOKEN_BYTES 32
#define CLOUDCODE_PC_CONTROL_MAX_REQUEST_BYTES (64 * 1024)
#define CLOUDCODE_PC_CONTROL_CHILD_TIMEOUT_MS 5000
#define CLOUDCODE_PC_CONTROL_LAUNCH_TIMEOUT_MS 12000
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

static pid_t CloudCodePCStartBackgroundGuardian(const char *executablePath, pid_t targetPID)
{
    if (!executablePath || !*executablePath || targetPID <= 1) { return -1; }

    int handshake[2] = {-1, -1};
    if (pipe(handshake) != 0) { return -1; }

    char targetArg[32] = {0};
    char handshakeArg[32] = {0};
    snprintf(targetArg, sizeof(targetArg), "%d", targetPID);
    snprintf(handshakeArg, sizeof(handshakeArg), "%d", handshake[1]);
    const char *guardianArgv[] = {
        executablePath,
        "background-assert-worker",
        targetArg,
        handshakeArg,
        NULL
    };

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(handshake[0]); close(handshake[1]);
        return -1;
    }
    (void)posix_spawn_file_actions_addclose(&actions, handshake[0]);

    pid_t guardianPID = 0;
    int spawnResult = posix_spawn(&guardianPID, executablePath, &actions, NULL, (char * const *)guardianArgv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(handshake[1]);
    handshake[1] = -1;
    if (spawnResult != 0 || guardianPID <= 1) {
        close(handshake[0]);
        return -1;
    }

    struct pollfd pollFD = {.fd = handshake[0], .events = POLLIN | POLLHUP, .revents = 0};
    int pollResult = 0;
    do {
        pollResult = poll(&pollFD, 1, 2500);
    } while (pollResult < 0 && errno == EINTR);
    uint8_t acquired = 0;
    ssize_t count = pollResult > 0 ? read(handshake[0], &acquired, sizeof(acquired)) : -1;
    close(handshake[0]);
    if (count == sizeof(acquired) && acquired == 1) { return guardianPID; }

    (void)kill(guardianPID, SIGTERM);
    return -1;
}

static void CloudCodePCStopBackgroundGuardian(pid_t guardianPID)
{
    if (guardianPID <= 1) { return; }
    (void)kill(guardianPID, SIGTERM);
    int status = 0;
    for (int attempt = 0; attempt < 20; attempt++) {
        pid_t waited = waitpid(guardianPID, &status, WNOHANG);
        if (waited == guardianPID || (waited < 0 && errno == ECHILD)) { return; }
        if (waited < 0 && errno != EINTR) { return; }
        usleep(10000);
    }
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

    // The PC-control worker must remain schedulable after Cloud Code leaves the foreground.
    // Reuse the already-proven BKS/RunningBoard assertion worker and target this server PID itself.
    // This keeps the authenticated loopback server independent of the SwiftUI app lifecycle while
    // preserving a bounded cleanup path: the guardian exits when this worker exits, and we also
    // stop it explicitly on normal shutdown.
    pid_t guardianPID = CloudCodePCStartBackgroundGuardian(executablePath, getpid());
    if (guardianPID <= 1 || !CloudCodePCWriteTokenRecord(token)) {
        CloudCodePCStopBackgroundGuardian(guardianPID);
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
    CloudCodePCStopBackgroundGuardian(guardianPID);
    return 0;
}
