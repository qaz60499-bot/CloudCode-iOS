/*
 * V141: Apple-SDK-compiled independent macOS loader client.
 *
 * This deliberately imports only the two *actual* AVFAudio NSString globals
 * used by the official encrypted ChatGPT image.  No ChatGPT code, microphone,
 * device privileges, class messages, or audio calls.
 */
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>

static int Check(const char *mode, NSString *value, const char *symbol,
                 const void *slot, const char *expected) {
    Dl_info info = {0};
    if (value == nil || ![value isEqualToString:[NSString stringWithUTF8String:expected]]) {
        fprintf(stderr, "wrong value for %s\n", symbol);
        return 3;
    }
    if (dladdr(slot, &info) == 0 || info.dli_fname == NULL) {
        fprintf(stderr, "no resolved provider for %s\n", symbol);
        return 4;
    }
    const bool candidate = strstr(info.dli_fname, "libV141AVAudioConstants.dylib") != NULL;
    if (candidate != (strcmp(mode, "candidate") == 0)) {
        fprintf(stderr, "wrong provider for %s: %s\n", symbol, info.dli_fname);
        return 5;
    }
    printf("%s | %s | %s\n", symbol, [value UTF8String], info.dli_fname);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "apple") != 0 &&
                          strcmp(argv[1], "candidate") != 0)) {
            fprintf(stderr, "usage: client apple|candidate\n");
            return 2;
        }
        /* Preserve the original provider's actual strong imports at link time. */
        int first = Check(argv[1], AVAudioApplicationInputMuteStateChangeNotification,
             "AVAudioApplicationInputMuteStateChangeNotification",
             (const void *)&AVAudioApplicationInputMuteStateChangeNotification,
             "AVAudioApplicationInputMuteStateChangeNotification");
        if (first != 0) return first;
        return Check(argv[1], AVAudioApplicationMuteStateKey,
             "AVAudioApplicationMuteStateKey",
             (const void *)&AVAudioApplicationMuteStateKey,
             "AVAudioApplicationMuteStateKey");
    }
}
