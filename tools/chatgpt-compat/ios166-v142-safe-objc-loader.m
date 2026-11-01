/*
 * V142 collision-safe ObjC ABI loader. Independent self-written host only.
 * A same-name AVAudioApplication already in the runtime MUST block dlopen:
 * ObjC's duplicate-class winner is nondeterministic.
 * Safe to compile for macOS arm64 and iphoneos arm64. Does not request audio,
 * alter the system, inspect user data, or invoke the app under study.
 *
 * argv: <candidate dylib> <expected class>
 * Exit 0 = class introduced by this candidate and four method ABIs match;
 * 20 = class already exists (candidate NEVER dlopened); 23 = ABI mismatch;
 * 24 = loader/class owner failure. Never label 0 as official app success.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>

typedef struct {
    const char *name;
    BOOL isClass;
    const char *ret;
    const char *args[4];
    unsigned count;
} Expected;
static const Expected kMethods[] = {
    {"sharedInstance", YES, "@", {"@", ":"}, 2},
    {"requestRecordPermissionWithCompletionHandler:", YES, "v", {"@", ":", "@?"}, 3},
    {"recordPermission", NO, "q", {"@", ":"}, 2},
    {"setInputMuted:error:", NO, "B", {"@", ":", "B", "^@"}, 4},
};
static BOOL EqType(const char *actual, const char *expected) {
    return actual != NULL && strcmp(actual, expected) == 0;
}
static BOOL CheckMethod(Class cls, const Expected *spec) {
    SEL selector = sel_registerName(spec->name);
    Method method = spec->isClass ? class_getClassMethod(cls, selector)
                                  : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != spec->count)
        return NO;
    char *ret = method_copyReturnType(method);
    BOOL valid = EqType(ret, spec->ret);
    free(ret);
    for (unsigned i = 0; valid && i < spec->count; i++) {
        char *arg = method_copyArgumentType(method, i);
        valid = EqType(arg, spec->args[i]);
        free(arg);
    }
    return valid;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || argv[1][0] != '/' || argv[2][0] == '\0') return 2;
        const char *libPath = argv[1], *className = argv[2];
        // Explicitly load the system's AVFAudio before checking the class:
        // merely querying objc_getClass in a process that has not yet loaded
        // the framework is insufficient to rule out collisions.
        void *system = dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio",
                             RTLD_NOW | RTLD_LOCAL);
        if (system == NULL) {
            fprintf(stderr, "BLOCKED_SYSTEM_AVFAUDIO_NOT_LOADABLE: %s\n", dlerror());
            return 21;
        }
        Class existing = objc_getClass(className);
        if (existing != Nil) {
            const char *owner = class_getImageName(existing);
            fprintf(stderr, "BLOCKED_DUPLICATE_OBJC_CLASS name=%s existingOwner=%s; candidate NOT LOADED\n",
                    className, owner != NULL ? owner : "(unknown)");
            return 20;
        }
        void *candidate = dlopen(libPath, RTLD_NOW | RTLD_LOCAL);
        if (candidate == NULL) {
            fprintf(stderr, "BLOCKED_DLOPEN %s\n", dlerror());
            return 22;
        }
        Class cls = objc_getClass(className);
        const char *owner = cls != Nil ? class_getImageName(cls) : NULL;
        Dl_info metadata = {0};
        // Verify owner using class image and dladdr; a class from another image
        // cannot be accepted as a successful provider.
        if (cls == Nil || owner == NULL || dladdr((const void *)cls, &metadata) == 0 ||
            metadata.dli_fname == NULL || strcmp(owner, libPath) != 0) {
            fprintf(stderr, "BLOCKED_CLASS_PROVIDER_MISMATCH class=%s owner=%s\n",
                    className, owner != NULL ? owner : "(none)");
            return 24;
        }
        for (unsigned i = 0; i < sizeof(kMethods)/sizeof(kMethods[0]); i++) {
            if (!CheckMethod(cls, &kMethods[i])) {
                fprintf(stderr, "FAIL_OBJC_METHOD_ABI selector=%s\n", kMethods[i].name);
                return 23;
            }
        }
        printf("PASS_ISOLATED_OBJC_CLASS_OWNER_AND_4_METHOD_ABIS class=%s image=%s\n", className, owner);
        dlclose(candidate);
        dlclose(system);
        return 0;
    }
}
