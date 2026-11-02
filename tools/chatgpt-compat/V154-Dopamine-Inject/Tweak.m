/*
 * V154: strict-target rootless ElleKit constructor PRELOAD PROOF, NOT a complete
 * API compatibility shim and NOT an official app patch.
 *
 * The installable Filter.plist matches ONLY the V150 self-authored research app.
 * A second offline-only compiler configuration (IPA_V154_OFFICIAL=1) allows
 * independent arm64 syntax/ABI checking of an exact 1.2026.286 version gate,
 * without making an installable package or targeting the installed 1.2024.348.
 *
 * Nothing is written to disk, no process is killed, and no dyld/internal
 * SpringBoard/fairplay APIs are modified.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if defined(IPA_V154_OFFICIAL) && IPA_V154_OFFICIAL
#define IPA_V154_ID @"com.openai.chat"
#define IPA_V154_VERSION @"1.2026.286"
#else
#define IPA_V154_ID @"cc.guess.ipatotal.swiftabi.v150"
#define IPA_V154_VERSION @"0.0.150"
#endif

static int gIPACompatV154State = 0;

// An exported read-only probe entry, never an install/hook control channel.
__attribute__((visibility("default")))
int IPACompatV154InjectionState(void) { return gIPACompatV154State; }

static BOOL IPACompatV154ExactTarget(NSString * _Nullable bundle,
                                    NSString * _Nullable version) {
    return bundle != nil && version != nil &&
        [bundle isEqualToString:IPA_V154_ID] &&
        [version isEqualToString:IPA_V154_VERSION];
}

__attribute__((constructor))
static void IPACompatV154Bootstrap(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        if (!IPACompatV154ExactTarget(bundle.bundleIdentifier,
                         [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"])) {
            // This must never touch the user's old com.openai.chat 1.2024.348.
            return;
        }
        gIPACompatV154State = 1;
#if defined(IPA_V154_OFFICIAL) && IPA_V154_OFFICIAL
        // A correct target-version check does NOT prove FairPlay execution,
        // pre-main dyld closure, or full Apple API semantics. Strictly inert
        // until a separately audited and explicitly enabled official provider
        // is available. Do not load the V140 incomplete AVAudio shim.
        NSLog(@"IPACompatV154 OFFICIAL VERSION GUARD PASSED; no hooks enabled");
#else
        // A unique, non-Apple ObjC class is a safe observer of actual injected
        // constructor execution. Never register an Apple/framework class name.
        if (objc_getClass("IPACompatV154ProbeMarker") != Nil) {
            NSLog(@"IPACompatV154 test marker already exists; no duplicate");
            return;
        }
        Class cls = objc_allocateClassPair([NSObject class],
                                           "IPACompatV154ProbeMarker", 0);
        if (cls == Nil) {
            NSLog(@"IPACompatV154 class allocation refused");
            return;
        }
        objc_registerClassPair(cls);
        gIPACompatV154State = 2;
        // AVFAudio is observed only: no new classes, no recording or requests.
        void *audio = dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio",
                             RTLD_LAZY | RTLD_LOCAL);
        if (audio) {
            Class apple = objc_getClass("AVAudioApplication");
            NSLog(@"IPACompatV154 TEST injected marker registered; AVAudioApplication=%@",
                  apple ? @"present" : @"absent");
            dlclose(audio);
        } else {
            NSLog(@"IPACompatV154 TEST marker registered; system AVFAudio not loadable");
        }
#endif
    }
}
