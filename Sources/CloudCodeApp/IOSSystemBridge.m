#import "RootHelperBridge.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// Declare only the upstream symbols used by this bridge instead of importing ios_error.h: that
// header intentionally macro-rewrites libc functions for ported command sources, which would also
// rewrite this host bridge's own stdio calls.
extern int ios_system(const char *inputCmd);
extern int ios_executable(const char *cmd);
extern int ios_kill(void);
extern int ios_setenv(const char *variableName, const char *value, int overwrite);
extern int ios_unsetenv(const char *variableName);
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

extern NSArray *commandsAsArray(void);
extern int ios_setMiniRoot(NSString *mRoot);
extern void ios_switchSession(void *sessionId);
extern void ios_setDirectoryURL(NSURL *workingDirectoryURL);
extern void ios_closeSession(void *sessionId);
extern char **environ;

static const NSUInteger CloudCodeCLIStreamCaptureLimit = 64 * 1024;
static pthread_mutex_t CloudCodeCLIStateLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *CloudCodeCLIActiveInvocationID = nil;
static BOOL CloudCodeCLIActiveTimedOut = NO;
static BOOL CloudCodeCLIActiveCancelled = NO;

@interface CloudCodeCLICaptureBuffer : NSObject
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic) NSUInteger totalBytes;
@property(nonatomic) BOOL truncated;
@end

@implementation CloudCodeCLICaptureBuffer
- (instancetype)init
{
    self = [super init];
    if (self) {
        _data = [NSMutableData data];
        _totalBytes = 0;
        _truncated = NO;
    }
    return self;
}
@end

static int CloudCodeCLICaptureWrite(void *cookie, const char *buffer, int length)
{
    if (!cookie || !buffer || length <= 0) { return MAX(length, 0); }
    CloudCodeCLICaptureBuffer *capture = (__bridge CloudCodeCLICaptureBuffer *)cookie;
    NSUInteger incoming = (NSUInteger)length;
    capture.totalBytes += incoming;
    if (capture.data.length < CloudCodeCLIStreamCaptureLimit) {
        NSUInteger remaining = CloudCodeCLIStreamCaptureLimit - capture.data.length;
        NSUInteger appendLength = MIN(remaining, incoming);
        if (appendLength > 0) { [capture.data appendBytes:buffer length:appendLength]; }
        if (appendLength < incoming) { capture.truncated = YES; }
    } else {
        capture.truncated = YES;
    }
    return length;
}

static BOOL CloudCodeCLIDataLooksBinary(NSData *data)
{
    if (data.length == 0) { return NO; }
    const uint8_t *bytes = data.bytes;
    NSUInteger suspicious = 0;
    for (NSUInteger index = 0; index < data.length; index++) {
        uint8_t byte = bytes[index];
        if (byte == 0) { return YES; }
        if (byte < 0x20 && byte != '\n' && byte != '\r' && byte != '\t' && byte != '\f') {
            suspicious++;
        }
    }
    return suspicious * 20 > data.length;
}

static NSString *CloudCodeCLITextFromCapture(CloudCodeCLICaptureBuffer *capture, BOOL *binarySuppressed)
{
    if (binarySuppressed) { *binarySuppressed = NO; }
    if (!capture || capture.data.length == 0) { return @""; }
    if (CloudCodeCLIDataLooksBinary(capture.data)) {
        if (binarySuppressed) { *binarySuppressed = YES; }
        return [NSString stringWithFormat:@"<binary output suppressed; captured %lu of %lu bytes>",
                (unsigned long)capture.data.length, (unsigned long)capture.totalBytes];
    }
    NSString *text = [[NSString alloc] initWithData:capture.data encoding:NSUTF8StringEncoding];
    if (!text) {
        if (binarySuppressed) { *binarySuppressed = YES; }
        return [NSString stringWithFormat:@"<non-UTF8 output suppressed; captured %lu of %lu bytes>",
                (unsigned long)capture.data.length, (unsigned long)capture.totalBytes];
    }
    return text;
}

