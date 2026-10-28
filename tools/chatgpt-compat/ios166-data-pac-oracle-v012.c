#include <stdint.h>
#include <ptrauth.h>

// Research-only device oracle. This function DOES NOT dereference a pointer
// authenticated with an intentionally wrong discriminator. Authentication
// failure is reported by pointer mismatch, never treated as a safe pointer.
// Only an arm64e process with data-PAC actually enabled can prove rejection.
#if !__has_feature(ptrauth_calls)
#error "arm64e ptrauth_calls target required; cannot run as an arm64 mock"
#endif

typedef struct {
    uint32_t correct_auth_matches_raw;
    uint32_t wrong_discriminator_rejected;
    uint32_t signing_changed_raw;
    uint32_t reserved;
} IpaDataPacResultV012;

static volatile uint64_t research_value = 0x1662026u;

__attribute__((visibility("default"), noinline))
int ipa_ios166_data_pac_oracle_v012(IpaDataPacResultV012 *result) {
    if (!result) { return -1; }

    // Never expose raw addresses or PAC material in the report.
    void *raw = (void *)(uintptr_t)&research_value;
    void *signed_pointer = ptrauth_sign_unauthenticated(
        raw, ptrauth_key_asda, 0xe909);
    void *correct = ptrauth_auth_data(
        signed_pointer, ptrauth_key_asda, 0xe909);
    void *wrong = ptrauth_auth_data(
        signed_pointer, ptrauth_key_asda, 0xbdd1);

    result->correct_auth_matches_raw = correct == raw;
    result->wrong_discriminator_rejected = wrong != raw;
    result->signing_changed_raw = signed_pointer != raw;
    result->reserved = 0;
    // Return success ONLY if all 3 live hardware observations hold.
    return (result->correct_auth_matches_raw &&
            result->wrong_discriminator_rejected &&
            result->signing_changed_raw) ? 0 : 97;
}
