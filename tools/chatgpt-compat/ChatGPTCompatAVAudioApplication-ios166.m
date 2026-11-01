/*
 * IPA Total -- AVAudioApplication iOS 16.6 compatibility candidate.
 *
 * This file implements the iOS 17+ microphone PERMISSION surface using the
 * actual iOS 16 AVAudioSession system permission API. It intentionally does
 * not pretend iOS 16 can apply AVAudioApplication's newer per-app input mute:
 * setting mute must fail with NSError until equivalent media-path semantics
 * have been demonstrated on a device.
 *
 * Research library only. NOT an installable ChatGPT build.
 */
#import <Foundation/Foundation.h>
#import <AVFAudio/AVAudioSession.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const IPACompatAudioErrorDomain = @"IPACompatAVAudioApplication";
enum { IPACompatAudioErrorUnsupportedInputMute = 1 };
/* V137 independently observed these exact exported NSString values by dlsym
 * against Apple AVFAudio on macOS 15.8.2. They are notification NAME metadata,
 * not evidence that iOS 16 generates corresponding input-mute events. The
 * adapter still refuses input mute and never synthesizes a false notification.
 * Provider routing, device runtime behavior and event semantics remain open. */
NSNotificationName const AVAudioApplicationInputMuteStateChangeNotification =
    @"AVAudioApplicationInputMuteStateChangeNotification";
NSString *const AVAudioApplicationMuteStateKey = @"AVAudioApplicationMuteStateKey";

@interface AVAudioApplication : NSObject
+ (instancetype)sharedInstance;
+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL granted))response;
@property(nonatomic, readonly) NSInteger recordPermission;
/* isInputMuted intentionally unavailable: iOS16 has no reliable app-wide query. */
- (BOOL)setInputMuted:(BOOL)muted error:(NSError * _Nullable * _Nullable)error;
@end

@implementation AVAudioApplication

+ (instancetype)sharedInstance {
    static AVAudioApplication *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL))response {
    if (response == nil) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Always asks the system. Never claims permission without a system answer.
    [[AVAudioSession sharedInstance] requestRecordPermission:response];
#pragma clang diagnostic pop
}

- (NSInteger)recordPermission {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Apple's enums have identical documented 'undt', 'deny', 'grnt'
    // values. Preserve the actual system permission, not a boolean guess.
    return (NSInteger)[AVAudioSession sharedInstance].recordPermission;
#pragma clang diagnostic pop
}

- (BOOL)setInputMuted:(BOOL)muted error:(NSError **)error {
    // iOS16 has no verified equivalent for app-level audio-input muting.
    // Reject BOTH requests: treating an unmute request as successful could
    // conceal another audio client's actual mute state.
    (void)muted;
    if (error != NULL) {
        *error = [NSError errorWithDomain:IPACompatAudioErrorDomain
                                     code:IPACompatAudioErrorUnsupportedInputMute
                                 userInfo:@{
             NSLocalizedDescriptionKey:
                 @"iOS 16.6 cannot provide AVAudioApplication per-app input mute; refusing to report success."
         }];
    }
    return NO;
}

@end
NS_ASSUME_NONNULL_END
