/*
 * IPA Total V109: device-local dyld shared-cache presence probe.
 *
 * Read-only, nonprivileged. No credential access, jailbreak service control,
 * process attachment, app launch/kill, network, filesystem writes, or hooks.
 * A missing framework FILE on disk is not a reliable absence test on iOS:
 * many system images are available exclusively through the dyld shared cache.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <objc/runtime.h>

struct Target {
    const char *category;
    const char *path;
    const char *symbol;
};
static const struct Target targets[] = {
    {"control/UIKit", "/System/Library/Frameworks/UIKit.framework/UIKit", "OBJC_CLASS_$_UIApplication"},
    {"control/AVFAudio", "/System/Library/Frameworks/AVFAudio.framework/AVFAudio", "OBJC_CLASS_$_AVAudioSession"},
    {"FinanceKit", "/System/Library/Frameworks/FinanceKit.framework/FinanceKit", "$s10FinanceKit0A5StoreC6sharedACvgZ"},
    {"MarketplaceKit", "/System/Library/Frameworks/MarketplaceKit.framework/MarketplaceKit", "$s14MarketplaceKit14AppDistributorO7currentACvgZ"},
    {"Symbols", "/System/Library/Frameworks/Symbols.framework/Symbols", "$s7Symbols19SymbolEffectOptionsV7defaultACvgZ"},
    {"Observation", "/usr/lib/swift/libswiftObservation.dylib", "$s11Observation0A9RegistrarVACycfC"},
    {"Synchronization", "/usr/lib/swift/libswiftSynchronization.dylib", "$s15Synchronization5MutexVMa"},
};

int main(int argc, char **argv) {
    if (argc != 1 || argv[0] == NULL) {
        fprintf(stderr, "usage: %s\n", argv[0] ? argv[0] : "IPA-V109-dyld-audit");
        return 2;
    }
    unsigned present = 0, missing = 0;
    const size_t count = sizeof(targets)/sizeof(targets[0]);
    puts("IPA_TOTAL_V109_NONPRIVILEGED_DYLD_READONLY");
    for (size_t i = 0; i < count; i++) {
        const struct Target *t = &targets[i];
        (void)dlerror();
        void *handle = dlopen(t->path, RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) {
            ++missing;
            printf("%s | DLOPEN=ABSENT_OR_UNAVAILABLE | SYMBOL=UNVERIFIED\n", t->category);
            continue;
        }
        ++present;
        /* Do not call symbol functions. dlsym only: no Swift ABI guessing. */
        (void)dlerror();
        void *symbol = dlsym(handle, t->symbol);
        printf("%s | DLOPEN=PASS | SYMBOL=%s\n", t->category,
               symbol ? "PRESENT" : "NOT_FOUND_IN_IMAGE");
        dlclose(handle);
    }
    printf("V109_DYLD_AUDIT_DONE targets=%zu dlopen_pass=%u dlopen_unavailable=%u\n",
           count, present, missing);
    return 0;
}
