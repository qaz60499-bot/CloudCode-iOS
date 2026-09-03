#import "RootHelperBridge.h"

#import <dlfcn.h>
#import <errno.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

typedef int (*PersonaSetFn)(const posix_spawnattr_t * _Nonnull __restrict, uid_t, uint32_t);
typedef int (*PersonaUIDFn)(const posix_spawnattr_t * _Nonnull __restrict, uid_t);
typedef int (*PersonaGIDFn)(const posix_spawnattr_t * _Nonnull __restrict, gid_t);

NSInteger CloudCodeSpawnRootHelper(NSString *path, NSArray<NSString *> *arguments)
{
    if (path.length == 0) { return -1001; }

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:path];
    [argvStrings addObjectsFromArray:arguments ?: @[]];

    const NSUInteger count = argvStrings.count;
    char **argv = calloc(count + 1, sizeof(char *));
    if (!argv) { return -1002; }

    for (NSUInteger index = 0; index < count; index++) {
        argv[index] = strdup(argvStrings[index].UTF8String ?: "");
    }
    argv[count] = NULL;

    PersonaSetFn setPersona = (PersonaSetFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    PersonaUIDFn setPersonaUID = (PersonaUIDFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    PersonaGIDFn setPersonaGID = (PersonaGIDFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!setPersona || !setPersonaUID || !setPersonaGID) {
        for (NSUInteger index = 0; index < count; index++) { free(argv[index]); }
        free(argv);
        return -1900;
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    int personaError = setPersona(&attributes, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (personaError == 0) {
        personaError = setPersonaUID(&attributes, 0);
    }
    if (personaError == 0) {
        personaError = setPersonaGID(&attributes, 0);
    }

    NSInteger result = 0;
    if (personaError != 0) {
        result = -2000 - personaError;
    } else {
        pid_t pid = 0;
        int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attributes, argv, NULL);
        if (spawnError != 0) {
            result = -3000 - spawnError;
        } else {
            int status = 0;
            pid_t waited;
            do {
                waited = waitpid(pid, &status, 0);
            } while (waited == -1 && errno == EINTR);

            if (waited == -1) {
                result = -4000 - errno;
            } else if (WIFEXITED(status)) {
                result = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                result = -5000 - WTERMSIG(status);
            } else {
                result = -5001;
            }
        }
    }

    posix_spawnattr_destroy(&attributes);
    for (NSUInteger index = 0; index < count; index++) {
        free(argv[index]);
    }
    free(argv);
    return result;
}
