/* IPA Total v008. Real Swift Runtime oracle for NULL-context mangled types.
 * This is NOT an iOS test, not a signed-descriptor PAC test, and not an
 * arbitrary metadata/witness pointer experiment. Compile alongside PAC shim.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#if !__has_attribute(swiftcall)
#error "Swift calling convention is required"
#endif
#define SWIFT_CC __attribute__((swiftcall))

extern SWIFT_CC const void *swift_getTypeByMangledNameInContext(
    const char *, size_t, const void *, const void *const *);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContext2(
    const char *, size_t, const void *, const void *const *);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState(
    uintptr_t, const char *, size_t, const void *, const void *const *);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState2(
    uintptr_t, const char *, size_t, const void *, const void *const *);

static int check(const char *mangled, size_t length) {
    /* No PAC descriptor: only test the real Swift Runtime path on builtins. */
    const void *a = swift_getTypeByMangledNameInContext(mangled, length, NULL, NULL);
    const void *b = swift_getTypeByMangledNameInContext2(mangled, length, NULL, NULL);
    const void *c = swift_getTypeByMangledNameInContextInMetadataState(
        0, mangled, length, NULL, NULL);
    const void *d = swift_getTypeByMangledNameInContextInMetadataState2(
        0, mangled, length, NULL, NULL);
    if (!a || b != a || c != a || d != a) {
        fprintf(stderr, "REAL_SWIFT_RUNTIME_METADATA_MISMATCH type=%.*s a=%p b=%p c=%p d=%p\n",
                (int)length, mangled, a, b, c, d);
        return 1;
    }
    printf("REAL_SWIFT_RUNTIME_METADATA_EQUAL type=%.*s\n", (int)length, mangled);
    return 0;
}
int main(void) {
    int rc = 0;
    rc |= check("Si", 2);  /* Swift.Int */
    rc |= check("Sb", 2);  /* Swift.Bool */
    rc |= check("SS", 2);  /* Swift.String */
    if (rc) return 1;
    puts("REAL_SWIFT_RUNTIME_MANGLED_TYPE_FORWARDING_PASS_NULL_CONTEXT_ONLY");
    puts("PAC_SIGNED_DESCRIPTOR_AUTHENTICATION_NOT_TESTED");
    puts("IOS16_SWIFT_RUNTIME_NOT_TESTED");
    return 0;
}
