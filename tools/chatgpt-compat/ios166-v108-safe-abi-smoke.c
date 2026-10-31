/*
 * IPA Total V108: isolated, minimal Swift metadata bridge call verification.
 * Only resolves the public Swift.Int mangled type "Si" with null context.
 * CANNOT establish PAC-authentication semantics for non-null signed descriptors.
 * Safe failure is observable, and no credentials, app containers or network touched.
 */
#include <stddef.h>
#include <stdint.h>
#if !defined(__aarch64__) && !defined(__arm64__)
#error "iOS arm64 required"
#endif
#if !__has_attribute(swiftcall)
#error "Apple Clang swiftcall required"
#endif
#define SWIFT_CC __attribute__((swiftcall))
extern SWIFT_CC const void *swift_getTypeByMangledNameInContext2(
    const char *, size_t, const void *, const void *const *);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContext(
    const char *, size_t, const void *, const void *const *);
__attribute__((visibility("default")))
int32_t ipa_v108_safe_metadata_lookup(void) {
    const char swift_int[] = {'S', 'i'};
    const void *original = swift_getTypeByMangledNameInContext(
        swift_int, 2, NULL, NULL);
    if (original == NULL) return -1;
    const void *adapted = swift_getTypeByMangledNameInContext2(
        swift_int, 2, NULL, NULL);
    if (adapted == NULL) return -2;
    if (adapted != original) return -3;
    return 1;
}