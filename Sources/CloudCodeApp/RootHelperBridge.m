#import "RootHelperBridge.h"

#import <dlfcn.h>
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

static void CloudCodeDrainPipe(int fd, NSMutableData *captured)
{
    if (fd < 0 || !captured) { return; }
    uint8_t buffer[2048];
    while (YES) {
        ssize_t readCount = read(fd, buffer, sizeof(buffer));
        if (readCount > 0) {
            if (captured.length < CLOUDCODE_HELPER_CAPTURE_LIMIT) {
                NSUInteger remaining = CLOUDCODE_HELPER_CAPTURE_LIMIT - captured.length;
                [captured appendBytes:buffer length:MIN((NSUInteger)readCount, remaining)];
            }
            continue;
        }
        if (readCount == 0) { return; }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) { return; }
        return;
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

static NSInteger CloudCodeSpawnHelperInternal(
    NSString *path,
    NSArray<NSString *> *arguments,
    BOOL asRoot,
    NSTimeInterval timeout,
    NSString * _Nullable * _Nullable diagnostic
)
{
    if (diagnostic) { *diagnostic = nil; }
    if (path.length == 0) { return -1001; }
    if (timeout <= 0) { timeout = CLOUDCODE_HELPER_DEFAULT_TIMEOUT; }

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:path];
    [argvStrings addObjectsFromArray:arguments ?: @[]];

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

    int diagnosticPipe[2] = {-1, -1};
    BOOL captureOutput = diagnostic != NULL;
    NSInteger earlyFailure = 0;
    if (captureOutput) {
        if (pipe(diagnosticPipe) != 0) {
            earlyFailure = -6000 - errno;
        } else {
            int actionError = posix_spawn_file_actions_adddup2(&actions, diagnosticPipe[1], STDOUT_FILENO);
            if (actionError == 0) { actionError = posix_spawn_file_actions_adddup2(&actions, diagnosticPipe[1], STDERR_FILENO); }
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, diagnosticPipe[0]); }
            if (actionError == 0) { actionError = posix_spawn_file_actions_addclose(&actions, diagnosticPipe[1]); }
            if (actionError != 0) { earlyFailure = -6100 - actionError; }
        }
    }

    NSInteger result = 0;
    NSMutableData *captured = captureOutput ? [NSMutableData data] : nil;
    NSString *diagnosticSuffix = @"";

    if (earlyFailure != 0) {
        result = earlyFailure;
    } else if (personaError != 0) {
        result = -2000 - personaError;
    } else {
        pid_t pid = 0;
        int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, captureOutput ? &actions : NULL, &attributes, argv, NULL);
        if (spawnError != 0) {
            result = -3000 - spawnError;
        } else {
            if (captureOutput) {
                close(diagnosticPipe[1]);
                diagnosticPipe[1] = -1;
                int flags = fcntl(diagnosticPipe[0], F_GETFL, 0);
                if (flags >= 0) { (void)fcntl(diagnosticPipe[0], F_SETFL, flags | O_NONBLOCK); }
            }

            const double start = CloudCodeMonotonicSeconds();
            int status = 0;
            BOOL finished = NO;
            while (!finished) {
                if (captureOutput) { CloudCodeDrainPipe(diagnosticPipe[0], captured); }

                pid_t waited = waitpid(pid, &status, WNOHANG);
                if (waited == pid) {
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
                    (void)kill(pid, SIGKILL);
                    do {
                        waited = waitpid(pid, &status, 0);
                    } while (waited == -1 && errno == EINTR);
                    result = -7000 - ETIMEDOUT;
                    diagnosticSuffix = [NSString stringWithFormat:@"helper timed out after %.1f seconds and was terminated", timeout];
                    finished = YES;
                    break;
                }

                if (captureOutput) {
                    struct pollfd pollFD = {.fd = diagnosticPipe[0], .events = POLLIN | POLLHUP, .revents = 0};
                    (void)poll(&pollFD, 1, 50);
                } else {
                    usleep(50000);
                }
            }

            if (captureOutput) { CloudCodeDrainPipe(diagnosticPipe[0], captured); }
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
        }
    }

    if (diagnostic && captureOutput) {
        NSString *text = CloudCodeCapturedText(captured ?: [NSData data], diagnosticSuffix);
        if (text.length > 0) { *diagnostic = text; }
    }

    if (diagnosticPipe[0] >= 0) { close(diagnosticPipe[0]); }
    if (diagnosticPipe[1] >= 0) { close(diagnosticPipe[1]); }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    CloudCodeFreeArgv(argv, count);
    return result;
}

NSInteger CloudCodeSpawnRootHelper(NSString *path, NSArray<NSString *> *arguments)
{
    return CloudCodeSpawnHelperInternal(path, arguments, YES, CLOUDCODE_HELPER_DEFAULT_TIMEOUT, NULL);
}

NSInteger CloudCodeSpawnRootHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, NSString * _Nullable * _Nullable diagnostic)
{
    return CloudCodeSpawnHelperInternal(path, arguments, YES, CLOUDCODE_HELPER_DEFAULT_TIMEOUT, diagnostic);
}

NSInteger CloudCodeSpawnHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, BOOL asRoot, NSTimeInterval timeout, NSString * _Nullable * _Nullable diagnostic)
{
    return CloudCodeSpawnHelperInternal(path, arguments, asRoot, timeout, diagnostic);
}
