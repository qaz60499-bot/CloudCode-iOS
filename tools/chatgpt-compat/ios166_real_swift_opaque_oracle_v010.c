/* IPA Total v010: Swift compiler-generated opaque-type descriptor oracle.
 * Only a valid exported descriptor created by Swift is used; no forged
 * metadata pointers, no iOS device execution or PAC-data-auth claims.
 */
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define SWIFT_CC __attribute__((swiftcall))
typedef struct { const void *value; uintptr_t state; } MetadataResponseCompat;
extern SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata(
    uintptr_t, const void *const *, const void *, unsigned);
extern SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata2(
    uintptr_t, const void *const *, const void *, unsigned);
extern SWIFT_CC const void *swift_getOpaqueTypeConformance(
    const void *const *, const void *, unsigned);
extern SWIFT_CC const void *swift_getOpaqueTypeConformance2(
    const void *const *, const void *, unsigned);

int main(void) {
    const char *path = getenv("IPA_OPAQUE_LIBRARY");
    const char *symbol = getenv("IPA_OPAQUE_DESCRIPTOR_SYMBOL");
    if (!path || !symbol || symbol[0] != '$') {
        fputs("OPAQUE_TEST_INPUT_UNVERIFIED\n", stderr);
        return 2;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "OPAQUE_LIBRARY_LOAD_ERROR %s\n", dlerror());
        return 3;
    }
    const void *descriptor = dlsym(handle, symbol);
    if (!descriptor) {
        fprintf(stderr, "OPAQUE_DESCRIPTOR_SYMBOL_MISSING %s\n", dlerror());
        return 4;
    }
    /* Request MetadataState::Complete = 0. Descriptor is an actual Swift
     * compiler emitted non-generic opaque return descriptor. */
    MetadataResponseCompat expected = swift_getOpaqueTypeMetadata(0, NULL, descriptor, 0);
    MetadataResponseCompat adapted = swift_getOpaqueTypeMetadata2(0, NULL, descriptor, 0);
    if (!expected.value || adapted.value != expected.value || adapted.state != expected.state) {
        fprintf(stderr, "OPAQUE_METADATA_ABI_MISMATCH expected=%p/%zu adapted=%p/%zu\n",
                expected.value, (size_t)expected.state, adapted.value, (size_t)adapted.state);
        return 5;
    }
    puts("REAL_SWIFT_RUNTIME_OPAQUE_METADATA_PASS");
    const void *witness = swift_getOpaqueTypeConformance(NULL, descriptor, 0);
    const void *adaptedWitness = swift_getOpaqueTypeConformance2(NULL, descriptor, 0);
    if (!witness || adaptedWitness != witness) {
        fprintf(stderr, "OPAQUE_WITNESS_ABI_MISMATCH old=%p new=%p\n", witness, adaptedWitness);
        return 6;
    }
    puts("REAL_SWIFT_RUNTIME_OPAQUE_CONFORMANCE_PASS");
    puts("REAL_SWIFT_RUNTIME_FIVE_SHIM_ENTRIES_EXERCISED_ACROSS_V008_V009_V010");
    puts("DATA_PAC_DESCRIPTOR_SIGNING_NOT_VERIFIED");
    puts("IOS16_DEVICE_RUNTIME_NOT_TESTED");
    dlclose(handle);
    return 0;
}
