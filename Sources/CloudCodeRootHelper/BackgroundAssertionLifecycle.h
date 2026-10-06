#ifndef CLOUDCODE_BACKGROUND_ASSERTION_LIFECYCLE_H
#define CLOUDCODE_BACKGROUND_ASSERTION_LIFECYCLE_H

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <time.h>
#include <unistd.h>

// A detached worker inherits its caller's thread mask and ignored dispositions.
// Normalize only its termination signal; preserve unrelated signal policy.
static inline int CloudCodeBackgroundAssertionSpawnAttributes(posix_spawnattr_t *attributes)
{
    int error = posix_spawnattr_init(attributes);
    if (error != 0) { return error; }
    sigset_t mask;
    sigset_t defaults;
    error = pthread_sigmask(SIG_SETMASK, NULL, &mask);
    if (error == 0) {
        sigdelset(&mask, SIGTERM);
        sigemptyset(&defaults);
        sigaddset(&defaults, SIGTERM);
        error = posix_spawnattr_setsigmask(attributes, &mask);
    }
    if (error == 0) { error = posix_spawnattr_setsigdefault(attributes, &defaults); }
    if (error == 0) {
        error = posix_spawnattr_setflags(attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    }
    if (error != 0) { posix_spawnattr_destroy(attributes); }
    return error;
}

static inline int CloudCodeStopBackgroundAssertionWorker(pid_t workerPID)
{
    if (workerPID <= 1) { return 10; }
    if (kill(workerPID, SIGTERM) != 0) { return errno == ESRCH ? 0 : 76; }
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) { return 78; }
    for (;;) {
        if (kill(workerPID, 0) != 0) { return errno == ESRCH ? 0 : 78; }
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { return 78; }
        double elapsed = (double)(now.tv_sec - started.tv_sec)
            + (double)(now.tv_nsec - started.tv_nsec) / 1000000000.0;
        if (elapsed >= 1.0) { return 78; }
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 50000000L};
        (void)nanosleep(&delay, NULL);
    }
}

#endif
