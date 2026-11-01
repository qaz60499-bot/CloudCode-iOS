// iOS 16.6 bounded, standalone FairPlay mapping precondition diagnostic.
// This program never writes the input file or exports mapped bytes.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_INPUT_SIZE (2u * 1024u * 1024u)
#define MAX_LOAD_COMMANDS_SIZE (256u * 1024u)
#define MAX_LOAD_COMMAND_COUNT 4096u
#define READ_BYTES 4096u
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u

typedef int (*fp_remap_fn)(void *, size_t, uint32_t, uint32_t, uint32_t);
typedef int (*csops_fn)(pid_t, uint32_t, void *, size_t);

enum run_mode {
    MODE_INVALID = 0,
    MODE_INSPECT,
    MODE_SIGNED_PAGE,
    MODE_UNSIGNED_PAGE
};

struct macho_info {
    struct mach_header_64 header;
    uint64_t file_size;
    uint64_t commands_end;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint32_t cryptid;
    uint32_t signature_offset;
    uint32_t signature_size;
    uint32_t encryption_command_count;
    uint32_t signature_command_count;
};

struct diagnostic {
    const char *status;
    const char *reason;
    uint32_t page_size;
    bool signature_attempted;
    int signature_return;
    int signature_errno;
    bool signature_input_valid;
    int64_t signature_input_file_start;
    uint64_t signature_input_blob_start;
    uint64_t signature_input_blob_size;
    bool signature_coverage_observed;
    int64_t signature_coverage_end;
    bool mmap_attempted;
    int mmap_errno;
    bool remap_attempted;
    int remap_return;
    int remap_errno;
    bool read_attempted;
    bool read_values_valid;
    kern_return_t read_kr;
    vm_size_t received;
    size_t changed_count;
};