static uint32_t CloudCodeCLIStableSessionKey(NSString *sessionID)
{
    NSData *data = [sessionID dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    const uint8_t *bytes = data.bytes;
    uint32_t hash = 2166136261u;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= 16777619u;
    }
    hash &= 0x7fffffffu;
    return hash == 0 ? 1 : hash;
}

static BOOL CloudCodeCLIPathIsInsideRoot(NSString *path, NSString *root)
{
    NSString *normalizedPath = path.stringByStandardizingPath;
    NSString *normalizedRoot = root.stringByStandardizingPath;
    if ([normalizedPath isEqualToString:normalizedRoot]) { return YES; }
    NSString *prefix = [normalizedRoot hasSuffix:@"/"] ? normalizedRoot : [normalizedRoot stringByAppendingString:@"/"];
    return [normalizedPath hasPrefix:prefix];
}

static void CloudCodeCLIApplyEnvironment(NSString *homeDirectory, NSString *temporaryDirectory, NSString *workingDirectory)
{
    // ios_system keeps a per-session environment. Remove inherited process variables from the
    // command session before installing a compact whitelist so App/provider secrets cannot become
    // accidental shell input merely because the host process happens to have an environment key.
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    if (environ) {
        for (char **entry = environ; *entry != NULL; entry++) {
            const char *equals = strchr(*entry, '=');
            if (!equals || equals == *entry) { continue; }
            size_t length = (size_t)(equals - *entry);
            NSString *name = [[NSString alloc] initWithBytes:*entry length:length encoding:NSUTF8StringEncoding];
            if (name.length > 0 && name.length <= 256) { [names addObject:name]; }
        }
    }
    NSSet<NSString *> *whitelist = [NSSet setWithArray:@[@"HOME", @"PATH", @"TMPDIR", @"PWD", @"LANG", @"LC_ALL", @"TERM"]];
    for (NSString *name in names) {
        if (![whitelist containsObject:name]) { ios_unsetenv(name.UTF8String); }
    }
    ios_setenv("HOME", homeDirectory.UTF8String ?: "", 1);
    ios_setenv("PATH", "/usr/bin:/bin", 1);
    ios_setenv("TMPDIR", temporaryDirectory.UTF8String ?: "", 1);
    ios_setenv("PWD", workingDirectory.UTF8String ?: "", 1);
    ios_setenv("LANG", "en_US.UTF-8", 1);
    ios_setenv("LC_ALL", "en_US.UTF-8", 1);
    ios_setenv("TERM", "dumb", 1);
}

