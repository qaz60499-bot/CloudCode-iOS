/*
 * Bounded, semantics-preserving Darwin helpers for compiling the upstream
 * Swift Observation module targeting iOS 16.6. Prototype only.
 *
 * Reimplements upstream Swift runtime's observation locking and thread-local
 * helpers with real POSIX mutex/TLS behavior; no no-op functions.
 * Never inject into the production ChatGPT application.
 *
 * ABI validation still requires exported-symbol, Swift runtime and device
 * conformance tests. This is not an Apple-signed runtime replacement.
 */
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#if !defined(__aarch64__) && !defined(__arm64__)
#error "An arm64 Apple platform target is required"
#endif
#if !__has_attribute(swiftcall)
#error "swiftcall calling convention is required"
#endif
#define SWIFT_CC __attribute__((swiftcall))
#define HIDDEN __attribute__((visibility("hidden")))

HIDDEN SWIFT_CC size_t _swift_observation_lock_size(void) {
    return sizeof(pthread_mutex_t);
}
HIDDEN SWIFT_CC void _swift_observation_lock_init(void *raw) {
    if (!raw || pthread_mutex_init((pthread_mutex_t *)raw, NULL) != 0)
        __builtin_trap();
}
HIDDEN SWIFT_CC void _swift_observation_lock_lock(void *raw) {
    if (!raw || pthread_mutex_lock((pthread_mutex_t *)raw) != 0)
        __builtin_trap();
}
HIDDEN SWIFT_CC void _swift_observation_lock_unlock(void *raw) {
    if (!raw || pthread_mutex_unlock((pthread_mutex_t *)raw) != 0)
        __builtin_trap();
}
static pthread_key_t tls_key;
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;
static void tls_initialize(void) {
    if (pthread_key_create(&tls_key, NULL) != 0) __builtin_trap();
}
HIDDEN SWIFT_CC void *_swift_observation_tls_get(void) {
    if (pthread_once(&tls_once, tls_initialize) != 0) __builtin_trap();
    return pthread_getspecific(tls_key);
}
HIDDEN SWIFT_CC void _swift_observation_tls_set(void *ptr) {
    if (pthread_once(&tls_once, tls_initialize) != 0) __builtin_trap();
    if (pthread_setspecific(tls_key, ptr) != 0) __builtin_trap();
}
