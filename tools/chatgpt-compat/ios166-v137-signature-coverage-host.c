// Exercise the actual diagnostic serializer with synthetic observations only.
// No device, fcntl, mmap, remap, csops, or file inspection is invoked here.
#define main v121_unused_entry
#include "ios166-v121-map-diagnostic.c"
#undef main

static void emit(bool observed, int64_t end, int registration_return) {
    struct macho_info info = {0};
    info.cryptoff = 4096;
    info.cryptsize = 4096;
    info.signature_offset = 12288;
    info.signature_size = 256;
    struct diagnostic result = {0};
    result.status = "synthetic_not_device";
    result.reason = "serializer_only_no_syscalls";
    result.signature_attempted = true;
    result.signature_return = registration_return;
    result.signature_errno = registration_return == 0 ? 0 : EINVAL;
    result.signature_coverage_observed = observed;
    result.signature_coverage_end = end;
    print_page_result(MODE_SIGNED_PAGE, &info, &result);
}

int main(void) {
    emit(false, 0, 0);      // Success return without a recorded output is unknown.
    emit(true, 12288, 0);   // Exact end reaches both boundaries.
    emit(true, 12287, 0);   // Ciphertext covered, signature offset not reached.
    emit(true, 8191, 0);    // Ciphertext interval not fully covered.
    emit(true, -1, 0);      // Invalid returned signed offset cannot pass.
    emit(false, 0, -1);     // Failed registration provides no coverage.
    return 0;
}
