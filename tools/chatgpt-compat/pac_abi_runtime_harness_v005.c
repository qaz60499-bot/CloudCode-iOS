/*
 * Research-only PAC signed-descriptor ABI harness. Compiles and runs on a
 * disposable macOS arm64 runner; NOT an iPhone executable or Swift-runtime test.
 * Mocks the old Swift runtime delegates so fake descriptors are NEVER read.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__aarch64__) && !defined(__arm64__)
#error "PAC integration oracle requires arm64"
#endif
#if !__has_attribute(swiftcall)
#error "swiftcall compiler support required"
#endif

#define SWIFT_CC __attribute__((swiftcall))
enum { DISC_PROTOCOL = 0xe909, DISC_OPAQUE = 0xbdd1, DISC_CONTEXT = 0xb5e3 };
typedef struct {
    const void *value;
    uintptr_t state;
} MetadataResponseCompat;

extern const void *swift_conformsToProtocol2(const void *, const void *);
extern SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata2(
    uintptr_t, const void *const *, const void *, unsigned);
extern SWIFT_CC const void *swift_getOpaqueTypeConformance2(
    const void *const *, const void *, unsigned);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContext2(
    const char *, size_t, const void *, const void *const *);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState2(
    uintptr_t, const char *, size_t, const void *, const void *const *);

static const char descriptor_protocol = 0x31;
static const char descriptor_opaque = 0x32;
static const char descriptor_context = 0x33;
static const char dummy_metadata = 0x34;
static const char return_marker = 0x35;
static const char type_name[] = "Sb";
static const void *arguments[] = { &dummy_metadata, NULL };
static int calls = 0;
static int errors = 0;

#define CHECK(ok) do { if (!(ok)) { ++errors; \
    fprintf(stderr, "HARNESS_ASSERT_FAILED line=%d\n", __LINE__); } } while (0)

static const void *sign_data(const void *value, uintptr_t discriminator) {
    uintptr_t signed_value = (uintptr_t)value;
    __asm__ volatile("pacda %x0, %x1" : "+r"(signed_value) : "r"(discriminator));
    return (const void *)signed_value;
}

/* Four mock delegates use the same externally declared calling conventions. */
const void *swift_conformsToProtocol(const void *type, const void *protocol) {
    calls++;
    CHECK(type == &dummy_metadata);
    CHECK(protocol == &descriptor_protocol);
    return &return_marker;
}
SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata(
    uintptr_t request, const void *const *args, const void *descriptor,
    unsigned index) {
    calls++;
    CHECK(request == 0x5cU);
    CHECK(args == arguments);
    CHECK(descriptor == &descriptor_opaque);
    CHECK(index == 0x12345678U);
    MetadataResponseCompat r = { &return_marker, (uintptr_t)0x66 };
    return r;
}
SWIFT_CC const void *swift_getOpaqueTypeConformance(
    const void *const *args, const void *descriptor, unsigned index) {
    calls++;
    CHECK(args == arguments);
    CHECK(descriptor == &descriptor_opaque);
    CHECK(index == 0x12345678U);
    return &return_marker;
}
SWIFT_CC const void *swift_getTypeByMangledNameInContext(
    const char *name, size_t len, const void *ctx, const void *const *args) {
    calls++;
    CHECK(name == type_name);
    CHECK(len == 2);
    CHECK(ctx == &descriptor_context);
    CHECK(args == arguments);
    return &return_marker;
}
SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState(
    uintptr_t state, const char *name, size_t len,
    const void *ctx, const void *const *args) {
    calls++;
    CHECK(state == 0x7f);
    CHECK(name == type_name);
    CHECK(len == 2);
    CHECK(ctx == &descriptor_context);
    CHECK(args == arguments);
    return &return_marker;
}

static int positive_tests(void) {
    const void *p = sign_data(&descriptor_protocol, DISC_PROTOCOL);
    const void *o = sign_data(&descriptor_opaque, DISC_OPAQUE);
    const void *c = sign_data(&descriptor_context, DISC_CONTEXT);
    CHECK(p != NULL && o != NULL && c != NULL);
    CHECK(swift_conformsToProtocol2(&dummy_metadata, p) == &return_marker);
    MetadataResponseCompat r = swift_getOpaqueTypeMetadata2(
        0x5cU, arguments, o, 0x12345678U);
    CHECK(r.value == &return_marker && r.state == 0x66);
    CHECK(swift_getOpaqueTypeConformance2(
        arguments, o, 0x12345678U) == &return_marker);
    CHECK(swift_getTypeByMangledNameInContext2(
        type_name, 2, c, arguments) == &return_marker);
    CHECK(swift_getTypeByMangledNameInContextInMetadataState2(
        0x7f, type_name, 2, c, arguments) == &return_marker);
    CHECK(calls == 5);
    return errors ? 1 : 0;
}
static int negative_tests(void) {
    pid_t child = fork();
    if (child < 0) {
        puts("PAC_NEGATIVE_FORK_UNAVAILABLE");
        return 2;
    }
    if (child == 0) {
        /* Sign a REAL process-local address with deliberately WRONG
         * discriminator. NEVER pass this to a real Swift runtime delegate.
         * The shim must trap in auth_data_descriptor before calling the stub.
         */
        const void *bad = sign_data(&descriptor_protocol, DISC_OPAQUE);
        (void)swift_conformsToProtocol2(&dummy_metadata, bad);
        _exit(97); /* incorrect acceptance */
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child) return 2;
    if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        if (sig == SIGTRAP || sig == SIGILL) {
            puts("PAC_WRONG_DISCRIMINATOR_REJECTED_IN_FORK_PASS");
            return 0;
        }
        fprintf(stderr, "PAC_NEGATIVE_WRONG_SIGNAL=%d\n", sig);
        return 3;
    }
    fprintf(stderr, "PAC_NEGATIVE_NOT_REJECTED exit=%d\n",
            WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    return 4;
}
int main(void) {
    if (positive_tests() != 0) return 1;
    puts("PAC_FIVE_NON_NULL_SIGNED_POINTER_FORWARDING_PASS");
    puts("PAC_SWIFTCALL_C_HARNESS_METADATA_RESPONSE_PASS");
    /* A test of mocked runtime ABI forwarding, NOT a Swift runtime call. */
    int negative = negative_tests();
    if (negative != 0) return negative;
    puts("PAC_RUNTIME_MOCK_DELEGATE_TESTS_PASS_NOT_REAL_SWIFT_RUNTIME");
    return 0;
}
