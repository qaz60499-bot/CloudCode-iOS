#include "BackgroundAssertionLifecycle.h"
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;
static void require(int condition, const char *message)
{
    if (condition) { return; }
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}
static void *reap(void *context)
{
    pid_t pid = *(pid_t *)context;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return (void *)(intptr_t)status;
}
static pid_t fixture(const char *executable, int ignoresTermination)
{
    struct sigaction ignored = {.sa_handler = SIG_IGN};
    struct sigaction original;
    sigemptyset(&ignored.sa_mask);
    require(sigaction(SIGTERM, &ignored, &original) == 0, "install inherited ignored SIGTERM");
    sigset_t blocked;
    sigset_t originalMask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGTERM);
    sigaddset(&blocked, SIGUSR1);
    require(pthread_sigmask(SIG_BLOCK, &blocked, &originalMask) == 0, "install inherited blocked signals");
    int pipeFDs[2];
    require(pipe(pipeFDs) == 0, "fixture pipe");
    char writeFD[32];
    snprintf(writeFD, sizeof(writeFD), "%d", pipeFDs[1]);
    char *arguments[] = {(char *)executable, (char *)"--fixture", writeFD,
        ignoresTermination ? (char *)"ignore" : (char *)"default", NULL};
    posix_spawnattr_t attributes;
    require(CloudCodeBackgroundAssertionSpawnAttributes(&attributes) == 0, "worker signal attributes");
    posix_spawn_file_actions_t actions;
    require(posix_spawn_file_actions_init(&actions) == 0, "fixture file actions");
    require(posix_spawn_file_actions_addclose(&actions, pipeFDs[0]) == 0, "close child pipe reader");
    pid_t pid = 0;
    int error = posix_spawn(&pid, executable, &actions, &attributes, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(pipeFDs[1]);
    require(pthread_sigmask(SIG_SETMASK, &originalMask, NULL) == 0, "restore parent mask");
    require(sigaction(SIGTERM, &original, NULL) == 0, "restore parent disposition");
    require(error == 0, "spawn fixture");
    struct pollfd ready = {.fd = pipeFDs[0], .events = POLLIN};
    require(poll(&ready, 1, 2000) > 0, "fixture readiness deadline");
    unsigned char policyValid = 0;
    require(read(pipeFDs[0], &policyValid, 1) == 1 && policyValid == 1,
        "SIGTERM default and unblocked; unrelated mask preserved");
    close(pipeFDs[0]);
    return pid;
}
int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "--fixture") == 0) {
        sigset_t mask;
        struct sigaction action;
        unsigned char valid = pthread_sigmask(SIG_SETMASK, NULL, &mask) == 0
            && sigaction(SIGTERM, NULL, &action) == 0
            && action.sa_handler == SIG_DFL
            && sigismember(&mask, SIGTERM) == 0
            && sigismember(&mask, SIGUSR1) == 1;
        if (strcmp(argv[3], "ignore") == 0) {
            struct sigaction ignored = {.sa_handler = SIG_IGN};
            sigemptyset(&ignored.sa_mask);
            if (sigaction(SIGTERM, &ignored, NULL) != 0) { valid = 0; }
        }
        (void)write(atoi(argv[2]), &valid, 1);
        close(atoi(argv[2]));
        if (!valid) { return 1; }
        for (;;) { pause(); }
    }
    pid_t pid = fixture(argv[0], 0);
    pthread_t reaper;
    require(pthread_create(&reaper, NULL, reap, &pid) == 0, "fixture reaper");
    require(CloudCodeStopBackgroundAssertionWorker(pid) == 0, "stop confirms real exit");
    void *result = NULL;
    require(pthread_join(reaper, &result) == 0, "join stopped fixture");
    int status = (int)(intptr_t)result;
    require(WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM, "normalized worker terminates by SIGTERM");
    require(kill(pid, 0) != 0 && errno == ESRCH, "success cannot leave an alive PID");
    require(CloudCodeStopBackgroundAssertionWorker(pid) == 0, "already exited stop is idempotent");
    pid = fixture(argv[0], 1);
    require(pthread_create(&reaper, NULL, reap, &pid) == 0, "unresponsive fixture reaper");
    require(CloudCodeStopBackgroundAssertionWorker(pid) == 78, "accepted SIGTERM without exit stays pending");
    require(kill(pid, 0) == 0, "pending fixture still alive");
    require(kill(pid, SIGKILL) == 0, "clean up owned test fixture");
    require(pthread_join(reaper, &result) == 0, "reap owned test fixture");
    require(CloudCodeStopBackgroundAssertionWorker(1) == 10, "invalid PID fails closed");
    puts("PASS: background assertion signal inheritance and confirmed teardown");
    return 0;
}