static bool pread_exact(int fd, void *buffer, size_t length, off_t offset) {
    uint8_t *cursor = (uint8_t *)buffer;
    while (length != 0) {
        ssize_t count = pread(fd, cursor, length, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        cursor += (size_t)count;
        length -= (size_t)count;
        offset += (off_t)count;
    }
    return true;
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static bool ranges_overlap(uint64_t a_start, uint64_t a_size,
                           uint64_t b_start, uint64_t b_size) {
    uint64_t a_end = a_start + a_size;
    uint64_t b_end = b_start + b_size;
    return a_start < b_end && b_start < a_end;
}

static bool validate_embedded_signature(int fd, uint32_t offset, uint32_t size,
                                        uint64_t file_size) {
    if (size < 12 || (uint64_t)offset + (uint64_t)size > file_size) return false;

    uint8_t *blob = (uint8_t *)malloc(size);
    if (blob == NULL) return false;
    bool valid = false;
    if (!pread_exact(fd, blob, size, (off_t)offset)) goto done;

    uint32_t magic = read_be32(blob);
    uint32_t length = read_be32(blob + 4);
    uint32_t count = read_be32(blob + 8);
    if (magic != CSMAGIC_EMBEDDED_SIGNATURE || length < 12 || length > size) goto done;

    uint64_t index_end = 12u + (uint64_t)count * 8u;
    if (index_end > length) goto done;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t blob_offset = read_be32(blob + 12u + (size_t)i * 8u + 4u);
        if ((uint64_t)blob_offset < index_end || (uint64_t)blob_offset + 8u > length) goto done;
        uint32_t blob_length = read_be32(blob + blob_offset + 4u);
        if (blob_length < 8 || (uint64_t)blob_offset + blob_length > length) goto done;
    }
    valid = true;

done:
    free(blob);
    return valid;
}

static bool parse_and_validate(int fd, struct stat *file_stat,
                               struct macho_info *info, const char **reason) {
    memset(info, 0, sizeof(*info));
    if (!S_ISREG(file_stat->st_mode)) {
        *reason = "input_not_regular_file";
        return false;
    }
    if (file_stat->st_size <= 0 || (uint64_t)file_stat->st_size > MAX_INPUT_SIZE) {
        *reason = "input_size_out_of_bounds";
        return false;
    }
    info->file_size = (uint64_t)file_stat->st_size;
    if (info->file_size < sizeof(info->header)
        || !pread_exact(fd, &info->header, sizeof(info->header), 0)) {
        *reason = "short_or_unreadable_macho_header";
        return false;
    }
    if (info->header.magic != MH_MAGIC_64) {
        *reason = "not_thin_little_endian_64_bit_macho";
        return false;
    }
    if (info->header.cputype != CPU_TYPE_ARM64) {
        *reason = "not_arm64";
        return false;
    }
    if (info->header.filetype != MH_EXECUTE) {
        *reason = "not_main_executable";
        return false;
    }
    if (info->header.ncmds == 0
        || info->header.sizeofcmds < sizeof(struct load_command)
        || (uint64_t)sizeof(info->header) + info->header.sizeofcmds > info->file_size
        || info->header.ncmds > info->header.sizeofcmds / sizeof(struct load_command)) {
        *reason = "load_command_region_out_of_bounds";
        return false;
    }
    if (info->header.ncmds > MAX_LOAD_COMMAND_COUNT
        || info->header.sizeofcmds > MAX_LOAD_COMMANDS_SIZE) {
        *reason = "load_command_region_too_large";
        return false;
    }

    size_t commands_size = (size_t)info->header.sizeofcmds;
    uint8_t *commands = (uint8_t *)malloc(commands_size);
    if (commands == NULL) {
        *reason = "load_command_allocation_failed";
        return false;
    }
    if (!pread_exact(fd, commands, commands_size, (off_t)sizeof(info->header))) {
        free(commands);
        *reason = "short_or_unreadable_load_commands";
        return false;
    }

    bool commands_valid = true;
    uint32_t position = 0;
    for (uint32_t i = 0; i < info->header.ncmds; ++i) {
        if ((uint64_t)position + sizeof(struct load_command) > commands_size) {
            commands_valid = false;
            break;
        }
        const struct load_command *command =
            (const struct load_command *)(const void *)(commands + position);
        if (command->cmdsize < sizeof(struct load_command)
            || (command->cmdsize & 7u) != 0
            || (uint64_t)position + command->cmdsize > commands_size) {
            commands_valid = false;
            break;
        }

        if (command->cmd == LC_ENCRYPTION_INFO_64 || command->cmd == LC_ENCRYPTION_INFO) {
            ++info->encryption_command_count;
            if (info->encryption_command_count > 1) {
                commands_valid = false;
                *reason = "duplicate_encryption_command";
                break;
            }
            size_t required_size = command->cmd == LC_ENCRYPTION_INFO_64
                ? sizeof(struct encryption_info_command_64)
                : sizeof(struct encryption_info_command);
            if (command->cmdsize < required_size) {
                commands_valid = false;
                *reason = "short_encryption_command";
                break;
            }
            const struct encryption_info_command *encryption =
                (const struct encryption_info_command *)(const void *)command;
            info->cryptoff = encryption->cryptoff;
            info->cryptsize = encryption->cryptsize;
            info->cryptid = encryption->cryptid;
        } else if (command->cmd == LC_CODE_SIGNATURE) {
            ++info->signature_command_count;
            if (info->signature_command_count > 1) {
                commands_valid = false;
                *reason = "duplicate_code_signature_command";
                break;
            }
            if (command->cmdsize < sizeof(struct linkedit_data_command)) {
                commands_valid = false;
                *reason = "short_code_signature_command";
                break;
            }
            const struct linkedit_data_command *signature =
                (const struct linkedit_data_command *)(const void *)command;
            info->signature_offset = signature->dataoff;
            info->signature_size = signature->datasize;
        }
        position += command->cmdsize;
    }
    if (commands_valid && position != commands_size) commands_valid = false;
    free(commands);
    if (!commands_valid) {
        if (*reason == NULL) *reason = "malformed_load_command_region";
        return false;
    }
    info->commands_end = sizeof(info->header) + (uint64_t)info->header.sizeofcmds;

    if (info->encryption_command_count != 1) {
        *reason = "single_encryption_command_required";
        return false;
    }
    if (info->cryptid != 1 || info->cryptsize == 0) {
        *reason = "cryptid1_nonempty_range_required";
        return false;
    }
    uint64_t crypt_end = (uint64_t)info->cryptoff + (uint64_t)info->cryptsize;
    if (info->cryptoff < info->commands_end || crypt_end > info->file_size) {
        *reason = "encrypted_range_out_of_bounds";
        return false;
    }
    if (info->signature_command_count != 1) {
        *reason = "single_code_signature_command_required";
        return false;
    }
    uint64_t signature_end = (uint64_t)info->signature_offset + (uint64_t)info->signature_size;
    if (info->signature_size == 0 || info->signature_offset < info->commands_end
        || signature_end > info->file_size
        || ranges_overlap(info->cryptoff, info->cryptsize,
                          info->signature_offset, info->signature_size)) {
        *reason = "code_signature_range_out_of_bounds";
        return false;
    }
    if (!validate_embedded_signature(fd, info->signature_offset,
                                     info->signature_size, info->file_size)) {
        *reason = "incomplete_embedded_code_signature";
        return false;
    }
    return true;
}

static enum run_mode parse_mode(const char *text) {
    if (strcmp(text, "--inspect") == 0) return MODE_INSPECT;
    if (strcmp(text, "--signed-page") == 0) return MODE_SIGNED_PAGE;
    if (strcmp(text, "--unsigned-page") == 0) return MODE_UNSIGNED_PAGE;
    return MODE_INVALID;
}

static int fp_remap(void *address, size_t size, uint32_t cryptid,
                    uint32_t cputype, uint32_t cpusubtype) {
    fp_remap_fn function = (fp_remap_fn)dlsym(RTLD_DEFAULT, "mremap_encrypted");
    if (function != NULL) return function(address, size, cryptid, cputype, cpusubtype);
#if defined(__arm64__)
    // SYS_mremap_encrypted = 489. Keep the fallback identical to the V118 probe.
    register uint64_t x0 __asm__("x0") = (uint64_t)(uintptr_t)address;
    register uint64_t x1 __asm__("x1") = (uint64_t)size;
    register uint64_t x2 __asm__("x2") = (uint64_t)cryptid;
    register uint64_t x3 __asm__("x3") = (uint64_t)cputype;
    register uint64_t x4 __asm__("x4") = (uint64_t)cpusubtype;
    register uint64_t x16 __asm__("x16") = 489;
    uint64_t failure = 1;
    __asm__ volatile("svc #0x80\n\tcset %[failure], cs"
                     : "+r"(x0), "+r"(x1), [failure]"=r"(failure)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    if (failure) {
        errno = (int)x0;
        return -1;
    }
    return (int)x0;
#else
    (void)address;
    (void)size;
    (void)cryptid;
    (void)cputype;
    (void)cpusubtype;
    errno = ENOSYS;
    return -1;
#endif
}

static void inspect_self_csops(bool *available, int *result, int *error_number,
                               bool *flags_valid, uint32_t *flags) {
    csops_fn function = (csops_fn)dlsym(RTLD_DEFAULT, "csops");
    *available = function != NULL;
    *result = 0;
    *error_number = 0;
    *flags_valid = false;
    *flags = 0;
    if (function == NULL) return;

    errno = 0;
    int call_result = function(getpid(), 0, flags, sizeof(*flags));
    *result = call_result;
    *error_number = errno;
    *flags_valid = call_result == 0;
}

static void print_header(const struct macho_info *info) {
    printf("\"header\":{\"magic\":\"MH_MAGIC_64\",\"cputype\":%d,"
           "\"cpusubtype\":%d,\"filetype\":%u,\"ncmds\":%u,"
           "\"sizeofcmds\":%u,\"flags\":%u,\"reserved\":%u}",
           info->header.cputype, info->header.cpusubtype,
           info->header.filetype, info->header.ncmds,
           info->header.sizeofcmds, info->header.flags, info->header.reserved);
}

static void print_inspect_result(const struct macho_info *info, uint32_t page_size,
                                 bool csops_available, int csops_result,
                                 int csops_errno, bool csops_flags_valid,
                                 uint32_t csops_flags) {
    printf("{\"schema\":\"ios166-v121-map-diagnostic/2\","
           "\"scope\":\"precondition_only_not_decryption_or_official_compatibility\","
           "\"mode\":\"inspect\",\"status\":\"eligible\",");
    print_header(info);
    printf(",\"page_size\":%u,\"csops_available\":%s,\"csops_return\":",
           page_size, csops_available ? "true" : "false");
    if (csops_available) printf("%d", csops_result);
    else printf("null");
    printf(",\"csops_errno\":");
    if (csops_available) printf("%d", csops_errno);
    else printf("null");
    printf(",\"csops_flags_valid\":%s,\"csops_flags\":",
           csops_flags_valid ? "true" : "false");
    if (csops_flags_valid) printf("%u", csops_flags);
    else printf("null");
    puts("}");
}

static void print_page_result(enum run_mode mode, const struct macho_info *info,
                              const struct diagnostic *result) {
    const char *mode_name = mode == MODE_SIGNED_PAGE ? "signed-page" : "unsigned-page";
    uint64_t encrypted_end = (uint64_t)info->cryptoff + (uint64_t)info->cryptsize;
    bool coverage_reaches_signature = result->signature_coverage_observed
        && result->signature_coverage_end >= 0
        && (uint64_t)result->signature_coverage_end >= info->signature_offset;
    bool coverage_covers_encrypted = result->signature_coverage_observed
        && result->signature_coverage_end >= 0
        && (uint64_t)result->signature_coverage_end >= encrypted_end;
    printf("{\"schema\":\"ios166-v121-map-diagnostic/2\","
           "\"scope\":\"precondition_only_not_decryption_or_official_compatibility\","
           "\"mode\":\"%s\",\"status\":\"%s\",\"reason\":\"%s\","
           "\"span_semantics\":\"single_page_attempt_only_partial_span_semantics_unknown_failure_does_not_disprove_full_range_mapping\","
           "\"encrypted_range_offset\":%u,\"encrypted_range_size\":%u,\"encrypted_range_end\":%llu,"
           "\"code_signature_offset\":%u,\"code_signature_size\":%u,",
           mode_name, result->status, result->reason,
           info->cryptoff, info->cryptsize, (unsigned long long)encrypted_end,
           info->signature_offset, info->signature_size);
    print_header(info);
    printf(",\"page_size\":%u,\"signature_fcntl_attempted\":%s,"
           "\"signature_fcntl_return\":",
           result->page_size, result->signature_attempted ? "true" : "false");
    if (result->signature_attempted) printf("%d", result->signature_return);
    else printf("null");
    printf(",\"signature_fcntl_errno\":");
    if (result->signature_attempted) printf("%d", result->signature_errno);
    else printf("null");
    printf(",\"signature_registration_inputs\":");
    if (result->signature_input_valid) {
        printf("{\"fs_file_start\":%lld,\"fs_blob_start\":%llu,\"fs_blob_size\":%llu}",
               (long long)result->signature_input_file_start,
               (unsigned long long)result->signature_input_blob_start,
               (unsigned long long)result->signature_input_blob_size);
    } else {
        printf("null");
    }
    printf(",\"signature_coverage_end_offset\":");
    if (result->signature_coverage_observed) {
        printf("%lld", (long long)result->signature_coverage_end);
    } else {
        printf("null");
    }
    printf(",\"signature_coverage_reaches_code_signature_offset\":");
    if (result->signature_coverage_observed) printf("%s", coverage_reaches_signature ? "true" : "false");
    else printf("null");
    printf(",\"signature_coverage_covers_encrypted_interval\":");
    if (result->signature_coverage_observed) printf("%s", coverage_covers_encrypted ? "true" : "false");
    else printf("null");
    printf(",\"mmap_attempted\":%s,\"mmap_errno\":",
           result->mmap_attempted ? "true" : "false");
    if (result->mmap_attempted) printf("%d", result->mmap_errno);
    else printf("null");
    printf(",\"remap_attempted\":%s,\"remap_return\":",
           result->remap_attempted ? "true" : "false");
    if (result->remap_attempted) printf("%d", result->remap_return);
    else printf("null");
    printf(",\"remap_errno\":");
    if (result->remap_attempted) printf("%d", result->remap_errno);
    else printf("null");
    printf(",\"read_attempted\":%s,\"kr\":",
           result->read_attempted ? "true" : "false");
    if (result->read_values_valid) printf("%d", result->read_kr);
    else printf("null");
    printf(",\"received\":");
    if (result->read_values_valid) printf("%llu", (unsigned long long)result->received);
    else printf("null");
    printf(",\"changed_count\":");
    if (result->read_values_valid && result->received == READ_BYTES
        && result->read_kr == KERN_SUCCESS) {
        printf("%zu", result->changed_count);
    } else {
        printf("null");
    }
    puts("}");
}

static void print_rejection(enum run_mode mode, const char *reason) {
    const char *mode_name = mode == MODE_INSPECT ? "inspect"
        : mode == MODE_SIGNED_PAGE ? "signed-page"
        : mode == MODE_UNSIGNED_PAGE ? "unsigned-page" : "invalid";
    printf("{\"schema\":\"ios166-v121-map-diagnostic/2\","
           "\"scope\":\"precondition_only_not_decryption_or_official_compatibility\","
           "\"mode\":\"%s\",\"status\":\"rejected\",\"reason\":\"%s\"}\n",
           mode_name, reason);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        print_rejection(MODE_INVALID, "expected_exactly_one_mode_and_one_file");
        return 2;
    }
    enum run_mode mode = parse_mode(argv[1]);
    if (mode == MODE_INVALID) {
        print_rejection(MODE_INVALID, "unsupported_or_repeated_mode");
        return 2;
    }

    int fd = open(argv[2], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        print_rejection(mode, "open_failed");
        return 1;
    }

    struct stat file_stat;
    struct macho_info info;
    const char *reason = NULL;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        print_rejection(mode, "fstat_failed");
        return 1;
    }
    if (!parse_and_validate(fd, &file_stat, &info, &reason)) {
        close(fd);
        print_rejection(mode, reason != NULL ? reason : "input_validation_failed");
        return 1;
    }

    int raw_page_size = getpagesize();
    if (raw_page_size <= 0 || (uint64_t)raw_page_size > info.file_size) {
        close(fd);
        print_rejection(mode, "invalid_device_page_size");
        return 1;
    }
    uint32_t page_size = (uint32_t)raw_page_size;
    if (mode == MODE_INSPECT) {
        bool available, flags_valid;
        int csops_result, csops_errno;
        uint32_t flags;
        inspect_self_csops(&available, &csops_result, &csops_errno,
                           &flags_valid, &flags);
        close(fd);
        print_inspect_result(&info, page_size, available, csops_result,
                             csops_errno, flags_valid, flags);
        return 0;
    }

    struct diagnostic result;
    memset(&result, 0, sizeof(result));
    result.status = "stopped_before_remap";
    result.reason = "page_preconditions_not_met";
    result.page_size = page_size;
    if (page_size < READ_BYTES || info.cryptoff % page_size != 0
        || info.cryptsize < page_size
        || (uint64_t)info.cryptoff + page_size > info.file_size) {
        result.reason = "encrypted_range_not_page_aligned_or_too_short";
        print_page_result(mode, &info, &result);
        close(fd);
        return 1;
    }

    if (mode == MODE_SIGNED_PAGE) {
        fsignatures_t signature_registration;
        memset(&signature_registration, 0, sizeof(signature_registration));
        signature_registration.fs_file_start = 0;
        signature_registration.fs_blob_start = (void *)(uintptr_t)info.signature_offset;
        signature_registration.fs_blob_size = info.signature_size;
        result.signature_input_valid = true;
        result.signature_input_file_start = (int64_t)signature_registration.fs_file_start;
        result.signature_input_blob_start = (uint64_t)(uintptr_t)signature_registration.fs_blob_start;
        result.signature_input_blob_size = (uint64_t)signature_registration.fs_blob_size;
        errno = 0;
        result.signature_attempted = true;
        result.signature_return = fcntl(fd, F_ADDFILESIGS_RETURN, &signature_registration);
        result.signature_errno = errno;
        if (result.signature_return == -1) {
            result.status = "stopped_before_remap";
            result.reason = "signature_registration_failed";
            print_page_result(mode, &info, &result);
            close(fd);
            return 1;
        }
        result.signature_coverage_observed = true;
        result.signature_coverage_end = (int64_t)signature_registration.fs_file_start;
    }

    uint8_t baseline[READ_BYTES];
    if (!pread_exact(fd, baseline, sizeof(baseline), (off_t)info.cryptoff)) {
        result.status = "stopped_before_remap";
        result.reason = "baseline_pread_failed";
        print_page_result(mode, &info, &result);
        close(fd);
        return 1;
    }

    result.mmap_attempted = true;
    errno = 0;
    void *page = mmap(NULL, page_size, PROT_READ, MAP_PRIVATE, fd, (off_t)info.cryptoff);
    if (page == MAP_FAILED) {
        result.mmap_errno = errno;
        result.status = "stopped_before_remap";
        result.reason = "read_only_page_mmap_failed";
        print_page_result(mode, &info, &result);
        close(fd);
        return 1;
    }

    errno = 0;
    result.remap_attempted = true;
    result.remap_return = fp_remap(page, page_size, 2u,
                                   (uint32_t)info.header.cputype,
                                   (uint32_t)info.header.cpusubtype);
    result.remap_errno = errno;
    if (result.remap_return != 0) {
        result.status = "remap_failed";
        result.reason = "read_not_attempted_after_remap_failure";
    } else {
        uint8_t after[READ_BYTES];
        vm_size_t received = 0;
        result.read_attempted = true;
        result.read_kr = vm_read_overwrite(mach_task_self(),
                                           (vm_address_t)(uintptr_t)page,
                                           (vm_size_t)READ_BYTES,
                                           (vm_address_t)(uintptr_t)after,
                                           &received);
        result.read_values_valid = true;
        result.received = received;
        if (result.read_kr == KERN_SUCCESS && received == READ_BYTES) {
            for (size_t i = 0; i < READ_BYTES; ++i) {
                result.changed_count += baseline[i] != after[i];
            }
            result.status = "page_read_complete";
            result.reason = "bounded_mapping_precondition_observed";
        } else {
            result.status = "page_read_failed";
            result.reason = "vm_read_overwrite_did_not_return_full_4096_bytes";
        }
    }

    (void)munmap(page, page_size);
    print_page_result(mode, &info, &result);
    close(fd);
    return (result.remap_return == 0 && result.read_values_valid
            && result.read_kr == KERN_SUCCESS && result.received == READ_BYTES) ? 0 : 1;
}