static NSDictionary<NSString *, id> *CloudCodeCLIFrameworkValidation(void)
{
    const char *requiredRuntimeSymbols[] = {
        "ios_system", "ios_executable", "commandsAsArray", "ios_kill",
        "ios_setMiniRoot", "ios_switchSession", "ios_setDirectoryURL", "ios_closeSession",
        "ios_setenv", "ios_unsetenv"
    };
    NSMutableArray<NSString *> *missingRuntimeSymbols = [NSMutableArray array];
    for (NSUInteger index = 0; index < sizeof(requiredRuntimeSymbols) / sizeof(requiredRuntimeSymbols[0]); index++) {
        if (!dlsym(RTLD_DEFAULT, requiredRuntimeSymbols[index])) {
            [missingRuntimeSymbols addObject:[NSString stringWithUTF8String:requiredRuntimeSymbols[index]]];
        }
    }
    BOOL runtimeSymbolsAvailable = missingRuntimeSymbols.count == 0;

    NSURL *dictionaryURL = [NSBundle.mainBundle URLForResource:@"commandDictionary" withExtension:@"plist"];
    NSURL *extraDictionaryURL = [NSBundle.mainBundle URLForResource:@"extraCommandsDictionary" withExtension:@"plist"];
    NSDictionary *dictionary = dictionaryURL ? [NSDictionary dictionaryWithContentsOfURL:dictionaryURL] : nil;
    NSDictionary *extraDictionary = extraDictionaryURL ? [NSDictionary dictionaryWithContentsOfURL:extraDictionaryURL] : nil;
    BOOL dictionariesPresent = dictionaryURL != nil && extraDictionaryURL != nil
        && [dictionary isKindOfClass:NSDictionary.class] && [extraDictionary isKindOfClass:NSDictionary.class];

    NSArray *reported = runtimeSymbolsAvailable && dictionariesPresent ? commandsAsArray() : @[];
    NSSet *reportedSet = [NSSet setWithArray:[reported isKindOfClass:NSArray.class] ? reported : @[]];
    NSMutableArray<NSString *> *verified = [NSMutableArray array];
    NSMutableArray<NSString *> *missingFrameworks = [NSMutableArray array];
    NSMutableArray<NSString *> *missingCommandSymbols = [NSMutableArray array];
    NSMutableArray<NSString *> *catalogMismatches = [NSMutableArray array];

    if ([dictionary isKindOfClass:NSDictionary.class]) {
        NSArray<NSString *> *keys = [[dictionary allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *command in keys) {
            id raw = dictionary[command];
            if (![raw isKindOfClass:NSArray.class] || [(NSArray *)raw count] != 4) {
                [catalogMismatches addObject:[NSString stringWithFormat:@"%@:<invalid-entry>", command]];
                continue;
            }
            NSArray *entry = (NSArray *)raw;
            NSString *framework = [entry[0] isKindOfClass:NSString.class] ? entry[0] : @"";
            NSString *functionName = [entry[1] isKindOfClass:NSString.class] ? entry[1] : @"";
            BOOL frameworkPresent = NO;
            BOOL commandSymbolPresent = NO;
            void *frameworkHandle = NULL;

            if ([framework isEqualToString:@"SELF"] || [framework isEqualToString:@"MAIN"]) {
                frameworkPresent = YES;
                commandSymbolPresent = functionName.length > 0 && dlsym(RTLD_DEFAULT, functionName.UTF8String) != NULL;
            } else if (framework.length > 0) {
                NSString *frameworkBinaryPath = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:framework];
                frameworkPresent = [[NSFileManager defaultManager] fileExistsAtPath:frameworkBinaryPath];
                if (frameworkPresent && functionName.length > 0) {
                    frameworkHandle = dlopen(frameworkBinaryPath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                    commandSymbolPresent = frameworkHandle != NULL && dlsym(frameworkHandle, functionName.UTF8String) != NULL;
                }
            }

            BOOL reportedCommand = [reportedSet containsObject:command] && ios_executable(command.UTF8String) != 0;
            if (frameworkPresent && commandSymbolPresent && reportedCommand) {
                [verified addObject:command];
            } else {
                if (!frameworkPresent) { [missingFrameworks addObject:framework.length > 0 ? framework : command]; }
                if (frameworkPresent && !commandSymbolPresent) {
                    [missingCommandSymbols addObject:[NSString stringWithFormat:@"%@:%@", command, functionName.length > 0 ? functionName : @"<missing>"]];
                }
                if (!reportedCommand) { [catalogMismatches addObject:command]; }
            }
            if (frameworkHandle) { dlclose(frameworkHandle); }
        }
    }

    BOOL runtimeAvailable = runtimeSymbolsAvailable && dictionariesPresent;
    NSString *detail = [NSString stringWithFormat:@"runtimeSymbols=%@ dictionaries=%@ verified=%lu reported=%lu missingRuntimeSymbols=%lu missingFrameworks=%lu missingCommandSymbols=%lu catalogMismatches=%lu",
                        runtimeSymbolsAvailable ? @"yes" : @"no",
                        dictionariesPresent ? @"yes" : @"no",
                        (unsigned long)verified.count,
                        (unsigned long)reportedSet.count,
                        (unsigned long)missingRuntimeSymbols.count,
                        (unsigned long)missingFrameworks.count,
                        (unsigned long)missingCommandSymbols.count,
                        (unsigned long)catalogMismatches.count];
    return @{
        @"runtimeAvailable": @(runtimeAvailable),
        @"commands": verified.copy,
        @"detail": detail,
        @"missingRuntimeSymbols": missingRuntimeSymbols.copy,
        @"missingFrameworks": missingFrameworks.copy,
        @"missingCommandSymbols": missingCommandSymbols.copy,
        @"catalogMismatches": catalogMismatches.copy
    };
}

NSDictionary<NSString *, id> *CloudCodeIOSSystemCapabilitySnapshot(void)
{
    @autoreleasepool {
        return CloudCodeCLIFrameworkValidation();
    }
}

void CloudCodeIOSSystemCancelInvocation(NSString *invocationID)
{
    if (invocationID.length == 0) { return; }
    BOOL shouldKill = NO;
    pthread_mutex_lock(&CloudCodeCLIStateLock);
    if ([CloudCodeCLIActiveInvocationID isEqualToString:invocationID] && !CloudCodeCLIActiveTimedOut) {
        CloudCodeCLIActiveCancelled = YES;
        shouldKill = YES;
    }
    pthread_mutex_unlock(&CloudCodeCLIStateLock);
    if (shouldKill) { (void)ios_kill(); }
}

NSDictionary<NSString *, id> *CloudCodeIOSSystemRunCommand(
    NSString *command,
    NSString *invocationID,
    NSString *sessionID,
    NSString *workspaceRoot,
    NSString *workingDirectory,
    NSString *homeDirectory,
    NSString *temporaryDirectory,
    NSTimeInterval timeout
)
{
    @autoreleasepool {
        CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
        if (command.length == 0 || invocationID.length == 0 || sessionID.length == 0 ||
            workspaceRoot.length == 0 || workingDirectory.length == 0 || homeDirectory.length == 0 || temporaryDirectory.length == 0) {
            return @{@"exitCode": @(-1), @"stderr": @"invalid CLI bridge arguments", @"stdout": @"",
                     @"timedOut": @NO, @"cancelled": @NO, @"stdoutTruncated": @NO, @"stderrTruncated": @NO,
                     @"binaryOutputSuppressed": @NO, @"cwd": workingDirectory ?: @"", @"durationMs": @0};
        }
        if (!CloudCodeCLIPathIsInsideRoot(workingDirectory, workspaceRoot)) {
            return @{@"exitCode": @(-1), @"stderr": @"CLI cwd escaped the workspace root", @"stdout": @"",
                     @"timedOut": @NO, @"cancelled": @NO, @"stdoutTruncated": @NO, @"stderrTruncated": @NO,
                     @"binaryOutputSuppressed": @NO, @"cwd": workingDirectory, @"durationMs": @0};
        }
        NSDictionary *capability = CloudCodeCLIFrameworkValidation();
        if (![capability[@"runtimeAvailable"] boolValue]) {
            return @{@"exitCode": @(-1), @"stderr": @"ios_system runtime/catalog is not packaged correctly", @"stdout": @"",
                     @"timedOut": @NO, @"cancelled": @NO, @"stdoutTruncated": @NO, @"stderrTruncated": @NO,
                     @"binaryOutputSuppressed": @NO, @"cwd": workingDirectory, @"durationMs": @0};
        }

        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *originalWorkingDirectory = fileManager.currentDirectoryPath ?: @"/";
        uint32_t sessionKeyValue = CloudCodeCLIStableSessionKey(sessionID);
        void *sessionKey = (void *)(uintptr_t)sessionKeyValue;
        ios_switchSession(sessionKey);
        if (!ios_setMiniRoot(workspaceRoot)) {
            ios_closeSession(sessionKey);
            return @{@"exitCode": @(-1), @"stderr": @"ios_setMiniRoot rejected the workspace root", @"stdout": @"",
                     @"timedOut": @NO, @"cancelled": @NO, @"stdoutTruncated": @NO, @"stderrTruncated": @NO,
                     @"binaryOutputSuppressed": @NO, @"cwd": workingDirectory, @"durationMs": @0};
        }
        ios_setDirectoryURL([NSURL fileURLWithPath:workingDirectory isDirectory:YES]);
        CloudCodeCLIApplyEnvironment(homeDirectory, temporaryDirectory, workingDirectory);

        CloudCodeCLICaptureBuffer *stdoutCapture = [CloudCodeCLICaptureBuffer new];
        CloudCodeCLICaptureBuffer *stderrCapture = [CloudCodeCLICaptureBuffer new];
        FILE *stdoutStream = funopen((__bridge void *)stdoutCapture, NULL, CloudCodeCLICaptureWrite, NULL, NULL);
        FILE *stderrStream = funopen((__bridge void *)stderrCapture, NULL, CloudCodeCLICaptureWrite, NULL, NULL);
        FILE *stdinStream = fopen("/dev/null", "r");
        FILE *previousStdin = thread_stdin;
        FILE *previousStdout = thread_stdout;
        FILE *previousStderr = thread_stderr;
        if (stdinStream) { thread_stdin = stdinStream; }
        if (stdoutStream) { thread_stdout = stdoutStream; }
        if (stderrStream) { thread_stderr = stderrStream; }

        pthread_mutex_lock(&CloudCodeCLIStateLock);
        CloudCodeCLIActiveInvocationID = [invocationID copy];
        CloudCodeCLIActiveTimedOut = NO;
        CloudCodeCLIActiveCancelled = NO;
        pthread_mutex_unlock(&CloudCodeCLIStateLock);

        NSTimeInterval boundedTimeout = MIN(MAX(timeout, 0.25), 15.0);
        NSString *timerInvocationID = [invocationID copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(boundedTimeout * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL shouldKill = NO;
            pthread_mutex_lock(&CloudCodeCLIStateLock);
            if ([CloudCodeCLIActiveInvocationID isEqualToString:timerInvocationID] && !CloudCodeCLIActiveCancelled) {
                CloudCodeCLIActiveTimedOut = YES;
                shouldKill = YES;
            }
            pthread_mutex_unlock(&CloudCodeCLIStateLock);
            if (shouldKill) { (void)ios_kill(); }
        });

        int code = ios_system(command.UTF8String ?: "");

        BOOL timedOut = NO;
        BOOL cancelled = NO;
        pthread_mutex_lock(&CloudCodeCLIStateLock);
        if ([CloudCodeCLIActiveInvocationID isEqualToString:invocationID]) {
            timedOut = CloudCodeCLIActiveTimedOut;
            cancelled = CloudCodeCLIActiveCancelled;
            CloudCodeCLIActiveInvocationID = nil;
            CloudCodeCLIActiveTimedOut = NO;
            CloudCodeCLIActiveCancelled = NO;
        }
        pthread_mutex_unlock(&CloudCodeCLIStateLock);

        if (stdoutStream) { fflush(stdoutStream); }
        if (stderrStream) { fflush(stderrStream); }
        thread_stdin = previousStdin;
        thread_stdout = previousStdout;
        thread_stderr = previousStderr;
        if (stdinStream) { fclose(stdinStream); }
        if (stdoutStream) { fclose(stdoutStream); }
        if (stderrStream) { fclose(stderrStream); }

        // ios_system's session cwd is process-global under the hood. The runtime serializes all
        // commands and always restores the host cwd before returning so no later Cloud Code task
        // inherits the command's directory.
        [fileManager changeCurrentDirectoryPath:originalWorkingDirectory];
        ios_closeSession(sessionKey);

        BOOL stdoutBinary = NO;
        BOOL stderrBinary = NO;
        NSString *stdoutText = CloudCodeCLITextFromCapture(stdoutCapture, &stdoutBinary);
        NSString *stderrText = CloudCodeCLITextFromCapture(stderrCapture, &stderrBinary);
        BOOL binarySuppressed = stdoutBinary || stderrBinary;
        NSInteger durationMS = MAX(0, (NSInteger)((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0));
        return @{
            @"exitCode": @(code),
            @"stdout": stdoutText ?: @"",
            @"stderr": stderrText ?: @"",
            @"timedOut": @(timedOut),
            @"cancelled": @(cancelled),
            @"stdoutTruncated": @(stdoutCapture.truncated),
            @"stderrTruncated": @(stderrCapture.truncated),
            @"binaryOutputSuppressed": @(binarySuppressed),
            @"cwd": workingDirectory,
            @"durationMs": @(durationMS),
            @"stdoutBytes": @(stdoutCapture.totalBytes),
            @"stderrBytes": @(stderrCapture.totalBytes)
        };
    }
}
