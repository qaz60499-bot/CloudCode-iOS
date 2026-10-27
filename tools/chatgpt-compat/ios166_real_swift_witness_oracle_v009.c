/* IPA Total v009: actual Swift Runtime witness-table oracle on macOS arm64.
 * Uses a compiler-emitted PUBLIC protocol descriptor loaded with dlopen.
 * No synthesized/invalid pointer, no device, no claim of PAC authentication.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern const void *swift_getTypeByMangledNameInContext(
    const char *, size_t, const void *, const void *const *) __attribute__((swiftcall));
extern const void *swift_conformsToProtocol(const void *, const void *);
extern const void *swift_conformsToProtocol2(const void *, const void *);

int main(void) {
    const char *path = getenv("IPA_WITNESS_LIBRARY");
    const char *symbol = getenv("IPA_WITNESS_PROTOCOL_SYMBOL");
    if (!path || !symbol || symbol[0] != '$') {
        fputs("MISSING_VERIFIED_SWIFT_PROTOCOL_DESCRIPTOR_ENV\n", stderr);
        return 2;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "SWIFT_PROTOCOL_LIBRARY_LOAD_FAILED %s\n", dlerror());
        return 3;
    }
    const void *protocol = dlsym(handle, symbol);
    if (!protocol) {
        fprintf(stderr, "SWIFT_PROTOCOL_DESCRIPTOR_NOT_EXPORTED %s\n", dlerror());
        return 4;
    }
    const void *int_metadata = swift_getTypeByMangledNameInContext("Si", 2, NULL, NULL);
    const void *bool_metadata = swift_getTypeByMangledNameInContext("Sb", 2, NULL, NULL);
    if (!int_metadata || !bool_metadata) {
        fputs("RUNTIME_BUILTIN_METADATA_NOT_FOUND\n", stderr);
        return 5;
    }
    const void *direct = swift_conformsToProtocol(int_metadata, protocol);
    const void *adapted = swift_conformsToProtocol2(int_metadata, protocol);
    if (!direct || adapted != direct) {
        fprintf(stderr, "WITNESS_POSITIVE_MISMATCH direct=%p adapted=%p\n", direct, adapted);
        return 6;
    }
    puts("REAL_SWIFT_RUNTIME_WITNESS_POSITIVE_PASS");
    const void *missing_direct = swift_conformsToProtocol(bool_metadata, protocol);
    const void *missing_adapter = swift_conformsToProtocol2(bool_metadata, protocol);
    if (missing_direct || missing_adapter) {
        fprintf(stderr, "WITNESS_NEGATIVE_MISMATCH direct=%p adapted=%p\n",
                missing_direct, missing_adapter);
        return 7;
    }
    puts("REAL_SWIFT_RUNTIME_WITNESS_NEGATIVE_PASS");
    puts("REAL_SWIFT_RUNTIME_PROTOCOL_FORWARDING_PASS_UNSIGNED_MACOS_ARM64");
    puts("DATA_PAC_DESCRIPTOR_SIGNING_NOT_VERIFIED");
    puts("IOS16_DEVICE_RUNTIME_NOT_TESTED");
    dlclose(handle);
    return 0;
}
